"""The library as the player sees it (quickshell/player, `barch player`): every album of /music with
its tracks' tags and lengths, in one JSON the desktop downloads once and keeps.

    catalog.json (in the pipeline's data folder)   the index; rebuilt from the files that changed
    GET /api/catalog[?since=<version>]             the whole thing (gzip when accepted), or just
                                                   {"changed": false} when nothing moved since
    GET /api/catalog/cover?folder=A/B              the cover: cover.jpg (or .png, folder.jpg...), else the
                                                   picture embedded in the first track
    GET /api/catalog/stream?folder=A/B&file=X      the audio itself, with Range (mpv seeks), for a
                                                   desktop without the share mounted
    GET /api/catalog/lyrics?folder=A/B&file=X      a .lrc next to the file or a LYRICS tag
    POST /api/catalog/refresh                      read the folders again now

A FLAC's tags sit in its first kilobytes, but the embedded cover (STREAMINFO, VORBIS_COMMENT, then
a PICTURE block of 0.5-1 MB) sits with them and mutagen reads it all, which over 20,000 files on the array
is 20 GB for nothing: `flac_header` reads the two blocks it needs and seeks past the rest, albums are
read eight at a time, and the index is published every 200 albums, so a restart carries on. An album is
only read again when its files' names, sizes or mtimes changed (`signature`); a pass over an unchanged
library is a stat per file. The pipeline refreshes it every `catalog_every_s` (15 min) and right after
it delivers or merges an album. Nothing here writes to /music."""
from __future__ import annotations

import gzip
import json
import re
import struct
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from . import style

NUMBERED = re.compile(r"^(\d+)\.(\d+)\s+-\s+(.*)\.flac$", re.I)
AUDIO = (".flac",)
IMAGES = (".jpg", ".jpeg", ".png", ".webp")
COVER_STEMS = ("cover", "folder", "front", "album", "albumart")   # in order of preference, any case
EMBEDDED = "embedded"                                              # the cover is the PICTURE block of the tracks
FORMAT = 2                                                         # of the records; a change reads every album again


def _int(v: str | None, default: int) -> int:
    m = re.match(r"\s*(\d+)", v or "")
    return int(m.group(1)) if m else default


def signature(folder: Path) -> str:
    """What changes when an album's files change: count, total size, newest mtime (a stat per file)."""
    n = size = newest = 0
    for f in folder.iterdir():
        if f.suffix.lower() in AUDIO + IMAGES or f.suffix.lower() == ".lrc":
            try:
                st = f.stat()
            except OSError:
                continue
            n += 1
            size += st.st_size
            newest = max(newest, st.st_mtime_ns)
    return f"{n}:{size}:{newest}"


def cover_file(folder: Path) -> Path | None:
    """The cover image of an album folder: cover.jpg first, then cover.png, folder.jpg, front.jpg... in any case."""
    found: dict[tuple[int, int], Path] = {}
    try:
        for f in folder.iterdir():
            stem, ext = f.stem.lower(), f.suffix.lower()
            if stem in COVER_STEMS and ext in IMAGES and f.is_file():
                found[(COVER_STEMS.index(stem), IMAGES.index(ext))] = f
    except OSError:
        return None
    return found[min(found)] if found else None


def flac_header(path: Path) -> tuple[dict, dict]:
    """(tags, info) of a FLAC from its metadata blocks, reading only STREAMINFO and VORBIS_COMMENT and
    seeking past PICTURE, PADDING and the rest (the cover is most of the header; info["picture"] says it is
    there). Tags keep the first value of each key, upper-cased, like mutagen's v[0]. ValueError when the file
    is not a FLAC."""
    tags: dict[str, str] = {}
    info = {"length": 0.0, "rate": 0, "bits": 0, "channels": 0, "picture": False}
    with open(path, "rb") as fh:
        if fh.read(4) != b"fLaC":
            raise ValueError("not a FLAC stream")
        last = False
        while not last:
            head = fh.read(4)
            if len(head) < 4:
                break
            last = bool(head[0] & 0x80)
            kind, size = head[0] & 0x7F, int.from_bytes(head[1:4], "big")
            if kind == 0 and size >= 18:                     # STREAMINFO
                b = fh.read(size)
                bits = int.from_bytes(b[10:18], "big")
                rate = bits >> 44
                channels = ((bits >> 41) & 0x7) + 1
                bps = ((bits >> 36) & 0x1F) + 1
                samples = bits & ((1 << 36) - 1)
                info.update({"length": samples / rate if rate else 0.0, "rate": rate, "bits": bps, "channels": channels})
            elif kind == 6:                                   # PICTURE: noted, not read
                info["picture"] = True
                fh.seek(size, 1)
            elif kind == 4:                                   # VORBIS_COMMENT
                b = fh.read(size)
                pos = 4 + struct.unpack_from("<I", b, 0)[0]   # the vendor string
                count = struct.unpack_from("<I", b, pos)[0]
                pos += 4
                for _ in range(count):
                    n = struct.unpack_from("<I", b, pos)[0]
                    pos += 4
                    item = b[pos:pos + n].decode("utf-8", "replace")
                    pos += n
                    k, _, v = item.partition("=")
                    tags.setdefault(k.upper(), v)
            else:                                             # PICTURE, PADDING, SEEKTABLE, APPLICATION, CUESHEET
                fh.seek(size, 1)
    return tags, info


def flac_picture(path: Path) -> tuple[str, bytes] | None:
    """(mime, data) of the picture embedded in a FLAC: the front cover (type 3) when there is one, else the
    first PICTURE block; None without any. ValueError when the file is not a FLAC."""
    first = None
    with open(path, "rb") as fh:
        if fh.read(4) != b"fLaC":
            raise ValueError("not a FLAC stream")
        last = False
        while not last:
            head = fh.read(4)
            if len(head) < 4:
                break
            last = bool(head[0] & 0x80)
            kind, size = head[0] & 0x7F, int.from_bytes(head[1:4], "big")
            if kind != 6:
                fh.seek(size, 1)
                continue
            b = fh.read(size)
            ptype = int.from_bytes(b[0:4], "big")
            n = int.from_bytes(b[4:8], "big")
            mime = b[8:8 + n].decode("ascii", "replace")
            pos = 8 + n
            n = int.from_bytes(b[pos:pos + 4], "big")          # the description
            pos += 4 + n + 16                                  # width, height, depth, colors
            n = int.from_bytes(b[pos:pos + 4], "big")
            data = b[pos + 4:pos + 4 + n]
            if not mime.startswith("image/"):
                mime = "image/png" if data[:4] == b"\x89PNG" else "image/jpeg"
            if ptype == 3:
                return mime, data
            first = first or (mime, data)
    return first


def read_track(path: Path) -> dict:
    """One file's tags and stream info, the way the player wants them."""
    tags, info = flac_header(path)
    m = NUMBERED.match(path.name)
    disc = _int(tags.get("DISCNUMBER"), int(m.group(1)) if m else 1)
    pos = _int(tags.get("TRACKNUMBER"), int(m.group(2)) if m else 0)
    title = tags.get("TITLE") or (m.group(3) if m else path.stem)
    lyrics = bool(tags.get("LYRICS") or tags.get("UNSYNCEDLYRICS")) or path.with_suffix(".lrc").exists()
    return {"file": path.name, "title": title, "artist": tags.get("ARTIST", ""), "album": tags.get("ALBUM", ""),
            "albumartist": tags.get("ALBUMARTIST", ""), "date": tags.get("DATE", ""), "genre": tags.get("GENRE", ""),
            "disc": disc, "pos": pos, "length": round(float(info["length"]), 2), "rate": int(info["rate"]),
            "bits": int(info["bits"]), "channels": int(info["channels"]), "lyrics": lyrics, "picture": bool(info.get("picture"))}


def read_album(folder: Path, rel: str, reader=None) -> dict:
    """The album record: what is common to its tracks once, the tracks sorted by disc and position."""
    reader = reader or read_track
    tracks = []
    for f in sorted(folder.iterdir(), key=lambda p: p.name.lower()):
        if f.suffix.lower() in AUDIO and f.is_file():
            try:
                tracks.append(reader(f))
            except Exception as e:  # noqa: BLE001  (a broken file is not the catalog's problem)
                tracks.append({"file": f.name, "title": f.stem, "artist": "", "album": "", "albumartist": "", "date": "",
                               "genre": "", "disc": 1, "pos": 0, "length": 0, "rate": 0, "bits": 0, "channels": 0,
                               "lyrics": False, "error": f"{type(e).__name__}: {e}"})
    tracks.sort(key=lambda t: (t["disc"], t["pos"], t["file"].lower()))
    first = tracks[0] if tracks else {}
    artist_folder, _, album_folder = rel.partition("/")
    album_artist = first.get("albumartist") or first.get("artist") or artist_folder.replace("_", ":")
    image = cover_file(folder)
    out = {
        "folder": rel,
        "artist": album_artist,
        "album": first.get("album") or re.sub(r"\s*\((?:19|20)\d{2}\)\s*$", "", album_folder).replace("_", ":"),
        "date": first.get("date", ""),
        "genre": first.get("genre", ""),
        "cover": image.name if image else (EMBEDDED if any(t.get("picture") for t in tracks) else ""),
        "length": round(sum(t["length"] for t in tracks), 2),
        "discs": max((t["disc"] for t in tracks), default=1),
        "tracks": [],
    }
    for t in tracks:
        row = {k: t[k] for k in ("file", "title", "disc", "pos", "length", "rate", "bits")}
        if t.get("artist") and t["artist"] != album_artist:
            row["artist"] = t["artist"]
        if t.get("lyrics"):
            row["lyrics"] = True
        if t.get("error"):
            row["error"] = t["error"]
        out["tracks"].append(row)
    return out


class Catalog:
    def __init__(self, music: Path, root: Path, reader=None):
        self.music = music
        self.file = root / "catalog.json"
        self.reader = reader
        self.lock = threading.Lock()          # the index and its cached payloads
        self.scan_lock = threading.Lock()     # one refresh at a time
        self.scanning = False
        self.version = 0
        self.scanned = 0.0
        self.last = {}                        # what the last refresh did
        self.progress: dict = {}              # while scanning: total, done, read, started
        self.albums: dict[str, dict] = {}     # folder -> record (with its "sig")
        self._payload: tuple[int, bytes, bytes] | None = None
        try:
            d = json.loads(self.file.read_text())
            self.version = int(d.get("version", 0))
            self.scanned = float(d.get("scanned", 0))
            self.albums = {a["folder"]: a for a in d.get("albums", [])}
            if int(d.get("format", 1)) != FORMAT:          # older records: served as they are, read again at the next pass
                for a in self.albums.values():
                    a["sig"] = ""
        except (OSError, ValueError, KeyError, TypeError):
            pass

    # ---------------------------------------------------------------- the index
    def folders(self) -> list[tuple[str, Path]]:
        out = []
        try:
            artists = sorted(self.music.iterdir(), key=lambda p: p.name.casefold())
        except OSError:
            return out
        for a in artists:
            if style.hidden(a.name) or not a.is_dir():
                continue
            try:
                albums = sorted(a.iterdir(), key=lambda p: p.name.casefold())
            except OSError:
                continue
            for b in albums:
                if b.is_dir() and not style.hidden(b.name):
                    out.append((f"{a.name}/{b.name}", b))
        return out

    WORKERS = 8
    CHUNK = 200

    def refresh(self, full: bool = False) -> dict:
        """Read the albums whose files changed (every album with full=True), eight at a time, publishing
        the index every CHUNK albums; returns what it did."""
        if not self.scan_lock.acquire(blocking=False):
            return {"skipped": "already scanning"}
        t0 = time.time()
        try:
            self.scanning = True
            read = removed = 0
            folders = self.folders()
            self.progress = {"total": len(folders), "done": 0, "read": 0, "started": t0}
            seen = set()
            new = dict(self.albums)
            todo = []
            for rel, folder in folders:
                seen.add(rel)
                sig = signature(folder)
                old = new.get(rel)
                if old and old.get("sig") == sig and not full:
                    self.progress["done"] += 1
                    continue
                todo.append((rel, folder, sig, old))

            def one(item):
                rel, folder, sig, old = item
                rec = read_album(folder, rel, self.reader)
                rec["sig"] = sig
                rec["added"] = old.get("added") if old and old.get("added") else int(folder.stat().st_mtime)
                return rel, rec

            with ThreadPoolExecutor(max_workers=self.WORKERS) as pool:
                for i in range(0, len(todo), self.CHUNK):
                    for rel, rec in pool.map(one, todo[i:i + self.CHUNK]):
                        new[rel] = rec
                        read += 1
                        self.progress["done"] += 1
                        self.progress["read"] = read
                    self.publish(new, partial=i + self.CHUNK < len(todo))
            for rel in list(new):
                if rel not in seen:
                    del new[rel]
                    removed += 1
            if removed or (not todo and not self.albums):      # the chunks published the rest as they went
                self.publish(new)
            with self.lock:
                self.scanned = time.time()
                self.last = {"read": read, "removed": removed, "albums": len(new), "seconds": round(time.time() - t0, 1), "full": full}
            return dict(self.last)
        finally:
            self.scanning = False
            self.progress = {}
            self.scan_lock.release()

    def publish(self, albums: dict, partial: bool = False) -> None:
        """The index as it stands, served and saved (a restart in the middle of a pass carries on from here)."""
        with self.lock:
            self.albums = dict(albums)
            self.version += 1
            self._payload = None
            if partial:
                self.scanned = time.time()
        self.save()

    def refresh_async(self, full: bool = False) -> None:
        threading.Thread(target=self.refresh, args=(full,), daemon=True).start()

    def save(self) -> None:
        tmp = self.file.with_suffix(".tmp")
        with self.lock:
            tmp.write_text(json.dumps({"version": self.version, "format": FORMAT, "scanned": self.scanned, "albums": list(self.albums.values())}))
        tmp.replace(self.file)

    # ---------------------------------------------------------------- what the API sends
    def status(self) -> dict:
        with self.lock:
            return {"version": self.version, "scanned": self.scanned, "scanning": self.scanning, "albums": len(self.albums),
                    "tracks": sum(len(a["tracks"]) for a in self.albums.values()), "last": self.last, "progress": dict(self.progress)}

    def payload(self, gz: bool) -> bytes:
        with self.lock:
            if not self._payload or self._payload[0] != self.version:
                albums = [{k: v for k, v in a.items() if k != "sig"} for a in self.albums.values()]
                raw = json.dumps({"ok": True, "changed": True, "version": self.version, "scanned": self.scanned,
                                  "scanning": self.scanning, "albums": albums}, ensure_ascii=False).encode()
                self._payload = (self.version, raw, gzip.compress(raw, 6))
            return self._payload[2] if gz else self._payload[1]

    # ---------------------------------------------------------------- files
    def path(self, folder: str, name: str = "") -> Path | None:
        """A file inside an album folder, or None for anything that points outside /music."""
        if not folder or "\x00" in folder or "\x00" in name:
            return None
        parts = [p for p in folder.split("/") if p]
        if len(parts) != 2 or any(p in (".", "..") for p in parts) or "/" in name or name in (".", ".."):
            return None
        p = self.music / parts[0] / parts[1]
        if name:
            p = p / name
        try:
            p.resolve().relative_to(self.music.resolve())
        except ValueError:
            return None
        return p if p.is_file() else None

    def cover(self, folder: str) -> tuple[Path | bytes, str] | None:
        """The album's cover: the image file of the folder (a Path) or the picture embedded in its first track
        (bytes), with its content type; None without either."""
        parts = [p for p in folder.split("/") if p] if folder and "\x00" not in folder else []
        if len(parts) != 2 or any(p in (".", "..") for p in parts):
            return None
        d = self.music / parts[0] / parts[1]
        try:
            d.resolve().relative_to(self.music.resolve())
        except ValueError:
            return None
        if not d.is_dir():
            return None
        image = cover_file(d)
        if image:
            ext = image.suffix.lower()
            return image, {".png": "image/png", ".webp": "image/webp"}.get(ext, "image/jpeg")
        for f in sorted(d.iterdir(), key=lambda p: p.name.lower()):
            if f.suffix.lower() in AUDIO and f.is_file():
                try:
                    pic = flac_picture(f)
                except (OSError, ValueError):
                    pic = None
                return (pic[1], pic[0]) if pic else None
        return None

    def lyrics(self, folder: str, name: str) -> dict:
        f = self.path(folder, name)
        if not f:
            return {"ok": False, "error": "no such file"}
        lrc = f.with_suffix(".lrc")
        if lrc.is_file():
            return {"ok": True, "synced": lrc.read_text(errors="replace"), "plain": "", "source": "lrc"}
        try:
            tags, _ = flac_header(f)
        except (OSError, ValueError, struct.error) as e:
            return {"ok": False, "error": str(e)}
        text = tags.get("LYRICS") or tags.get("UNSYNCEDLYRICS") or ""
        if not text:
            return {"ok": True, "synced": "", "plain": "", "source": ""}
        synced = bool(re.search(r"^\[\d+:\d+(?:\.\d+)?\]", text, re.M))
        return {"ok": True, "synced": text if synced else "", "plain": "" if synced else text, "source": "tag"}


def send_file(handler, path: Path, ctype: str) -> None:
    """Write a file as the response, honouring a single Range (what mpv and browsers ask for)."""
    size = path.stat().st_size
    start, end, partial = 0, size - 1, False
    m = re.match(r"bytes=(\d*)-(\d*)$", handler.headers.get("Range") or "")
    if m and (m.group(1) or m.group(2)):
        partial = True
        if m.group(1):
            start = int(m.group(1))
            end = min(int(m.group(2)), size - 1) if m.group(2) else size - 1
        else:
            start = max(0, size - int(m.group(2)))
        if start >= size or start > end:
            handler.send_response(416)
            handler.send_header("Content-Range", f"bytes */{size}")
            handler.send_header("Content-Length", "0")
            handler.end_headers()
            return
    handler.send_response(206 if partial else 200)
    handler.send_header("Content-Type", ctype)
    handler.send_header("Accept-Ranges", "bytes")
    handler.send_header("Content-Length", str(end - start + 1))
    if partial:
        handler.send_header("Content-Range", f"bytes {start}-{end}/{size}")
    handler.end_headers()
    left = end - start + 1
    try:
        with open(path, "rb") as fh:
            fh.seek(start)
            while left > 0:
                chunk = fh.read(min(1 << 20, left))
                if not chunk:
                    break
                handler.wfile.write(chunk)
                left -= len(chunk)
    except (BrokenPipeError, ConnectionResetError, OSError):
        pass          # the player moved on

