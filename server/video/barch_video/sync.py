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
import re
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
MIN_CONF = 1.3      # envelope peak over the next best peak (outside +-0.5 s): a confident window; the real
                    # test is agreement, random placements never fall within TOLERANCE of each other
STRONG_CONF = 1.8   # a window this confident at another offset than the rest is a cut, not noise
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
    """One audio stream (absolute ffprobe index), whole length, mono at `sr`, as float32, on the file's
    absolute clock: -copyts keeps the container's timestamps (a file or track that starts at 2.5 s
    stays there, as mkvmerge sees it) and the resampler pads from 0 up to the first sample."""
    p = subprocess.run(["ffmpeg", "-v", "error", "-nostdin", "-copyts", "-i", str(path), "-map", f"0:{index}",
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


def fit(ws: list[Window]) -> tuple[float, list[Window], list[Window]]:
    """The offset most windows share (the largest group within TOLERANCE of each other, whatever their
    confidence: a wrong placement lands there by chance about once in a few thousand), that group, and
    the confident windows outside it (each one is a part of the film at another offset: a cut)."""
    if not ws:
        return 0.0, [], []
    best: list[Window] = []
    for w in ws:
        near = [v for v in ws if abs(v.offset - w.offset) <= TOLERANCE]
        if len(near) > len(best) or (len(near) == len(best) and sum(v.conf for v in near) > sum(v.conf for v in best)):
            best = near
    off = float(np.median([w.offset for w in best]))
    outside = [w for w in ws if w not in best and w.conf >= STRONG_CONF]
    return off, best, outside


def align_pcm(ref_pcm: np.ndarray, don_pcm: np.ndarray, count: int = 12, expect: float | None = None) -> Alignment:
    """Map the donor onto the reference. `expect` (seconds) checks a known offset instead of finding one
    (the muxed file against itself: 0)."""
    ref_env, don_env = envelope(ref_pcm), envelope(don_pcm)
    ratio = len(don_pcm) / max(1, len(ref_pcm))
    need = max(5, int(np.ceil(0.75 * count)))
    best: Alignment | None = None
    for name, speed in SPEEDS.items():
        # a speed is only tried when the lengths allow it (within 2 % once scaled: credits, logos)
        if expect is not None and name != "1":
            continue
        if name != "1" and abs(ratio * speed - 1) > 0.02:
            continue
        ws = windows(ref_env, don_env, speed, count)
        if expect is not None:
            group = [w for w in ws if abs(w.offset - expect) <= TOLERANCE]
            off = float(np.median([w.offset for w in group])) if group else expect
            outside = [w for w in ws if w not in group and w.conf >= STRONG_CONF]
        else:
            off, group, outside = fit(ws)
        firm = sum(1 for w in group if w.conf >= MIN_CONF)
        a = Alignment(ok=False, offset=off, speed=name, windows=ws, agreeing=len(group), counted=firm)
        a.segments = [{"from": w.donor_t, "to": w.donor_t, "offset": w.offset, "n": 1} for w in outside]
        if group:
            a.segments.insert(0, {"from": min(w.donor_t for w in group), "to": max(w.donor_t for w in group),
                                  "offset": off, "n": len(group)})
        if best is None or (a.agreeing, a.counted) > (best.agreeing, best.counted):
            best = a
    assert best is not None
    outside = best.segments[1:]
    second = max((sum(1 for v in outside if abs(v["offset"] - w["offset"]) <= TOLERANCE) for w in outside), default=0)
    cut = "the offset changes along the film (another cut): " + ", ".join(
        f"{w['from'] / 60:.0f} min at {w['offset'] * 1000:+.0f} ms" for w in outside) + \
        f" while {best.agreeing} windows are at {best.offset * 1000:+.0f} ms"
    if second >= 2:
        best.reason = cut
    elif best.agreeing < need:
        best.reason = (f"no common offset: {best.agreeing}/{count} windows agree (need {need}); "
                       f"another master or another film")
    elif best.counted < max(3, need // 2):
        best.reason = f"the windows agree but too few clearly ({best.counted} confident): mostly silence?"
    elif outside:
        best.reason = cut
    else:
        best.ok = True
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


PORTUGAL_RE = re.compile(r"(?i)portugal|europe|\bpt[-_ ]?pt\b|\(pt\)")
SDH_RE = re.compile(r"(?i)\bsdh\b|\bcc\b|hearing|deaf|surdos|closed caption")
FORCED_RE = re.compile(r"(?i)forced|for[cç]ad[ao]")
TRIM_VERSION = 2   # bump when the rules below change: done files are checked again


def is_portugal(t: dict) -> bool:
    """A Portuguese track from Portugal (pt-PT tag, or a name saying so), not Brazil's."""
    pr = t["properties"]
    return (pr.get("language_ietf") or "").lower() in ("pt-pt",) or bool(PORTUGAL_RE.search(pr.get("track_name") or ""))


def is_forced(t: dict) -> bool:
    return bool(t["properties"].get("forced_track")) or bool(FORCED_RE.search(t["properties"].get("track_name") or ""))


def is_sdh(t: dict) -> bool:
    return bool(t["properties"].get("flag_hearing_impaired")) or bool(SDH_RE.search(t["properties"].get("track_name") or ""))


def pick_subs(subs: list[dict], keep: set[str], have: set[tuple[str, bool]] = frozenset()) -> list[dict]:
    """Per language in `keep`: one full subtitle and one forced; SDH (sound descriptions) and Portugal's
    Portuguese never, even when they are all there is. `have` = (language, forced) already covered (the
    reference's, when picking a donor's)."""
    tl = lambda t: norm_lang(t["properties"].get("language", "und"))
    out = []
    for lang in sorted(keep):
        cands = [t for t in subs if tl(t) == lang and not is_sdh(t) and not (lang == "por" and is_portugal(t))]
        for forced in (False, True):
            if (lang, forced) in have:
                continue
            pool = [t for t in cands if is_forced(t) == forced]
            pool.sort(key=lambda t: t["id"])
            if pool:
                out.append(pool[0])
    return sorted(out, key=lambda t: t["id"])


@dataclass
class MuxPlan:
    ref: str
    donor: str
    original: list[str]              # language codes of the original audio (ISO 639-2/B or T)
    alignment: Alignment
    keep_subs: list[str] = field(default_factory=lambda: ["por", "eng"])
    ref_audio_pos: list[int] | None = None   # which audio tracks of the reference are the original (by order)
    donor_por_pos: list[int] | None = None   # which audio tracks of the donor are the dub (by order)
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

    ra_all, da_all = tracks(ri, "audio"), tracks(di, "audio")
    ref_audio = ([ra_all[k] for k in plan.ref_audio_pos if k < len(ra_all)] if plan.ref_audio_pos is not None
                 else [t for t in ra_all if tlang(t) in orig])
    if not ref_audio:
        raise ValueError(f"the reference has no audio in {sorted(orig)}")
    ref_subs = pick_subs(tracks(ri, "subtitles"), keep_subs)
    have_subs = {(tlang(t), is_forced(t)) for t in ref_subs}
    don_audio = ([da_all[k] for k in plan.donor_por_pos if k < len(da_all)] if plan.donor_por_pos is not None
                 else [t for t in da_all if tlang(t) == "por"])
    if not don_audio:
        raise ValueError("the donor has no Portuguese audio track")
    don_subs = pick_subs(tracks(di, "subtitles"), keep_subs, have_subs)

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


def verify(muxed: str | Path, orig_pos: int = 0, por_pos: int = 1, count: int = 8) -> Alignment:
    """The muxed file against itself: its Portuguese track (audio number `por_pos`) must sit on its
    original track (audio number `orig_pos`) at offset ~0 all along the film."""
    audio = [s for s in probe(muxed)["streams"] if s["codec_type"] == "audio"]
    if max(orig_pos, por_pos) >= len(audio):
        return Alignment(ok=False, reason="the muxed file lacks the original or the Portuguese track")
    return align_pcm(decode(muxed, audio[orig_pos]["index"]), decode(muxed, audio[por_pos]["index"]),
                     count, expect=0.0)


# --------------------------------------------------------------------------------------------- trim

def trim_plan(path: str | Path, original: list[str], keep_subs: list[str]) -> dict | None:
    """What a file that already has PT-BR carries beyond the rule: audio in other languages, subtitles
    outside `keep_subs`, or a default audio that is not the original. None when there is nothing to do,
    or when it cannot be done safely (not Matroska, no track in the original language or in Portuguese)."""
    path = Path(path)
    if path.suffix.lower() != ".mkv":
        return None
    info = mkvmerge_ids(path)
    orig = {norm_lang(x) for x in original}
    tlang = lambda t: norm_lang(t["properties"].get("language", "und"))
    audio = [t for t in info["tracks"] if t["type"] == "audio"]
    subs = [t for t in info["tracks"] if t["type"] == "subtitles"]
    keep_o = [t for t in audio if tlang(t) in orig]
    keep_p = [t for t in audio if tlang(t) == "por" and not is_portugal(t)]
    if "por" in orig:
        keep_o = [t for t in keep_o if not is_portugal(t)] or keep_o
    if not keep_o or not keep_p:
        return None     # no Brazilian dub (Portugal's only, or none): the pipeline's business, not a trim
    keep_a = keep_o + [t for t in keep_p if t not in keep_o]
    drop_a = [t for t in audio if t not in keep_a]
    keep_s = pick_subs(subs, {norm_lang(x) for x in keep_subs})
    drop_s = [t for t in subs if t not in keep_s]
    default_ok = bool(audio) and audio[0] is keep_o[0] and bool(keep_o[0]["properties"].get("default_track", True)) \
        and not any(t["properties"].get("default_track") for t in keep_a[1:])
    if not drop_a and not drop_s and default_ok:
        return None
    return {"keep_audio": [t["id"] for t in keep_a], "keep_subs": [t["id"] for t in keep_s],
            "drop_audio": [f"{tlang(t)} {t.get('codec', '')}".strip() for t in drop_a],
            "drop_subs": sorted({tlang(t) + (" (Portugal)" if is_portugal(t) else " SDH" if is_sdh(t) else
                                         " forced" if is_forced(t) else "") for t in drop_s}),
            "reorder": not default_ok}


def trim(path: str | Path, plan: dict) -> Path:
    """Write <stem>.barch.mkv next to `path` with the video, the audio in `plan["keep_audio"]` (the original
    first and default) and the subtitles in `plan["keep_subs"]`; chapters kept. Checked (same length, the
    tracks expected) before it is returned; nothing is replaced here."""
    path = Path(path)
    out = path.with_name(path.stem + ".barch.mkv")
    vid = [t["id"] for t in mkvmerge_ids(path)["tracks"] if t["type"] == "video"]
    cmd = ["mkvmerge", "-q", "-o", str(out), "--audio-tracks", ",".join(map(str, plan["keep_audio"]))]
    cmd += ["--subtitle-tracks", ",".join(map(str, plan["keep_subs"]))] if plan["keep_subs"] else ["--no-subtitles"]
    for n, tid in enumerate(plan["keep_audio"]):
        cmd += ["--default-track-flag", f"{tid}:{'1' if n == 0 else '0'}"]
    for tid in plan["keep_subs"]:
        cmd += ["--default-track-flag", f"{tid}:0"]
    cmd += ["--track-order", ",".join(f"0:{t}" for t in vid + plan["keep_audio"] + plan["keep_subs"])]
    cmd += ["--no-attachments", str(path)]
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=7200)
    if p.returncode > 1:
        out.unlink(missing_ok=True)
        raise RuntimeError("mkvmerge failed: " + (p.stdout + p.stderr)[-500:])
    a, b = probe(path), probe(out)
    da, db = float(a["format"].get("duration", 0)), float(b["format"].get("duration", 0))
    na = sum(1 for s in b["streams"] if s["codec_type"] == "audio")
    nv = sum(1 for s in b["streams"] if s["codec_type"] == "video")
    if abs(da - db) > 2 or na != len(plan["keep_audio"]) or nv < 1:
        out.unlink(missing_ok=True)
        raise RuntimeError(f"the trimmed copy did not check out ({db:.0f} s vs {da:.0f} s, {na} audio, {nv} video)")
    return out
