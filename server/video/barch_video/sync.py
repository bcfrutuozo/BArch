"""Audio alignment between a movie file and a donor release, and the mux that follows.

The movie (the 4K HEVC file Radarr imported, in the original language) is the reference. The donor is
another release of the same movie that carries what the reference lacks: a PT-BR audio track, subtitles.
Both are decoded to 8 kHz mono; the donor's timeline is mapped onto the reference's by cross-correlation
in windows spread over the whole film:

  coarse   the onset envelope (energy rise in 200-3000 Hz, 100 frames/s) of a donor window against a wide
           stretch of the reference: finds the offset to 10 ms even between a dub and the original, since
           music, effects and room tone are the same in both mixes
  fine     the waveforms around the coarse offset, to the sample (only trusted when it agrees)

The offsets of the windows are fitted as  ref_time = offset + speed * donor_time  for each known speed
(1, PAL 25/23.976, 24/23.976 and their inverses). A constant fit over (nearly) every window is a match;
windows that disagree in a run are a different cut (a scene added or missing), which is reported and
never muxed. The donor tracks are then muxed into a copy of the reference with mkvmerge, delayed by the
offset; a PAL donor's audio is first re-timed with ffmpeg (atempo) and its subtitles get mkvmerge's
ratio sync. The result is checked once more the same way before it may replace anything.
"""
from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
from scipy.signal import fftconvolve, stft

SR = 8000           # decode rate
ENV_RATE = 100      # envelope frames per second (hop of 80 samples)
WINDOW_S = 120      # donor window length
SEARCH_S = 120      # wide search radius: the first window, and any window the narrow search cannot place
NEAR_S = 3          # narrow search radius around the offset found so far
MIN_CONF = 1.3      # envelope peak over the next best peak (outside +-0.5 s) for a window to count at all;
                    # the real test is agreement: random placements never fall within TOLERANCE of each other
TOLERANCE = 0.040   # windows within 40 ms of each other share one offset
SPEEDS = {"1": 1.0, "pal": 25 / (24000 / 1001), "pal-inverse": (24000 / 1001) / 25,
          "24": 24 / (24000 / 1001), "24-inverse": (24000 / 1001) / 24}
# the envelope ignores the voice band: a dub changes the dialogue, not the music, effects and room tone
BANDS = ((40, 250), (3000, 3990))


def probe(path: str | Path) -> dict:
    out = subprocess.run(["ffprobe", "-v", "error", "-show_format", "-show_streams", "-of", "json", str(path)],
                         capture_output=True, text=True, timeout=300)
    if out.returncode:
        raise RuntimeError(f"ffprobe {path}: {out.stderr.strip()[:300]}")
    return json.loads(out.stdout)


def lang(stream: dict) -> str:
    return stream.get("tags", {}).get("language", "und")


def decode(path: str | Path, index: int, sr: int = SR) -> np.ndarray:
    """One audio stream (absolute ffprobe index), whole length, mono at `sr`, as float32. A track that
    starts late (a delay in the container) is padded from 0, so the samples sit on the file's clock."""
    p = subprocess.run(["ffmpeg", "-v", "error", "-nostdin", "-i", str(path), "-map", f"0:{index}",
                        "-af", "aresample=async=1:first_pts=0", "-ac", "1", "-ar", str(sr), "-f", "s16le", "-"],
                       capture_output=True, timeout=7200)
    if p.returncode or not p.stdout:
        raise RuntimeError(f"ffmpeg decode {path} #{index}: {p.stderr.decode(errors='replace')[-300:]}")
    return np.frombuffer(p.stdout, dtype=np.int16).astype(np.float32) / 32768


def envelope(x: np.ndarray, chunk_s: int = 300) -> np.ndarray:
    """Spectral flux at ENV_RATE over BANDS (log-spaced sub-bands, positive changes summed), computed in
    chunks so a whole film never needs the full spectrogram in memory."""
    nper, hop = 256, SR // ENV_RATE
    edges = np.geomspace(40, 3990, 25)
    out = []
    step = chunk_s * SR
    prev_last = None
    for s in range(0, len(x), step):
        seg = x[s: s + step + nper]
        if len(seg) < nper:
            break
        f, _, z = stft(seg, fs=SR, nperseg=nper, noverlap=nper - hop, boundary=None, padded=False)
        p = np.log1p(np.abs(z) * 50).astype(np.float32)
        rows = []
        for lo, hi in zip(edges[:-1], edges[1:]):
            if any(lo >= a and hi <= b for a, b in BANDS):
                sel = (f >= lo) & (f < hi)
                if sel.any():
                    rows.append(p[sel].mean(axis=0))
        band = np.vstack(rows)[:, : step // hop]
        first = band[:, :1] if prev_last is None else prev_last
        out.append(np.maximum(np.diff(band, axis=1, prepend=first), 0).sum(axis=0))
        prev_last = band[:, -1:]
    return np.concatenate(out).astype(np.float32) if out else np.zeros(0, np.float32)


def _xcorr(needle: np.ndarray, hay: np.ndarray, rate: int) -> tuple[float, float]:
    """Where `needle` sits in `hay` (in samples, sub-sample by a parabola through the peak) and how much
    the best peak beats the next one outside half a second."""
    if len(needle) < rate or len(hay) < len(needle):
        return 0.0, 0.0
    a = (needle - needle.mean()) / (needle.std() or 1)
    b = (hay - hay.mean()) / (hay.std() or 1)
    c = fftconvolve(b, a[::-1], mode="valid")
    k = int(np.argmax(c))
    m = np.abs(c)
    w = rate // 2
    rest = np.concatenate([m[: max(0, k - w)], m[k + w:]])
    conf = float(c[k] / rest.max()) if rest.size and rest.max() > 0 else 0.0
    frac = 0.0
    if 0 < k < len(c) - 1:
        y0, y1, y2 = c[k - 1], c[k], c[k + 1]
        d = y0 - 2 * y1 + y2
        frac = float(0.5 * (y0 - y2) / d) if d else 0.0
    return k + max(-0.5, min(0.5, frac)), conf


@dataclass
class Window:
    donor_t: float          # start of the window on the donor's own clock (s)
    offset: float           # ref_time - speed * donor_time at that window (s)
    conf: float


@dataclass
class Alignment:
    ok: bool
    offset: float = 0.0                      # seconds to add to the donor's (speed-scaled) timestamps
    speed: str = "1"                         # key of SPEEDS
    windows: list[Window] = field(default_factory=list)
    agreeing: int = 0
    counted: int = 0
    reason: str = ""
    segments: list[dict] = field(default_factory=list)   # runs of windows sharing one offset (cuts)

    def summary(self) -> str:
        if self.ok:
            return (f"offset {self.offset * 1000:+.0f} ms, speed {self.speed}, "
                    f"{self.agreeing}/{len(self.windows)} windows agree")
        return self.reason

    def to_dict(self) -> dict:
        return {"ok": self.ok, "offset_ms": round(self.offset * 1000), "speed": self.speed,
                "agreeing": self.agreeing, "windows": len(self.windows), "reason": self.reason,
                "segments": [{**s, "offset_ms": round(s["offset"] * 1000)} for s in self.segments],
                "detail": [{"t": round(w.donor_t), "offset_ms": round(w.offset * 1000), "conf": round(w.conf, 2)}
                           for w in self.windows]}


def _place(needle: np.ndarray, ref_env: np.ndarray, t: float, centre: float, radius: float) -> tuple[float, float]:
    lo = max(0, int((t + centre - radius) * ENV_RATE))
    hi = min(len(ref_env), int((t + centre + WINDOW_S + radius) * ENV_RATE))
    k, conf = _xcorr(needle, ref_env[lo:hi], ENV_RATE)
    return (lo + k) / ENV_RATE - t, conf


def windows(ref_env: np.ndarray, don_env: np.ndarray, speed: float = 1.0, count: int = 12) -> list[Window]:
    """The offset at `count` windows spread over the donor, its envelope first put on the reference's clock
    (stretched by `speed`). Each window is looked for near the offset found so far; when it is not there
    (a cut), it is looked for again over the wide radius."""
    if speed != 1.0:
        idx = np.arange(0, int(len(don_env) * speed)) / speed
        don_env = np.interp(idx, np.arange(len(don_env)), don_env).astype(np.float32)
    dur = len(don_env) / ENV_RATE
    margin = dur * 0.03
    starts = np.linspace(margin, max(margin, dur - WINDOW_S - margin), count)
    out: list[Window] = []
    last = None
    for t in starts:
        needle = don_env[int(t * ENV_RATE): int((t + WINDOW_S) * ENV_RATE)]
        if last is not None:
            off, conf = _place(needle, ref_env, t, last, NEAR_S)
            if conf < MIN_CONF:
                off2, conf2 = _place(needle, ref_env, t, last, SEARCH_S)
                if conf2 > conf:
                    off, conf = off2, conf2
        else:
            off, conf = _place(needle, ref_env, t, 0.0, SEARCH_S)
        if conf == 0.0:
            continue
        out.append(Window(donor_t=float(t / speed), offset=float(off), conf=conf))
        if conf >= MIN_CONF:
            last = off
    return out


def fit(ws: list[Window]) -> tuple[float, int, int, list[dict]]:
    """The offset most windows share (the largest cluster within TOLERANCE), how many share it, how many
    count at all, and the runs of consecutive windows sharing an offset (more than one run = cuts)."""
    counted = [w for w in ws if w.conf >= MIN_CONF]
    if not counted:
        return 0.0, 0, 0, []
    best: list[Window] = []
    for w in counted:
        near = [v for v in counted if abs(v.offset - w.offset) <= TOLERANCE]
        if len(near) > len(best):
            best = near
    off = float(np.median([w.offset for w in best]))
    runs: list[dict] = []
    for w in counted:
        if runs and abs(w.offset - runs[-1]["offset"]) <= TOLERANCE:
            r = runs[-1]
            r["to"], r["n"] = w.donor_t, r["n"] + 1
        else:
            runs.append({"from": w.donor_t, "to": w.donor_t, "offset": w.offset, "n": 1})
    return off, len(best), len(counted), runs


def align_pcm(ref_pcm: np.ndarray, don_pcm: np.ndarray, count: int = 12) -> Alignment:
    ref_env, don_env = envelope(ref_pcm), envelope(don_pcm)
    ratio = len(don_pcm) / max(1, len(ref_pcm))
    best: Alignment | None = None
    for name, speed in SPEEDS.items():
        # a speed is only tried when the lengths allow it (within 2 % once scaled: credits, logos)
        if name != "1" and abs(ratio * speed - 1) > 0.02:
            continue
        ws = windows(ref_env, don_env, speed, count)
        off, agree, counted, runs = fit(ws)
        a = Alignment(ok=False, offset=off, speed=name, windows=ws, agreeing=agree, counted=counted, segments=runs)
        if best is None or a.agreeing > best.agreeing:
            best = a
    assert best is not None
    need = max(5, int(np.ceil(0.75 * count)))
    big_runs = [r for r in best.segments if r["n"] >= 2]
    if best.agreeing >= need and len(big_runs) <= 1:
        best.ok = True
    elif len(big_runs) >= 2:
        best.reason = "the offset changes along the film (another cut): " + ", ".join(
            f"{r['from'] / 60:.0f}-{r['to'] / 60:.0f} min at {r['offset'] * 1000:+.0f} ms" for r in big_runs)
    else:
        best.reason = (f"no common offset: {best.agreeing}/{count} windows agree (need {need}); "
                       f"another master or another film")
    return best


def align(ref: str | Path, ref_index: int, donor: str | Path, donor_index: int, count: int = 12) -> Alignment:
    """Map the donor's timeline onto the reference's, comparing one audio stream of each."""
    return align_pcm(decode(ref, ref_index), decode(donor, donor_index), count)


# ---------------------------------------------------------------------------------------------- mux

ISO_ALIASES = {"pob": "por", "pt": "por", "ptb": "por", "en": "eng", "ger": "deu", "fre": "fra", "dut": "nld",
               "chi": "zho", "cze": "ces", "gre": "ell", "ice": "isl", "nob": "nor"}


def norm_lang(code: str) -> str:
    code = (code or "und").lower()
    return ISO_ALIASES.get(code, code)


def mkvmerge_ids(path: str | Path) -> dict:
    p = subprocess.run(["mkvmerge", "-J", str(path)], capture_output=True, text=True, timeout=300)
    if p.returncode > 1:
        raise RuntimeError(f"mkvmerge -J {path}: {p.stdout[-300:]}")
    return json.loads(p.stdout)


@dataclass
class MuxPlan:
    ref: str
    donor: str
    original: list[str]              # language codes of the original audio (ISO 639-2/B or T)
    alignment: Alignment
    keep_subs: list[str] = field(default_factory=lambda: ["por", "eng"])
    out: str = ""
    log: list[str] = field(default_factory=list)


def mux(plan: MuxPlan, workdir: str | Path | None = None) -> Path:
    """Write <ref stem>.barch.mkv next to the reference: the reference's video, its audio in the original
    language (other languages dropped, the original first and default), its subtitles in `keep_subs`, and
    from the donor every Portuguese audio track and every subtitle in `keep_subs` it has that the reference
    lacks, all delayed by the offset (a PAL donor's audio re-timed first). Nothing is replaced here."""
    ref, donor, a = Path(plan.ref), Path(plan.donor), plan.alignment
    if not a.ok:
        raise ValueError("refusing to mux an alignment that did not match: " + a.reason)
    orig = {norm_lang(x) for x in plan.original}
    keep_subs = {norm_lang(x) for x in plan.keep_subs}
    ri, di = mkvmerge_ids(ref), mkvmerge_ids(donor)
    tracks = lambda info, kind: [t for t in info["tracks"] if t["type"] == kind]
    tlang = lambda t: norm_lang(t["properties"].get("language", "und"))

    ref_audio = [t for t in tracks(ri, "audio") if tlang(t) in orig]
    if not ref_audio:
        raise ValueError(f"the reference has no audio in {sorted(orig)}")
    ref_subs = [t for t in tracks(ri, "subtitles") if tlang(t) in keep_subs]
    have_subs = {tlang(t) for t in ref_subs}
    don_audio = [t for t in tracks(di, "audio") if tlang(t) == "por"]
    if not don_audio:
        raise ValueError("the donor has no Portuguese audio track")
    don_subs = [t for t in tracks(di, "subtitles") if tlang(t) in keep_subs and tlang(t) not in have_subs]

    tmp = Path(tempfile.mkdtemp(prefix="barch-mux-", dir=workdir))
    out = ref.with_name(ref.stem + ".barch.mkv")
    plan.out = str(out)
    delay_ms = round(a.offset * 1000)
    speed = SPEEDS[a.speed]
    try:
        donor_src = donor
        if speed != 1.0:
            # PAL and friends: the donor plays faster or slower; re-time its Portuguese audio with atempo
            # (pitch kept) into a small mka, the subtitles get mkvmerge's ratio sync below
            mka = tmp / "por.mka"
            maps, codecs = [], []
            for n, t in enumerate(don_audio):
                ch = t["properties"].get("audio_channels", 2)
                maps += ["-map", f"0:{t['id']}"]
                codecs += [f"-c:a:{n}", "eac3", f"-b:a:{n}", "640k" if ch > 2 else "224k",
                           f"-metadata:s:a:{n}", "language=por"]
            cmd = ["ffmpeg", "-v", "error", "-nostdin", "-i", str(donor), *maps, "-af", f"atempo={1 / speed:.8f}",
                   *codecs, str(mka)]
            subprocess.run(cmd, check=True, timeout=7200)
            plan.log.append(f"donor audio re-timed by {1 / speed:.6f} (speed {a.speed})")
            donor_src = mka
            dsrc_audio = [{"id": n, "properties": t["properties"]} for n, t in enumerate(don_audio)]
        else:
            dsrc_audio = don_audio

        cmd = ["mkvmerge", "-q", "-o", str(out)]
        # the reference: video + original audio + kept subtitles, nothing else
        cmd += ["--audio-tracks", ",".join(str(t["id"]) for t in ref_audio)]
        cmd += ["--subtitle-tracks", ",".join(str(t["id"]) for t in ref_subs)] if ref_subs else ["--no-subtitles"]
        for n, t in enumerate(ref_audio):
            cmd += ["--default-track-flag", f"{t['id']}:{'1' if n == 0 else '0'}"]
        for t in ref_subs:
            cmd += ["--default-track-flag", f"{t['id']}:0"]
        cmd += ["--no-attachments", "--no-global-tags", str(ref)]
        # the donor (or its re-timed audio): Portuguese audio, missing subtitles, delayed by the offset
        cmd += ["--no-video", "--no-attachments", "--no-chapters", "--no-global-tags"]
        cmd += ["--audio-tracks", ",".join(str(t["id"]) for t in dsrc_audio)]
        for t in dsrc_audio:
            cmd += ["--sync", f"{t['id']}:{delay_ms}", "--language", f"{t['id']}:pt-BR",
                    "--default-track-flag", f"{t['id']}:0",
                    "--track-name", f"{t['id']}:Português (Brasil)"]
        if donor_src is donor and don_subs:
            cmd += ["--subtitle-tracks", ",".join(str(t["id"]) for t in don_subs)]
            for t in don_subs:
                cmd += ["--sync", f"{t['id']}:{delay_ms}", "--default-track-flag", f"{t['id']}:0"]
                if tlang(t) == "por":
                    cmd += ["--language", f"{t['id']}:pt-BR"]
        else:
            cmd += ["--no-subtitles"]
        cmd += [str(donor_src)]
        if donor_src is not donor and don_subs:   # subtitles straight from the donor, ratio-synced
            cmd += ["--no-video", "--no-audio", "--no-attachments", "--no-chapters", "--no-global-tags",
                    "--subtitle-tracks", ",".join(str(t["id"]) for t in don_subs)]
            for t in don_subs:
                cmd += ["--sync", f"{t['id']}:{delay_ms},{speed:.8f}", "--default-track-flag", f"{t['id']}:0"]
                if tlang(t) == "por":
                    cmd += ["--language", f"{t['id']}:pt-BR"]
            cmd += [str(donor)]
        plan.log.append(" ".join(cmd))
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=7200)
        if p.returncode > 1:   # 1 = warnings
            out.unlink(missing_ok=True)
            raise RuntimeError("mkvmerge failed: " + (p.stdout + p.stderr)[-500:])
        if p.stdout.strip():
            plan.log.append("mkvmerge: " + p.stdout.strip()[-500:])
        return out
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def verify(muxed: str | Path, original: list[str], count: int = 8) -> Alignment:
    """The muxed file against itself: its Portuguese track must sit on its original track at offset ~0."""
    info = probe(muxed)
    audio = [s for s in info["streams"] if s["codec_type"] == "audio"]
    orig = {norm_lang(x) for x in original}
    o = next((s for s in audio if norm_lang(lang(s)) in orig), None)
    p = next((s for s in audio if norm_lang(lang(s)) == "por"), None)
    if o is None or p is None:
        return Alignment(ok=False, reason="the muxed file lacks the original or the Portuguese track")
    a = align(muxed, o["index"], muxed, p["index"], count)
    if a.ok and abs(a.offset) > 0.040:
        a.ok, a.reason = False, f"the Portuguese track ended up {a.offset * 1000:+.0f} ms off"
    return a
