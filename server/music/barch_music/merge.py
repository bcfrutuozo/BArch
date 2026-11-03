"""An album that is already in /music: complete it and fix it, never replace it.

Every position of the release is decided on its own, with the MusicBrainz length as the judge:
    missing in the library, right in the download   -> added, with the album's own ALBUM/ARTIST/DATE/GENRE
    in the library and right                         -> its audio stays, whatever the download has
    in the library and wrong, right in the download  -> review: replacing audio Bruno has needs his ok
                                                        (resolve --replace-tracks 1.15)
The tracks that stay get the library's rules only (style.py on their own TITLE, the file name from
the tag, tags outside the set removed, empty required tags filled, the cover embedded if missing):
his choices win over MusicBrainz. Every change to an existing file goes to an undo log.
"""
from __future__ import annotations

import json
import os
import re
import shutil
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

from mutagen.flac import FLAC, Picture

from . import style
from .album import KEEP, REQUIRED, Album

RIP = {"CDTOC", "CTDBDISCCONFIDENCE", "CTDBTRACKCONFIDENCE"}      # proof of Bruno's own rips: kept
TOLERANCE = 5.0                                                    # seconds against MusicBrainz


@dataclass
class Plan:
    add: list[tuple] = field(default_factory=list)          # (Track, tags, file name)
    fix: list[dict] = field(default_factory=list)           # {path, rename, set, drop, cover}
    replace: list[tuple] = field(default_factory=list)      # (key, library path, Track, tags) approved
    review: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)
    date: str = ""
    genre: str = ""

    def summary(self) -> dict:
        return {"add": [n for _, _, n in self.add],
                "fix": [{"file": Path(f["path"]).name, "rename": f["rename"], "set": f["set"], "drop": f["drop"],
                         "cover": f["cover"]} for f in self.fix],
                "replace": [k for k, *_ in self.replace], "review": self.review, "notes": self.notes}


def _key(tags: dict, path: Path) -> str:
    d, t = (tags.get("DISCNUMBER") or [""])[0], (tags.get("TRACKNUMBER") or [""])[0]
    if d.split("/")[0].isdigit() and t.split("/")[0].isdigit():
        return f"{int(d.split('/')[0])}.{int(t.split('/')[0]):02d}"
    m = re.match(r"^(\d{1,2})\.(\d{2}) - ", path.name)
    return f"{int(m.group(1))}.{m.group(2)}" if m else ""


def _majority(values: list[str]) -> str:
    vals = [v for v in values if v]
    return Counter(vals).most_common(1)[0][0] if vals else ""


def plan(alb: Album, target: Path, replace_ok: set[str]) -> Plan:
    p = Plan()
    lib: dict[str, tuple[Path, FLAC]] = {}
    for f in sorted(target.glob("*.flac")):
        x = FLAC(f)
        k = _key({kk.upper(): vv for kk, vv in (x.tags or {}).items()}, f)
        if k:
            lib[k] = (f, x)
    album_vals = {k: _majority([(x.get(k) or [""])[0] for _, x in lib.values()]) for k in ("ALBUM", "ARTIST", "DATE", "GENRE")}
    one_artist = len({(x.get("ARTIST") or [""])[0] for _, x in lib.values()}) == 1
    # the date must have the day and every track a genre, in the library as much as in a new album:
    # the library's own values win when they are complete, else what the sources found
    full = lambda d: bool(re.fullmatch(r"\d{4}-\d{2}-\d{2}", d or ""))
    if full(album_vals["DATE"]):
        p.date = album_vals["DATE"]
    elif full(alb.date):
        p.date = alb.date
        p.notes.append(f"the library has DATE {album_vals['DATE'] or 'empty'}: set to {alb.date} "
                       + next((n[n.find('('):] for n in alb.notes if n.startswith('date ')), ""))
    else:
        p.date = ""
        p.review.append(f"the album's DATE is {album_vals['DATE'] or 'empty'} (no day) and no source has the day: "
                        "find it (--date YYYY-MM-DD) or, if it exists nowhere, --date-year-only")
    p.genre = album_vals["GENRE"] or alb.genre
    if not p.genre:
        p.review.append("no genre in the library tracks nor in any source: --genre ...")
    for t, tags, name in alb.files():
        key = f"{tags['DISCNUMBER']}.{tags['TRACKNUMBER']}"
        want = alb.lengths.get(key) or 0
        dl_ok = not want or abs(t.seconds - want) <= TOLERANCE
        if key not in lib:
            if not dl_ok:
                p.review.append(f"{key} is missing in the library and the download's is {t.seconds:.0f}s, MusicBrainz {want:.0f}s")
                continue
            new = dict(tags)
            if album_vals["ALBUM"]:
                new["ALBUM"] = album_vals["ALBUM"]          # the album as the library already has it
            new["DATE"], new["GENRE"] = p.date, p.genre
            if one_artist and album_vals["ARTIST"] and alb.artist_folder != "Various Artists":
                new["ARTIST"] = album_vals["ARTIST"]        # the album's artist as the library spells it
            p.add.append((t, new, style.file_name(new["DISCNUMBER"], new["TRACKNUMBER"], new["TITLE"])))
            continue
        path, x = lib[key]
        lib_ok = not want or abs(x.info.length - want) <= TOLERANCE
        if not lib_ok and dl_ok:
            if key in replace_ok:
                p.replace.append((key, path, t, tags))
            else:
                p.review.append(f"{key} in the library is {x.info.length:.0f}s, MusicBrainz {want:.0f}s, the download's "
                                f"{t.seconds:.0f}s: replace it with --replace-tracks {key}")
            continue
        if not lib_ok:
            p.notes.append(f"{key}: the library's ({x.info.length:.0f}s) and the download's ({t.seconds:.0f}s) both differ from MusicBrainz ({want:.0f}s); kept")
        if not dl_ok and lib_ok:
            p.notes.append(f"{key}: the download's is {t.seconds:.0f}s, MusicBrainz {want:.0f}s; the library's kept")
        p.fix += _fixes(path, x, {**tags, "DATE": p.date, "GENRE": p.genre}, alb, p.date)
    swaps = [r for r in p.review if "--replace-tracks" in r]
    if len(swaps) > max(2, len(alb.tracks) // 5):
        # many tracks off at once: not damaged files, the library copy is split at other points (or is
        # another edition); swapping some of them would leave the neighbours overlapping or short
        p.review = [r for r in p.review if r not in swaps] + [
            f"{len(swaps)} of {len(alb.tracks)} library tracks differ from MusicBrainz while the download fits it: the library "
            "copy looks split at other points (or another edition). Take the download as a whole with --replace "
            "(the old album is kept with the job, barch music undo brings it back), or reject to keep yours"]
    for k in sorted(set(lib) - {f"{tg['DISCNUMBER']}.{tg['TRACKNUMBER']}" for _, tg, _ in alb.files()}):
        p.notes.append(f"{k} ({lib[k][0].name}) is not on this release: left as it is")
    return p


def _fixes(path: Path, x: FLAC, proposed: dict, alb: Album, album_date: str) -> list[dict]:
    cur = {k.upper(): v[0] for k, v in (x.tags or {}).items()}
    sets, drop = {}, sorted(k for k in cur if k not in set(KEEP) | RIP)
    if album_date and cur.get("DATE") != album_date and not re.fullmatch(r"\d{4}-\d{2}-\d{2}", cur.get("DATE", "")):
        sets["DATE"] = album_date                     # a year-only (or empty) DATE gets the full one
    title = cur.get("TITLE", "")
    if title and style.make_title(title) != title:
        sets["TITLE"] = style.make_title(title)
    for k in REQUIRED:
        if not cur.get(k, "").strip() and proposed.get(k):
            sets[k] = proposed[k]
    for k in ("MUSICBRAINZ_ALBUMID", "MUSICBRAINZ_TRACKID"):
        if not cur.get(k) and proposed.get(k):
            sets[k] = proposed[k]
    final = {**cur, **sets}
    name = style.file_name(final.get("DISCNUMBER", "1"), final.get("TRACKNUMBER", "0"), final.get("TITLE", ""))
    cover = not any(pic.type == 3 and min(_size(pic)) >= 500 for pic in x.pictures)
    if not (sets or drop or cover or name != path.name):
        return []
    return [{"path": str(path), "rename": name if name != path.name else "", "set": sets, "drop": drop, "cover": cover}]


def _size(pic) -> tuple[int, int]:
    """The picture's real size: many taggers leave width/height 0 in the block, so measure it."""
    if pic.width and pic.height:
        return pic.width, pic.height
    import subprocess
    import tempfile
    with tempfile.NamedTemporaryFile(suffix=".img") as f:
        f.write(pic.data)
        f.flush()
        r = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
                            "-of", "csv=p=0", f.name], capture_output=True, text=True, timeout=60)
    try:
        w, h = (int(v) for v in r.stdout.strip().split(",")[:2])
        return w, h
    except ValueError:
        return 0, 0


def apply(p: Plan, target: Path, cover_jpeg: bytes, cw: int, ch: int, undo_path: Path, write_new) -> list[str]:
    """Run the plan; write_new(track, tags, dst) writes a new file the way new albums are written.
    A replaced original is kept next to the undo log (never left inside the album folder)."""
    keep_dir = undo_path.parent / "replaced"
    undo = json.loads(undo_path.read_text()) if undo_path.exists() else []
    done = []

    def save_undo():
        undo_path.write_text(json.dumps(undo, ensure_ascii=False, indent=1))

    for f in p.fix:
        path = Path(f["path"])
        x = FLAC(path)
        undo.append({"op": "tags", "path": str(path), "tags": {k.upper(): list(v) for k, v in (x.tags or {}).items()},
                     "had_cover": bool(x.pictures)})
        save_undo()
        for k in f["drop"]:
            for kk in list(x.keys()):
                if kk.upper() == k:
                    del x[kk]
        for k, v in f["set"].items():
            x[k] = v
        if f["cover"]:
            x.clear_pictures()
            pic = Picture()
            pic.type, pic.mime, pic.width, pic.height, pic.depth, pic.data = 3, "image/jpeg", cw, ch, 24, cover_jpeg
            x.add_picture(pic)
        x.save()
        msg = []
        if f["set"]:
            msg.append(", ".join(f"{k}={v}" for k, v in f["set"].items()))
        if f["drop"]:
            msg.append("removed " + ", ".join(f["drop"]))
        if f["cover"]:
            msg.append("cover embedded")
        if f["rename"]:
            new = path.with_name(f["rename"])
            if new.exists() and new.name.lower() != path.name.lower():
                raise RuntimeError(f"cannot rename {path.name}: {new.name} exists")
            tmp = path.with_name(path.name + ".renaming")
            os.replace(path, tmp)
            os.replace(tmp, new)
            undo.append({"op": "rename", "old": str(path), "new": str(new)})
            save_undo()
            msg.append(f"renamed to {new.name}")
        done.append(f"{path.name}: " + "; ".join(msg))
    for key, path, t, tags in p.replace:
        keep_dir.mkdir(parents=True, exist_ok=True)
        keep = keep_dir / path.name
        shutil.move(str(path), str(keep))
        undo.append({"op": "replaced", "path": str(path), "kept": str(keep)})
        save_undo()
        old = FLAC(keep)
        mine = {k.upper(): v[0] for k, v in (old.tags or {}).items() if k.upper() in set(KEEP)}
        write_new(t, {**tags, **mine}, path)
        done.append(f"{path.name}: audio replaced (the original is kept with the job)")
    for t, tags, name in p.add:
        dst = target / name
        if dst.exists():
            raise RuntimeError(f"cannot add {name}: it exists")
        write_new(t, tags, dst)
        undo.append({"op": "added", "path": str(dst)})
        save_undo()
        done.append(f"{name}: added")
    cov = target / "cover.jpg"
    if not cov.exists():
        cov.write_bytes(cover_jpeg)
        undo.append({"op": "added", "path": str(cov)})
        save_undo()
        done.append("cover.jpg added")
    return done


def undo(undo_path: Path) -> list[str]:
    """Put an album back as it was before the merge (barch music undo <id>)."""
    out = []
    for e in reversed(json.loads(undo_path.read_text())):
        if e["op"] == "rename" and Path(e["new"]).exists():
            os.replace(e["new"], e["old"])
            out.append(f"renamed back: {Path(e['old']).name}")
        elif e["op"] == "tags" and Path(e["path"]).exists():
            x = FLAC(e["path"])
            x.delete()
            for k, v in e["tags"].items():
                x[k.upper()] = v                    # the library writes tag names in upper case
            x.save()
            out.append(f"tags restored: {Path(e['path']).name}")
        elif e["op"] == "added" and Path(e["path"]).exists():
            os.remove(e["path"])
            out.append(f"removed: {Path(e['path']).name}")
        elif e["op"] == "replaced" and Path(e["kept"]).exists():
            if Path(e["path"]).exists():
                os.remove(e["path"])
            shutil.move(e["kept"], e["path"])
            out.append(f"original back: {Path(e['path']).name}")
    undo_path.rename(undo_path.with_suffix(".undone.json"))
    return out
