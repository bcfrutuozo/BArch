"""The album cover: at least 500x500, 1000x1000 whenever a source has it.

Sources in order: Cover Art Archive (the release, then its release group), the images that came
with the download (Front/Cover/Folder), iTunes and Deezer (both serve 1000+ px). The first one
of 1000 px or more wins; otherwise the largest of at least 500 px. The result is a JPEG of
1000x1000 (or the source size if smaller), embedded in every track and written as cover.jpg.
"""
from __future__ import annotations

import json
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

from . import mb

MIN, TARGET = 500, 1000


@dataclass
class Cover:
    data: bytes                    # the final JPEG
    width: int
    height: int
    source: str                    # where it came from, for the report


def _size(path: Path) -> tuple[int, int]:
    r = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
                        "-of", "json", str(path)], capture_output=True, text=True, timeout=60)
    try:
        s = json.loads(r.stdout)["streams"][0]
        return int(s["width"]), int(s["height"])
    except (KeyError, IndexError, ValueError, json.JSONDecodeError):
        return 0, 0


def _square(w: int, h: int) -> bool:
    return w and h and 0.9 <= w / h <= 1.1


def _to_jpeg(src: Path, w: int, h: int) -> tuple[bytes, int, int]:
    side = min(TARGET, w, h) if _square(w, h) else 0
    out = src.with_suffix(".out.jpg")
    vf = f"scale={side}:{side}:flags=lanczos" if side else f"scale='min({TARGET},iw)':-2:flags=lanczos"
    subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", str(src), "-vf", vf, "-frames:v", "1",
                    "-q:v", "2", "-pix_fmt", "yuvj420p", str(out)], check=True, timeout=120)
    data = out.read_bytes()
    nw, nh = _size(out)
    out.unlink(missing_ok=True)
    return data, nw, nh


def _try(data: bytes | None, label: str, tmp: Path, found: list) -> bool:
    """Measure a candidate; True when it already reaches the target (stop looking)."""
    if not data or len(data) < 2000:
        return False
    p = tmp / f"c{len(found)}"
    p.write_bytes(data)
    w, h = _size(p)
    if not _square(w, h) or min(w, h) < MIN:
        return False
    found.append((min(w, h), p, w, h, label))
    return min(w, h) >= TARGET


def find(release_mbid: str, group_mbid: str, artist: str, album: str, local: list[Path], explicit: str = "") -> tuple[Cover | None, list[str]]:
    """(the cover or None, what was tried) - explicit is a URL or path chosen in the review."""
    tried: list[str] = []
    found: list = []
    with tempfile.TemporaryDirectory(prefix="barch-cover-") as td:
        tmp = Path(td)

        def attempt(get, label):
            try:
                data = get()
            except mb.NetError as e:
                tried.append(f"{label}: {e}")
                return False
            hit = _try(data, label, tmp, found)
            tried.append(f"{label}: " + ("ok" if found and found[-1][4] == label else "too small, not square or missing"))
            return hit

        if explicit:
            src = Path(explicit)
            attempt(lambda: src.read_bytes() if src.exists() else mb.download(explicit), f"chosen: {explicit}")
        else:
            done = False
            for kind, mbid in (("release", release_mbid), ("release-group", group_mbid)):
                if done or not mbid:
                    continue
                for img in mb.caa_images(kind, mbid)[:2]:
                    url = img.get("url")
                    if url and attempt(lambda u=url: mb.download(u), f"Cover Art Archive ({kind})"):
                        done = True
                        break
            for p in local[:6]:
                if done:
                    break
                done = attempt(lambda p=p: p.read_bytes(), f"download: {p.name}")
            for name, fn in (("iTunes", mb.itunes_covers), ("Deezer", mb.deezer_covers)):
                if done:
                    break
                try:
                    urls = fn(artist, album)[:2]
                except mb.NetError as e:
                    tried.append(f"{name}: {e}")
                    continue
                for u in urls:
                    if attempt(lambda u=u: mb.download(u), name):
                        done = True
                        break
        if not found:
            return None, tried
        best = next((f for f in found if f[0] >= TARGET), None) or max(found, key=lambda f: f[0])
        _, path, w, h, label = best
        data, nw, nh = _to_jpeg(path, w, h)
        return Cover(data, nw, nh, f"{label} ({w}x{h})"), tried
