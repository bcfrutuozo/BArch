"""The library's artists tied to MusicBrainz in Lidarr, the way library.py ties the albums.

Lidarr knows an artist by its MusicBrainz id and keeps one folder of /music for it; the files of an
album only map when the folder they are in belongs to the artist MusicBrainz credits the release to.
So every artist folder of /music should be one Lidarr artist, with the right id, at that folder.
`classify` (pure, tests/test_artists.py) puts each folder and each Lidarr artist in one state:

  linked     the folder is a Lidarr artist's path, and Lidarr maps files there (or none are tagged yet)
  suspect    a Lidarr artist's path, but Lidarr maps none of the files of its tagged albums: most
             likely the wrong MusicBrainz artist (a namesake), Link the right one
  missing    no Lidarr artist at this folder: Link it to its MusicBrainz artist
  pending    linked, but Lidarr's metadata server does not know the artist yet (retried hourly)
  skipped    Bruno said to leave it (a folder of a credit MusicBrainz has no artist for)
  no-folder  a Lidarr artist with no folder in /music yet (added by an import list, nothing in yet)

Evidence for the right artist comes from the folder's own albums: the releases the library sweep
tied them to (library.json) are looked up once and their artist credits counted (cached per release).
"""
from __future__ import annotations

import json
import os
import re
import shutil
import threading
import time
from pathlib import Path

from . import mb, style
from .integrations import norm_name

UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")


def mbid_of(text: str) -> str:
    m = UUID.search((text or "").lower())
    return m.group(0) if m else ""


def classify(folders: list[dict], tagged: dict[str, int], lidarr: list[dict], pending: list[dict],
             skipped: set[str], credited: dict[str, set[str]] | None = None) -> list[dict]:
    """folders: [{name, albums}] of /music; tagged: artist folder -> albums with MusicBrainz ids;
    lidarr: Lidarr.artists() rows (with path, albums, files); pending: [{mbid, folder}] waiting for
    Lidarr's metadata server; skipped: folders left alone; credited: artist folder -> the MusicBrainz
    artists its tied albums are credited to, where already known. One row per folder, then one per
    Lidarr artist without one."""
    credited = credited or {}
    by_dir = {}
    for a in lidarr:
        by_dir.setdefault(Path(a.get("path") or "").name, a)
    by_norm = {}
    for a in lidarr:
        if norm_name(a.get("name", "")):          # a name in another script flattens to "": no key
            by_norm.setdefault(norm_name(a.get("name", "")), a)
    pend = {x.get("folder"): x for x in pending}
    names = {f["name"] for f in folders}
    rows = []
    for f in folders:
        name, n, t = f["name"], f.get("albums", 0), tagged.get(f["name"], 0)
        a = by_dir.get(name)
        row = {"key": name, "folder": name, "albums": n, "tagged": t, "lidarr": a}
        if a:
            known = credited.get(name)
            if not t or a.get("files"):
                row.update(state="linked", why=f"{a.get('files', 0)} files mapped by Lidarr")
            elif known and a.get("mbid") not in known:
                row.update(state="suspect", why=f"its albums are credited to another MusicBrainz artist than {a.get('name')}: Link the right one")
            elif not a.get("albums"):
                # the artist is right (or nothing says otherwise), but Lidarr lists none of its albums: their
                # release type is outside the metadata profile (a game composer's Soundtrack), nothing to map to
                row.update(state="linked", why="Lidarr lists no album of this artist (its release types are outside the metadata profile)")
            elif known:
                row.update(state="linked", why=f"the right artist; Lidarr has not mapped the files of its {t} tied album(s) yet")
            else:
                row.update(state="suspect", why=f"Lidarr maps none of the files of its {t} tied album(s): "
                                                 f"is {a.get('name')} the right MusicBrainz artist? (its albums' credits are being looked up)")
        elif name in pend:
            row.update(state="pending", why="Lidarr's metadata server does not know this artist yet; tried again every hour",
                       mbid=pend[name].get("mbid", ""))
        elif name in skipped:
            row.update(state="skipped", why="left without a Lidarr artist")
        else:
            other = by_norm.get(norm_name(name)) if norm_name(name) else None
            row.update(state="missing", why=(f"not in Lidarr; Lidarr tracks {other.get('name')} at {other.get('path')}"
                                             if other else "not in Lidarr"))
        rows.append(row)
    for a in lidarr:
        d = Path(a.get("path") or "").name
        if d not in names:
            rows.append({"key": f"lidarr:{a.get('id')}", "folder": "", "albums": 0, "tagged": 0, "lidarr": a,
                         "state": "no-folder",
                         "why": "nothing of this artist in /music yet" + (f" ({a.get('files')} files mapped elsewhere?)" if a.get("files") else "")})
    return rows


def plan_move(src: list[str], dst: list[str]) -> tuple[list[str], list[str]]:
    """The album folders of one artist folder (`src`) going into another's (`dst`): (the ones that move,
    the ones that cannot: a folder of the same name, compared as the library does, is there already)."""
    there = {norm_name(d) for d in dst}
    moves = [a for a in src if norm_name(a) not in there]
    return moves, [a for a in src if a not in moves]


def count_credits(credits: list[list[dict]]) -> list[dict]:
    """The artist credits of a folder's releases ([[{mbid, name}], ...], one list per release) ->
    [{mbid, name, releases}], the most credited first (a release counts once per artist)."""
    out: dict[str, dict] = {}
    for rel in credits:
        for c in {x["mbid"]: x for x in rel if x.get("mbid")}.values():
            e = out.setdefault(c["mbid"], {"mbid": c["mbid"], "name": c.get("name", ""), "releases": 0})
            e["releases"] += 1
    return sorted(out.values(), key=lambda e: (-e["releases"], e["name"].casefold()))


class Artists:
    def __init__(self, music: Path, root: Path, lidarr, library, add_artists, pending_artists,
                 covers=None, plex=None, catalog=None):
        self.music = music
        self.lidarr = lidarr
        self.library = library
        self.add_artists = add_artists          # Pipeline.add_artists: [{mbid, folder}] -> lines
        self.pending_artists = pending_artists  # Pipeline.pending_artists
        self.covers = covers                    # LibraryCovers (its state is keyed by album folder)
        self.plex = plex
        self.catalog = catalog
        self.file = root / "artists.json"
        self.cache_file = root / "artist-credits.json"
        self.lock = threading.Lock()
        try:
            self.state = json.loads(self.file.read_text())
        except (OSError, ValueError):
            self.state = {}
        try:
            self.credits = json.loads(self.cache_file.read_text())
        except (OSError, ValueError):
            self.credits = {}

    def _save(self) -> None:
        self.file.write_text(json.dumps(self.state, ensure_ascii=False))

    def skipped(self) -> set[str]:
        return set(self.state.get("skipped") or [])

    # ------------------------------------------------------------ reading
    def folders(self) -> list[dict]:
        out = []
        for d in sorted(self.music.iterdir(), key=lambda x: x.name.casefold()):
            if d.is_dir() and not style.hidden(d.name):
                try:
                    n = sum(1 for a in d.iterdir() if a.is_dir() and not style.hidden(a.name))
                except OSError:
                    n = 0
                out.append({"name": d.name, "albums": n})
        return out

    def tagged(self) -> dict[str, int]:
        out: dict[str, int] = {}
        for folder, e in list(self.library.state.items()):
            if e.get("mbid") and e.get("state") in ("had", "tagged"):
                a = folder.split("/")[0]
                out[a] = out.get(a, 0) + 1
        return out

    def credited(self) -> dict[str, set[str]]:
        """Artist folder -> the artists its tied albums are credited to, from the cache only (no request)."""
        out: dict[str, set[str]] = {}
        for f, e in list(self.library.state.items()):
            if e.get("mbid") in self.credits:
                out.setdefault(f.split("/")[0], set()).update(c["mbid"] for c in self.credits[e["mbid"]] if c.get("mbid"))
        return out

    def _warm(self, folders: list[str]) -> None:
        """The credits of these folders' albums looked up in the background (MusicBrainz, a request a second)."""
        if not folders or getattr(self, "_warming", False):
            return
        self._warming = True

        def run():
            try:
                for f in folders:
                    try:
                        self.evidence(f)
                    except Exception:  # noqa: BLE001
                        pass
            finally:
                self._warming = False
        threading.Thread(target=run, daemon=True).start()

    def overview(self) -> dict:
        rows = classify(self.folders(), self.tagged(), self.lidarr.artists(), self.pending_artists(), self.skipped(), self.credited())
        self._warm([r["folder"] for r in rows if r["state"] in ("suspect", "missing") and r["tagged"]
                    and any(rid not in self.credits for rid in self.releases(r["folder"]))])
        counts: dict[str, int] = {}
        for r in rows:
            counts[r["state"]] = counts.get(r["state"], 0) + 1
        return {"counts": counts, "artists": rows}

    def releases(self, folder: str, limit: int = 4) -> list[str]:
        """Release ids the sweep tied this artist folder's albums to (the first `limit`)."""
        return [e["mbid"] for f, e in sorted(self.library.state.items())
                if f.split("/")[0] == folder and e.get("mbid") and e.get("state") in ("had", "tagged")][:limit]

    def evidence(self, folder: str) -> list[dict]:
        """Who MusicBrainz credits the folder's tied albums to: [{mbid, name, releases}]."""
        lists = []
        for rid in self.releases(folder):
            if rid not in self.credits:
                rel = mb.release(rid) or {}
                self.credits[rid] = [{"mbid": (c.get("artist") or {}).get("id", ""), "name": (c.get("artist") or {}).get("name", "")}
                                     for c in rel.get("artist-credit") or [] if isinstance(c, dict)]
                with self.lock:
                    self.cache_file.write_text(json.dumps(self.credits))
            lists.append(self.credits[rid])
        return count_credits(lists)

    def candidates(self, folder: str = "", q: str = "") -> dict:
        """MusicBrainz artists for a folder (its name, plus who its albums are credited to) or for a
        name typed by hand: [{mbid, name, disambiguation, type, country, years, score, releases, lidarr}]."""
        name = (q or folder).strip()
        if not name:
            raise ValueError("a folder or a name")
        ev = self.evidence(folder) if folder else []
        found = []
        if mbid_of(name):                         # an artist id or its MusicBrainz URL, pasted
            a = mb.artist(mbid_of(name))
            found = [a] if a else []
        else:
            d = mb.get(f"{mb.MB}/artist", {"query": f"artist:{mb._q(name)} OR alias:{mb._q(name)}", "limit": 10, "fmt": "json"}, mb=True) or {}  # noqa: SLF001
            found = d.get("artists") or []
        have = {a["id"] for a in found}
        for e in ev:                              # a credited artist the search did not bring
            if e["mbid"] not in have:
                a = mb.artist(e["mbid"])
                if a:
                    found.insert(0, a)
        tracked = {a["mbid"]: a for a in self.lidarr.artists()}
        counts = {e["mbid"]: e["releases"] for e in ev}
        out = []
        for a in found:
            life = a.get("life-span") or {}
            years = "–".join(x[:4] for x in (life.get("begin") or "", life.get("end") or "") if x)
            t = tracked.get(a["id"])
            out.append({"mbid": a["id"], "name": a.get("name", ""), "disambiguation": a.get("disambiguation", ""),
                        "type": a.get("type", ""), "country": a.get("country") or (a.get("area") or {}).get("name", ""),
                        "years": years, "score": a.get("score", 100 if a["id"] in counts else 0), "releases": counts.get(a["id"], 0),
                        "lidarr": {"id": t["id"], "path": t.get("path", ""), "files": t.get("files", 0)} if t else None,
                        "url": f"https://musicbrainz.org/artist/{a['id']}"})
        out.sort(key=lambda c: (-c["releases"], -int(c["score"] or 0)))
        return {"query": name, "tied": len(self.releases(folder)) if folder else 0, "candidates": out}

    # ------------------------------------------------------------ acting
    def link(self, folder: str, mbid_text: str) -> str:
        """The folder becomes the Lidarr artist `mbid` (Lidarr's path set to it): a wrong artist at the folder
        leaves Lidarr (its files stay), the right one already tracked elsewhere with nothing mapped moves here."""
        mbid = mbid_of(mbid_text)
        if not mbid:
            raise ValueError("no MusicBrainz artist id")
        if not folder or "/" in folder or not (self.music / folder).is_dir():
            raise ValueError(f"no artist folder {folder!r} in the library")
        artists = self.lidarr.artists()
        here = next((a for a in artists if Path(a.get("path") or "").name == folder), None)
        there = next((a for a in artists if a["mbid"] == mbid), None)
        if here and here["mbid"] == mbid:
            return f"{folder}: already {here['name']} in Lidarr"
        if there and there.get("files"):
            raise ValueError(f"Lidarr tracks {there['name']} at {there['path']} with {there['files']} files mapped, and keeps one "
                             f"folder per artist: move the albums of {folder} into {Path(there['path']).name}, or Skip this folder")
        out = []
        if here:
            out.append(self.lidarr.delete_artist(here["id"]))
        if there:
            out.append(self.lidarr.set_artist_path(there["id"], folder))
            out.append(self.lidarr.targeted_rescans([there["id"]]))
        else:
            out += self.add_artists([{"mbid": mbid, "folder": folder}])
        self.unskip(folder)
        return "\n".join(o for o in out if o)

    def add(self, mbid_text: str) -> str:
        """An artist the library does not have yet (one an import list could not map): tracked in Lidarr at
        the folder its name gives, so the hourly enforce brings its official albums."""
        mbid = mbid_of(mbid_text)
        if not mbid:
            raise ValueError("no MusicBrainz artist id")
        if any(a["mbid"] == mbid for a in self.lidarr.artists()):
            return "Lidarr tracks this artist already"
        a = mb.artist(mbid)
        if not a:
            raise ValueError(f"MusicBrainz has no artist {mbid}")
        return "\n".join(self.add_artists([{"mbid": mbid, "folder": style.folder_name(a.get("name", mbid))}]))

    def remove(self, lidarr_id: int) -> str:
        """A Lidarr artist out of Lidarr (a wrong match of an import list); never one that maps files."""
        a = next((x for x in self.lidarr.artists() if x["id"] == int(lidarr_id)), None)
        if not a:
            raise ValueError(f"Lidarr has no artist {lidarr_id}")
        if a.get("files"):
            raise ValueError(f"{a['name']} maps {a['files']} files: Link its folder to the right artist instead")
        return self.lidarr.delete_artist(a["id"])

    def albums_of(self, folder: str) -> list[str]:
        d = self.music / folder
        return sorted((x.name for x in d.iterdir() if x.is_dir() and not style.hidden(x.name)), key=str.casefold) if d.is_dir() else []

    TRASH = ".library-trash"        # as Pipeline.TRASH: /music/.library-trash/<stamp> Artist - Album, purged after 30 days

    def move(self, folder: str, into: str, replace: bool = False) -> str:
        """The album folders of /music/<folder> moved into /music/<into> (the folder of the artist MusicBrainz
        credits them to, which Lidarr tracks), names kept; one whose name is there already stays, unless
        `replace`: then the one in <into> goes to the library trash (30 days) and this one takes its place (Bruno
        picked the edition to keep). The sweep's and the covers' entries follow, Lidarr rescans <into>, Plex
        scans both, the Player's catalog reads them again, and <folder> goes once empty."""
        for f in (folder, into):
            if not f or "/" in f or style.hidden(f) or not (self.music / f).is_dir():
                raise ValueError(f"no artist folder {f!r} in the library")
        if folder == into:
            raise ValueError("the same folder")
        dst_albums = self.albums_of(into)
        moves, stay = plan_move(self.albums_of(folder), dst_albums)
        trashed = []
        if replace and stay:
            trash = self.music / self.TRASH
            trash.mkdir(parents=True, exist_ok=True)
            for a in stay:
                old = next(d for d in dst_albums if norm_name(d) == norm_name(a))
                t = trash / f"{time.strftime('%Y%m%d-%H%M%S')} {style.folder_name(into)} - {style.folder_name(old)}"
                shutil.move(str(self.music / into / old), str(t))
                os.utime(t, None)
                self.library.forget(f"{into}/{old}")
                trashed.append(f"{into}/{old} -> {self.TRASH}/{t.name}")
            moves, stay = moves + stay, []
        if not moves:
            raise ValueError(f"every album of {folder} has a folder of the same name in {into}: nothing moved")
        done = []
        for a in moves:
            old, new = f"{folder}/{a}", f"{into}/{a}"
            shutil.move(str(self.music / old), str(self.music / new))
            done.append(a)
            for st, save in ((self.library.state, self.library.save), (getattr(self.covers, "state", None), getattr(self.covers, "save", None))):
                if st is not None and old in st:
                    st[new] = st.pop(old)
                    save()
        out = [f"{len(done)} album(s) moved from {folder} into {into}: " + ", ".join(done)]
        if trashed:
            out.append("replaced (kept 30 days): " + ", ".join(trashed))
        if stay:
            out.append(f"stayed in {folder} (a folder of the same name is in {into}): " + ", ".join(stay))
        try:
            next(x for x in (self.music / folder).iterdir())
            if not stay:
                out.append(f"{folder} still holds files that are not albums; left as is")
        except StopIteration:
            (self.music / folder).rmdir()
            self.unskip(folder)
            out.append(f"{folder} removed (empty)")
        for step in (lambda: self.lidarr.rescan_artists([into]), lambda: self.plex and self.plex.scan(into),
                     lambda: self.plex and self.plex.scan(folder)):
            try:
                r = step()
                if r:
                    out.append(r)
            except Exception as e:  # noqa: BLE001
                out.append(str(e))
        if self.catalog:
            self.catalog.refresh_async()
        return "\n".join(out)

    def skip(self, folder: str) -> str:
        with self.lock:
            s = self.skipped() | {folder}
            self.state["skipped"] = sorted(s)
            self._save()
        return f"{folder}: left without a Lidarr artist"

    def unskip(self, folder: str) -> str:
        with self.lock:
            s = self.skipped()
            if folder not in s:
                return ""
            self.state["skipped"] = sorted(s - {folder})
            self._save()
        return f"{folder}: back in the list"
