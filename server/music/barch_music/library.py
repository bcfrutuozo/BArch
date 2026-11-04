"""The library made by hand, tied to MusicBrainz: every album folder of /music whose files carry no
MusicBrainz ids goes through the matcher with the lengths of its own files (nothing is downloaded,
the audio never changes). Without that, Lidarr maps the files by name and guesses (thousands of
unmapped files), merges compare by title and a same-title album looks like the one in the library.

    certain match (the matcher accepts it: lengths, titles, names, no rival with other titles)
        -> MUSICBRAINZ_ALBUMID and MUSICBRAINZ_TRACKID written on the files, nothing else; the old
           values go to an undo log; Lidarr rescans the artist
    anything else (two editions with other titles, lengths off, nothing on MusicBrainz)
        -> waits in `library.json` with the candidates and the reason: the Music app's Library tab
           (Use a candidate after the comparison, Tag; Add to MusicBrainz; Skip)

One album per step, only while no job waits (the pipeline's loop calls step()); the state survives
restarts, so the first pass over 1,800 albums simply takes its hours. Albums already tagged are
skipped; "none" and "ambiguous" are tried again after a month (MusicBrainz grows)."""
from __future__ import annotations

import json
import re
import threading
import time
from pathlib import Path

from mutagen.flac import FLAC

from . import matcher
from .audio import Track

RETRY = 30 * 86400
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")


def _int(v: str, default: int) -> int:
    m = re.match(r"\s*(\d+)", v or "")
    return int(m.group(1)) if m else default


def read_tracks(folder: Path) -> list[Track]:
    """The album's files as the matcher's Tracks: disc and position from the tags (or the "1.03 - "
    file name the library uses), length from the stream, title and artist as hints."""
    files = sorted(folder.rglob("*.flac"), key=lambda p: (str(p.parent), p.name.lower()))
    out = []
    for n, f in enumerate(files, 1):
        x = FLAC(f)
        tags = {k.upper(): v[0] for k, v in (x.tags or {}).items()}
        m = re.match(r"^(\d+)\.(\d+)\s", f.name)
        disc = _int(tags.get("DISCNUMBER", ""), int(m.group(1)) if m else 1)
        index = _int(tags.get("TRACKNUMBER", ""), int(m.group(2)) if m else n)
        out.append(Track(f, disc, index, x.info.total_samples, x.info.sample_rate, x.info.bits_per_sample,
                         {"title": tags.get("TITLE", ""), "artist": tags.get("ARTIST", ""),
                          "album_id": tags.get("MUSICBRAINZ_ALBUMID", ""), "track_id": tags.get("MUSICBRAINZ_TRACKID", "")}))
    return out


def hints_for(folder: str, tracks: list[Track]) -> dict:
    artist, _, album = folder.partition("/")
    base = re.sub(r"\s*\((?:19|20)\d{2}\)\s*$", "", album)          # "Greatest Hits (2008)": a same-title album's folder
    year = ""
    try:
        d = (FLAC(tracks[0].path).get("DATE") or [""])[0] if tracks else ""
        year = d[:4] if re.match(r"\d{4}", d) else ""
    except Exception:  # noqa: BLE001
        pass
    return {"artist": artist.replace("_", ":"), "album": base.replace("_", ":"), "album_folder": base, "year": year, "mbid": ""}


def pairs(cand: matcher.Candidate, tracks: list[Track]) -> list[tuple[Track, dict]]:
    """(file, MusicBrainz track) as the matcher paired them (one disc spread over several included)."""
    discs, _ = matcher.discs_for(tracks, cand.media)
    out = []
    for (_, ts), m in zip(sorted(discs.items()), cand.media):
        for t, mt in zip(sorted(ts, key=lambda x: x.index), m.get("tracks") or []):
            out.append((t, mt))
    return out


class Library:
    def __init__(self, music: Path, root: Path, lidarr=None):
        self.music = music
        self.file = root / "library.json"
        self.undo_dir = root / "library-undo"
        self.lidarr = lidarr
        self.lock = threading.Lock()
        self.paused = False
        self.current = ""
        self.last_error = ""
        self.rescan: set[str] = set()                     # artists tagged since the last Lidarr rescan
        try:
            self.state = json.loads(self.file.read_text())
        except (OSError, ValueError):
            self.state = {}

    def save(self) -> None:
        tmp = self.file.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.state))
        tmp.replace(self.file)

    def folders(self) -> list[str]:
        out = []
        for a in sorted(self.music.iterdir(), key=lambda p: p.name.casefold()):
            if a.is_dir() and not a.name.startswith("."):
                for b in sorted(a.iterdir(), key=lambda p: p.name.casefold()):
                    if b.is_dir() and not b.name.startswith("."):
                        out.append(f"{a.name}/{b.name}")
        return out

    def next_folder(self) -> str:
        now = time.time()
        for f in self.folders():
            e = self.state.get(f)
            if not e:
                return f
            if e["state"] in ("none", "ambiguous", "error") and now - e.get("t", 0) > RETRY:
                return f
        return ""

    # ---------------------------------------------------------------- one album
    def step(self) -> bool:
        """Judge the next album (False when there is nothing left or the sweep is paused)."""
        if self.paused:
            return False
        folder = self.next_folder()
        if not folder:
            self.flush_rescan()
            return False
        self.current = folder
        try:
            entry = self.judge(folder)
        except Exception as e:  # noqa: BLE001
            entry = {"state": "error", "why": f"{type(e).__name__}: {e}"}
        finally:
            self.current = ""
        entry["t"] = time.time()
        with self.lock:
            self.state[folder] = entry
            self.save()
        if entry["state"] == "tagged" and len(self.rescan) >= 1 and folder.split("/")[0] not in self.rescan:
            self.flush_rescan()                            # the previous artist is done: Lidarr sees it now
        if entry["state"] == "tagged":
            self.rescan.add(folder.split("/")[0])
        return True

    def judge(self, folder: str) -> dict:
        path = self.music / folder
        tracks = read_tracks(path)
        if not tracks:
            return {"state": "empty", "why": "no FLAC files"}
        ids = {t.hints.get("album_id") for t in tracks}
        if len(ids) == 1 and "" not in ids and all(t.hints.get("track_id") for t in tracks):
            return {"state": "had", "mbid": ids.pop()}
        hints = hints_for(folder, tracks)
        best, cands, reason = matcher.find(tracks, hints)
        summary = [c.summary() for c in cands[:6]]
        if best and best.ok and not best.bad and not best.reorder:
            n = self.write(folder, best, tracks, "the matcher")
            return {"state": "tagged", "mbid": best.mbid, "title": best.title, "why": f"{n} files tagged", "candidates": summary[:1]}
        state = "none" if not cands else "ambiguous"
        return {"state": state, "why": reason or "no release fits well enough", "candidates": summary,
                "tracks": [{"disc": t.disc, "index": t.index, "seconds": round(t.seconds, 1), "title": t.hints.get("title", "")} for t in tracks]}

    def write(self, folder: str, cand: matcher.Candidate, tracks: list[Track], who: str) -> int:
        """MUSICBRAINZ_ALBUMID and MUSICBRAINZ_TRACKID on every file of the album, the old values kept in
        an undo log. Nothing else is touched (the library's own titles, numbers and art stay)."""
        undo, n = [], 0
        for t, mt in pairs(cand, tracks):
            rec = (mt.get("recording") or {}).get("id", "")
            x = FLAC(t.path)
            old = {k: list(x.get(k) or []) for k in ("MUSICBRAINZ_ALBUMID", "MUSICBRAINZ_TRACKID")}
            new = {"MUSICBRAINZ_ALBUMID": [cand.mbid], "MUSICBRAINZ_TRACKID": [rec] if rec else old["MUSICBRAINZ_TRACKID"]}
            if old == new:
                continue
            for k, v in new.items():
                if v:
                    x[k] = v
            x.save()
            undo.append({"path": str(t.path), "tags": old})
            n += 1
        if undo:
            self.undo_dir.mkdir(parents=True, exist_ok=True)
            (self.undo_dir / f"{time.strftime('%Y%m%d-%H%M%S')}-{re.sub(r'[^A-Za-z0-9]+', '_', folder)[:80]}.json").write_text(
                json.dumps({"folder": folder, "release": cand.mbid, "by": who, "files": undo}, ensure_ascii=False))
        return n

    def flush_rescan(self) -> None:
        if self.rescan and self.lidarr and self.lidarr.enabled:
            try:
                self.lidarr.rescan_artists(sorted(self.rescan))
            except Exception as e:  # noqa: BLE001
                print(f"[library] Lidarr rescan: {e}", flush=True)
        self.rescan.clear()

    # ---------------------------------------------------------------- decisions (the app)
    def tag(self, folder: str, release: str) -> str:
        """Bruno picked the release (after the comparison): tag the album with it, whatever the score,
        as long as the track count per disc fits."""
        m = UUID.search(release or "")
        if not m:
            raise ValueError("no MusicBrainz release id")
        tracks = read_tracks(self.music / folder)
        if not tracks:
            raise ValueError(f"{folder}: no FLAC files")
        best, cands, reason = matcher.find(tracks, hints_for(folder, tracks), force=m.group(0))
        if not best:
            raise ValueError(reason)
        n = self.write(folder, best, tracks, "Bruno")
        with self.lock:
            self.state[folder] = {"state": "tagged", "mbid": best.mbid, "title": best.title, "why": f"{n} files tagged (chosen)", "t": time.time()}
            self.save()
        self.rescan.add(folder.split("/")[0])
        self.flush_rescan()
        return f"{folder}: {n} files tagged with {best.artist} – {best.title} ({best.mbid})"

    def skip(self, folder: str) -> str:
        with self.lock:
            e = self.state.get(folder) or {}
            e.update(state="skipped", t=time.time())
            self.state[folder] = e
            self.save()
        return f"{folder}: skipped (not tied to MusicBrainz)"

    def retry(self, folder: str) -> str:
        with self.lock:
            self.state.pop(folder, None)
            self.save()
        return f"{folder}: judged again in the next idle step"

    def compare(self, folder: str, release: str) -> dict:
        from . import mb
        m = UUID.search(release or "")
        if not m:
            raise ValueError("no MusicBrainz release id")
        rel = mb.release(m.group(0))
        if not rel:
            raise ValueError("MusicBrainz has no such release")
        tracks = read_tracks(self.music / folder)
        return {"mbid": m.group(0), **matcher.compare([{"disc": t.disc, "index": t.index, "seconds": t.seconds,
                                                        "title": t.hints.get("title", "")} for t in tracks], rel)}

    def summary(self) -> dict:
        counts: dict[str, int] = {}
        for e in self.state.values():
            counts[e["state"]] = counts.get(e["state"], 0) + 1
        todo = [{"folder": f, **e} for f, e in sorted(self.state.items()) if e["state"] in ("ambiguous", "none", "error")]
        return {"counts": counts, "albums": sum(1 for _ in self.folders()), "current": self.current, "paused": self.paused,
                "last_error": self.last_error,
                "decide": todo}
