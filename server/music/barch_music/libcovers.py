"""The covers of albums already in /music: which ones look like a scan with a frame, and the
clean artwork that could replace them (cover.find with the library's cover as one more
candidate). Nothing changes without a decision: apply() replaces cover.jpg and the picture
embedded in every track of that album, keeping the old ones for undo().

State: <jobs>/covers/state.json (one entry per album folder), the proposals and the backups
next to it (<slug>.jpg, undo/<slug>/).
"""
from __future__ import annotations

import hashlib
import json
import shutil
import tempfile
import threading
import time
from pathlib import Path

from mutagen.flac import FLAC, Picture

from . import cover, mb


def slug(folder: str) -> str:
    return hashlib.sha1(folder.encode()).hexdigest()[:16]


class LibraryCovers:
    def __init__(self, music: Path, root: Path, plex=None):
        self.music, self.root, self.plex = music, root, plex
        self.root.mkdir(parents=True, exist_ok=True)
        self.state_path = root / "state.json"
        self.lock = threading.Lock()
        self.running = ""                 # what is being checked now
        self.queue: list[str] = []
        try:
            self.state = json.loads(self.state_path.read_text())
        except (OSError, json.JSONDecodeError):
            self.state = {}

    def save(self) -> None:
        tmp = self.state_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.state, ensure_ascii=False, indent=1))
        tmp.replace(self.state_path)

    # ------------------------------------------------------------ what to check
    def albums(self, artist: str) -> list[str]:
        """Album folders ("Artist/Album") of one artist folder (matched without case or accents)."""
        from .style import norm
        if not self.music.is_dir():
            return []
        out = []
        for a in sorted(self.music.iterdir()):
            if a.is_dir() and (not artist or norm(a.name) == norm(artist)):
                out += [f"{a.name}/{d.name}" for d in sorted(a.iterdir()) if d.is_dir() and any(d.glob("*.flac"))]
        return out

    def check(self, artist: str) -> int:
        folders = self.albums(artist)
        with self.lock:
            new = [f for f in folders if f not in self.queue and f != self.running]
            self.queue += new
            for f in new:                         # a queued album keeps its verdict and proposal meanwhile
                e = self.state.setdefault(f, {})
                e["queued"] = True
                e.setdefault("verdict", "queued")
            self.save()
            start = not self.running
        if start and new:
            threading.Thread(target=self._work, daemon=True).start()
        return len(new)

    def _work(self) -> None:
        while True:
            with self.lock:
                if not self.queue:
                    self.running = ""
                    return
                self.running = self.queue.pop(0)
            folder = self.running
            try:
                entry = self._check_one(folder)
            except Exception as e:  # noqa: BLE001 - one album never stops the others
                entry = {"verdict": "error", "error": str(e)}
            with self.lock:
                old = self.state.get(folder, {})
                entry["applied"] = old.get("applied", False) if entry.get("verdict") != "better" else False
                entry["checked"] = time.time()
                entry["queued"] = folder in self.queue
                if old.get("applied_at"):
                    entry["applied_at"] = old["applied_at"]
                self.state[folder] = entry
                self.save()

    def _check_one(self, folder: str) -> dict:
        d = self.music / folder
        flacs = sorted(d.glob("*.flac"))
        tags = FLAC(flacs[0]).tags or {}
        get = lambda k: (tags.get(k) or [""])[0]
        rid = get("MUSICBRAINZ_ALBUMID")
        gid = ((mb.release(rid) or {}).get("release-group") or {}).get("id", "") if rid else ""
        artist, album = folder.split("/", 1)[0], get("ALBUM") or d.name
        lib = d / "cover.jpg"
        cur = {"exists": lib.exists()}
        with tempfile.TemporaryDirectory(prefix="barch-libcover-") as td:
            tried: list[str] = []
            cands = cover.gather(rid, gid, artist, album, [], "", Path(td), tried, lib)
            mine = next((c for c in cands if c.kind == "library"), None)
            if mine:
                cur.update(w=mine.w, h=mine.h, framed=mine.framed, borders=mine.borders)
            best = cover.choose(cands)
            for c in cands:
                tried.append(f"{c.label}: {c.describe()}" + ("  <- best" if c is best else ""))
            entry = {"current": cur, "tried": tried, "mbid": rid, "artist": artist, "album": album}
            entry["alts"] = self._save_alts(folder, [c for c in cands if c.kind != "library"])
            small = mine is not None and min(mine.w, mine.h) < cover.TARGET
            if best is None:
                entry["verdict"] = "nothing"            # no usable image at all (not even the library's)
            elif best is mine or (mine and not mine.framed and not small):
                entry["verdict"] = "fine"
            elif mine and best.framed and mine.framed:
                entry["verdict"] = "framed"             # a scan, and nothing cleaner exists
            else:
                i = next((i for i, a in enumerate(entry["alts"]) if a.get("best")), None)
                if i is not None:
                    self._propose_alt(folder, entry, i)
                else:
                    entry["verdict"] = "error"
                    entry["error"] = "the best image could not be converted"
            kept = [a for a in (self.state.get(folder) or {}).get("alts", []) if a.get("kind") == "claude"]
            entry["alts"] += [a for a in kept if (self._alt_dir(folder) / a["file"]).is_file()]
        return entry

    # ------------------------------------------------------------ the candidates
    def _alt_dir(self, folder: str) -> Path:
        return self.root / "alts" / slug(folder)

    def _save_alts(self, folder: str, cands: list) -> list[dict]:
        """Every candidate as the JPEG it would become (frame trimmed), to look at and pick from;
        the ones Claude proposed earlier are kept (moved aside and back by the caller)."""
        d = self._alt_dir(folder)
        d.mkdir(parents=True, exist_ok=True)
        for f in d.glob("alt*.jpg"):
            f.unlink()
        best = cover.choose(cands)
        out = []
        for i, c in enumerate(sorted(cands, key=cover.rank_key, reverse=True)[:8]):
            try:
                data, w, h = cover._to_jpeg(c)
            except Exception:  # noqa: BLE001 - one bad image never stops the check
                continue
            name = f"alt{i}.jpg"
            (d / name).write_bytes(data)
            out.append({"file": name, "source": c.label, "kind": c.kind, "w": w, "h": h, "orig": f"{c.w}x{c.h}",
                        "framed": c.framed, "same": c.same, "trusted": c.trusted, "best": c is best})
        return out

    def _propose_alt(self, folder: str, entry: dict, i: int) -> None:
        a = entry["alts"][i]
        shutil.copy2(self._alt_dir(folder) / a["file"], self.root / f"{slug(folder)}.jpg")
        entry.update(verdict="better", proposal={k: a[k] for k in ("source", "w", "h", "orig", "framed", "same")} | {"alt": i})

    def pick(self, folder: str, i: int) -> str:
        """Make candidate i the proposal (Replace still has to be clicked)."""
        with self.lock:
            e = self.state.get(folder)
            if not e or not (0 <= i < len(e.get("alts", []))):
                raise KeyError("no such candidate")
            self._propose_alt(folder, e, i)
            e["applied"] = False
            self.save()
        return f"{folder}: proposal is now {e['proposal']['source']}"

    def propose(self, folder: str, data: bytes, label: str) -> str:
        """A new image for an album (Claude's, or one found by hand): checked like any candidate,
        kept with the album's candidates and made the proposal."""
        if not (self.music / folder).is_dir():
            raise KeyError("no such album in the library")
        with tempfile.TemporaryDirectory(prefix="barch-propose-") as td:
            p = Path(td) / "in"
            p.write_bytes(data)
            w, h = cover._size(p)
            if not cover._square(w, h) or min(w, h) < cover.MIN:
                raise ValueError(f"the image is {w}x{h}: it has to be square (±10 %) and at least {cover.MIN} px")
            b, fp = cover.look(p)
            c = cover.Cand(label or "Claude", "chosen", p, w, h, b, fp)
            jpeg, nw, nh = cover._to_jpeg(c, trim=False)
        d = self._alt_dir(folder)
        d.mkdir(parents=True, exist_ok=True)
        name = f"claude-{int(time.time())}.jpg"
        (d / name).write_bytes(jpeg)
        with self.lock:
            e = self.state.setdefault(folder, {})
            alts = e.setdefault("alts", [])
            alts.append({"file": name, "source": label or "Claude", "kind": "claude", "w": nw, "h": nh, "orig": f"{w}x{h}",
                         "framed": c.framed, "same": None, "trusted": True, "best": False})
            self._propose_alt(folder, e, len(alts) - 1)
            e["applied"] = False
            self.save()
        return f"{folder}: new proposal {label or 'Claude'} ({nw}x{nh}" + (", has a frame" if c.framed else "") + ")"

    # ------------------------------------------------------------ decisions
    def image(self, folder: str, which: str) -> bytes | None:
        if which.startswith("alt:"):
            e = self.state.get(folder) or {}
            try:
                p = self._alt_dir(folder) / e["alts"][int(which[4:])]["file"]
            except (KeyError, IndexError, ValueError):
                return None
        elif which == "proposal":
            p = self.root / f"{slug(folder)}.jpg"
        elif which == "previous":
            p = self.root / "undo" / slug(folder) / "cover.jpg"
        else:
            p = self.music / folder / "cover.jpg"
        return p.read_bytes() if p.is_file() else None

    @staticmethod
    def _embed(path: Path, data: bytes, w: int, h: int) -> None:
        x = FLAC(path)
        x.clear_pictures()
        pic = Picture()
        pic.type, pic.mime, pic.width, pic.height, pic.depth, pic.data = 3, "image/jpeg", w, h, 24, data
        x.add_picture(pic)
        x.save()

    def apply(self, folder: str) -> str:
        e = self.state.get(folder) or {}
        src = self.root / f"{slug(folder)}.jpg"
        if not e.get("proposal") or not src.is_file():
            raise KeyError("no proposal for this album")
        d = self.music / folder
        undo = self.root / "undo" / slug(folder)
        if not undo.exists():                     # the first replacement keeps the original
            undo.mkdir(parents=True)
            if (d / "cover.jpg").exists():
                shutil.copy2(d / "cover.jpg", undo / "cover.jpg")
            for f in sorted(d.glob("*.flac")):
                pics = [p for p in FLAC(f).pictures if p.type == 3]
                if pics:
                    (undo / "embedded.jpg").write_bytes(pics[0].data)
                    (undo / "embedded.json").write_text(json.dumps({"w": pics[0].width, "h": pics[0].height, "mime": pics[0].mime}))
                    break
        data = src.read_bytes()
        w, h = e["proposal"]["w"], e["proposal"]["h"]
        n = 0
        for f in sorted(d.glob("*.flac")):
            self._embed(f, data, w, h)
            n += 1
        (d / "cover.jpg").write_bytes(data)
        with self.lock:
            e["applied"], e["applied_at"] = True, time.time()
            self.save()
        plex = self._plex(folder, data)
        return f"{folder}: cover.jpg and {n} track(s) now carry {e['proposal']['source']} ({w}x{h})" + (f"; {plex}" if plex else "")

    def undo(self, folder: str) -> str:
        d = self.music / folder
        undo = self.root / "undo" / slug(folder)
        if not undo.is_dir():
            raise KeyError("nothing to undo for this album")
        old = undo / "cover.jpg"
        if old.exists():
            shutil.copy2(old, d / "cover.jpg")
        emb = undo / "embedded.jpg"
        n = 0
        if emb.exists():
            meta = json.loads((undo / "embedded.json").read_text())
            for f in sorted(d.glob("*.flac")):
                self._embed(f, emb.read_bytes(), meta["w"], meta["h"])
                n += 1
        shutil.rmtree(undo)
        with self.lock:
            e = self.state.get(folder) or {}
            e["applied"] = False
            self.save()
        plex = self._plex(folder, (d / "cover.jpg").read_bytes() if (d / "cover.jpg").exists() else None)
        return f"{folder}: the previous cover is back (cover.jpg, {n} track(s))" + (f"; {plex}" if plex else "")

    def _plex(self, folder: str, jpeg: bytes | None) -> str:
        if self.plex is None:
            return ""
        try:
            return self.plex.set_poster(folder, jpeg) if jpeg else self.plex.scan(folder)
        except Exception as e:  # noqa: BLE001 - Plex being down never undoes a cover
            return f"Plex: {e}"

    def summary(self) -> dict:
        with self.lock:
            entries = [{"folder": f, **{k: v for k, v in e.items() if k != "tried"}, "tried": e.get("tried", [])}
                       for f, e in sorted(self.state.items())]
            return {"running": self.running, "queued": len(self.queue), "entries": entries}

    def forget(self, folder: str) -> None:
        """Drop the proposal (keep the library's cover; checked again only when asked)."""
        with self.lock:
            e = self.state.get(folder)
            if e:
                e["verdict"] = "kept"
                (self.root / f"{slug(folder)}.jpg").unlink(missing_ok=True)
                self.save()
