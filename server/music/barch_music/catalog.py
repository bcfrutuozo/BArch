"""The library as the player sees it (quickshell/player, `barch player`): every album of /music with
its tracks' tags and lengths, in one JSON the desktop downloads once and keeps.

    catalog.json (in the pipeline's data folder)   the index; rebuilt from the files that changed
    GET /api/catalog[?since=<version>]             the whole thing (gzip when accepted), or just
                                                   {"changed": false} when nothing moved since
    GET /api/catalog/cover?folder=A/B              cover.jpg
    GET /api/catalog/stream?folder=A/B&file=X      the audio itself, with Range (mpv seeks), for a
                                                   desktop without the share mounted
    GET /api/catalog/lyrics?folder=A/B&file=X      a .lrc next to the file or a LYRICS tag
    POST /api/catalog/refresh                      read the folders again now

Reading 20,000 FLAC headers takes a couple of minutes on the NAS, so an album is only read again
when its files' names, sizes or mtimes changed (`signature`); a pass over an unchanged library is a
stat per file. The pipeline refreshes it every `catalog_every_s` (15 min) and right after it
delivers or merges an album. Nothing here writes to /music."""
from __future__ import annotations

import gzip
import json
import re
import threading
import time
from pathlib import Path

NUMBERED = re.compile(r"^(\d+)\.(\d+)\s+-\s+(.*)\.flac$", re.I)
AUDIO = (".flac",)


def _int(v: str | None, default: int) -> int:
    m = re.match(r"\s*(\d+)", v or "")
    return int(m.group(1)) if m else default


def signature(folder: Path) -> str:
    """What changes when an album's files change: count, total size, newest mtime (a stat per file)."""
    n = size = newest = 0
    for f in folder.iterdir():
        if f.suffix.lower() in AUDIO or f.suffix.lower() == ".lrc" or f.name == "cover.jpg":
            try:
                st = f.stat()
            except OSError:
                continue
            n += 1
            size += st.st_size
            newest = max(newest, st.st_mtime_ns)
    return f"{n}:{size}:{newest}"


def read_track(path: Path) -> dict:
    """One file's tags and stream info, the way the player wants them (mutagen)."""
    from mutagen.flac import FLAC

    x = FLAC(path)
    tags = {k.upper(): v[0] for k, v in (x.tags or {}).items()}
    m = NUMBERED.match(path.name)
    disc = _int(tags.get("DISCNUMBER"), int(m.group(1)) if m else 1)
    pos = _int(tags.get("TRACKNUMBER"), int(m.group(2)) if m else 0)
    title = tags.get("TITLE") or (m.group(3) if m else path.stem)
    lyrics = bool(tags.get("LYRICS") or tags.get("UNSYNCEDLYRICS")) or path.with_suffix(".lrc").exists()
    return {"file": path.name, "title": title, "artist": tags.get("ARTIST", ""), "album": tags.get("ALBUM", ""),
            "albumartist": tags.get("ALBUMARTIST", ""), "date": tags.get("DATE", ""), "genre": tags.get("GENRE", ""),
            "disc": disc, "pos": pos, "length": round(float(x.info.length or 0), 2), "rate": int(x.info.sample_rate or 0),
            "bits": int(x.info.bits_per_sample or 0), "channels": int(x.info.channels or 0), "lyrics": lyrics}


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
    out = {
        "folder": rel,
        "artist": album_artist,
        "album": first.get("album") or re.sub(r"\s*\((?:19|20)\d{2}\)\s*$", "", album_folder).replace("_", ":"),
        "date": first.get("date", ""),
        "genre": first.get("genre", ""),
        "cover": (folder / "cover.jpg").is_file(),
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
        self.albums: dict[str, dict] = {}     # folder -> record (with its "sig")
        self._payload: tuple[int, bytes, bytes] | None = None
        try:
            d = json.loads(self.file.read_text())
            self.version = int(d.get("version", 0))
            self.scanned = float(d.get("scanned", 0))
            self.albums = {a["folder"]: a for a in d.get("albums", [])}
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
            if a.name.startswith(".") or not a.is_dir():
                continue
            try:
                albums = sorted(a.iterdir(), key=lambda p: p.name.casefold())
            except OSError:
                continue
            for b in albums:
                if b.is_dir() and not b.name.startswith("."):
                    out.append((f"{a.name}/{b.name}", b))
        return out

    def refresh(self, full: bool = False) -> dict:
        """Read the albums whose files changed (every album with full=True); returns what it did."""
        if not self.scan_lock.acquire(blocking=False):
            return {"skipped": "already scanning"}
        t0 = time.time()
        try:
            self.scanning = True
            read = removed = 0
            seen = set()
            new = dict(self.albums)
            for rel, folder in self.folders():
                seen.add(rel)
                sig = signature(folder)
                old = new.get(rel)
                if old and old.get("sig") == sig and not full:
                    continue
                rec = read_album(folder, rel, self.reader)
                rec["sig"] = sig
                rec["added"] = old.get("added") if old and old.get("added") else int(folder.stat().st_mtime)
                new[rel] = rec
                read += 1
            for rel in list(new):
                if rel not in seen:
                    del new[rel]
                    removed += 1
            changed = read > 0 or removed > 0 or not self.albums
            with self.lock:
                if changed:
                    self.albums = new
                    self.version += 1
                    self._payload = None
                self.scanned = time.time()
                self.last = {"read": read, "removed": removed, "albums": len(new), "seconds": round(time.time() - t0, 1), "full": full}
            if changed:
                self.save()
            return dict(self.last)
        finally:
            self.scanning = False
            self.scan_lock.release()

    def refresh_async(self, full: bool = False) -> None:
        threading.Thread(target=self.refresh, args=(full,), daemon=True).start()

    def save(self) -> None:
        tmp = self.file.with_suffix(".tmp")
        with self.lock:
            tmp.write_text(json.dumps({"version": self.version, "scanned": self.scanned, "albums": list(self.albums.values())}))
        tmp.replace(self.file)

    # ---------------------------------------------------------------- what the API sends
    def status(self) -> dict:
        with self.lock:
            return {"version": self.version, "scanned": self.scanned, "scanning": self.scanning, "albums": len(self.albums),
                    "tracks": sum(len(a["tracks"]) for a in self.albums.values()), "last": self.last}

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

    def lyrics(self, folder: str, name: str) -> dict:
        f = self.path(folder, name)
        if not f:
            return {"ok": False, "error": "no such file"}
        lrc = f.with_suffix(".lrc")
        if lrc.is_file():
            return {"ok": True, "synced": lrc.read_text(errors="replace"), "plain": "", "source": "lrc"}
        try:
            from mutagen.flac import FLAC
            tags = {k.upper(): v[0] for k, v in (FLAC(f).tags or {}).items()}
        except Exception as e:  # noqa: BLE001
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

