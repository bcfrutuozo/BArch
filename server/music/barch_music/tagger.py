"""Write a track exactly as the library wants it: every existing tag and picture removed, then
only the KEEP tags and the front cover. Nothing else survives (no lyrics, comments, encoder,
ReplayGain, cue sheets, old ids)."""
from __future__ import annotations

from pathlib import Path

from mutagen.flac import FLAC, Picture

from .album import KEEP


def write(path: Path, tags: dict, cover_jpeg: bytes, width: int, height: int) -> None:
    f = FLAC(path)
    f.delete()                         # all Vorbis comments
    f.clear_pictures()
    if f.cuesheet is not None:
        f.cuesheet = None
    for k in KEEP:
        v = str(tags.get(k, "")).strip()
        if v:
            f[k] = v
    pic = Picture()
    pic.type = 3                       # front cover
    pic.mime = "image/jpeg"
    pic.desc = ""
    pic.width, pic.height, pic.depth = width, height, 24
    pic.data = cover_jpeg
    f.add_picture(pic)
    f.save(deleteid3=True)


def read(path: Path) -> tuple[dict, int]:
    """(tags, number of pictures) - to verify what was written."""
    f = FLAC(path)
    return {k.upper(): v[0] for k, v in (f.tags or {}).items()}, len(f.pictures)
