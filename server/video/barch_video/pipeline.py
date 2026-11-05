"""The video pipeline: every movie Radarr has a file for, and every episode Sonarr has, ends up with its
original audio and PT-BR.

Radarr grabs the best 4K HEVC HDR release it finds (profile "BArch 4K", server/video/recyclarr). When
that file has no Portuguese audio, this pipeline gets the dub from another release of the same film and
puts it in, without touching the video:

  search       Prowlarr, by the original title and the Brazilian one (Wikidata), for a release tagged as
               dubbed/dual; candidates ranked (dual first: it brings the original audio to compare with)
  downloading  the best candidate in qBittorrent, category barch-dub (Radarr never sees it)
  aligning     sync.align: the donor's timeline mapped onto the 4K file's from the audio; a donor of
               another cut or another master is dropped and the next candidate tried
  (mux)        sync.mux: the 4K file's video and original audio, the donor's PT-BR audio and the
               subtitles the 4K file lacks, all shifted by the offset; checked again (sync.verify), then
               it replaces the file in place, Radarr rescans and is told the file's languages
  done         the file has PT-BR (muxed, or it came with it)
  (trim)       a file that has PT-BR but also other audio languages, subtitles outside `subtitles` or a dub
               as default: remuxed with only the video, the original (default) and PT-BR audio, those
               subtitles; never while it is hardlinked to a seeding torrent (that would cost space)
  waiting      no candidate now: searched again every `research_h` hours
  review       what needs Bruno: every candidate failed, the 4K file lacks the original audio...
  skipped      left alone by hand

One job per movie, `m<radarr id>.json` under `jobs`, and one per season of a series, `s<sonarr id>x<season>`:
a season's donor is a dubbed season pack (or a range of episodes, or one episode), each of its episodes
aligned and muxed into the matching file on its own; what the donor did not cover, or did not fit, is
searched again. Only torrents are donors (qBittorrent). Heavy steps run one at a time in the worker.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import threading
import time
import traceback
import unicodedata
from pathlib import Path

from . import sync
from .integrations import QBit, Prowlarr, Radarr, Sonarr, Telegram, portuguese_titles
from .langs import codes

STATES = ["search", "waiting", "downloading", "aligning", "review", "done", "skipped"]
ACTIVE = {"search", "waiting", "downloading", "aligning"}
VIDEO_EXT = (".mkv", ".mp4", ".avi", ".m4v", ".ts", ".m2ts", ".wmv", ".mov")
PT_RE = re.compile(r"\b(dual([ ._-]?[aá]udio)?|dublado|dublagem|nacional|pt[ ._-]?br|brazilian|portugu[eê]s)\b", re.I)
DUAL_RE = re.compile(r"\b(dual([ ._-]?[aá]udio)?|multi)\b", re.I)
BAD_RE = re.compile(r"\b(cam|hdcam|camrip|ts|hdts|telesync|tc|telecine|screener|scr|dvdscr|r5|legendado|leg)\b", re.I)
PACK_RE = re.compile(r"\b(cole[cç][aã]o|collection|trilogia|trilogy|saga|quadrilogia|complete|pack|box)\b", re.I)
SERIES_PACK_RE = re.compile(r"\b(cole[cç][aã]o|collection|complete[ ._-]series|s[eé]rie[ ._-]completa|todas[ ._-]as[ ._-]temporadas)\b", re.I)
EP_FILE_RE = re.compile(r"(?i)(?:\bs(\d{1,2})[ ._-]?e(\d{1,3})|\b(\d{1,2})x(\d{2,3})\b)")


def release_scope(title: str) -> tuple[set[int], range | None]:
    """The seasons a release title names and its episodes (None: the whole season).
    "S06 1080p" -> ({6}, None); "S11.E01-E20" -> ({11}, 1..20); "S06E03" -> ({6}, 3..3)."""
    seasons = {int(x) for x in re.findall(r"(?i)\bs(\d{1,2})(?=[ ._-]?e\d|\b)", title)}
    seasons |= {int(x) for x in re.findall(r"(?i)\b(\d{1,2})\s*(?:ª|a|o|º)?\s*temporada\b", title)}
    seasons |= {int(x) for x in re.findall(r"(?i)\b(?:season|temporada)[ ._-]?(\d{1,2})\b", title)}
    eps = [int(x) for x in re.findall(r"(?i)(?:\bs\d{1,2}[ ._-]?|[ ._-])e(\d{1,3})\b", title)]
    return seasons, (range(min(eps), max(eps) + 1) if eps else None)


def series_named(title: str, series: str) -> bool:
    """The release is of this series: its name at the start (or after a site tag or a dash) and the season
    right after it, so "Fear the Walking Dead S06" or "The Walking Dead Daryl Dixon S01" are not The Walking Dead."""
    words = norm(series).split()
    if not words:
        return False
    m = re.search(r"(?i)" + r"[\W_]+".join(map(re.escape, words)), unicodedata.normalize("NFKD", title)
                  .encode("ascii", "ignore").decode())
    if not m:
        return False
    before = title[:m.start()].strip()
    if before and before[-1] not in "-]|):" and not re.fullmatch(r"(?i)(www\.)?\S+\.(com|net|org|br|to)(\.br)?", before):
        return False
    return bool(re.match(r"(?i)[\W_]*(\(?(19|20)\d\d\)?[\W_]*)?(s\d{1,2}|season|temporada|\d{1,2}\s*(ª|a|o|º)?\s*temporada|\d{1,2}x\d)",
                         title[m.end():]))


def episode_of(name: str, season: int) -> int | None:
    """The episode number in a file name of that season (S06E03, 6x03), or None."""
    for m in EP_FILE_RE.finditer(Path(name).name):
        s, e = (m.group(1), m.group(2)) if m.group(1) else (m.group(3), m.group(4))
        if int(s) == season:
            return int(e)
    return None


def now() -> float:
    return time.time()


def norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return " ".join(re.sub(r"[^a-z0-9]+", " ", s).split())


class Store:
    def __init__(self, root: Path):
        self.root = root / "jobs"
        self.root.mkdir(parents=True, exist_ok=True)
        self.lock = threading.RLock()

    def path(self, jid: str) -> Path:
        return self.root / f"{jid}.json"

    def load(self, jid: str) -> dict | None:
        p = self.path(jid)
        return json.loads(p.read_text()) if p.exists() else None

    def save(self, j: dict) -> None:
        with self.lock:
            j["updated"] = now()
            tmp = self.path(j["id"]).with_suffix(".tmp")
            tmp.write_text(json.dumps(j, ensure_ascii=False, indent=1))
            tmp.replace(self.path(j["id"]))

    def all(self) -> list[dict]:
        out = []
        for p in sorted(self.root.glob("*.json")):
            try:
                out.append(json.loads(p.read_text()))
            except (OSError, json.JSONDecodeError):
                pass
        return sorted(out, key=lambda j: j.get("updated", 0))


def log(j: dict, msg: str) -> None:
    j.setdefault("history", []).append({"t": now(), "msg": msg})
    j["history"] = j["history"][-60:]


class Pipeline:
    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.root = Path(cfg["jobs"])
        self.store = Store(self.root)
        self.radarr = Radarr(cfg.get("radarr", {}))
        self.sonarr = Sonarr(cfg["sonarr"]) if (cfg.get("sonarr") or {}).get("api_key") else None
        self.prowlarr = Prowlarr(cfg.get("prowlarr", {}))
        self.qbit = QBit(cfg.get("qbittorrent", {}))
        self.tg = Telegram(cfg.get("telegram", {}))
        self.category = cfg.get("category", "barch-dub")
        self.doing = ""
        self.current = ""
        self.wake = threading.Event()
        self.lock = threading.Lock()   # one heavy step at a time (worker vs API "run now")

    # ---------------------------------------------------------------------------------------- loop

    def loop(self) -> None:
        try:
            self.qbit.ensure_category(self.category, self.cfg.get("download_path", "/data/completed/videos/barch-dub"))
        except Exception as e:  # noqa: BLE001
            print(f"video pipeline: qBittorrent category: {e}", flush=True)
        while True:
            try:
                self.tick()
            except Exception:  # noqa: BLE001 - the loop never dies; the trace goes to the container log
                traceback.print_exc()
            self.doing = ""
            self.wake.wait(float(self.cfg.get("poll_s", 300)))
            self.wake.clear()

    def tick(self) -> None:
        with self.lock:
            self.doing = "library"
            self.sync_library()
            if self.sonarr:
                self.doing = "series"
                self.sync_series()
            jobs = self.store.all()
            for j in [j for j in jobs if j["state"] == "downloading"]:
                self.doing = f"download {j['title']}"
                self.check_download(j)
            searches = 0
            busy = sum(1 for j in self.store.all() if j["state"] == "downloading")
            for j in self.store.all():
                if busy >= int(self.cfg.get("max_downloads", 3)) or searches >= int(self.cfg.get("searches_per_tick", 4)):
                    break
                due = j["state"] == "search" or (j["state"] == "waiting" and now() >= j.get("next_search", 0))
                if due:
                    self.doing = f"search {j['title']}"
                    searches += 1
                    if self.search(j):
                        busy += 1
            for j in [j for j in self.store.all() if j["state"] == "aligning"]:
                self.current, self.doing = j["id"], f"align {j['title']}"
                if j.get("kind") == "season":
                    self.align_season(j)
                else:
                    self.align_and_mux(j)
                self.current = ""
            if self.cfg.get("trim", True):
                self.trim_pass()

    # ------------------------------------------------------------------------------------- library

    def sync_library(self) -> None:
        """A job for every movie with a file; a new or changed file is probed once."""
        for m in self.radarr.movies():
            mf = m.get("movieFile")
            if not m.get("hasFile") or not mf:
                continue
            jid = f"m{m['id']}"
            j = self.store.load(jid)
            path, size = mf["path"], int(mf.get("size", 0))
            if j and j.get("file") == path and j.get("file_size") == size and \
                    (j.get("state") != "done" or j.get("trim_checked") == f"{path}:{size}:{sync.TRIM_VERSION}"):
                continue
            if j and j["state"] == "aligning":
                continue   # our own mux in flight changes the file; the next tick sees the result
            try:
                info = sync.probe(path)
            except Exception as e:  # noqa: BLE001 - not reachable now (a rename in flight): next tick
                print(f"video pipeline: probe {path}: {e}", flush=True)
                continue
            audio = [s for s in info["streams"] if s["codec_type"] == "audio"]
            langs = [sync.norm_lang(sync.lang(s)) for s in audio]
            orig = (m.get("originalLanguage") or {}).get("name", "English")
            j = j or {"id": jid, "movie_id": m["id"], "created": now(), "candidates": []}
            j.update({"title": m["title"], "year": m.get("year"), "imdb": m.get("imdbId", ""),
                      "original": orig, "file": path, "file_size": size, "audio": langs,
                      "runtime": m.get("runtime", 0)})
            if j.get("state") == "skipped":
                self.store.save(j)
                continue
            if "por" in langs:
                if j.get("state") != "done":
                    log(j, "the file has PT-BR audio")
                j["state"], j["reason"] = "done", ""
                j["trim"] = self.plan_trim(j, path)
                j["trim_checked"] = f"{path}:{size}:{sync.TRIM_VERSION}"
            elif j.get("state") == "downloading":
                log(j, "Radarr replaced the file; the dub being downloaded will be aligned with the new one")
            else:
                log(j, f"new file without PT-BR audio ({', '.join(langs) or 'no audio'}): looking for a dub")
                j["state"], j["reason"] = "search", ""
                j["failures"] = 0
            self.store.save(j)

    def sync_series(self) -> None:
        """A job per season with episode files; a new or changed episode file is probed once."""
        for s in self.sonarr.all_series():
            sid = s["id"]
            try:
                files = self.sonarr.episode_files(sid)
                eps = self.sonarr.episodes(sid) if files else []
            except Exception as e:  # noqa: BLE001
                print(f"video pipeline: Sonarr {s.get('title')}: {e}", flush=True)
                continue
            by_file: dict[int, list[int]] = {}
            for e in eps:
                if e.get("episodeFileId"):
                    by_file.setdefault(e["episodeFileId"], []).append(e["episodeNumber"])
            seasons: dict[int, list[dict]] = {}
            for f in files:
                seasons.setdefault(f["seasonNumber"], []).append(f)
            orig = (s.get("originalLanguage") or {}).get("name", "English")
            for season, fl in sorted(seasons.items()):
                if season == 0:
                    continue          # specials: no dubbed packs to speak of
                self.sync_season(s, season, fl, by_file, orig)

    def sync_season(self, s: dict, season: int, files: list[dict], by_file: dict, orig: str) -> None:
        jid = f"s{s['id']}x{season:02d}"
        j = self.store.load(jid)
        if j and j["state"] == "aligning":
            return            # our own muxes in flight change the files; the next tick sees the result
        j = j or {"id": jid, "kind": "season", "series_id": s["id"], "season": season, "created": now(),
                  "candidates": [], "episodes": {}}
        j.update({"title": f"{s['title']} S{season:02d}", "show": s["title"], "year": s.get("year"),
                  "imdb": s.get("imdbId", ""), "original": orig, "file": s.get("path", "")})
        changed, seen = "state" not in j, set()
        for f in files:
            nums = sorted(by_file.get(f["id"], []))
            if not nums:
                continue
            key = str(nums[0])
            seen.add(key)
            old = j["episodes"].get(key)
            path, size = f["path"], int(f.get("size", 0))
            if old and old["file"] == path and old["size"] == size and \
                    (old["state"] != "done" or old.get("trim_checked") == f"{path}:{size}:{sync.TRIM_VERSION}"):
                if old.get("file_id") != f["id"]:
                    old["file_id"], changed = f["id"], True
                continue
            try:
                info = sync.probe(path)
            except Exception as e:  # noqa: BLE001 - a rename in flight: next tick
                print(f"video pipeline: probe {path}: {e}", flush=True)
                continue
            langs = [sync.norm_lang(sync.lang(x)) for x in info["streams"] if x["codec_type"] == "audio"]
            e = {"file_id": f["id"], "file": path, "size": size, "episodes": nums, "audio": langs,
                 "state": "done" if "por" in langs else "todo", "reason": ""}
            if e["state"] == "done":
                e["trim"], e["trim_checked"] = self.plan_trim(j, path), f"{path}:{size}:{sync.TRIM_VERSION}"
            j["episodes"][key] = e
            changed = True
        for k in [k for k in j["episodes"] if k not in seen]:
            del j["episodes"][k]
            changed = True
        if not changed:
            return
        todo = [k for k, e in j["episodes"].items() if e["state"] == "todo"]
        j["audio"] = [f"{len(j['episodes']) - len(todo)}/{len(j['episodes'])} episodes with por"]
        st = j.get("state")
        if st == "skipped":
            pass
        elif not todo:
            if st != "done":
                log(j, "every episode has PT-BR audio")
            j["state"], j["reason"] = "done", ""
        elif st in (None, "done"):
            log(j, f"{len(todo)} episode(s) without PT-BR audio: looking for a dubbed season")
            j["state"], j["reason"], j["failures"] = "search", "", 0
        self.store.save(j)

    def todo(self, j: dict) -> list[int]:
        return sorted(int(k) for k, e in j.get("episodes", {}).items() if e["state"] == "todo")

    # -------------------------------------------------------------------------------------- search

    def titles(self, j: dict) -> list[str]:
        if "titles" not in j and j.get("kind") == "season":
            s = self.sonarr.series(j["series_id"])
            t = [s.get("title") or ""] + [a.get("title", "") for a in s.get("alternateTitles") or []
                                          if a.get("seasonNumber") in (None, -1, j["season"])]
            t += portuguese_titles(j.get("imdb", ""))
            j["titles"] = [x for i, x in enumerate(t) if x and norm(x) not in {norm(y) for y in t[:i]}]
        if "titles" not in j:
            m = self.radarr.movie(j["movie_id"])
            t = [m.get("originalTitle") or "", m.get("title") or ""] + portuguese_titles(j.get("imdb", ""))
            j["titles"] = [x for i, x in enumerate(t) if x and norm(x) not in {norm(y) for y in t[:i]}]
        return j["titles"]

    def rank(self, j: dict, r: dict) -> tuple[int, str]:
        """A score for a Prowlarr result (higher is better) or a reason it is no candidate."""
        title = r.get("title", "")
        if not PT_RE.search(title):
            return -1, "not dubbed"
        if BAD_RE.search(title):
            return -1, "cam/ts or subtitled only"
        if r.get("protocol", "torrent") != "torrent":
            return -1, "not a torrent (donors go through qBittorrent)"
        if j.get("kind") == "season":
            return self.rank_season(j, r, title)
        if PACK_RE.search(title):
            return -1, "a pack"
        nt = norm(title)
        if not any(norm(t) and norm(t) in nt for t in self.titles(j)):
            return -1, "another title"
        year = j.get("year") or 0
        years = [int(y) for y in re.findall(r"\b(19\d\d|20\d\d)\b", title)]
        if years and year and not any(abs(y - year) <= 1 for y in years):
            return -1, "another year"
        if int(r.get("seeders") or 0) < 1 and r.get("protocol") == "torrent":
            return -1, "no seeders"
        size_gb = (r.get("size") or 0) / 2**30
        if size_gb > float(self.cfg.get("max_donor_gb", 40)):
            return -1, "too big"
        s = 0
        if DUAL_RE.search(title):
            s += 40          # brings the original audio: alignment original vs original
        if re.search(r"\b1080p\b", title, re.I):
            s += 20
        elif re.search(r"\b2160p|4k\b", title, re.I):
            s += 15
        elif re.search(r"\b720p\b", title, re.I):
            s += 10
        if re.search(r"blu-?ray|bdrip|brrip", title, re.I):
            s += 6           # the same cut as the UHD disc more often than a web release
        if re.search(r"\b(5\.1|ddp?5|ac3|eac3|dts|truehd|atmos)\b", title, re.I):
            s += 8           # a surround dub
        s += min(20, int(r.get("seeders") or 0)) // 2
        return s, ""

    def rank_season(self, j: dict, r: dict, title: str) -> tuple[int, str]:
        """rank() for a season: the right season, the episodes still without PT-BR (more is better)."""
        if SERIES_PACK_RE.search(title):
            return -1, "a pack of the whole series"
        if not any(series_named(title, t) for t in self.titles(j)):
            return -1, "another title (or a spin-off)"
        seasons, eps = release_scope(title)
        if not seasons:
            return -1, "no season in the title"
        if len(seasons) > 1:
            return -1, "several seasons"
        if j["season"] not in seasons:
            return -1, "another season"
        todo = self.todo(j)
        covered = todo if eps is None else [e for e in todo if e in eps]
        if todo and not covered:
            return -1, "only episodes that already have PT-BR"
        if int(r.get("seeders") or 0) < 1:
            return -1, "no seeders"
        if (r.get("size") or 0) / 2**30 > float(self.cfg.get("max_season_donor_gb", 120)):
            return -1, "too big"
        s = min(40, 2 * len(covered)) + (10 if eps is None else 0)
        if DUAL_RE.search(title):
            s += 40
        if re.search(r"\b1080p\b", title, re.I):
            s += 20
        elif re.search(r"\b2160p|4k\b", title, re.I):
            s += 15
        elif re.search(r"\b720p\b", title, re.I):
            s += 10
        if re.search(r"\b(5\.1|ddp?5|ac3|eac3|dts|truehd|atmos)\b", title, re.I):
            s += 8
        s += min(20, int(r.get("seeders") or 0)) // 2
        return s, ""

    def search(self, j: dict) -> bool:
        """Look for candidates (if none are left untried) and start the best one. True when one started."""
        cands = j.setdefault("candidates", [])
        fresh = [c for c in cands if c.get("status") == "new"]
        if not fresh:
            seen = {c["guid"] for c in cands}
            found = 0
            if j.get("kind") == "season":
                queries = [q for t in self.titles(j)[:2] for q in (f"{t} S{j['season']:02d}", f"{t} temporada {j['season']}")]
                cats: tuple[int, ...] = (5000,)
            else:
                queries = [f"{t} {j.get('year') or ''}".strip() for t in self.titles(j)[:3]]
                cats = (2000,)
            for q in queries:
                try:
                    results = self.prowlarr.search(q, cats)
                except Exception as e:  # noqa: BLE001
                    log(j, f"Prowlarr: {e}")
                    continue
                for r in results:
                    if not isinstance(r, dict) or r.get("guid") in seen:
                        continue
                    score, why = self.rank(j, r)
                    if score < 0:
                        continue
                    seen.add(r["guid"])
                    found += 1
                    cands.append({"guid": r["guid"], "title": r.get("title", ""), "size": r.get("size", 0),
                                  "seeders": r.get("seeders"), "indexer": r.get("indexer", ""),
                                  "url": r.get("magnetUrl") or r.get("downloadUrl") or "", "score": score,
                                  "status": "new", "reason": ""})
            log(j, f"search: {found} new candidate(s) ({', '.join(self.titles(j)[:3])})")
            fresh = [c for c in cands if c.get("status") == "new" and c["url"]]
        if not fresh:
            hours = float(self.cfg.get("research_h", 24))
            j["state"], j["next_search"] = "waiting", now() + hours * 3600
            j["reason"] = f"no dubbed release found; searching again in {hours:.0f} h"
            self.store.save(j)
            return False
        best = max(fresh, key=lambda c: c["score"])
        tag = f"bv-{j['id']}-{len([c for c in cands if c['status'] != 'new'])}"
        try:
            self.qbit.add(best["url"], self.category, tag)
        except Exception as e:  # noqa: BLE001
            best["status"], best["reason"] = "failed", f"qBittorrent: {e}"
            log(j, f"could not add {best['title']}: {e}")
            self.store.save(j)
            return False
        best["status"], best["tag"], best["started"] = "downloading", tag, now()
        j["state"], j["reason"], j["donor"] = "downloading", "", best["guid"]
        log(j, f"downloading {best['title']} ({best['size'] / 2**30:.1f} GB, {best['indexer']})")
        self.store.save(j)
        return True

    def cand(self, j: dict) -> dict | None:
        return next((c for c in j.get("candidates", []) if c["guid"] == j.get("donor")), None)

    def fail_candidate(self, j: dict, why: str, delete: bool = True) -> None:
        c = self.cand(j)
        if c:
            c["status"], c["reason"] = "failed", why
            if delete and c.get("hash"):
                try:
                    self.qbit.delete(c["hash"], files=True)
                except Exception:  # noqa: BLE001
                    pass
        log(j, f"candidate dropped: {why}")
        j["failures"] = j.get("failures", 0) + 1
        j["donor"] = ""
        if j["failures"] >= int(self.cfg.get("max_failures", 4)):
            j["state"] = "review"
            j["reason"] = f"{j['failures']} dubbed releases tried, none fits this file (last: {why})"
            self.tg.send(f"🎬 {j['title']} ({j.get('year')}): {j['reason']}")
        else:
            j["state"] = "search"
        self.store.save(j)

    # ------------------------------------------------------------------------------------ download

    def check_download(self, j: dict) -> None:
        c = self.cand(j)
        if not c:
            j["state"] = "search"
            self.store.save(j)
            return
        try:
            t = self.qbit.by_tag(c["tag"])
        except Exception as e:  # noqa: BLE001
            log(j, f"qBittorrent: {e}")
            return
        if not t:
            if now() - c.get("started", now()) > 600:
                self.fail_candidate(j, "the torrent is not in qBittorrent (removed, or the link was dead)", delete=False)
            return
        c["hash"] = t["hash"]
        prog = float(t.get("progress", 0))
        if prog > c.get("progress", -1) + 0.001:
            c["progress"], c["moved"] = prog, now()
        if prog >= 1.0:
            files = [f for f in self.qbit.files(t["hash"]) if f["name"].lower().endswith(VIDEO_EXT)]
            if not files:
                return self.fail_candidate(j, "no video file in the torrent")
            if j.get("kind") == "season":
                found: dict[str, dict] = {}
                for f in files:
                    e = episode_of(f["name"], j["season"])
                    if e is not None and (str(e) not in found or f["size"] > found[str(e)]["size"]):
                        found[str(e)] = f
                if not found:
                    return self.fail_candidate(j, f"no file of season {j['season']} named SxxEyy in the torrent")
                c["files"] = {k: str(Path(t["save_path"]) / f["name"]) for k, f in found.items()}
                j["state"] = "aligning"
                log(j, f"downloaded: {len(found)} episode file(s) of season {j['season']}")
                self.store.save(j)
                return
            main = max(files, key=lambda f: f["size"])
            c["path"] = str(Path(t["save_path"]) / main["name"])
            j["state"] = "aligning"
            log(j, f"downloaded: {main['name']}")
            self.store.save(j)
            return
        stall_h = float(self.cfg.get("stalled_h", 24))
        if now() - c.get("moved", c.get("started", now())) > stall_h * 3600:
            return self.fail_candidate(j, f"no progress for {stall_h:.0f} h ({prog * 100:.0f} %)")
        self.store.save(j)

    # ------------------------------------------------------------------------------------ align+mux

    def dub_file(self, j: dict, ref: str, donor: str, label: str) -> dict:
        """Align `donor` with `ref`, mux its PT-BR audio (and the subtitles `ref` lacks) into a copy, check the
        copy and put it in place of `ref`. Answers {"ok", "why", "review" (only another release of `ref`
        fixes it), "alignment", "mux_log", "verify"}; nothing is replaced unless ok."""
        out: dict = {"ok": False, "why": "", "review": False}
        orig_codes = codes(j.get("original", ""))
        try:
            ri, di = sync.probe(ref), sync.probe(donor)
        except Exception as e:  # noqa: BLE001
            return out | {"why": f"probe: {e}"}
        ra = [s for s in ri["streams"] if s["codec_type"] == "audio"]
        da = [s for s in di["streams"] if s["codec_type"] == "audio"]
        lang = lambda s: sync.norm_lang(sync.lang(s))
        orig_norm = {sync.norm_lang(x) for x in orig_codes}
        ref_pos = [k for k, s in enumerate(ra) if lang(s) in orig_norm]
        if not ref_pos and len(ra) == 1 and lang(ra[0]) == "und":
            ref_pos = [0]       # one untagged track in the file: the original
        if not ref_pos:
            return out | {"review": True, "why": f"the file has no {j.get('original')} audio "
                          f"({', '.join(lang(s) for s in ra)}): it needs another release, not a dub"}
        por_pos = [k for k, s in enumerate(da) if lang(s) == "por"]
        don_orig = [k for k, s in enumerate(da) if lang(s) in orig_norm]
        if not por_pos:
            und = [k for k, s in enumerate(da) if lang(s) == "und"]
            if len(da) == 1 and und:
                por_pos = und           # a single untagged track in a dubbed release: the dub
            elif len(und) == 1 and don_orig:
                por_pos = und           # original tagged, the other one untagged: the dub
            else:
                return out | {"why": "its audio tracks are not tagged with a language: " + ", ".join(lang(s) for s in da)}
        # compare original with original when the donor has it, otherwise the dub with the original
        dref = don_orig[0] if don_orig else por_pos[0]
        self.doing = f"align {label}: decoding"
        try:
            a = sync.align(ref, ra[ref_pos[0]]["index"], donor, da[dref]["index"])
        except Exception as e:  # noqa: BLE001
            return out | {"why": f"align: {e}"}
        out["alignment"] = a.to_dict() | {"compared": "original" if don_orig else "dub"}
        out["summary"] = a.summary()
        if not a.ok:
            return out | {"why": a.reason}
        if shutil.disk_usage(Path(ref).parent).free < os.path.getsize(ref) * 1.05:
            return out | {"review": True, "why": "not enough free space next to the file for the muxed copy"}
        plan = sync.MuxPlan(ref=ref, donor=donor, original=sorted(orig_codes) or ["und"], alignment=a,
                            keep_subs=self.cfg.get("subtitles", ["por", "eng"]), ref_audio_pos=ref_pos,
                            donor_por_pos=por_pos)
        self.doing = f"mux {label}"
        try:
            muxed = sync.mux(plan)
        except Exception as e:  # noqa: BLE001
            return out | {"why": f"mux: {e}", "mux_log": plan.log[-5:]}
        out["mux_log"] = plan.log[-5:]
        self.doing = f"verify {label}"
        try:
            v = sync.verify(muxed, orig_pos=0, por_pos=len(ref_pos))
        except Exception as e:  # noqa: BLE001
            v = sync.Alignment(ok=False, reason=str(e))
        out["verify"] = v.to_dict()
        if not v.ok:
            Path(muxed).unlink(missing_ok=True)
            return out | {"why": "the muxed file did not check out: " + v.reason}
        os.replace(muxed, ref)
        return out | {"ok": True, "offset_ms": round(a.offset * 1000), "speed": a.speed}

    def drop_donor(self, j: dict, c: dict) -> None:
        if self.cfg.get("delete_donor", True) and c.get("hash"):
            try:
                self.qbit.delete(c["hash"], files=True)
            except Exception as e:  # noqa: BLE001
                log(j, f"qBittorrent delete: {e}")

    def align_and_mux(self, j: dict) -> None:
        c = self.cand(j)
        if not c or not c.get("path"):
            j["state"] = "search"
            self.store.save(j)
            return
        ref = j["file"]
        r = self.dub_file(j, ref, c["path"], j["title"])
        for k in ("alignment", "mux_log", "verify"):
            if k in r:
                j[k] = r[k]
        if "summary" in r:
            log(j, "alignment: " + r["summary"])
        if not r["ok"]:
            if r["review"]:
                j["state"], j["reason"] = "review", r["why"]
                log(j, r["why"])
                self.store.save(j)
                return
            return self.fail_candidate(j, r["why"])
        log(j, f"muxed: PT-BR from {c['title']} at {r['offset_ms']:+d} ms ({r['speed']}); file replaced")
        c["status"] = "used"
        self.drop_donor(j, c)
        if not self.movie_linked(j):
            return
        try:
            m = self.radarr.movie(j["movie_id"])
            if m.get("movieFile"):
                self.radarr.set_file_languages(m["movieFile"]["id"], [j.get("original") or "English",
                                                                       "Portuguese (Brazil)"])
                j["file"], j["file_size"] = m["movieFile"]["path"], int(m["movieFile"].get("size", 0))
        except Exception as e:  # noqa: BLE001
            log(j, f"Radarr after the mux: {e}")
        j["state"], j["reason"], j["done_at"] = "done", "", now()
        j["audio"] = [sync.norm_lang(sync.lang(s)) for s in sync.probe(ref)["streams"] if s["codec_type"] == "audio"]
        self.store.save(j)
        self.tg.send(f"🎬 {j['title']} ({j.get('year')}): PT-BR adicionado ({r['offset_ms']:+d} ms)")

    def align_season(self, j: dict) -> None:
        """Every episode still without PT-BR that the donor has: aligned and muxed one by one. What it did not
        cover or did not fit is searched again with the next donor."""
        c = self.cand(j)
        if not c or not c.get("files"):
            j["state"] = "search"
            self.store.save(j)
            return
        muxed, misfit = [], []
        for k in [str(e) for e in self.todo(j)]:
            donor = c["files"].get(k)
            if not donor:
                continue
            e = j["episodes"][k]
            label = f"{j['title']}E{int(k):02d}"
            r = self.dub_file(j, e["file"], donor, label)
            e["alignment"] = r.get("alignment")
            if r["ok"]:
                e.update({"state": "done", "reason": "", "offset_ms": r["offset_ms"], "donor": c["title"]})
                muxed.append(k)
                log(j, f"E{int(k):02d}: PT-BR at {r['offset_ms']:+d} ms ({r['speed']})")
            else:
                e["reason"] = r["why"]
                if r["review"]:
                    e["state"] = "review"
                misfit.append(k)
                log(j, f"E{int(k):02d}: {r['why']}")
            self.store.save(j)
        c["status"] = "used" if muxed else "failed"
        c["reason"] = f"{len(muxed)} episode(s) muxed" + (f", {len(misfit)} did not fit" if misfit else "")
        self.drop_donor(j, c)
        if muxed:
            self.after_series_mux(j, muxed)
        left = self.todo(j)
        if not left:
            j["state"], j["reason"], j["donor"], j["done_at"] = "done", "", "", now()
            stuck = [k for k, e in j["episodes"].items() if e["state"] == "review"]
            if stuck:
                j["state"], j["reason"] = "review", f"{len(stuck)} episode file(s) lack the original audio"
            self.store.save(j)
            self.tg.send(f"📺 {j['title']}: PT-BR em {len(muxed)} episódio(s)")
            return
        if not muxed:
            first = j["episodes"][misfit[0]]["reason"] if misfit else "it has none of the episodes still missing"
            return self.fail_candidate(j, first, delete=False)
        j["state"], j["donor"] = "search", ""
        j["reason"] = f"{len(left)} episode(s) still without PT-BR"
        log(j, f"{len(muxed)} muxed with {c['title']}; {len(left)} left: searching for another donor")
        self.store.save(j)

    def after_series_mux(self, j: dict, muxed: list[str]) -> None:
        """Sonarr rescans the series and is told the muxed files' languages."""
        self.episodes_linked(j, muxed)
        try:
            by_path = {f["path"]: f for f in self.sonarr.episode_files(j["series_id"])}
            for k in muxed:
                e = j["episodes"][k]
                f = by_path.get(e["file"])
                if not f:
                    continue
                self.sonarr.set_file_languages(f["id"], [j.get("original") or "English", "Portuguese (Brazil)"])
                e["file_id"], e["size"] = f["id"], int(f.get("size", 0))
                e["audio"] = [sync.norm_lang(sync.lang(x)) for x in sync.probe(e["file"])["streams"]
                              if x["codec_type"] == "audio"]
        except Exception as ex:  # noqa: BLE001
            log(j, f"Sonarr after the mux: {ex}")
        todo = self.todo(j)
        j["audio"] = [f"{len(j['episodes']) - len(todo)}/{len(j['episodes'])} episodes with por"]

    # ------------------------------------------------------------------------------- after a replace

    def movie_linked(self, j: dict) -> bool:
        """After the file was replaced: Radarr rescans and must still have it. Once (2026-11-05) Radarr saw
        the path missing during the replace, dropped the record and re-added it without linking the movie
        (hasFile false: it would have downloaded the film again). Then: rescan again, import it in place;
        still not linked -> review, Telegram. True when Radarr has the file."""
        mid = j["movie_id"]
        for attempt in ("rescan", "rescan again", "manual import"):
            try:
                if attempt == "manual import":
                    st = self.radarr.manual_import(str(Path(j["file"]).parent), j["file"], {"movieId": mid})
                else:
                    if attempt == "rescan again":
                        time.sleep(30)
                    st = self.radarr.wait(self.radarr.rescan(mid))
                m = self.radarr.movie(mid)
            except Exception as e:  # noqa: BLE001
                log(j, f"Radarr after the replace ({attempt}): {e}")
                continue
            if m.get("hasFile"):
                if attempt != "rescan":
                    log(j, f"Radarr had lost the file after the replace; linked again by {attempt}")
                return True
            log(j, f"Radarr has no file for the movie after {attempt} ({st})")
        j["state"] = "review"
        j["reason"] = "Radarr lost the file after it was replaced (it would search the movie again): import it by hand"
        self.store.save(j)
        self.tg.send(f"⚠️ {j['title']}: o Radarr perdeu o arquivo depois da troca; importar à mão")
        return False

    def episodes_linked(self, j: dict, keys: list[str]) -> bool:
        """movie_linked() for episodes: every replaced file must still be an episode file of the series."""
        sid = j["series_id"]
        missing: list[str] = []
        for attempt in ("rescan", "rescan again", "manual import"):
            try:
                if attempt == "manual import":
                    eps = {e["episodeNumber"]: e["id"] for e in self.sonarr.episodes(sid) if e["seasonNumber"] == j["season"]}
                    for k in missing:
                        e = j["episodes"][k]
                        self.sonarr.manual_import(str(Path(e["file"]).parent), e["file"],
                                                  {"seriesId": sid, "seasonNumber": j["season"],
                                                   "episodeIds": [eps[n] for n in e.get("episodes", [int(k)]) if n in eps]})
                else:
                    if attempt == "rescan again":
                        time.sleep(30)
                    self.sonarr.wait(self.sonarr.rescan(sid))
                have = {f["path"] for f in self.sonarr.episode_files(sid)}
            except Exception as ex:  # noqa: BLE001
                log(j, f"Sonarr after the replace ({attempt}): {ex}")
                continue
            missing = [k for k in keys if j["episodes"][k]["file"] not in have]
            if not missing:
                if attempt != "rescan":
                    log(j, f"Sonarr had lost episode files after the replace; linked again by {attempt}")
                return True
            log(j, f"Sonarr lost {len(missing)} episode file(s) after {attempt}")
        for k in missing:
            j["episodes"][k]["state"] = "review"
            j["episodes"][k]["reason"] = "Sonarr lost the file after it was replaced: import it by hand"
        self.store.save(j)
        self.tg.send(f"⚠️ {j['title']}: o Sonarr perdeu {len(missing)} episódio(s) depois da troca; importar à mão")
        return False

    # ---------------------------------------------------------------------------------------- trim

    def plan_trim(self, j: dict, path: str) -> dict | None:
        if not self.cfg.get("trim", True):
            return None
        try:
            return sync.trim_plan(path, sorted(codes(j.get("original", ""))) or ["und"],
                                  self.cfg.get("subtitles", ["por", "eng"]))
        except Exception as e:  # noqa: BLE001 - a file it cannot read now is checked when it changes
            print(f"video pipeline: trim plan {path}: {e}", flush=True)
            return None

    def trim_pass(self) -> None:
        """A few pending trims per tick (`trims_per_tick`), never inside a job whose files a mux is changing."""
        budget = int(self.cfg.get("trims_per_tick", 4))
        for j in self.store.all():
            if j["state"] in ("aligning", "skipped"):
                continue
            items = ([None] if j.get("trim") else []) + \
                    [k for k, e in sorted(j.get("episodes", {}).items(), key=lambda kv: int(kv[0])) if e.get("trim")]
            touched = []
            for k in items:
                rec = j if k is None else j["episodes"][k]
                path, plan = rec["file"], rec["trim"]
                try:
                    links = os.stat(path).st_nlink
                except OSError:
                    continue
                if links > 1:
                    wait = "hardlinked to a seeding torrent: trimmed once the seed is removed"
                    if rec.get("trim_wait") != wait:
                        rec["trim_wait"] = wait
                        self.store.save(j)
                    continue
                if budget <= 0:
                    break
                budget -= 1
                label = j["title"] + ("" if k is None else f"E{int(k):02d}")
                self.current, self.doing = j["id"], f"trim {label}"
                before = os.path.getsize(path)
                try:
                    if shutil.disk_usage(Path(path).parent).free < before * 1.02:
                        raise RuntimeError("not enough free space for the trimmed copy")
                    out = sync.trim(path, plan)
                    after = os.path.getsize(out)
                    os.replace(out, path)
                except Exception as e:  # noqa: BLE001 - left as it is, not tried again until the file changes
                    log(j, f"trim {label}: {e}")
                    rec["trim"], rec["trim_error"] = None, str(e)[:300]
                    self.store.save(j)
                    continue
                dropped = ", ".join(x for x in [", ".join(plan["drop_audio"]) and "audio " + ", ".join(plan["drop_audio"]),
                                                 plan["drop_subs"] and "subtitles " + ", ".join(plan["drop_subs"]),
                                                 plan.get("reorder") and "original made the default"] if x)
                log(j, f"trimmed {label}: {dropped}; {(before - after) / 2**30:.2f} GB freed")
                rec["trim"], rec["trim_wait"] = None, ""
                rec["trimmed"] = {"t": now(), "freed": before - after, "what": dropped}
                rec["audio"] = [sync.norm_lang(sync.lang(x)) for x in sync.probe(path)["streams"]
                                if x["codec_type"] == "audio"]
                if k is None:
                    j["file_size"] = after
                    j["trim_checked"] = f"{path}:{after}:{sync.TRIM_VERSION}"
                else:
                    rec["size"], rec["trim_checked"] = after, f"{path}:{after}:{sync.TRIM_VERSION}"
                touched.append(k)
                self.store.save(j)
            self.current = ""
            if touched:
                if j.get("kind") == "season":
                    self.episodes_linked(j, touched)
                else:
                    self.movie_linked(j)
            if budget <= 0:
                return

    # ------------------------------------------------------------------------------------ actions

    def act(self, jid: str, action: str, guid: str = "") -> dict:
        j = self.store.load(jid)
        if not j:
            raise KeyError(jid)
        if action == "retry":       # a fresh start: every candidate forgotten, searched again now
            j["candidates"], j["failures"], j["state"], j["reason"], j["donor"] = [], 0, "search", "", ""
            for e in j.get("episodes", {}).values():
                if e["state"] == "review":
                    e["state"], e["reason"] = "todo", ""
            j.pop("titles", None)
            log(j, "retry by hand")
        elif action == "skip":
            j["state"], j["reason"] = "skipped", "left alone by hand"
            log(j, "skipped by hand")
        elif action == "unskip":
            j["state"], j["reason"] = "search", ""
            j["file_size"] = -1     # probed again on the next tick
            log(j, "unskipped")
        elif action == "use":       # this candidate next
            c = next((c for c in j.get("candidates", []) if c["guid"] == guid), None)
            if not c:
                raise KeyError(guid)
            c["status"], c["score"] = "new", 10**6
            j["state"], j["reason"] = "search", ""
            log(j, f"candidate chosen by hand: {c['title']}")
        else:
            raise ValueError(action)
        self.store.save(j)
        self.wake.set()
        return j

    def digest(self, days: int = 7) -> str:
        since = now() - days * 86400
        jobs = self.store.all()
        done = [j for j in jobs if j["state"] == "done" and j.get("done_at", 0) >= since]
        rev = [j for j in jobs if j["state"] == "review"]
        wait = [j for j in jobs if j["state"] == "waiting"]
        lines = [f"🎬 Vídeo, últimos {days} dias"]
        lines.append(f"• PT-BR adicionado: {len(done)}" + (": " + ", ".join(j["title"] for j in done[:8]) if done else ""))
        if rev:
            lines.append(f"• Revisão ({len(rev)}): " + "; ".join(f"{j['title']}: {j.get('reason', '')[:80]}" for j in rev[:6]))
        if wait:
            lines.append(f"• Sem dublagem encontrada ainda: {len(wait)}")
        return "\n".join(lines)
