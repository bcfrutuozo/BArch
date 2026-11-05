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
from .canon import Canon
from .library import Library
from .libcovers import LibraryCovers
from .seeds import SeedKeeper, SeedLog
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


def _disc_tags(f: Path) -> tuple[str, str, int, int]:
    """(album artist, album, disc number, total discs) from a file's tags; empty strings / 0 when missing."""
    try:
        import mutagen
        m = mutagen.File(f, easy=True)
        t = dict(m.tags or {}) if m is not None else {}
    except Exception:  # noqa: BLE001
        return "", "", 0, 0
    first = lambda *ks: next((str(t[k][0]).strip() for k in ks if t.get(k) and str(t[k][0]).strip()), "")
    def num(s: str) -> tuple[int, int]:
        m = re.match(r"\s*(\d+)\s*(?:/\s*(\d+))?", s or "")
        return (int(m.group(1)), int(m.group(2) or 0)) if m else (0, 0)
    disc, total = num(first("discnumber"))
    total = total or num(first("disctotal", "totaldiscs"))[0]
    return first("albumartist", "artist"), first("album"), disc, total


_ALBUM_DISC = re.compile(r"[\s\-_,:(\[]*\b(?:cd|disc|disk)\s*#?\s*(\d+)\s*[)\]]?\s*$", re.I)


def split_album_disc(album: str) -> tuple[str, int]:
    """"Crossroads (Disc 1)", "A Fire In The Sky : ... CD2", "Red [Disc 1]" -> the album without the
    disc, and the disc number (0 when the title names none)."""
    m = _ALBUM_DISC.search(album or "")
    if not m or not album[:m.start()].strip():
        return album, 0
    return album[:m.start()].strip(), int(m.group(1))


def regroup_discs(box: Path, settle: float, now: float | None = None, wait_missing: float = 6 * 3600) -> list[str]:
    """slskd moves a finished file into downloads/<the folder it was in>, so the discs of a double album
    land in loose folders ("CD 02", "Disc 1", "CD2 - Come Hell or High Water") and two albums' "CD 02"
    mix. Once an album's own files sat still for `settle` seconds, its audio is put back together by
    its tags as <box>/<Artist> - <Album>/CD<n>/, which album_roots() reads as one album. An album whose
    tags say it has more discs than arrived waits up to `wait_missing` for the rest. Files without an
    album tag stay where they are. Returns the album folders made or completed."""
    now = now or time.time()
    disc_dirs = [d for d in sorted(box.iterdir()) if d.is_dir() and is_disc_folder(d.name)] if box.is_dir() else []
    files = [f for d in disc_dirs for f in d.rglob("*") if f.is_file() and f.suffix.lower() in audio.LOSSLESS]
    if not files:
        return []
    groups: dict[tuple[str, str], list[tuple[Path, int, int]]] = {}
    for f in files:
        artist, album, disc, total = _disc_tags(f)
        album, named = split_album_disc(album)      # one disc per ALBUM tag: they are the same album
        disc = disc or named
        if album:
            groups.setdefault((artist, album), []).append((f, disc, total))
    made = []
    for (artist, album), fs in groups.items():
        total = max(t for _, _, t in fs)
        discs = {d for _, d, _ in fs if d}
        quiet = now - max(f.stat().st_mtime for f, _, _ in fs)
        if quiet < settle:
            continue                                   # this album is still arriving (slskd writes others meanwhile)
        if total and len(discs) < total and quiet < wait_missing:
            continue                                   # the other discs are probably still downloading
        name = style.folder_name(f"{artist} - {album}" if artist else album)
        dest = box / name
        for f, disc, _ in fs:
            sub = dest / f"CD{disc or 1}"
            sub.mkdir(parents=True, exist_ok=True)
            if not (sub / f.name).exists():
                f.rename(sub / f.name)
        made.append(name)
    for d in disc_dirs:                                # what is left of a disc folder without audio goes
        if d.exists() and not any(p.is_file() and p.suffix.lower() in audio.LOSSLESS for p in d.rglob("*")):
            shutil.rmtree(d, ignore_errors=True)
    return made


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
        # other folders read like the inbox, each with how long a folder must sit still before it is taken:
        # Soulseek's downloads (slskd, fed by Soularr from Lidarr's wanted list), which nothing else cleans
        self.inboxes = [(self.inbox, 120)] + [
            (Path(x["path"]), int(x.get("settle_min", 30)) * 60)
            for x in cfg.get("extra_inboxes", [{"path": "/data/slskd/completed", "settle_min": 30}]) if x.get("path")]
        self.qbit = QBit(cfg.get("qbittorrent", {}))
        self.lidarr = Lidarr(cfg.get("lidarr", {}))
        self.plex = Plex(cfg.get("plex", {}))
        self.tg = Telegram(cfg.get("telegram", {}))
        self.wake = threading.Event()
        self.current = ""
        self.last_enforce = 0.0
        self.doing = ""                     # what the loop does between jobs (the API's status)
        self.stalled_before: set[int] = set()   # queue items stalled at the previous hourly check
        self.covers = LibraryCovers(self.music, self.store.root / "covers", self.plex)
        self.canon = Canon(self.store.root)
        self.library = Library(self.music, self.store.root, self.lidarr)
        self.seeds = SeedLog(self.store.root)
        self.seeding = SeedKeeper(self.store.root, cfg, self.qbit, self.seeds)

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
        try:
            (folder / ".pipeline").write_text(json.dumps([j["id"] for j in jobs]))
        except OSError:
            pass                                       # read-only to the container: scan() knows it by its jobs
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
        # a folder that already has jobs is never taken again, marker or not: the container user cannot
        # write the marker into slskd's folders, and every scan made the same albums anew (2026-11-04)
        taken = {j.get("inbox") for j in self.store.all() if j.get("kind") == "inbox" and not j.get("superseded")}
        for i, (box, settle) in enumerate(self.inboxes):
            if not box.is_dir():
                continue
            if i:                                              # Soulseek: loose disc folders back into albums
                try:
                    for name in regroup_discs(box, settle):
                        print(f"[inbox] {box}: discs regrouped into {name}", flush=True)
                except OSError as e:
                    print(f"regroup {box}: {e}", flush=True)
            for d in sorted(box.iterdir()):
                if not d.is_dir() or d.name.startswith(".") or (d / ".pipeline").exists() or str(d) in taken:
                    continue
                try:
                    age = time.time() - max((p.stat().st_mtime for p in d.rglob("*")), default=0)
                    if age < settle or (i and is_disc_folder(d.name) and age < 86400):
                        continue                               # still arriving; a loose disc waits for regroup_discs
                    n += len(self.from_inbox(d))
                except OSError as e:
                    print(f"scan {d}: {e}", flush=True)
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
        seen = set()
        for j in self.store.all():              # a job cut by a restart starts again
            if j["state"] == "working":
                j["state"] = "queued"
                self.store.save(j)
            # the same album queued twice (an inbox folder taken again by an older version): one is enough
            key = (j.get("inbox"), j.get("source")) if j.get("kind") == "inbox" and not j.get("superseded") else None
            if key and j["state"] == "queued" and self.disposable(j) and is_disc_folder(Path(j["inbox"]).name):
                shutil.rmtree(self.store.path(j["id"]), ignore_errors=True)   # a loose disc: regroup_discs has it
                print(f"[{j['id']}] loose disc folder, left to regroup_discs", flush=True)
            elif key and j["state"] == "queued" and key in seen:
                shutil.rmtree(self.store.path(j["id"]), ignore_errors=True)
                print(f"[{j['id']}] duplicate of a queued job, removed", flush=True)
            elif key:
                seen.add(key)
        while True:
            job = self.next_job()
            if not job:
                self.doing = "Lidarr check"
                self.enforce_lidarr()
                self.doing = "seed check"
                self.seed_check()
                self.purge_work()
                self.weekly_digest()
                # idle: one album of the library tied to MusicBrainz, then the queue is looked at again
                if self.cfg.get("library_sweep", True):
                    self.doing = "library sweep"
                    try:
                        if self.library.step():
                            continue
                    except Exception as e:  # noqa: BLE001
                        self.library.last_error = f"{type(e).__name__}: {e}"
                        print(f"[library] {e}", flush=True)
                self.doing = "idle"
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

    def purge_work(self) -> int:
        """Every hour: the working copy of a finished job (done, rejected) goes. Delivery removes it, but a
        rejected job kept its copy of the whole download forever (14 GB of the downloads cache on
        2026-11-04); a retry collects the download again from scratch, so nothing needs it."""
        if time.time() - getattr(self, "_purged", 0) < 3600:
            return 0
        self._purged, n = time.time(), 0
        for j in self.store.all():
            w = self.store.path(j["id"]) / "work"
            if j["state"] in ("done", "rejected") and w.is_dir():
                shutil.rmtree(w, ignore_errors=True)
                n += 1
        if n:
            print(f"[work] removed the working copy of {n} finished job(s)", flush=True)
        # an extra inbox (Soulseek) folder whose albums are all settled but still on disk (its delete failed:
        # slskd wrote as root until 2026-11-04) goes now
        left = {}
        for j in self.store.all():
            if self.disposable({**j, "chosen": "", "overrides": None}) and not j.get("superseded"):
                left.setdefault(j["inbox"], []).append(j)
        for folder, g in left.items():
            if Path(folder).exists() and all(j["state"] in ("done", "rejected") for j in g) and len(g) >= g[0].get("siblings", 1):
                shutil.rmtree(folder, ignore_errors=True)
                if not Path(folder).exists():
                    print(f"[work] {folder}: settled, removed", flush=True)
        return n

    def seed_check(self, force: bool = False) -> list[str]:
        """Every hour (or now): the torrents seeding for the pipeline that reached their goal go (seeds.py).
        A torrent still in qBittorrent whose albums are all finished (done, or rejected without delete) and
        that is not seeding for the policy yet is handed to it first, so nothing stays in the client forever."""
        try:
            if self.seeding.enabled and (force or time.time() - self.seeding.last >= 3600):
                kept, groups = self.seeding.kept(), {}
                for j in self.store.all():
                    if j.get("kind") == "torrent" and j.get("hash") and not j.get("superseded"):
                        groups.setdefault(j["hash"].lower(), []).append(j)
                for h, g in groups.items():
                    if h in kept or any(j["state"] not in ("done", "rejected") for j in g) or len(g) < g[0].get("siblings", 1):
                        continue
                    if self.qbit.torrent(h):
                        reason = "imported" if all(j["state"] == "done" for j in g) else "rejected"
                        self.seeding.keep(h, reason, g[0].get("torrent") or g[0].get("name", ""))
                        print(f"[seeds] {g[0].get('torrent')}: finished, now seeding for the policy ({reason})", flush=True)
                for name in self.seeding.adopt_categories():
                    print(f"[seeds] {name}: finished, now seeding for the policy", flush=True)
            gone = self.seeding.check(force)
        except Exception as e:  # noqa: BLE001
            print(f"[seeds] check failed: {e}", flush=True)
            return [f"seed check failed: {e}"]
        if gone:
            print("[seeds] deleted: " + "; ".join(gone), flush=True)
        return gone

    def fail(self, job: dict, e: Exception) -> None:
        job["state"] = "failed"
        job["problems"] = [f"{type(e).__name__}: {e}"]
        job.pop("retry_at", None)
        self.log(job, "failed: " + traceback.format_exc().strip().splitlines()[-1])
        self.store.save(job)
        self.tg.send(f"❌ Música: {job['name']}\n{e}")

    def enforce_lidarr(self, force: bool = False) -> str:
        """Every hour (or now): every artist Lidarr has on the library's metadata profile, every canonical
        album without a file monitored, new ones too (`lidarr.profile` in config.json, "BArch"; "" turns it
        off; `lidarr.canon` false monitors every album the profile lets in, unofficial ones included).
        Judging the artists against Wikipedia takes up to five minutes a run here, 40 s when asked over the
        API (the CLI waits a minute); the rest is done in the next runs."""
        profile = self.cfg.get("lidarr", {}).get("profile", "BArch")
        if not profile or (not force and time.time() - self.last_enforce < 3600):
            return ""
        self.last_enforce = time.time()
        try:
            r = self.lidarr.enforce(profile, self.store.root / "lidarr-seen.json",
                                    canon=self.canon if self.cfg.get("lidarr", {}).get("canon", True) else None,
                                    budget=40 if force else 300)
        except Exception as e:  # noqa: BLE001
            r = f"Lidarr: profile check failed: {e}"
        if not r.endswith(("nothing to change", "nothing changed", "nothing else changed")) or "release profile" in r:
            print(f"[pipeline] {r}", flush=True)
        s = "; ".join(x for x in (self.clean_stalled(), self.retry_pending_artists()) if x)
        return r + ("; " + s if s else "")

    # ------------------------------------------------------------ the week, in one message
    def digest(self, days: int = 7) -> str:
        """What happened in the last `days`: albums in, albums waiting and why, Lidarr's queue, the
        library sweep, artists waiting for Lidarr. Sent to Telegram on Sundays at 18:00 (`digest: false`
        in config.json turns that off); `barch music digest` shows it any time."""
        since = time.time() - days * 86400
        jobs = self.store.all()
        recent = [j for j in jobs if float(j.get("updated") or j.get("created") or 0) >= since]
        done = [j for j in recent if j["state"] == "done"]
        merged = [j for j in done if (j.get("result") or {}).get("merged")]
        review = [j for j in jobs if j["state"] == "review"]
        failed = [j for j in recent if j["state"] == "failed"]
        lines = [f"🎵 Música, últimos {days} dias"]
        lines.append(f"• {len(done)} álbum(ns) entraram ({len(merged)} completando um que já existia)")
        for j in done[:12]:
            lines.append("   – " + ((j.get("result") or {}).get("folder") or j.get("name", "")))
        if len(done) > 12:
            lines.append(f"   … e mais {len(done) - 12}")
        if review:
            lines.append(f"• {len(review)} esperando você na Review:")
            for j in review[:8]:
                lines.append(f"   – {j.get('name', '')[:60]}: {((j.get('problems') or ['?'])[0])[:90]}")
        if failed:
            lines.append(f"• {len(failed)} falharam: " + ", ".join(j.get("name", "")[:40] for j in failed[:5]))
        try:
            q = self.lidarr.queue()
            st = self.lidarr.stalled(self.qbit, float(self.cfg.get("lidarr", {}).get("stalled_hours", 48)))
            lines.append(f"• Lidarr baixando {len(q)} release(s)" + (f", {len(st)} parado(s) (serão trocados)" if st else ""))
        except Exception as e:  # noqa: BLE001
            lines.append(f"• Lidarr: {e}")
        lib = self.library.summary()
        c = lib["counts"]
        judged = sum(c.values())
        lines.append(f"• Biblioteca: {c.get('tagged', 0) + c.get('had', 0)} de {lib['albums']} álbuns com ids do MusicBrainz"
                     f" ({judged} vistos), {len(lib['decide'])} para decidir na aba Library")
        try:
            seeding = self.seeding.status()
            if seeding:
                up = sum(r["uploaded"] for r in seeding) / 1e9
                lines.append(f"• Semeando {len(seeding)} torrent(s) até ratio {self.seeding.cfg['ratio']}: {up:.1f} GB enviados,"
                             f" {sum(1 for r in seeding if r['ratio'] >= 1)} já acima de 1")
        except Exception:  # noqa: BLE001
            pass
        st = self.seeds.totals(self.seeds.rows(days))
        if st["torrents"]:
            lines.append(f"• Seed dos {st['torrents']} torrent(s) removidos: {st['uploaded'] / 1e9:.1f} GB enviados de"
                         f" {st['downloaded'] / 1e9:.1f} GB baixados (ratio {st['ratio']}), {st['below_1']} abaixo de 1")
        pend = self.pending_artists()
        if pend:
            lines.append("• Esperando o Lidarr conhecer: " + ", ".join(x["folder"] for x in pend))
        return "\n".join(lines)

    def weekly_digest(self) -> None:
        if not self.cfg.get("digest", True):
            return
        now = time.localtime()
        f = self.store.root / "digest-sent"
        try:
            last = float(f.read_text())
        except (OSError, ValueError):
            last = 0.0
        if now.tm_wday == 6 and now.tm_hour >= 18 and time.time() - last > 5 * 86400:
            f.write_text(str(time.time()))
            self.tg.send(self.digest())

    # artists of /music Lidarr's metadata server does not know yet (one just added to MusicBrainz takes
    # days to reach it): kept in lidarr-pending.json and tried again every hour until Lidarr takes them
    def pending_file(self) -> Path:
        return self.store.root / "lidarr-pending.json"

    def pending_artists(self) -> list[dict]:
        try:
            return json.loads(self.pending_file().read_text())
        except (OSError, ValueError):
            return []

    def add_artists(self, artists: list[dict]) -> list[str]:
        """lidarr.add_artist for each {mbid, folder}; the ones Lidarr's metadata server does not know yet
        wait in the pending list. Then one editor call monitors them all and one rescan of their folders
        replaces the whole-library rescans Lidarr queued for each."""
        out, mbids = [], {str(a.get("mbid")) for a in artists}
        pending = {x["mbid"]: x for x in self.pending_artists()}
        for a in artists:
            try:
                out.append(self.lidarr.add_artist(str(a["mbid"]), str(a["folder"]), monitor=False))
                pending.pop(str(a["mbid"]), None)
            except ValueError as e:
                if "metadata server does not know" in str(e):
                    pending.setdefault(str(a["mbid"]), {"mbid": str(a["mbid"]), "folder": str(a["folder"]), "since": time.time()})
                    out.append(f"{a.get('folder')}: Lidarr's metadata server does not know it yet; tried again every hour")
                else:
                    out.append(f"{a.get('folder')}: {e}")
            except Exception as e:  # noqa: BLE001
                out.append(f"{a.get('folder')}: {e}")
        self.pending_file().write_text(json.dumps(list(pending.values())))
        added = [x for x in self.lidarr.artists() if x["mbid"] in mbids]
        ids = [x["id"] for x in added if not x["monitored"]]
        if ids:
            out.append(self.lidarr.set_artists(ids, monitored=True))
        if added:
            out.append(self.lidarr.targeted_rescans([x["id"] for x in added]))
        return [o for o in out if o]

    def retry_pending_artists(self) -> str:
        pending = self.pending_artists()
        if not pending:
            return ""
        before = {x["mbid"] for x in pending}
        self.add_artists(pending)
        now = {x["mbid"] for x in self.pending_artists()}
        done = [x["folder"] for x in pending if x["mbid"] in before - now]
        if done:
            self.tg.send("🎵 Lidarr agora acompanha: " + ", ".join(done))
            return f"{len(done)} pending artist(s) added to Lidarr: {', '.join(done)}"
        return ""

    def clean_stalled(self) -> str:
        """Downloads Lidarr grabbed that have not moved for `lidarr.stalled_hours` (48; 0 turns it off), at
        two hourly checks in a row: out of the queue and the client, the release blocklisted, and Lidarr
        searches another one."""
        hours = float(self.cfg.get("lidarr", {}).get("stalled_hours", 48))
        if not hours:
            return ""
        try:
            found = self.lidarr.stalled(self.qbit, hours)
            # only what was already stalled at the previous check (an hour ago): a torrent that just
            # found a seeder, or a restart of the pipeline, never costs a download
            dead = [d for d in found if d["id"] in self.stalled_before]
            self.stalled_before = {d["id"] for d in found}
            if not dead:
                return ""
            for d in dead:
                self.seeds.record(self.qbit, d["hash"], "stalled", d.get("album") or d.get("title", ""))
            self.lidarr.remove_queue([d["id"] for d in dead], blocklist=True, from_client=True, redownload=True)
        except Exception as e:  # noqa: BLE001
            return f"stalled downloads: {e}"
        names = ", ".join(f"{d['title']} ({d['state']}, {d['progress']}%, {d['quiet_h']} h)" for d in dead[:10])
        print(f"[pipeline] stalled downloads replaced: {names}", flush=True)
        self.tg.send(f"⏳ Música: {len(dead)} download(s) parado(s) trocado(s) por outro release: {names}")
        return f"{len(dead)} stalled download(s) blocklisted, another release searched"

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
            return self.discard(job, str(e)) if self.disposable(job) else self.to_review(job, [str(e)])
        job["notes"] += notes
        job["audio"] = {"tracks": len(tracks), "discs": len({t.disc for t in tracks}),
                        "format": sorted({f"{t.bits or 16}/{t.rate // 1000 if t.rate % 1000 == 0 else t.rate / 1000}" for t in tracks})}
        # what the download holds, track by track (the review, the agent and the MusicBrainz seed use it)
        job["tracks"] = [{"disc": t.disc, "index": t.index, "seconds": round(t.seconds, 1),
                          "title": t.hints.get("title", ""), "artist": t.hints.get("artist", "")} for t in tracks]
        hints = matcher.hints_from(job.get("name") or src.name, tracks)
        job["hints"] = hints
        self.log(job, f"{len(tracks)} tracks; looking up {hints.get('artist')} - {hints.get('album')}")
        best, cands, reason = matcher.find(tracks, hints, force=job.get("chosen", ""), acoustid_key=self.cfg.get("acoustid_key", ""),
                                           keep_order=bool(job.get("keep_order")))
        job["candidates"] = [c.summary() for c in cands[:8]]
        if not best:
            return self.discard(job, reason) if self.disposable(job) else self.to_review(job, [reason])
        job["match"] = best.summary()
        for attempt in (1, 2):
            alb = albummod.build(best, tracks, self.music, job.get("overrides"))
            target = find_existing(self.music, alb.folder)
            if target != self.music / alb.folder:
                alb.notes.append(f"the library has this album as {target.relative_to(self.music)}: that folder is used")
                alb.folder = str(target.relative_to(self.music))
            existing = target.is_dir() and any(target.glob("*.flac")) and not job.get("replace")
            other = other_album_in(target, alb.group_mbid) if existing else ""
            # another album with the same title is already there (the eight "Greatest Hits" of Deep Purple):
            # this one gets its own folder and ALBUM with its year, as --album "Greatest Hits (2008)" does
            if other and attempt == 1 and alb.date[:4] and not (job.get("overrides") or {}).get("album"):
                job.setdefault("overrides", {})["album"] = f"{alb.album} ({alb.date[:4]})"
                self.log(job, f"{alb.folder} holds another album with the same title (release group {other}): "
                              f"this one becomes {job['overrides']['album']!r}")
                continue
            break
        job["notes"] += alb.notes
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

    def disposable(self, job: dict) -> bool:
        """A folder of an extra inbox (Soulseek) not touched by hand (no release chosen, no overrides): what
        has no MusicBrainz match or is not lossless is rejected and deleted instead of waiting in the
        review, since Lidarr still wants the album and searches again (Soularr brings bootlegs, vinyl
        rips of unknown pressings, stray discs)."""
        if job.get("kind") != "inbox" or job.get("chosen") or job.get("overrides"):
            return False
        return Path(job.get("inbox", "")).parent in {b for b, _ in self.inboxes[1:]}

    def discard(self, job: dict, reason: str) -> None:
        """A disposable job that would go to the review: rejected, its folder deleted once its siblings are
        settled too (cleanup_source), no Telegram; the album stays wanted in Lidarr."""
        job["state"], job["problems"] = "rejected", [reason]
        job.pop("net_retries", None)
        self.log(job, f"discarded (extra inbox, nothing to review): {reason}")
        shutil.rmtree(self.store.path(job["id"]) / "work", ignore_errors=True)
        self.store.save(job)
        self.cleanup_source(job, finished=("done", "rejected"))

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
        if self.disposable({**job, "chosen": "", "overrides": None}):
            finished = ("done", "rejected")             # a Soulseek folder goes once nothing of it waits
        group = [j for j in self.store.all() if j.get(key) == job.get(key) and not j.get("superseded")]
        if any(j["state"] not in finished for j in group) or len(group) < job.get("siblings", 1):
            return
        if job.get("kind") == "torrent" and self.cfg.get("delete_torrent", True):
            reason = "imported" if all(j["state"] == "done" for j in group) else "rejected"
            if self.seeding.enabled:
                self.seeding.keep(job["hash"], reason, job.get("torrent") or job.get("name", ""))
                c = self.seeding.cfg
                self.log(job, f"torrent kept seeding (deleted at ratio {c['ratio']} after {c['min_hours']} h,"
                              f" or {c['max_days']} days after it finished)")
            else:
                row = self.seeding.remove(job["hash"], reason, job.get("torrent") or job.get("name", ""))
                self.log(job, "torrent and its files deleted from qBittorrent" + (
                    f" (seeded {row['uploaded'] / 1e9:.2f} GB, ratio {row['ratio']}, {row['seeding_time'] // 3600} h; seed-history.jsonl)"
                    if row else " (its seed numbers could not be read)"))
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

    def adopt(self, folder: str, release: str) -> list[dict]:
        """An album of /music made by hand, now on MusicBrainz (an edition added with mb-add, a local artist):
        a copy of /music/<folder> goes into the inbox as a job tied to `release`, so the run merges it into
        the same folder: the library's rules and the MusicBrainz ids on the files, the audio never replaced,
        an undo log as for any merge. The copy is the job's source (the inbox folder is deleted after the
        run), never the library folder itself."""
        src = (self.music / folder).resolve()
        if self.music.resolve() not in src.parents or not src.is_dir() or not any(src.rglob("*.flac")):
            raise ValueError(f"{folder}: not an album folder of the library")
        m = re.search(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", release)
        if not m:
            raise ValueError("no MusicBrainz release id")
        dst = self.inbox / f"{src.parent.name} - {src.name} (library {time.strftime('%Y%m%d-%H%M%S')})"
        shutil.copytree(src, dst)
        jobs = self.from_inbox(dst)
        for j in jobs:
            j["chosen"] = m.group(0)
            self.log(j, f"the library's {folder} taken in again with MusicBrainz release {m.group(0)}")
            self.store.save(j)
        self.wake.set()
        return jobs

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
            shutil.rmtree(self.store.path(jid) / "work", ignore_errors=True)
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
