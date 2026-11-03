"""One album from a download to /music, or to the review queue with the reason.

Jobs live on disk (<jobs>/<id>/job.json), so a restart, a retry or a decision made in the review
(another release, a cover, a date) just runs the job again. A torrent that holds several albums
(a discography) becomes one job per album; it is deleted from qBittorrent only when every one of
them is in the library.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import threading
import time
import traceback
import uuid
from pathlib import Path

from mutagen.flac import FLAC

from . import album as albummod
from . import audio, cover, matcher, mb, merge, style, tagger
from .libcovers import LibraryCovers
from .integrations import Lidarr, Plex, QBit, Telegram

STATES = ("queued", "working", "review", "done", "failed", "rejected")
NET_RETRIES = 5          # a job cut by a network error (MusicBrainz 503...) waits 2, 4, 8, 16, 32 min, then fails


class Store:
    def __init__(self, root: Path):
        self.root = root
        self.root.mkdir(parents=True, exist_ok=True)
        self.lock = threading.RLock()

    def path(self, jid: str) -> Path:
        return self.root / jid

    def load(self, jid: str) -> dict | None:
        try:
            return json.loads((self.path(jid) / "job.json").read_text())
        except (OSError, json.JSONDecodeError):
            return None

    def save(self, job: dict) -> None:
        with self.lock:
            job["updated"] = time.time()
            d = self.path(job["id"])
            d.mkdir(parents=True, exist_ok=True)
            tmp = d / "job.json.tmp"
            tmp.write_text(json.dumps(job, ensure_ascii=False, indent=1))
            tmp.replace(d / "job.json")

    def all(self) -> list[dict]:
        out = []
        for d in sorted(self.root.iterdir()) if self.root.exists() else []:
            j = self.load(d.name)
            if j:
                out.append(j)
        return out

    def new(self, **kw) -> dict:
        job = {"id": time.strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:4], "state": "queued", "created": time.time(),
               "log": [], "notes": [], "problems": [], "candidates": [], "chosen": "", "cover": "",
               "overrides": {}, "replace": False, "result": {}, **kw}
        self.save(job)
        return job


def album_roots(source: Path) -> list[Path]:
    """The albums inside a download: folders holding audio (or a CUE), with disc folders (CD1,
    Disc 2) folded into their album."""
    if source.is_file():
        return [source]
    roots = set()
    for f in source.rglob("*"):
        if f.is_file() and (f.suffix.lower() in audio.LOSSLESS or f.suffix.lower() in (".cue",) or f.suffix.lower() in audio.ARCHIVES):
            d = f.parent
            while d != source and is_disc_folder(d.name):
                d = d.parent
            roots.add(d)
    if len(roots) > 1 and source in roots:
        roots.discard(source)
    # nested album folders under one album folder (a CD1 not named CD1): keep the outermost
    roots = {r for r in roots if not any(r != o and o in r.parents for o in roots)} if len(roots) > 1 else roots
    return sorted(roots) or [source]


_DISC_ONLY = re.compile(r"(?i)(cd|disc|disk|dvd|vol(ume)?)[\s._-]*\d{1,2}.*")
_DISC_AT_END = re.compile(r"(?i)(?:^|[\s,._(\[-])(?:cd|disc|disk|dvd|vol(?:ume)?)[\s._-]*\d{1,2}\s*[)\]]?\s*$")


def is_disc_folder(name: str) -> bool:
    """"CD1", "Disc 2 - The Battle", "The Platinum Collection, disc 2", "Album (CD 3)": one disc of
    the album in the folder above, not an album of its own."""
    return bool(_DISC_ONLY.fullmatch(name) or _DISC_AT_END.search(name))


def other_album_in(target: Path, group_mbid: str) -> str:
    """The MusicBrainz release group of the album already in `target`, when it is not `group_mbid`:
    a library with "Greatest Hits" (1998) must not receive the tracks of the other seven albums
    MusicBrainz calls Greatest Hits. Empty when it is the same album (any edition) or unknown."""
    if not group_mbid:
        return ""
    for f in sorted(target.glob("*.flac")):
        try:
            lib_id = (FLAC(f).get("MUSICBRAINZ_ALBUMID") or [""])[0].strip()
        except Exception:  # noqa: BLE001
            return ""
        if not lib_id:
            return ""
        rel = mb.release(lib_id) or {}
        lib_group = (rel.get("release-group") or {}).get("id", "")
        return lib_group if lib_group and lib_group != group_mbid else ""
    return ""


def find_existing(music: Path, folder: str) -> Path:
    """The album folder as the library already names it: "Pandora’s Box" finds "Pandora's Box",
    "Motorhead" finds "Motörhead" (compared without accents, punctuation and case)."""
    target = music / folder
    if target.exists():
        return target
    artist, album = folder.split("/", 1)
    adir = music / artist
    if not adir.is_dir():
        adir = next((d for d in music.iterdir() if d.is_dir() and style.norm(d.name) == style.norm(artist)), adir) if music.is_dir() else adir
    if adir.is_dir() and style.norm(album):
        hit = next((d for d in adir.iterdir() if d.is_dir() and style.norm(d.name) == style.norm(album)), None)
        if hit:
            return hit
    return adir / album


class Pipeline:
    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.music = Path(cfg.get("music", "/music"))
        self.store = Store(Path(cfg.get("jobs", "/data/music-pipeline")))
        self.inbox = Path(cfg.get("inbox", "/data/music-inbox"))
        self.qbit = QBit(cfg.get("qbittorrent", {}))
        self.lidarr = Lidarr(cfg.get("lidarr", {}))
        self.plex = Plex(cfg.get("plex", {}))
        self.tg = Telegram(cfg.get("telegram", {}))
        self.wake = threading.Event()
        self.current = ""
        self.last_enforce = 0.0
        self.covers = LibraryCovers(self.music, self.store.root / "covers", self.plex)

    # ------------------------------------------------------------ intake
    def log(self, job: dict, msg: str) -> None:
        job.setdefault("log", []).append(time.strftime("%H:%M:%S ") + msg)
        print(f"[{job['id']}] {msg}", flush=True)

    def from_torrent(self, t: dict) -> list[dict]:
        """A completed torrent -> one job per album in it (once: the torrent gets a tag)."""
        path = Path(t.get("content_path") or Path(t["save_path"]) / t["name"])
        roots = album_roots(path) if path.exists() else [path]
        jobs = []
        for r in roots:
            jobs.append(self.store.new(kind="torrent", hash=t["hash"], torrent=t["name"], source=str(r),
                                       name=r.name if r != path else t["name"], siblings=len(roots)))
        self.qbit.tag(t["hash"], add="pipeline")
        return jobs

    def from_inbox(self, folder: Path) -> list[dict]:
        roots = album_roots(folder)
        jobs = [self.store.new(kind="inbox", source=str(r), name=r.name, inbox=str(folder), siblings=len(roots)) for r in roots]
        (folder / ".pipeline").write_text(json.dumps([j["id"] for j in jobs]))
        return jobs

    def scan(self) -> int:
        """New completed torrents of the configured categories and new folders in the inbox."""
        n = 0
        try:
            for t in self.qbit.completed(self.cfg.get("categories", ["lidarr"])):
                if "pipeline" in (t.get("tags") or "").split(", "):
                    continue
                n += len(self.from_torrent(t))
        except Exception as e:  # noqa: BLE001
            print("scan qBittorrent:", e, flush=True)
        if self.inbox.is_dir():
            for d in sorted(self.inbox.iterdir()):
                if d.name.startswith(".") or (d / ".pipeline").exists():
                    continue
                if time.time() - max((p.stat().st_mtime for p in d.rglob("*")), default=0) < 120:
                    continue                                   # still being copied
                n += len(self.from_inbox(d))
        if n:
            self.wake.set()
        return n

    # ------------------------------------------------------------ the work
    def next_job(self) -> dict | None:
        now = time.time()
        for j in self.store.all():
            if j["state"] == "queued" and float(j.get("retry_at") or 0) <= now:
                return j
        return None

    def run_forever(self) -> None:
        for j in self.store.all():              # a job cut by a restart starts again
            if j["state"] == "working":
                j["state"] = "queued"
                self.store.save(j)
        while True:
            job = self.next_job()
            if not job:
                self.enforce_lidarr()
                self.wake.wait(timeout=60)
                self.wake.clear()
                continue
            self.current = job["id"]
            try:
                self.process(job)
            except mb.NetError as e:
                # the network, not the album: back in the queue with a growing wait, failed only after NET_RETRIES
                job = self.store.load(job["id"]) or job
                n = int(job.get("net_retries") or 0) + 1
                if n > NET_RETRIES:
                    self.fail(job, e)
                else:
                    wait = 2 ** n                                      # minutes: 2, 4, 8, 16, 32
                    job.update(state="queued", net_retries=n, retry_at=time.time() + wait * 60, problems=[f"network: {e}"])
                    self.log(job, f"network error: {e}; retry {n}/{NET_RETRIES} in {wait} min")
                    self.store.save(job)
            except Exception as e:  # noqa: BLE001
                self.fail(self.store.load(job["id"]) or job, e)
            finally:
                self.current = ""

    def fail(self, job: dict, e: Exception) -> None:
        job["state"] = "failed"
        job["problems"] = [f"{type(e).__name__}: {e}"]
        job.pop("retry_at", None)
        self.log(job, "failed: " + traceback.format_exc().strip().splitlines()[-1])
        self.store.save(job)
        self.tg.send(f"❌ Música: {job['name']}\n{e}")

    def enforce_lidarr(self, force: bool = False) -> str:
        """Every hour (or now): every artist Lidarr has on the library's metadata profile, every album
        without a file monitored, new ones too (`lidarr.profile` in config.json, "BArch"; "" turns it off)."""
        profile = self.cfg.get("lidarr", {}).get("profile", "BArch")
        if not profile or (not force and time.time() - self.last_enforce < 3600):
            return ""
        self.last_enforce = time.time()
        try:
            r = self.lidarr.enforce(profile, self.store.root / "lidarr-seen.json")
        except Exception as e:  # noqa: BLE001
            r = f"Lidarr: profile check failed: {e}"
        if not r.endswith("nothing to change") and not r.endswith("nothing changed"):
            print(f"[pipeline] {r}", flush=True)
        return r

    def process(self, job: dict) -> None:
        from .service import missing_tools
        if missing_tools():
            job["state"] = "queued"          # stays in the queue until the tools are there
            self.log(job, "waiting: missing " + ", ".join(missing_tools()))
            self.store.save(job)
            time.sleep(300)
            return
        job.update(state="working", problems=[], notes=[])
        job.pop("retry_at", None)
        self.store.save(job)
        src = Path(job["source"])
        if not src.exists():
            if (job.get("result") or {}).get("files") or (job.get("result") or {}).get("merged"):
                # delivered before and its download already cleaned up: run twice, nothing to redo
                job["state"], job["problems"] = "done", []
                self.log(job, "already delivered; the download is gone, nothing to do again")
                return self.store.save(job)
            raise FileNotFoundError(f"the download is gone: {src}")
        work = self.store.path(job["id"]) / "work"
        shutil.rmtree(work, ignore_errors=True)
        work.mkdir(parents=True)
        self.log(job, f"collecting {src}")
        try:
            tracks, notes = audio.collect(src, work)
        except audio.AudioError as e:
            return self.to_review(job, [str(e)])
        job["notes"] += notes
        job["audio"] = {"tracks": len(tracks), "discs": len({t.disc for t in tracks}),
                        "format": sorted({f"{t.bits or 16}/{t.rate // 1000 if t.rate % 1000 == 0 else t.rate / 1000}" for t in tracks})}
        hints = matcher.hints_from(job.get("name") or src.name, tracks)
        job["hints"] = hints
        self.log(job, f"{len(tracks)} tracks; looking up {hints.get('artist')} - {hints.get('album')}")
        best, cands, reason = matcher.find(tracks, hints, force=job.get("chosen", ""), acoustid_key=self.cfg.get("acoustid_key", ""),
                                           keep_order=bool(job.get("keep_order")))
        job["candidates"] = [c.summary() for c in cands[:8]]
        if not best:
            return self.to_review(job, [reason])
        job["match"] = best.summary()
        alb = albummod.build(best, tracks, self.music, job.get("overrides"))
        job["notes"] += alb.notes
        target = find_existing(self.music, alb.folder)
        if target != self.music / alb.folder:
            job["notes"].append(f"the library has this album as {target.relative_to(self.music)}: that folder is used")
            alb.folder = str(target.relative_to(self.music))
        existing = target.is_dir() and any(target.glob("*.flac")) and not job.get("replace")
        other = other_album_in(target, alb.group_mbid) if existing else ""
        if other:
            return self.to_review(job, [f"{alb.folder} is in the library but it is another album with the same name "
                                        f"(MusicBrainz release group {other}, this download is {alb.group_mbid}): give this one "
                                        f"its own folder with --album \"{alb.album} ({alb.date[:4] or 'year'})\", or reject it"])
        local = audio.find_images(src, work)
        lib_cover = target / "cover.jpg"
        cov, tried = cover.find(alb.mbid, alb.group_mbid, alb.artist_folder, alb.album, local, job.get("cover", ""),
                                library=lib_cover if existing else None, asin=(best.release or {}).get("asin") or "",
                                discogs_token=self.cfg.get("discogs_token", ""), explicit_label=job.get("cover_label", ""),
                                year=(alb.date or best.date or "")[:4])
        job["cover_tried"] = tried
        problems = list(alb.problems)
        if existing:
            # the library's album already has its date and genre: MusicBrainz's gaps do not matter
            problems = [x for x in problems if not x.startswith(("no full original release date", "no genre"))]
        if cov:
            (work / "cover.jpg").write_bytes(cov.data)
            job["notes"].append(f"cover {cov.width}x{cov.height} from {cov.source}")
            if cov.better:
                job["notes"].append(f"the library's cover.jpg looks like a scan with a frame; a clean one exists: {cov.better} "
                                    "(Covers in the Music app)")
        else:
            problems.append("no cover of at least 500x500 (tried: " + "; ".join(tried) + ")")
        job["proposal"] = {"folder": alb.folder, "album": alb.album, "artist_folder": alb.artist_folder,
                           "date": alb.date, "genre": alb.genre, "mbid": alb.mbid,
                           "tracks": [{"file": name, **tags} for _, tags, name in alb.files()]}
        if problems:
            return self.to_review(job, problems)
        accepted = set(job.get("replace_tracks") or [])
        unfit = [k for k in best.bad if k not in accepted]
        if unfit and not existing:
            return self.to_review(job, [f"the download's track(s) {', '.join(unfit)} do not fit MusicBrainz (cut short or another take): "
                                        f"find a better download, or accept with --replace-tracks {','.join(unfit)} after checking them"])
        if best.bad and not existing:
            job["notes"].append(f"track(s) {', '.join(best.bad)} do not fit MusicBrainz's lengths; accepted from the review (--replace-tracks)")
        if existing and best.reorder:
            return self.to_review(job, [f"{alb.folder} is in the library and this download is another edition (the same songs "
                                        "in another order): positions cannot be merged; --replace takes this edition, reject keeps yours"])
        if existing:
            return self.merge_into(job, alb, cov, target)
        self.deliver(job, alb, cov, target)
        self.after(job, alb)

    def write_track(self, t, tags: dict, cov, dst: Path) -> None:
        """One new file: tags from scratch, read back, flac -t, then moved into place."""
        tmp = dst.with_name(f".pipeline-{dst.name}")
        shutil.copyfile(t.path, tmp)
        tagger.write(tmp, tags, cov.data, cov.width, cov.height)
        got, pics = tagger.read(tmp)
        want = {k: str(v) for k, v in tags.items() if k in albummod.KEEP and str(v).strip()}
        if {k: got.get(k) for k in want} != want or pics != 1:
            tmp.unlink(missing_ok=True)
            raise RuntimeError(f"{dst.name}: the tags read back differ from what was written")
        audio.run(["flac", "-s", "-t", str(tmp)])
        os.replace(tmp, dst)

    def merge_into(self, job: dict, alb, cov, target: Path) -> None:
        pl = merge.plan(alb, target, set(job.get("replace_tracks") or []))
        job["merge"] = pl.summary()
        job["notes"] += pl.notes
        if pl.review:
            return self.to_review(job, pl.review)
        undo = self.store.path(job["id"]) / "undo.json"
        done = merge.apply(pl, target, cov.data, cov.width, cov.height, undo,
                           lambda t, tags, dst: self.write_track(t, tags, cov, dst))
        job["result"] = {"folder": alb.folder, "merged": done or ["nothing to change: the library already had it right"]}
        self.log(job, f"merged into {alb.folder}: {len(done)} changes")
        self.after(job, alb, merged=done)

    def to_review(self, job: dict, problems: list[str]) -> None:
        job["state"] = "review"
        job["problems"] = problems
        job.pop("net_retries", None)
        self.log(job, "review: " + " | ".join(problems))
        self.store.save(job)
        if self.cfg.get("qbittorrent") and job.get("hash"):
            try:
                self.qbit.tag(job["hash"], add="pipeline:review")
            except Exception:  # noqa: BLE001
                pass
        self.tg.send(f"⚠️ Música para revisar: {job['name']}\n" + "\n".join("• " + p for p in problems[:6]) +
                     f"\n\nbarch music show {job['id']}")

    def deliver(self, job: dict, alb, cov, target: Path) -> None:
        """Write every track into a hidden folder next to the album, check it, then move it in."""
        tmp = target.parent / f".pipeline-{job['id']}"
        shutil.rmtree(tmp, ignore_errors=True)
        tmp.mkdir(parents=True)
        written = []
        for t, tags, name in alb.files():
            dst = tmp / name
            shutil.copyfile(t.path, dst)
            tagger.write(dst, tags, cov.data, cov.width, cov.height)
            got, pics = tagger.read(dst)
            want = {k: str(v) for k, v in tags.items() if str(v).strip()}
            if {k: got.get(k) for k in want} != want or set(got) - set(albummod.KEEP) or pics != 1:
                raise RuntimeError(f"{name}: the tags read back differ from what was written")
            audio.run(["flac", "-s", "-t", str(dst)])
            written.append(name)
        (tmp / "cover.jpg").write_bytes(cov.data)
        if job.get("replace") and target.exists():
            backup = self.store.path(job["id"]) / "replaced"
            if backup.exists():
                # never over the first backup: that is Bruno's original album (undo brings it back)
                raise RuntimeError(f"{backup} already holds the album this job replaced; undo first")
            shutil.move(str(target), str(backup))
            self.log(job, f"the previous {alb.folder} moved to {backup}")
        target.mkdir(parents=True, exist_ok=True)
        for name in written + ["cover.jpg"]:
            os.replace(tmp / name, target / name)
        tmp.rmdir()
        job["result"] = {"folder": alb.folder, "files": written, "cover": f"{cov.width}x{cov.height}"}
        self.log(job, f"delivered {len(written)} tracks to {alb.folder}")

    def after(self, job: dict, alb, merged: list[str] | None = None) -> None:
        done = []
        for step in (lambda: self.lidarr.refresh(alb.group_mbid), lambda: self.plex.scan(alb.folder)):
            try:
                done.append(step())
            except Exception as e:  # noqa: BLE001
                done.append(f"{e}")
        job["state"] = "done"
        job["after"] = done
        job.pop("net_retries", None)
        shutil.rmtree(self.store.path(job["id"]) / "work", ignore_errors=True)
        self.store.save(job)
        self.cleanup_source(job)
        if merged is not None:
            head = f"✅ Música (já estava na biblioteca): {alb.artist_folder} - {alb.album}\n"
            body = "\n".join("• " + m for m in merged[:15]) or "• nada a corrigir"
            self.tg.send(head + body + ("\n…" if len(merged) > 15 else "") + "\n" + "\n".join(done))
        else:
            self.tg.send(f"✅ Música: {alb.artist_folder} - {alb.album} ({len(alb.tracks)} faixas)\n" + "\n".join(done))

    def cleanup_source(self, job: dict, finished: tuple = ("done",)) -> None:
        """When every album of the torrent (or inbox folder) is in the library: delete it. A reject
        with delete counts the rejected ones as finished too (a box set Bruno does not want)."""
        key = "hash" if job.get("kind") == "torrent" else "inbox"
        group = [j for j in self.store.all() if j.get(key) == job.get(key) and not j.get("superseded")]
        if any(j["state"] not in finished for j in group) or len(group) < job.get("siblings", 1):
            return
        if job.get("kind") == "torrent" and self.cfg.get("delete_torrent", True):
            self.qbit.delete(job["hash"], files=True)
            self.log(job, "torrent and its files deleted from qBittorrent")
        elif job.get("kind") == "inbox":
            shutil.rmtree(job["inbox"], ignore_errors=True)
            self.log(job, "inbox folder removed")
        self.store.save(job)

    def library_artists(self) -> list[dict]:
        """The artist folders of /music with how many album folders each holds (the Covers page's list)."""
        out = []
        if self.music.is_dir():
            for d in sorted(self.music.iterdir(), key=lambda x: x.name.casefold()):
                if d.is_dir() and not d.name.startswith("."):
                    try:
                        n = sum(1 for a in d.iterdir() if a.is_dir())
                    except OSError:
                        n = 0
                    out.append({"name": d.name, "albums": n})
        return out

    def retitle_album(self, folder: str, album: str) -> dict:
        """ALBUM on every track of /music/<folder> set to `album` (as given, no restyling) and the folder
        renamed to the library's name for it; Plex rescans the artist, Lidarr the album's artist."""
        src = self.music / folder
        if "/" not in folder or not src.is_dir():
            raise KeyError("no such album in the library")
        album = album.strip()
        if not album:
            raise ValueError("an empty title")
        dst = src.parent / style.folder_name(album)
        if dst != src and dst.exists():
            raise ValueError(f"{dst.relative_to(self.music)} exists already")
        files = sorted(src.glob("*.flac"))
        for f in files:
            x = FLAC(f)
            x["ALBUM"] = album
            x.save()
        if dst != src:
            os.rename(src, dst)
        new = str(dst.relative_to(self.music))
        done = [f"ALBUM={album} on {len(files)} track(s)"] + ([f"folder renamed to {new}"] if dst != src else [])
        group = ""
        if files:
            try:
                rel = mb.release((FLAC(dst / files[0].name).get("MUSICBRAINZ_ALBUMID") or [""])[0]) or {}
                group = (rel.get("release-group") or {}).get("id", "")
            except Exception:  # noqa: BLE001
                group = ""
        for step in ((lambda: self.lidarr.refresh(group)) if group else None, lambda: self.plex.scan(new.split("/")[0])):
            if step:
                try:
                    done.append(step())
                except Exception as e:  # noqa: BLE001
                    done.append(f"{e}")
        return {"folder": new, "done": done}

    def rescan(self, jid: str) -> list[dict]:
        """The download of this job taken in again from scratch, as the album roots are found now (a
        torrent split into one job per disc folder by an older version): every job of the same
        torrent or inbox folder is marked superseded (cleanup ignores them; the ones in review are
        rejected), the torrent loses its pipeline tags and the next scan makes the new jobs."""
        job = self.store.load(jid)
        if not job:
            raise KeyError(jid)
        key = "hash" if job.get("kind") == "torrent" else "inbox"
        old = [j for j in self.store.all() if j.get(key) and j.get(key) == job.get(key)]
        for j in old:
            j["superseded"] = True
            if j["state"] in ("review", "failed", "queued"):
                j["state"] = "rejected"
            self.log(j, f"superseded: the download is taken in again (rescan from {jid})")
            self.store.save(j)
        if key == "hash":
            self.qbit.tag(job["hash"], remove="pipeline,pipeline:review")
            t = self.qbit.torrent(job["hash"])
            new = self.from_torrent(t) if t else []
        else:
            (Path(job["inbox"]) / ".pipeline").unlink(missing_ok=True)
            new = self.from_inbox(Path(job["inbox"])) if Path(job["inbox"]).is_dir() else []
        self.wake.set()
        return new

    # ------------------------------------------------------------ decisions from the review
    def set_cover(self, jid: str, data: bytes | None, label: str = "", url: str = "") -> dict:
        """The cover Bruno found himself for a job (an image uploaded from the app or the phone, or a
        URL): checked like any candidate (square, at least 500 px), kept with the job as
        cover-chosen.jpg and made the chosen cover; Resolve then runs the job with it. An empty url
        with no data clears the choice."""
        job = self.store.load(jid)
        if not job:
            raise KeyError(jid)
        chosen = self.store.path(jid) / "cover-chosen.jpg"
        if data is None:
            if not url:
                chosen.unlink(missing_ok=True)
                job["cover"] = ""
                self.log(job, "cover choice cleared")
                self.store.save(job)
                return {"result": "cover choice cleared", "cover": ""}
            data = mb.download(url)
            if not data:
                raise ValueError(f"could not download {url}")
            label = label or url
        import tempfile
        with tempfile.TemporaryDirectory(prefix="barch-cover-") as td:
            p = Path(td) / "in"
            p.write_bytes(data)
            w, h = cover._size(p)
            if not cover._square(w, h) or min(w, h) < cover.MIN:
                raise ValueError(f"the image is {w}x{h}: it has to be square (±10 %) and at least {cover.MIN} px")
            b, fp = cover.look(p)
            jpeg, nw, nh = cover._to_jpeg(cover.Cand(label or "upload", "chosen", p, w, h, b, fp), trim=False)
        chosen.parent.mkdir(parents=True, exist_ok=True)
        chosen.write_bytes(jpeg)
        job["cover"] = str(chosen)
        job["cover_label"] = label or "upload"
        self.log(job, f"cover chosen: {label or 'upload'} ({w}x{h} -> {nw}x{nh}); Resolve runs the album with it")
        self.store.save(job)
        return {"result": f"cover set from {label or 'upload'} ({w}x{h}, kept as {nw}x{nh}): Resolve to use it",
                "cover": str(chosen), "w": nw, "h": nh}

    def job_cover(self, jid: str) -> Path | None:
        """The image to show for a job: the one chosen by hand (what the next run uses), else the proposal's."""
        for p in (self.store.path(jid) / "cover-chosen.jpg", self.store.path(jid) / "work" / "cover.jpg"):
            if p.exists():
                return p
        return None

    def resolve(self, jid: str, action: str, **kw) -> dict:
        job = self.store.load(jid)
        if not job:
            raise KeyError(jid)
        if action == "reject":
            job["state"] = "rejected"
            self.log(job, "rejected in the review" + (" (download deleted once every album of it is settled)" if kw.get("delete") else ""))
            rel = mb.release((job.get("match") or {}).get("mbid", "")) if job.get("match") else None
            note = self.lidarr.unmonitor_group(((rel or {}).get("release-group") or {}).get("id", ""), "rejected")
            if note:
                job.setdefault("notes", []).append(note)
            if kw.get("delete"):
                self.store.save(job)
                self.cleanup_source(job, finished=("done", "rejected"))
        elif action == "undo":
            u = self.store.path(jid) / "undo.json"
            if u.exists():
                job["undone"] = merge.undo(u)
            elif job.get("state") == "done" and (job.get("result") or {}).get("files"):
                d = self.music / job["result"]["folder"]
                for n in job["result"]["files"] + ["cover.jpg"]:
                    (d / n).unlink(missing_ok=True)
                if d.exists() and not any(d.iterdir()):
                    d.rmdir()
                job["undone"] = [f"removed {job['result']['folder']}"]
                backup = self.store.path(jid) / "replaced"
                if backup.is_dir() and not d.exists():       # --replace: the album it replaced comes back
                    shutil.move(str(backup), str(d))
                    job["undone"].append(f"the previous {job['result']['folder']} is back")
            else:
                raise KeyError("nothing to undo")
            job["state"] = "rejected"
            self.log(job, "undone: " + "; ".join(job["undone"][:5]))
        else:
            if kw.get("release"):
                m = re.search(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", kw["release"])
                job["chosen"] = m.group(0) if m else kw["release"]
            if kw.get("cover"):
                job["cover"] = kw["cover"]
            if kw.get("overrides"):
                ov = job.get("overrides") or {}
                for k, v in kw["overrides"].items():
                    if k == "tracks":
                        ov.setdefault("tracks", {})
                        for tk, tv in v.items():
                            ov["tracks"].setdefault(tk, {}).update(tv)
                    else:
                        ov[k] = v
                job["overrides"] = ov
            if "replace" in kw:
                job["replace"] = bool(kw["replace"])
            if kw.get("keep_order"):
                job["keep_order"] = True
            if kw.get("replace_tracks"):
                job["replace_tracks"] = sorted(set(job.get("replace_tracks") or []) | set(kw["replace_tracks"]))
            job["state"] = "queued"
            job.pop("net_retries", None)
            job.pop("retry_at", None)
            self.log(job, f"queued again from the review ({action})")
        self.store.save(job)
        self.wake.set()
        return job
