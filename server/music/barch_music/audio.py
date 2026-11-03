"""From a download folder to one FLAC per track: archives extracted, CUE images split, other
lossless formats converted, anything lossy refused. Needs flac, ffmpeg/ffprobe and 7z.

The source folder is never written: everything happens in a work folder, so the torrent keeps
seeding and a failed album can be retried from scratch.
"""
from __future__ import annotations

import json
import re
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

LOSSLESS = {".flac", ".wav", ".ape", ".wv", ".aiff", ".aif", ".m4a", ".alac", ".tta"}
LOSSY = {".mp3", ".aac", ".ogg", ".opus", ".wma", ".mpc", ".mp2"}
ARCHIVES = {".zip", ".rar", ".7z"}
IMAGES = {".jpg", ".jpeg", ".png", ".webp"}


class AudioError(Exception):
    """The download cannot become a clean album; the message says why (for the review queue)."""


@dataclass
class Track:
    path: Path                      # FLAC in the work folder
    disc: int
    index: int                      # position on the disc (1-based), from the CUE or the file order
    samples: int
    rate: int
    bits: int
    hints: dict = field(default_factory=dict)   # what the CUE or the old tags said (title, artist...)

    @property
    def seconds(self) -> float:
        return self.samples / self.rate if self.rate else 0.0


def run(cmd: list[str], timeout: int = 3600) -> subprocess.CompletedProcess:
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise AudioError(f"{Path(cmd[0]).name} failed: {(r.stderr or r.stdout).strip()[-400:]}")
    return r


def probe(path: Path) -> dict:
    """codec, sample rate, bits, channels, samples (exact for FLAC), duration."""
    r = run(["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries",
             "stream=codec_name,sample_rate,channels,bits_per_raw_sample,bits_per_sample,duration_ts,duration"
             ":format=duration", "-of", "json", str(path)], timeout=120)
    d = json.loads(r.stdout)
    s = (d.get("streams") or [{}])[0]
    rate = int(s.get("sample_rate") or 0)
    bits = int(s.get("bits_per_raw_sample") or s.get("bits_per_sample") or 0)
    dur = float(s.get("duration") or (d.get("format") or {}).get("duration") or 0)
    samples = int(s.get("duration_ts") or 0) if s.get("codec_name") == "flac" else 0
    if path.suffix.lower() == ".flac":
        try:                                     # the exact count, from STREAMINFO
            samples = int(run(["metaflac", "--show-total-samples", str(path)], 60).stdout.strip())
        except (AudioError, ValueError):
            pass
    if not samples and rate:
        samples = round(dur * rate)
    return {"codec": s.get("codec_name", ""), "rate": rate, "bits": bits, "channels": int(s.get("channels") or 0),
            "samples": samples, "seconds": samples / rate if rate else dur}


# ---------------------------------------------------------------- CUE sheets

@dataclass
class CueTrack:
    number: int
    file: str
    start: int                      # in CD frames (1/75 s) from the start of its file
    title: str = ""
    performer: str = ""


@dataclass
class Cue:
    path: Path
    tracks: list[CueTrack]
    title: str = ""
    performer: str = ""
    disc: int = 0
    date: str = ""
    genre: str = ""

    @property
    def files(self) -> list[str]:
        return list(dict.fromkeys(t.file for t in self.tracks))


def _read_text(path: Path) -> str:
    raw = path.read_bytes()
    for enc in ("utf-8-sig", "cp1252", "latin-1"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", "replace")


def parse_cue(path: Path) -> Cue:
    cue = Cue(path=path, tracks=[])
    cur_file, cur = "", None
    for line in _read_text(path).splitlines():
        s = line.strip()
        m = re.match(r'^(\w+)\s+(.*)$', s)
        if not m:
            continue
        key, rest = m.group(1).upper(), m.group(2).strip()
        val = rest[1:rest.rindex('"')] if rest.startswith('"') and rest.count('"') >= 2 else rest
        if key == "FILE":
            cur_file = val if rest.startswith('"') else rest.rsplit(" ", 1)[0]
        elif key == "TRACK":
            cur = CueTrack(number=int(rest.split()[0]), file=cur_file, start=-1)
            if "AUDIO" in rest.upper():
                cue.tracks.append(cur)
        elif key == "INDEX" and cur is not None:
            n, t = rest.split()[:2]
            mm, ss, ff = (int(x) for x in t.split(":"))
            if int(n) == 1:
                cur.start = (mm * 60 + ss) * 75 + ff
                # a track belongs to the file its INDEX 01 is in: EAC's cue of split tracks puts
                # the TRACK (and its INDEX 00, the gap) in the previous file, then a new FILE line
                cur.file = cur_file
        elif key == "TITLE":
            if cur is None:
                cue.title = val
            else:
                cur.title = val
        elif key == "PERFORMER":
            if cur is None:
                cue.performer = val
            else:
                cur.performer = val
        elif key == "REM":
            r = re.match(r'^(\w+)\s+"?([^"]*)"?$', rest)
            if r:
                k, v = r.group(1).upper(), r.group(2).strip()
                if k == "DISCNUMBER" and v.split("/")[0].isdigit():
                    cue.disc = int(v.split("/")[0])
                elif k == "DATE":
                    cue.date = v
                elif k == "GENRE":
                    cue.genre = v
    cue.tracks = [t for t in cue.tracks if t.start >= 0]
    return cue


def _resolve(folder: Path, name: str) -> Path | None:
    """The CUE says "Album.wav" and the folder has "Album.flac": match by name, then by stem."""
    p = folder / name
    if p.exists():
        return p
    stem = Path(name).stem.lower()
    for f in folder.iterdir():
        if f.is_file() and f.suffix.lower() in LOSSLESS and f.stem.lower() == stem:
            return f
    return None


# ---------------------------------------------------------------- the work

def _disc_from_path(rel: Path) -> int:
    for part in reversed(rel.parts[:-1]):
        m = re.search(r"\b(?:cd|disc|disk|dvd)\s*[-_ ]?\s*(\d{1,2})\b", part, re.I)
        if m:
            return int(m.group(1))
    return 0


def _to_flac(src: Path, dst: Path, skip: int = 0, until: int = 0) -> None:
    """src (any lossless) -> dst FLAC, optionally only samples [skip, until). FLAC sources go
    through the flac tool (sample exact, keeps 16/24 bit); the rest are decoded to WAV first."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = None
    if src.suffix.lower() == ".flac":
        with open(src, "rb") as fh:
            glued = fh.read(3) == b"ID3"
        if glued:                                    # an image with ID3 glued to it: flac cannot read it
            tmp = dst.with_suffix(".tmp.flac")
            copy_flac(src, tmp)
            src = tmp
    elif src.suffix.lower() != ".flac":
        info = probe(src)
        if info["codec"] in ("aac", "mp3", "vorbis", "opus"):
            raise AudioError(f"{src.name} is {info['codec']}, not lossless")
        tmp = dst.with_suffix(".tmp.wav")
        fmt = "s32" if info["bits"] > 16 else "s16"
        run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", str(src), "-map", "0:a:0",
             "-c:a", "pcm_" + fmt + "le", str(tmp)])
        src = tmp
    cmd = ["flac", "-s", "-f", "-8", "--no-padding", "-o", str(dst)]
    if skip:
        cmd.append(f"--skip={skip}")
    if until:
        cmd.append(f"--until={until}")
    run(cmd + [str(src)])
    if tmp:
        tmp.unlink(missing_ok=True)


def extract_archives(folder: Path, work: Path) -> list[str]:
    """Every zip/rar/7z under folder into work/_extracted/<name>; returns their names."""
    done = []
    for a in sorted(p for p in folder.rglob("*") if p.is_file() and p.suffix.lower() in ARCHIVES):
        if re.search(r"\.part0*[2-9]\d*\.rar$|\.r\d\d$", a.name, re.I):
            continue                                  # later volumes of a multi-part rar
        out = work / "_extracted" / a.stem
        out.mkdir(parents=True, exist_ok=True)
        run(["7z", "x", "-y", "-bd", f"-o{out}", str(a)], timeout=7200)
        done.append(a.name)
    return done


def collect(source: Path, work: Path) -> tuple[list[Track], list[str]]:
    """source folder (or single file) -> (tracks as FLAC in work/tracks, notes for the report)."""
    notes: list[str] = []
    roots = [source]
    if source.is_dir():
        arch = extract_archives(source, work)
        if arch:
            notes.append("extracted: " + ", ".join(arch))
            roots.append(work / "_extracted")
    files = []
    for r in roots:
        files += [p for p in (r.rglob("*") if r.is_dir() else [r]) if p.is_file()]
    lossy = [f for f in files if f.suffix.lower() in LOSSY]
    audio = [f for f in files if f.suffix.lower() in LOSSLESS]
    if lossy and not audio:
        raise AudioError("only lossy audio in the download: " + ", ".join(sorted({f.suffix for f in lossy})))
    if lossy:
        notes.append(f"ignored {len(lossy)} lossy files next to the lossless ones")
    if not audio:
        raise AudioError("no audio files in the download")

    tracks: list[Track] = []
    used: set[Path] = set()
    out = work / "tracks"
    # 1. CUE sheets that describe an image (several tracks in one file): split them
    cues = sorted(f for f in files if f.suffix.lower() == ".cue")
    images = []
    for cpath in cues:
        try:
            cue = parse_cue(cpath)
        except (ValueError, IndexError) as e:
            raise AudioError(f"cannot read {cpath.name}: {e}")
        if not cue.tracks:
            continue
        per_file = {}
        for t in cue.tracks:
            per_file.setdefault(t.file, []).append(t)
        if all(len(v) == 1 for v in per_file.values()) and len(per_file) > 1:
            continue                                  # a CUE of already split tracks: just a hint
        missing = [f for f in cue.files if _resolve(cue.path.parent, f) is None]
        if missing:
            others = [a for a in audio if a.parent == cue.path.parent]
            if len(others) >= len(cue.tracks):        # the image did not come, its tracks did
                notes.append(f"{cue.path.name} describes an image that is not in the download; using the {len(others)} tracks")
                continue
            raise AudioError(f"{cue.path.name} points to {missing[0]!r}, which is not in the download")
        images.append(cue)
    images.sort(key=lambda c: (c.disc or 99, str(c.path)))
    for n, cue in enumerate(images, 1):
        disc = cue.disc or _disc_from_path(cue.path.relative_to(cue.path.anchor)) or n
        for fname in cue.files:
            img = _resolve(cue.path.parent, fname)
            if img is None:
                raise AudioError(f"{cue.path.name} points to {fname!r}, which is not in the download")
            info = probe(img)
            rate = info["rate"]
            ts = [t for t in cue.tracks if t.file == fname]
            bounds = [round(t.start * rate / 75) for t in ts] + [info["samples"]]
            for i, t in enumerate(ts):
                start, end = bounds[i], bounds[i + 1]
                if end - start < rate:                # under a second: a broken CUE
                    raise AudioError(f"{cue.path.name}: track {t.number} would be {(end - start) / rate:.2f}s")
                dst = out / f"{disc}.{t.number:02d}.flac"
                _to_flac(img, dst, skip=start, until=end)
                tracks.append(Track(dst, disc, t.number, end - start, rate, info["bits"],
                                    {"title": t.title, "artist": t.performer or cue.performer,
                                     "album": cue.title, "date": cue.date, "genre": cue.genre}))
            total = sum(tr.samples for tr in tracks if tr.disc == disc and tr.path.parent == out)
            check = sum(probe(tr.path)["samples"] for tr in tracks if tr.disc == disc)
            if check != total:
                raise AudioError(f"split of {img.name} lost samples ({check} written, {total} expected)")
            used.add(img)
        notes.append(f"split {cue.path.name} into {len(cue.tracks)} tracks (disc {disc})")
    # 2. files that are already one track each
    loose = [f for f in audio if f not in used]
    if images and loose:
        # an image plus loose tracks: the loose ones are usually the same album already split
        if len(loose) >= sum(len(c.tracks) for c in images):
            notes.append("both an image and split tracks: using the split tracks")
            tracks, used = [], set()
            for t in out.glob("*.flac"):
                t.unlink()
        else:
            loose = []
    if not images or not tracks:
        groups: dict[int, list[Path]] = {}
        for f in loose:
            groups.setdefault(_disc_from_path(f.relative_to(source if source.is_dir() else source.parent)) or 1, []).append(f)
        id3 = 0
        for disc, fs in sorted(groups.items()):
            fs.sort(key=lambda p: _sort_key(p))
            for i, f in enumerate(fs, 1):
                dst = out / f"{disc}.{i:02d}.flac"
                if f.suffix.lower() == ".flac":
                    if copy_flac(f, dst):
                        id3 += 1
                else:
                    _to_flac(f, dst)
                    notes.append(f"converted {f.name} to FLAC")
                info = probe(dst)
                tracks.append(Track(dst, disc, i, info["samples"], info["rate"], info["bits"], _old_tags(dst)))
        if id3:
            notes.append(f"removed the ID3 tags glued to {id3} FLAC files")
    tracks.sort(key=lambda t: (t.disc, t.index))
    for t in tracks:
        run(["flac", "-s", "-t", str(t.path)])        # integrity: the stream decodes and its MD5 matches
    return tracks, notes


def copy_flac(src: Path, dst: Path) -> bool:
    """Copy a FLAC without the ID3 tags some rippers glue to it (ID3v2 before the stream, ID3v1
    after it): non-standard, and flac -t cannot decode through them. True when one was removed."""
    data = src.read_bytes()
    head = 0
    if data[:3] == b"ID3" and len(data) > 10:
        size = data[6:10]
        head = 10 + ((size[0] << 21) | (size[1] << 14) | (size[2] << 7) | size[3]) + (10 if data[5] & 0x10 else 0)
        if data[head:head + 4] != b"fLaC":           # a padded ID3: look for the stream right after it
            found = data.find(b"fLaC", 10, head + 65536)
            head = found if found > 0 else head
    tail = 128 if len(data) > 128 and data[-128:-125] == b"TAG" else 0
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(data[head:len(data) - tail if tail else None])
    shutil.copystat(src, dst)
    return bool(head or tail)


def _sort_key(p: Path):
    m = re.match(r"^\D*?(\d{1,3})", p.stem)
    return (int(m.group(1)) if m else 999, p.name.lower())


def _old_tags(path: Path) -> dict:
    """What the file already says, as hints for the match (never copied to the result)."""
    try:
        out = run(["metaflac", "--export-tags-to=-", str(path)], 60).stdout
    except AudioError:
        return {}
    t = {}
    for line in out.splitlines():
        k, _, v = line.partition("=")
        t.setdefault(k.upper(), v)
    return {"title": t.get("TITLE", ""), "artist": t.get("ARTIST", ""), "album": t.get("ALBUM", ""),
            "albumartist": t.get("ALBUMARTIST", ""), "date": t.get("DATE", ""), "track": t.get("TRACKNUMBER", ""),
            "disc": t.get("DISCNUMBER", ""), "mb_albumid": t.get("MUSICBRAINZ_ALBUMID", ""), "genre": t.get("GENRE", "")}


def find_images(source: Path, work: Path) -> list[Path]:
    """Cover candidates shipped with the download (Covers/Front.jpg, folder.jpg...)."""
    roots = [source] + ([work / "_extracted"] if (work / "_extracted").exists() else [])
    found = []
    for r in roots:
        if r.is_dir():
            found += [p for p in r.rglob("*") if p.is_file() and p.suffix.lower() in IMAGES]
    def score(p: Path):
        n = p.stem.lower()
        return (0 if re.search(r"front|cover|folder", n) else 1 if "album" in n else 2, -p.stat().st_size)
    return sorted(found, key=score)
