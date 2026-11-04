"""The video pipeline: every movie Radarr has a file for ends up with its original audio and PT-BR.

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
  waiting      no candidate now: searched again every `research_h` hours
  review       what needs Bruno: every candidate failed, the 4K file lacks the original audio...
  skipped      left alone by hand

One job per movie, `m<radarr id>.json` under `jobs`. Heavy steps run one at a time in the worker.
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
from .integrations import QBit, Prowlarr, Radarr, Telegram, portuguese_titles
from .langs import codes

STATES = ["search", "waiting", "downloading", "aligning", "review", "done", "skipped"]
ACTIVE = {"search", "waiting", "downloading", "aligning"}
VIDEO_EXT = (".mkv", ".mp4", ".avi", ".m4v", ".ts", ".m2ts", ".wmv", ".mov")
PT_RE = re.compile(r"\b(dual([ ._-]?[aá]udio)?|dublado|dublagem|nacional|pt[ ._-]?br|brazilian|portugu[eê]s)\b", re.I)
DUAL_RE = re.compile(r"\b(dual([ ._-]?[aá]udio)?|multi)\b", re.I)
BAD_RE = re.compile(r"\b(cam|hdcam|camrip|ts|hdts|telesync|tc|telecine|screener|scr|dvdscr|r5|legendado|leg)\b", re.I)
PACK_RE = re.compile(r"\b(cole[cç][aã]o|collection|trilogia|trilogy|saga|quadrilogia|complete|pack|box)\b", re.I)


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
                self.align_and_mux(j)
                self.current = ""

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
            if j and j.get("file") == path and j.get("file_size") == size:
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
            elif j.get("state") == "downloading":
                log(j, "Radarr replaced the file; the dub being downloaded will be aligned with the new one")
            else:
                log(j, f"new file without PT-BR audio ({', '.join(langs) or 'no audio'}): looking for a dub")
                j["state"], j["reason"] = "search", ""
                j["failures"] = 0
            self.store.save(j)

    # -------------------------------------------------------------------------------------- search

    def titles(self, j: dict) -> list[str]:
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

    def search(self, j: dict) -> bool:
        """Look for candidates (if none are left untried) and start the best one. True when one started."""
        cands = j.setdefault("candidates", [])
        fresh = [c for c in cands if c.get("status") == "new"]
        if not fresh:
            seen = {c["guid"] for c in cands}
            found = 0
            for t in self.titles(j)[:3]:
                q = f"{t} {j.get('year') or ''}".strip()
                try:
                    results = self.prowlarr.search(q)
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

    def align_and_mux(self, j: dict) -> None:
        c = self.cand(j)
        if not c or not c.get("path"):
            j["state"] = "search"
            self.store.save(j)
            return
        ref, donor = j["file"], c["path"]
        orig_codes = codes(j.get("original", ""))
        try:
            ri, di = sync.probe(ref), sync.probe(donor)
        except Exception as e:  # noqa: BLE001
            return self.fail_candidate(j, f"probe: {e}")
        ra = [s for s in ri["streams"] if s["codec_type"] == "audio"]
        da = [s for s in di["streams"] if s["codec_type"] == "audio"]
        lang = lambda s: sync.norm_lang(sync.lang(s))
        orig_norm = {sync.norm_lang(x) for x in orig_codes}
        ref_pos = [k for k, s in enumerate(ra) if lang(s) in orig_norm]
        if not ref_pos and len(ra) == 1 and lang(ra[0]) == "und":
            ref_pos = [0]       # one untagged track in the 4K file: the original
        if not ref_pos:
            j["state"] = "review"
            j["reason"] = (f"the 4K file has no {j.get('original')} audio ({', '.join(lang(s) for s in ra)}): "
                           "it needs another 4K release, not a dub")
            log(j, j["reason"])
            self.store.save(j)
            return
        por_pos = [k for k, s in enumerate(da) if lang(s) == "por"]
        don_orig = [k for k, s in enumerate(da) if lang(s) in orig_norm]
        if not por_pos:
            und = [k for k, s in enumerate(da) if lang(s) == "und"]
            if len(da) == 1 and und:
                por_pos = und           # a single untagged track in a dubbed release: the dub
            elif len(und) == 1 and don_orig:
                por_pos = und           # original tagged, the other one untagged: the dub
            else:
                return self.fail_candidate(j, "its audio tracks are not tagged with a language: "
                                              + ", ".join(lang(s) for s in da))
        # compare original with original when the donor has it, otherwise the dub with the original
        dref = don_orig[0] if don_orig else por_pos[0]
        self.doing = f"align {j['title']}: decoding"
        try:
            a = sync.align(ref, ra[ref_pos[0]]["index"], donor, da[dref]["index"])
        except Exception as e:  # noqa: BLE001
            return self.fail_candidate(j, f"align: {e}")
        j["alignment"] = a.to_dict() | {"compared": "original" if don_orig else "dub"}
        log(j, "alignment: " + a.summary())
        if not a.ok:
            return self.fail_candidate(j, a.reason)
        # room for the new file next to the old one
        need = os.path.getsize(ref) * 1.05
        if shutil.disk_usage(Path(ref).parent).free < need:
            j["state"], j["reason"] = "review", "not enough free space next to the movie for the muxed copy"
            self.store.save(j)
            return
        plan = sync.MuxPlan(ref=ref, donor=donor, original=sorted(orig_codes) or ["und"], alignment=a,
                            keep_subs=self.cfg.get("subtitles", ["por", "eng"]), ref_audio_pos=ref_pos,
                            donor_por_pos=por_pos)
        self.doing = f"mux {j['title']}"
        try:
            out = sync.mux(plan)
        except Exception as e:  # noqa: BLE001
            j["mux_log"] = plan.log[-5:]
            return self.fail_candidate(j, f"mux: {e}")
        j["mux_log"] = plan.log[-5:]
        self.doing = f"verify {j['title']}"
        try:
            v = sync.verify(out, orig_pos=0, por_pos=len(ref_pos))
        except Exception as e:  # noqa: BLE001
            v = sync.Alignment(ok=False, reason=str(e))
        j["verify"] = v.to_dict()
        if not v.ok:
            Path(out).unlink(missing_ok=True)
            return self.fail_candidate(j, "the muxed file did not check out: " + v.reason)
        os.replace(out, ref)
        log(j, f"muxed: PT-BR from {c['title']} at {a.offset * 1000:+.0f} ms ({a.speed}); file replaced")
        c["status"] = "used"
        if self.cfg.get("delete_donor", True) and c.get("hash"):
            try:
                self.qbit.delete(c["hash"], files=True)
            except Exception as e:  # noqa: BLE001
                log(j, f"qBittorrent delete: {e}")
        try:
            cid = self.radarr.rescan(j["movie_id"])
            for _ in range(60):
                st = self.radarr.get(f"/command/{cid}") or {}
                if st.get("status") in ("completed", "failed"):
                    break
                time.sleep(5)
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
        self.tg.send(f"🎬 {j['title']} ({j.get('year')}): PT-BR adicionado ({a.offset * 1000:+.0f} ms)")

    # ------------------------------------------------------------------------------------ actions

    def act(self, jid: str, action: str, guid: str = "") -> dict:
        j = self.store.load(jid)
        if not j:
            raise KeyError(jid)
        if action == "retry":       # a fresh start: every candidate forgotten, searched again now
            j["candidates"], j["failures"], j["state"], j["reason"], j["donor"] = [], 0, "search", "", ""
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
