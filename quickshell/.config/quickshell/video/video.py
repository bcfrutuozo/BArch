#!/usr/bin/env python3
"""video.py: Radarr, Sonarr and the PT-BR pipeline (server/video) for the Video app and `barch video`.

Standard library only; every command prints one JSON object ({"ok": true, ...} or {"ok": false, "error"}).
Keys in ~/.config/barch/video.json: {"radarr": {"url", "key"}, "sonarr": {...}, "pipeline": {"url", "token"}}.

    status
    search <query> [--kind movie|series]           TMDB (Radarr) / TVDB (Sonarr) lookups
    add movie <tmdbId> | add series <tvdbId> [--profile auto|4k|1080p]
                                                   auto: added with BArch 4K, the releases looked at, BArch 1080p
                                                   when no 2160p release fits; then searched
    movies · movie <id>                            the library with the checklist, one movie in full
    series · show <id>                             the series, one series with its seasons and episodes
    releases movie <id> | series <id> --season N [--episode E]   interactive search, ranked (cached)
    grab movie|series <id> --pick N [--season N]   download one of those
    search-now movie <id> | series <id> [--season N]
    profile movie|series <id> 4k|1080p
    queue · remove radarr|sonarr <queue id> [--blocklist] [--search]
    dub [state] · dub-show <job> · dub-act <job> retry|skip|unskip|use [--guid G]
    audit                                          server/video/audit.py --json

The checklist of a file: original-language audio, PT-BR audio, English subtitle, PT-BR subtitle (from
Radarr's/Sonarr's mediaInfo; null when there is no file).
"""
from __future__ import annotations

import json
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(REPO / "server" / "video"))
from barch_video.langs import codes  # noqa: E402

CONF = Path.home() / ".config" / "barch" / "video.json"
CACHE = Path.home() / ".cache" / "barch" / "video"
PROFILES = {"4k": "BArch 4K", "1080p": "BArch 1080p"}
ALIASES = {"pob": "por", "pt": "por", "ptb": "por", "en": "eng", "ger": "deu", "fre": "fra", "dut": "nld",
           "chi": "zho", "cze": "ces", "gre": "ell", "ice": "isl", "nob": "nor"}


class Fail(Exception):
    pass


def conf() -> dict:
    try:
        return json.loads(CONF.read_text())
    except (OSError, json.JSONDecodeError) as e:
        raise Fail(f"{CONF}: {e}") from None


def http(base: str, method: str, path: str, headers: dict, params: dict | None = None, body=None, timeout: int = 60):
    url = base.rstrip("/") + path + ("?" + urllib.parse.urlencode(params, doseq=True) if params else "")
    data = json.dumps(body).encode() if body is not None else None
    h = {"User-Agent": "BArch-video-app/1.0", **headers}
    if data is not None:
        h["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read().decode() or "null"
    except urllib.error.HTTPError as e:
        msg = e.read().decode(errors="replace")[:300]
        raise Fail(f"{method} {path}: {e.code} {msg}") from None
    except (urllib.error.URLError, TimeoutError) as e:
        raise Fail(f"{base} not reachable: {e}") from None
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return raw


class Arr:
    def __init__(self, name: str):
        c = conf().get(name) or {}
        if not c.get("url") or not c.get("key"):
            raise Fail(f"no {name} in {CONF}")
        self.name, self.url, self.h = name, c["url"], {"X-Api-Key": c["key"]}

    def get(self, path, timeout=60, **params):
        return http(self.url, "GET", "/api/v3" + path, self.h, params or None, timeout=timeout)

    def post(self, path, body, timeout=60):
        return http(self.url, "POST", "/api/v3" + path, self.h, body=body, timeout=timeout)

    def put(self, path, body):
        return http(self.url, "PUT", "/api/v3" + path, self.h, body=body)

    def delete(self, path, **params):
        return http(self.url, "DELETE", "/api/v3" + path, self.h, params or None)

    def command(self, name, **body):
        return self.post("/command", {"name": name, **body})

    def profiles(self) -> dict[str, int]:
        return {p["name"]: p["id"] for p in self.get("/qualityprofile") or []}

    def profile_names(self) -> dict[int, str]:
        return {v: k for k, v in self.profiles().items()}


def pipeline(method: str, path: str, body=None):
    c = conf().get("pipeline") or {}
    if not c.get("url"):
        raise Fail("no pipeline in video.json: barch video install")
    return http(c["url"], method, path, {"X-Barch-Token": c.get("token", "")}, body=body, timeout=30)


def opt(args: list[str], name: str, default: str = "") -> str:
    if name in args:
        i = args.index(name)
        if i + 1 < len(args):
            return args[i + 1]
    return default


def flag(args: list[str], name: str) -> bool:
    return name in args


def poster(images: list | None, remote: str = "") -> str:
    url = remote or next((i.get("remoteUrl", "") for i in images or [] if i.get("coverType") == "poster"), "")
    return url.replace("/t/p/original/", "/t/p/w342/")


def langset(s: str | None) -> set[str]:
    return {ALIASES.get(x.strip().lower(), x.strip().lower()) for x in (s or "").split("/") if x.strip()}


def checklist(media: dict | None, original: str) -> dict | None:
    """Original-language audio, PT-BR audio, English and PT-BR subtitles, and no audio in any other
    language (a German DL release of an English series, a MULTi: the pipeline trims it); None without a file."""
    if not media:
        return None
    audio, subs = langset(media.get("audioLanguages")), langset(media.get("subtitles"))
    orig = {ALIASES.get(c, c) for c in codes(original)}
    extra = sorted(audio - orig - {"por", "und"})
    return {"native": bool(orig & audio) if orig else None, "por_audio": "por" in audio,
            "eng_sub": "eng" in subs, "por_sub": "por" in subs,
            "no_foreign": (not extra) if (orig and audio) else None, "extra": extra}


def all_ok(c: dict | None) -> bool:
    return bool(c) and all(v is not False for k, v in c.items() if k != "extra")


def media_view(mi: dict | None) -> dict:
    mi = mi or {}
    return {"resolution": mi.get("resolution", ""), "codec": mi.get("videoCodec", ""),
            "hdr": mi.get("videoDynamicRangeType") or mi.get("videoDynamicRange") or "",
            "audio": mi.get("audioLanguages", ""), "audio_codec": mi.get("audioCodec", ""),
            "channels": mi.get("audioChannels"), "subs": mi.get("subtitles", ""), "runtime": mi.get("runTime", ""),
            "bitrate": mi.get("videoBitrate") or 0}


def jobs_by_id() -> dict:
    try:
        return {j["id"]: j for j in (pipeline("GET", "/api/jobs") or {}).get("jobs", [])}
    except Fail:
        return {}


# ------------------------------------------------------------------------------------------- status

def cmd_status(args) -> dict:
    r, s = Arr("radarr"), Arr("sonarr")
    movies, series = r.get("/movie") or [], s.get("/series") or []
    rq, sq = r.get("/queue", pageSize=1) or {}, s.get("/queue", pageSize=1) or {}
    try:
        p = pipeline("GET", "/api/status") or {}
    except Fail as e:
        p = {"error": str(e)}
    return {"ok": True, "movies": len(movies), "movies_with_file": sum(1 for m in movies if m.get("hasFile")),
            "series": len(series), "queue": (rq.get("totalRecords") or 0) + (sq.get("totalRecords") or 0),
            "pipeline": {"counts": p.get("counts", {}), "doing": p.get("doing", ""), "error": p.get("error")},
            "free_gb": round(max((f.get("freeSpace") or 0) for f in r.get("/rootfolder") or [{}]) / 2**30)}


# ------------------------------------------------------------------------------------------- search

def cmd_search(args) -> dict:
    q = " ".join(a for a in args if not a.startswith("--") and a != opt(args, "--kind"))
    if not q:
        raise Fail("search <query> [--kind movie|series]")
    kind = opt(args, "--kind", "movie")
    if kind == "series":
        s = Arr("sonarr")
        have = {x["tvdbId"]: x["id"] for x in s.get("/series") or []}
        out = [{"kind": "series", "id": x.get("tvdbId"), "title": x.get("title", ""), "year": x.get("year"),
                "overview": (x.get("overview") or "")[:400], "poster": poster(x.get("images"), x.get("remotePoster", "")),
                "original": (x.get("originalLanguage") or {}).get("name", ""), "network": x.get("network", ""),
                "status": x.get("status", ""), "seasons": len([z for z in x.get("seasons", []) if z["seasonNumber"] > 0]),
                "library_id": have.get(x.get("tvdbId"))}
               for x in s.get("/series/lookup", term=q) or [] if x.get("tvdbId")]
    else:
        r = Arr("radarr")
        have = {x["tmdbId"]: x["id"] for x in r.get("/movie") or []}
        out = [{"kind": "movie", "id": x.get("tmdbId"), "title": x.get("title", ""), "year": x.get("year"),
                "overview": (x.get("overview") or "")[:400], "poster": poster(x.get("images"), x.get("remotePoster", "")),
                "original": (x.get("originalLanguage") or {}).get("name", ""), "runtime": x.get("runtime", 0),
                "library_id": have.get(x.get("tmdbId"))}
               for x in r.get("/movie/lookup", term=q) or [] if x.get("tmdbId")]
    return {"ok": True, "kind": kind, "query": q, "results": out[:40]}


def accepted_2160(releases: list) -> int:
    return sum(1 for x in releases if not x.get("rejected") and (x.get("quality") or {}).get("quality", {}).get("resolution") == 2160)


def cmd_add(args) -> dict:
    if len(args) < 2 or args[0] not in ("movie", "series"):
        raise Fail("add movie <tmdbId> | add series <tvdbId> [--profile auto|4k|1080p]")
    kind, ext = args[0], int(args[1])
    want = opt(args, "--profile", "auto")
    if want not in ("auto", "4k", "1080p"):
        raise Fail("--profile auto|4k|1080p")
    arr = Arr("radarr" if kind == "movie" else "sonarr")
    profiles = arr.profiles()
    first = PROFILES["1080p" if want == "1080p" else "4k"]
    if first not in profiles:
        raise Fail(f"no quality profile {first} in {arr.name} (Recyclarr sync)")
    root = (arr.get("/rootfolder") or [{}])[0].get("path")
    if not root:
        raise Fail(f"{arr.name} has no root folder")
    if kind == "movie":
        hit = next((x for x in arr.get("/movie/lookup", term=f"tmdb:{ext}") or []), None)
        if not hit:
            raise Fail(f"tmdb:{ext} not found")
        if hit.get("id"):
            raise Fail(f"{hit['title']} is already in the library")
        body = hit | {"qualityProfileId": profiles[first], "rootFolderPath": root, "monitored": True,
                      "minimumAvailability": "released", "addOptions": {"searchForMovie": False}}
        item = arr.post("/movie", body)
    else:
        hit = next((x for x in arr.get("/series/lookup", term=f"tvdb:{ext}") or []), None)
        if not hit:
            raise Fail(f"tvdb:{ext} not found")
        if hit.get("id"):
            raise Fail(f"{hit['title']} is already in the library")
        body = hit | {"qualityProfileId": profiles[first], "rootFolderPath": root, "monitored": True,
                      "seasonFolder": True, "addOptions": {"monitor": "all", "searchForMissingEpisodes": False}}
        item = arr.post("/series", body)
    iid, chosen, why = item["id"], first, f"{first} as asked"
    if want == "auto":
        # the 2160p releases that fit the 4K profile now; none -> 1080p (The Walking Dead has no real 4K)
        if kind == "movie":
            rel = arr.get("/release", timeout=240, movieId=iid) or []
            n = accepted_2160(rel)
        else:
            seasons = sorted(x["seasonNumber"] for x in item.get("seasons", []) if x["seasonNumber"] > 0)
            n, rel = 0, []
            for sn in ([seasons[0], seasons[-1]] if len(seasons) > 1 else seasons)[:2]:
                rel = arr.get("/release", timeout=240, seriesId=iid, seasonNumber=sn) or []
                n += accepted_2160(rel)
        if n:
            why = f"{n} 4K release(s) fit"
        elif PROFILES["1080p"] in profiles:
            chosen, why = PROFILES["1080p"], "no 4K release fits: BArch 1080p"
            cur = arr.get(f"/{kind}/{iid}")
            arr.put(f"/{kind}/{iid}", cur | {"qualityProfileId": profiles[chosen]})
    if kind == "movie":
        arr.command("MoviesSearch", movieIds=[iid])
    else:
        arr.command("SeriesSearch", seriesId=iid)
    return {"ok": True, "kind": kind, "id": iid, "title": item.get("title", ""), "profile": chosen, "why": why}


# ------------------------------------------------------------------------------------------ library

def queue_map(arr: Arr, key: str) -> dict:
    out: dict = {}
    for q in (arr.get("/queue", pageSize=500) or {}).get("records", []):
        k = q.get(key)
        if k is None:
            continue
        size, left = q.get("size") or 0, q.get("sizeleft") or 0
        out.setdefault(k, {"progress": round(100 * (1 - left / size), 1) if size else 0, "status": q.get("status", ""),
                           "state": q.get("trackedDownloadState", ""), "timeleft": q.get("timeleft", ""),
                           "protocol": q.get("protocol", ""), "count": 0})
        out[k]["count"] += 1
    return out


def movie_view(m: dict, names: dict, queue: dict, jobs: dict) -> dict:
    mf = m.get("movieFile") or {}
    orig = (m.get("originalLanguage") or {}).get("name", "")
    chk = checklist(mf.get("mediaInfo"), orig) if m.get("hasFile") else None
    job = jobs.get(f"m{m['id']}") or {}
    return {"kind": "movie", "id": m["id"], "title": m.get("title", ""), "year": m.get("year"),
            "poster": poster(m.get("images")), "original": orig, "profile": names.get(m.get("qualityProfileId"), ""),
            "monitored": m.get("monitored", False), "has_file": bool(m.get("hasFile")),
            "quality": ((mf.get("quality") or {}).get("quality") or {}).get("name", ""),
            "size_gb": round((mf.get("size") or 0) / 2**30, 1), "file": mf.get("relativePath", ""),
            "media": media_view(mf.get("mediaInfo")) if mf else None, "check": chk, "complete": all_ok(chk),
            "queue": queue.get(m["id"]), "dub": job.get("state", ""), "dub_reason": job.get("reason", ""),
            "tmdb": m.get("tmdbId"), "imdb": m.get("imdbId", ""), "overview": (m.get("overview") or "")[:600]}


def cmd_movies(args) -> dict:
    r = Arr("radarr")
    names, queue, jobs = r.profile_names(), queue_map(r, "movieId"), jobs_by_id()
    out = [movie_view(m, names, queue, jobs) for m in r.get("/movie") or []]
    out.sort(key=lambda x: x["title"].lower())
    return {"ok": True, "movies": out}


def cmd_movie(args) -> dict:
    if not args:
        raise Fail("movie <id>")
    r = Arr("radarr")
    m = r.get(f"/movie/{int(args[0])}")
    v = movie_view(m, r.profile_names(), queue_map(r, "movieId"), jobs_by_id())
    mf = m.get("movieFile") or {}
    v["path"] = mf.get("path", "")
    v["custom_formats"] = [c.get("name") for c in mf.get("customFormats") or []]
    return {"ok": True, "movie": v}


def series_jobs(jobs: dict, sid: int) -> dict:
    return {j["season"]: j for j in jobs.values() if j.get("kind") == "season" and j.get("series_id") == sid}


def cmd_series(args) -> dict:
    s = Arr("sonarr")
    names, queue, jobs = s.profile_names(), queue_map(s, "seriesId"), jobs_by_id()
    out = []
    for x in s.get("/series") or []:
        st = x.get("statistics") or {}
        sj = series_jobs(jobs, x["id"])
        out.append({"kind": "series", "id": x["id"], "title": x.get("title", ""), "year": x.get("year"),
                    "poster": poster(x.get("images")), "original": (x.get("originalLanguage") or {}).get("name", ""),
                    "profile": names.get(x.get("qualityProfileId"), ""), "monitored": x.get("monitored", False),
                    "files": st.get("episodeFileCount", 0), "episodes": st.get("episodeCount", 0),
                    "size_gb": round((st.get("sizeOnDisk") or 0) / 2**30, 1), "queue": queue.get(x["id"]),
                    "dub_done": sum(1 for j in sj.values() if j.get("state") == "done"), "dub_seasons": len(sj),
                    "network": x.get("network", ""), "status": x.get("status", "")})
    out.sort(key=lambda v: v["title"].lower())
    return {"ok": True, "series": out}


def cmd_show(args) -> dict:
    if not args:
        raise Fail("show <series id>")
    s = Arr("sonarr")
    sid = int(args[0])
    x = s.get(f"/series/{sid}")
    orig = (x.get("originalLanguage") or {}).get("name", "")
    files = {f["id"]: f for f in s.get("/episodefile", seriesId=sid) or []}
    eps = s.get("/episode", seriesId=sid) or []
    queue: dict = {}
    for q in (s.get("/queue", pageSize=500, seriesId=sid) or {}).get("records", []):
        size, left = q.get("size") or 0, q.get("sizeleft") or 0
        queue[q.get("episodeId")] = {"progress": round(100 * (1 - left / size), 1) if size else 0,
                                     "state": q.get("trackedDownloadState", ""), "protocol": q.get("protocol", "")}
    sj = series_jobs(jobs_by_id(), sid)
    seasons = []
    for sn in sorted({e["seasonNumber"] for e in eps}):
        if sn == 0:
            continue
        rows = []
        for e in sorted((e for e in eps if e["seasonNumber"] == sn), key=lambda e: e["episodeNumber"]):
            f = files.get(e.get("episodeFileId") or 0) or {}
            chk = checklist(f.get("mediaInfo"), orig) if f else None
            rows.append({"episode": e["episodeNumber"], "title": e.get("title", ""), "aired": (e.get("airDate") or ""),
                         "has_file": bool(f), "quality": ((f.get("quality") or {}).get("quality") or {}).get("name", ""),
                         "size_gb": round((f.get("size") or 0) / 2**30, 2), "media": media_view(f.get("mediaInfo")) if f else None,
                         "check": chk, "complete": all_ok(chk), "queue": queue.get(e["id"]), "monitored": e.get("monitored")})
        have = [r for r in rows if r["has_file"]]
        job = sj.get(sn) or {}
        seasons.append({"season": sn, "episodes": rows, "files": len(have), "total": len(rows),
                        "complete": sum(1 for r in have if r["complete"]),
                        "check": {k: (all(r["check"][k] is not False for r in have) if have else None)
                                  for k in ("native", "por_audio", "eng_sub", "por_sub", "no_foreign")}
                                 | {"extra": sorted({x for r in have for x in r["check"].get("extra", [])})},
                        "dub": job.get("state", ""), "dub_reason": job.get("reason", ""), "dub_job": job.get("id", "")})
    return {"ok": True, "series": {"id": sid, "title": x.get("title", ""), "year": x.get("year"), "original": orig,
                                   "poster": poster(x.get("images")), "profile": s.profile_names().get(x.get("qualityProfileId"), ""),
                                   "overview": (x.get("overview") or "")[:600], "network": x.get("network", ""),
                                   "path": x.get("path", ""), "seasons": seasons}}


# ----------------------------------------------------------------------------------------- releases

def target(args) -> tuple[Arr, str, int, dict]:
    if len(args) < 2 or args[0] not in ("movie", "series"):
        raise Fail("<movie|series> <id> ...")
    kind, iid = args[0], int(args[1])
    if kind == "movie":
        return Arr("radarr"), kind, iid, {"movieId": iid}
    p = {"seriesId": iid}
    if opt(args, "--season"):
        p["seasonNumber"] = int(opt(args, "--season"))
    if opt(args, "--episode"):
        s = Arr("sonarr")
        ep = next((e for e in s.get("/episode", seriesId=iid) or [] if e["seasonNumber"] == int(opt(args, "--season", "0"))
                   and e["episodeNumber"] == int(opt(args, "--episode"))), None)
        if not ep:
            raise Fail("no such episode")
        p = {"episodeId": ep["id"]}
        return s, kind, iid, p
    return Arr("sonarr"), kind, iid, p


def cache_name(kind: str, iid: int, p: dict) -> Path:
    tail = "-".join(f"{k}{v}" for k, v in sorted(p.items()))
    return CACHE / f"releases-{kind}-{iid}-{tail}.json"


def release_view(n: int, x: dict) -> dict:
    q = (x.get("quality") or {}).get("quality") or {}
    return {"n": n, "title": x.get("title", ""), "indexer": x.get("indexer", ""), "protocol": x.get("protocol", ""),
            "quality": q.get("name", ""), "resolution": q.get("resolution", 0), "score": x.get("customFormatScore", 0),
            "formats": [c.get("name") for c in x.get("customFormats") or []], "size_gb": round((x.get("size") or 0) / 2**30, 1),
            "seeders": x.get("seeders"), "age_days": round((x.get("ageHours") or 0) / 24),
            "languages": [l.get("name") for l in x.get("languages") or []], "full_season": x.get("fullSeason", False),
            "accepted": not x.get("rejected"), "rejections": [str(r) for r in x.get("rejections") or []][:3],
            "info_url": x.get("infoUrl") or ""}


def cmd_releases(args) -> dict:
    arr, kind, iid, p = target(args)
    raw = arr.get("/release", timeout=300, **p) or []
    raw.sort(key=lambda x: (bool(x.get("rejected")), -((x.get("quality") or {}).get("quality") or {}).get("resolution", 0),
                            -(x.get("customFormatScore") or 0), -(x.get("seeders") or 0)))
    CACHE.mkdir(parents=True, exist_ok=True)
    cache_name(kind, iid, p).write_text(json.dumps([{"guid": x["guid"], "indexerId": x["indexerId"], "title": x.get("title")}
                                                    for x in raw]))
    out = [release_view(n, x) for n, x in enumerate(raw)]
    return {"ok": True, "releases": out, "accepted": sum(1 for x in out if x["accepted"])}


def cmd_grab(args) -> dict:
    arr, kind, iid, p = target(args)
    try:
        cached = json.loads(cache_name(kind, iid, p).read_text())
    except OSError:
        raise Fail("no releases listed for it: run releases first") from None
    n = int(opt(args, "--pick", "-1"))
    if not 0 <= n < len(cached):
        raise Fail(f"--pick {n}: {len(cached)} releases")
    rel = cached[n]
    arr.post("/release", {"guid": rel["guid"], "indexerId": rel["indexerId"]}, timeout=120)
    return {"ok": True, "grabbed": rel["title"]}


def cmd_search_now(args) -> dict:
    arr, kind, iid, p = target(args)
    if kind == "movie":
        c = arr.command("MoviesSearch", movieIds=[iid])
    elif "seasonNumber" in p:
        c = arr.command("SeasonSearch", seriesId=iid, seasonNumber=p["seasonNumber"])
    else:
        c = arr.command("SeriesSearch", seriesId=iid)
    return {"ok": True, "command": c.get("name"), "id": c.get("id")}


def cmd_profile(args) -> dict:
    if len(args) < 3 or args[2] not in PROFILES:
        raise Fail("profile movie|series <id> 4k|1080p")
    arr, kind, iid, _ = target(args[:2])
    profiles = arr.profiles()
    name = PROFILES[args[2]]
    cur = arr.get(f"/{kind}/{iid}")
    arr.put(f"/{kind}/{iid}", cur | {"qualityProfileId": profiles[name]})
    return {"ok": True, "profile": name}


# -------------------------------------------------------------------------------------------- queue

def cmd_queue(args) -> dict:
    out = []
    for app, key in (("radarr", "movie"), ("sonarr", "series")):
        arr = Arr(app)
        params = {"pageSize": 500, "includeMovie": "true"} if app == "radarr" else \
            {"pageSize": 500, "includeSeries": "true", "includeEpisode": "true"}
        groups: dict = {}
        for q in (arr.get("/queue", **params) or {}).get("records", []):
            g = groups.setdefault(q.get("downloadId") or q["id"], {"app": app, "id": q["id"], "ids": [], "episodes": []})
            g["ids"].append(q["id"])
            if app == "sonarr" and q.get("episode"):
                e = q["episode"]
                g["episodes"].append(f"S{e['seasonNumber']:02d}E{e['episodeNumber']:02d}")
            size, left = q.get("size") or 0, q.get("sizeleft") or 0
            what = (q.get("movie") or {}).get("title") if app == "radarr" else (q.get("series") or {}).get("title")
            g.update({"what": what or "", "release": q.get("title", ""), "protocol": q.get("protocol", ""),
                      "client": q.get("downloadClient", ""), "status": q.get("status", ""),
                      "state": q.get("trackedDownloadState", ""), "health": q.get("trackedDownloadStatus", ""),
                      "progress": round(100 * (1 - left / size), 1) if size else 0, "size_gb": round(size / 2**30, 1),
                      "timeleft": q.get("timeleft", ""), "eta": q.get("estimatedCompletionTime", ""),
                      "messages": [m for s in q.get("statusMessages") or [] for m in s.get("messages") or []][:3],
                      "error": q.get("errorMessage", "")})
        for g in groups.values():
            if g["episodes"]:
                g["what"] += f" {g['episodes'][0]}" + (f"…{g['episodes'][-1]} ({len(g['episodes'])})" if len(g["episodes"]) > 1 else "")
            out.append(g)
    out.sort(key=lambda g: (g["state"] != "downloading", -g["progress"]))
    return {"ok": True, "items": out}


def cmd_remove(args) -> dict:
    if len(args) < 2 or args[0] not in ("radarr", "sonarr"):
        raise Fail("remove radarr|sonarr <queue id>[,id...] [--blocklist] [--search]")
    arr = Arr(args[0])
    ids = [int(x) for x in args[1].split(",")]
    for i in ids:
        arr.delete(f"/queue/{i}", removeFromClient="true", blocklist="true" if flag(args, "--blocklist") else "false",
                   skipRedownload="false" if flag(args, "--search") else "true")
    return {"ok": True, "removed": len(ids)}


# ----------------------------------------------------------------------------------------------- dub

def cmd_dub(args) -> dict:
    st = args[0] if args else ""
    d = pipeline("GET", "/api/jobs" + (f"?state={st}" if st else "")) or {}
    return {"ok": True, "jobs": d.get("jobs", [])}


def cmd_dub_show(args) -> dict:
    if not args:
        raise Fail("dub-show <job id>")
    return {"ok": True, "job": (pipeline("GET", f"/api/jobs/{args[0]}") or {}).get("job")}


def cmd_dub_act(args) -> dict:
    if len(args) < 2 or args[1] not in ("retry", "skip", "unskip", "use", "search", "add"):
        raise Fail("dub-act <job id> retry|skip|unskip|use|search|add [--guid G] [--query Q] [--url U --title T]")
    body = {"action": args[1]} | ({"guid": opt(args, "--guid")} if args[1] == "use" else {}) \
        | ({"query": opt(args, "--query")} if args[1] == "search" else {}) \
        | ({"url": opt(args, "--url"), "title": opt(args, "--title")} if args[1] == "add" else {})
    d = pipeline("POST", f"/api/jobs/{args[0]}", body) or {}
    if not d.get("ok", True):
        raise Fail(d.get("error", "the pipeline refused"))
    return {"ok": True, "job": d.get("job")}


def cmd_foreign(args) -> dict:
    """The pipeline's list of files with audio beyond the original and PT-BR, and what the trim does."""
    d = pipeline("GET", "/api/foreign") or {}
    return {"ok": True, "files": d.get("files", [])}


def cmd_audit(args) -> dict:
    p = subprocess.run([sys.executable, "-I", str(REPO / "server" / "video" / "audit.py"), "--json"],
                       capture_output=True, text=True, timeout=1800)
    if p.returncode:
        raise Fail("audit.py: " + (p.stderr.strip().splitlines() or ["failed"])[-1])
    return {"ok": True, "movies": json.loads(p.stdout or "[]")}


COMMANDS = {"status": cmd_status, "search": cmd_search, "add": cmd_add, "movies": cmd_movies, "movie": cmd_movie,
            "series": cmd_series, "show": cmd_show, "releases": cmd_releases, "grab": cmd_grab,
            "search-now": cmd_search_now, "profile": cmd_profile, "queue": cmd_queue, "remove": cmd_remove,
            "dub": cmd_dub, "dub-show": cmd_dub_show, "dub-act": cmd_dub_act, "foreign": cmd_foreign, "audit": cmd_audit}


def main(argv: list[str]) -> int:
    if not argv or argv[0] not in COMMANDS:
        print(json.dumps({"ok": False, "error": "commands: " + ", ".join(COMMANDS)}))
        return 2
    try:
        out = COMMANDS[argv[0]](argv[1:])
    except Fail as e:
        out = {"ok": False, "error": str(e)}
    except Exception as e:  # noqa: BLE001 - the app shows it instead of a traceback
        out = {"ok": False, "error": f"{type(e).__name__}: {e}"}
    print(json.dumps(out, ensure_ascii=False))
    return 0 if out.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
