"""The music pipeline as a service inside the beets container (s6: custom-services.d).

    python3 -m barch_music serve [--config /config/pipeline/config.json]
    python3 -m barch_music once <folder>      process one folder now, as an inbox job (testing)

HTTP API (port 8338, header X-Barch-Token or ?token=, except /done and the page):
    GET  /  (or /review)                 the review page (review.html next to this file): the queue and the
                                         resolve form in a browser, phone included; it asks for the token once
    GET  /api/mb/search?artist=&album=   MusicBrainz releases for the form's search by hand
    GET  /api/status                     counts per state, the job running now
    GET  /api/jobs[?state=review]        summaries
    GET  /api/jobs/<id>                  everything: problems, candidates, the proposed tags
    GET  /api/jobs/<id>/cover            the proposed cover (JPEG), or the one chosen by hand
    POST /api/jobs/<id>/cover            an image as the body (Content-Type image/*, ?label=), or {"url": ...}:
                                         checked (square, >= 500 px), kept with the job and made its cover;
                                         {"url": ""} clears the choice. Resolve then runs the album with it
    POST /api/jobs/<id>                  {"action": "retry|resolve|reject", "release": mbid or URL,
                                          "cover": URL, "overrides": {...}, "replace": bool}
    POST /api/scan                       look for new torrents and inbox folders now
    POST /api/lidarr/flac-only           set every Lidarr quality profile to FLAC / FLAC 24bit
    POST /api/lidarr/monitor             {"ids": [album ids], "monitored": bool}
    POST /api/lidarr/search              {"ids": [album ids]}: monitor them and search the indexers now
    GET  /api/lidarr/artists[?q=name]    the artists Lidarr tracks; /api/lidarr/albums?artist=<name|id> their albums
    GET  /api/lidarr/metadata-profiles   the metadata profiles (allowed types and statuses)
    POST /api/lidarr/metadata-profile    {"name", "primary", "secondary", "statuses", "apply_to": "all" | [artist ids]}
    GET  /api/lidarr/import-lists        POST /api/lidarr/import-list {"type": "LastFmUser", "name", "fields", "monitor"}
    GET  /api/lidarr/commands            Lidarr's running and recent commands (a RefreshArtist in flight undoes monitor changes)
    POST /api/lidarr/command-cancel      {"id": command id}: stop it
    POST /api/lidarr/enforce             the library's rule on every artist now (done every hour by itself): the
                                         "BArch" metadata profile, new albums monitored, albums without a file monitored once
    GET  /api/lidarr/queue               what Lidarr grabbed and still waits for; POST /api/lidarr/queue-remove {"ids", "blocklist", "from_client"}
    POST /api/lidarr/artists             {"ids": "all" | [artist ids], "monitored": bool, "monitor_new_items": "all|none|new"}
    GET  /api/covers                     the library's covers that were checked, with their verdict
    GET  /api/covers/image?folder=A/B&which=current|proposal|previous   one of them (JPEG)
    POST /api/covers/check               {"artist": "Dokken"} ("" = the whole library): check in the background
    POST /api/covers/apply|undo|keep     {"folder": "Dokken/Tooth and Nail"}: replace cover.jpg and the
                                          embedded picture (and Plex's poster) / put the old one back / keep it
    POST /api/covers/pick                {"folder", "alt": n}: candidate n becomes the proposal
    POST /api/covers/propose             ?folder=A/B&label=.. with an image body, or {"folder", "url", "label"}:
                                          a new candidate (Claude's edit or find), made the proposal
    POST /api/restart                    end the process: s6 starts it again (after barch music install)
    GET  /done?hash=<hash>               qBittorrent's "run on torrent finished" (just a scan)
"""
from __future__ import annotations

import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from .pipeline import STATES, Pipeline

DEFAULTS = {
    "music": "/music",
    "jobs": "/data/music-pipeline",
    "inbox": "/data/music-inbox",
    "categories": ["lidarr", "music"],
    "poll_s": 120,
    "port": 8338,
    "delete_torrent": True,
}


def load_config(path: str) -> dict:
    cfg = dict(DEFAULTS)
    p = Path(path)
    if p.exists():
        cfg.update(json.loads(p.read_text()))
    sec = p.with_name("secrets.json")              # tokens and passwords: never in the repository
    if sec.exists():
        for k, v in json.loads(sec.read_text()).items():
            if isinstance(v, dict):
                cfg.setdefault(k, {}).update(v)
            else:
                cfg[k] = v
    return cfg


def missing_tools() -> list[str]:
    """What the pipeline needs that this container lacks (50-music-pipeline-packages installs it)."""
    import shutil
    out = [t for t in ("flac", "metaflac", "ffmpeg", "ffprobe", "7z") if not shutil.which(t)]
    try:
        import mutagen  # noqa: F401
    except ImportError:
        out.append("python mutagen")
    return out


def summary(j: dict) -> dict:
    return {k: j.get(k) for k in ("id", "state", "name", "kind", "created", "updated", "problems", "torrent")} | {
        "match": (j.get("match") or {}).get("title"), "folder": (j.get("proposal") or j.get("result") or {}).get("folder")}


def make_handler(p: Pipeline, token: str):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _send(self, code: int, obj=None, raw: bytes | None = None, ctype="application/json"):
            body = raw if raw is not None else json.dumps(obj, ensure_ascii=False).encode()
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _auth(self, q) -> bool:
            if not token:
                return True
            got = self.headers.get("X-Barch-Token") or (q.get("token") or [""])[0]
            if got != token:
                self._send(401, {"ok": False, "error": "token"})
                return False
            return True

        def do_GET(self):
            u = urlparse(self.path)
            q = parse_qs(u.query)
            parts = [x for x in u.path.split("/") if x]
            if parts == ["done"]:
                threading.Thread(target=p.scan, daemon=True).start()
                return self._send(200, {"ok": True})
            if parts in ([], ["review"]):          # the review page: static, asks for the token itself
                return self._send(200, raw=(Path(__file__).with_name("review.html")).read_bytes(), ctype="text/html; charset=utf-8")
            if parts == ["favicon.ico"]:
                return self._send(404, {"ok": False, "error": "no icon"})
            if not self._auth(q):
                return
            if parts == ["api", "mb", "search"]:
                from . import mb as _mb
                try:
                    rels = _mb.search_releases((q.get("artist") or [""])[0], (q.get("album") or [""])[0], limit=25)
                except Exception as e:  # noqa: BLE001
                    return self._send(502, {"ok": False, "error": f"MusicBrainz: {e}"})
                out = [{"mbid": r["id"], "title": r.get("title", ""), "disambiguation": r.get("disambiguation", ""),
                        "artist": "".join(a.get("name", "") + a.get("joinphrase", "") for a in r.get("artist-credit", [])),
                        "date": r.get("date", ""), "country": r.get("country", ""), "tracks": r.get("track-count", 0),
                        "formats": " + ".join(m.get("format") or "?" for m in r.get("media", [])), "status": r.get("status", ""),
                        "group": (r.get("release-group") or {}).get("primary-type", ""),
                        "url": f"https://musicbrainz.org/release/{r['id']}"} for r in rels]
                return self._send(200, {"ok": True, "releases": out})
            if parts == ["api", "status"]:
                jobs = p.store.all()
                return self._send(200, {"ok": True, "running": p.current, "missing": missing_tools(),
                                        "counts": {s: sum(1 for j in jobs if j["state"] == s) for s in STATES}})
            if parts == ["api", "jobs"]:
                st = (q.get("state") or [""])[0]
                jobs = [summary(j) for j in p.store.all() if not st or j["state"] == st]
                return self._send(200, {"ok": True, "jobs": jobs[-300:]})
            if len(parts) == 3 and parts[:2] == ["api", "jobs"]:
                j = p.store.load(parts[2])
                return self._send(200, {"ok": True, "job": j}) if j else self._send(404, {"ok": False, "error": "no such job"})
            if parts == ["api", "covers"]:
                return self._send(200, {"ok": True, **p.covers.summary()})
            if parts[:2] == ["api", "lidarr"] and len(parts) == 3 and parts[2] in ("artists", "albums", "metadata-profiles", "import-lists", "queue", "commands"):
                try:
                    if parts[2] == "artists":
                        return self._send(200, {"ok": True, "artists": p.lidarr.artists((q.get("q") or [""])[0])})
                    if parts[2] == "albums":
                        return self._send(200, {"ok": True, "albums": p.lidarr.albums((q.get("artist") or [""])[0])})
                    if parts[2] == "metadata-profiles":
                        return self._send(200, {"ok": True, "profiles": p.lidarr.metadata_profiles()})
                    if parts[2] == "queue":
                        return self._send(200, {"ok": True, "queue": p.lidarr.queue()})
                    if parts[2] == "commands":
                        return self._send(200, {"ok": True, "commands": p.lidarr.commands()})
                    return self._send(200, {"ok": True, "lists": p.lidarr.import_lists()})
                except ValueError as e:
                    return self._send(400, {"ok": False, "error": str(e)})
                except Exception as e:  # noqa: BLE001
                    return self._send(500, {"ok": False, "error": str(e)})
            if parts == ["api", "covers", "image"]:
                data = p.covers.image((q.get("folder") or [""])[0], (q.get("which") or ["current"])[0])
                return self._send(200, raw=data, ctype="image/jpeg") if data else self._send(404, {"ok": False, "error": "no image"})
            if len(parts) == 4 and parts[:2] == ["api", "jobs"] and parts[3] == "cover":
                f = p.job_cover(parts[2])
                return self._send(200, raw=f.read_bytes(), ctype="image/jpeg") if f else self._send(404, {"ok": False})
            self._send(404, {"ok": False, "error": "unknown path"})

        def do_POST(self):
            u = urlparse(self.path)
            q = parse_qs(u.query)
            if not self._auth(q):
                return
            n = int(self.headers.get("Content-Length") or 0)
            parts = [x for x in u.path.split("/") if x]
            if parts == ["api", "covers", "propose"] and (self.headers.get("Content-Type") or "").startswith("image/"):
                # an image as the body: ?folder=Artist/Album&label=what it is
                data = self.rfile.read(n)
                try:
                    r = p.covers.propose((q.get("folder") or [""])[0], data, (q.get("label") or ["Claude"])[0])
                    return self._send(200, {"ok": True, "result": r})
                except (KeyError, ValueError) as e:
                    return self._send(400, {"ok": False, "error": str(e.args[0] if e.args else e)})
            if len(parts) == 4 and parts[:2] == ["api", "jobs"] and parts[3] == "cover" and (self.headers.get("Content-Type") or "").startswith("image/"):
                # the cover Bruno found: the image itself as the body, ?label= what it is
                data = self.rfile.read(n)
                try:
                    return self._send(200, {"ok": True, **p.set_cover(parts[2], data, (q.get("label") or ["upload"])[0])})
                except KeyError:
                    return self._send(404, {"ok": False, "error": "no such job"})
                except ValueError as e:
                    return self._send(400, {"ok": False, "error": str(e)})
            try:
                body = json.loads(self.rfile.read(n) or b"{}")
            except json.JSONDecodeError:
                return self._send(400, {"ok": False, "error": "bad JSON"})
            try:
                if parts == ["api", "restart"]:
                    self._send(200, {"ok": True, "result": "restarting"})
                    threading.Timer(0.5, lambda: os._exit(0)).start()
                    return
                if parts == ["api", "covers", "pick"]:
                    return self._send(200, {"ok": True, "result": p.covers.pick(str(body.get("folder", "")), int(body.get("alt", -1)))})
                if parts == ["api", "covers", "propose"]:      # {"folder", "url", "label"}
                    from . import mb as _mb
                    data = _mb.download(str(body.get("url", "")))
                    if not data:
                        return self._send(400, {"ok": False, "error": "could not download " + str(body.get("url", ""))})
                    try:
                        r = p.covers.propose(str(body.get("folder", "")), data, str(body.get("label", "") or body.get("url", "")))
                    except ValueError as e:
                        return self._send(400, {"ok": False, "error": str(e)})
                    return self._send(200, {"ok": True, "result": r})
                if parts == ["api", "covers", "check"]:
                    n = p.covers.check(str(body.get("artist", "")))
                    return self._send(200, {"ok": True, "result": f"checking {n} album(s)", "queued": n})
                if len(parts) == 3 and parts[:2] == ["api", "covers"] and parts[2] in ("apply", "undo", "keep"):
                    folder = str(body.get("folder", ""))
                    if parts[2] == "keep":
                        p.covers.forget(folder)
                        return self._send(200, {"ok": True, "result": f"{folder}: the library's cover stays"})
                    return self._send(200, {"ok": True, "result": getattr(p.covers, parts[2])(folder)})
                if parts == ["api", "scan"]:
                    return self._send(200, {"ok": True, "new": p.scan()})
                if parts == ["api", "lidarr", "flac-only"]:
                    return self._send(200, {"ok": True, "result": p.lidarr.flac_only_profile()})
                if parts == ["api", "lidarr", "monitor"]:
                    ids = [int(i) for i in body.get("ids", [])]
                    return self._send(200, {"ok": True, "result": p.lidarr.monitor(ids, bool(body.get("monitored", True)))})
                if parts == ["api", "lidarr", "search"]:
                    ids = [int(i) for i in body.get("ids", [])]
                    return self._send(200, {"ok": True, "result": p.lidarr.search(ids)})
                if parts == ["api", "lidarr", "enforce"]:
                    try:
                        return self._send(200, {"ok": True, "result": p.enforce_lidarr(force=True) or "Lidarr: profile check is off"})
                    except ValueError as e:
                        return self._send(400, {"ok": False, "error": str(e)})
                if parts == ["api", "lidarr", "command-cancel"]:
                    return self._send(200, {"ok": True, "result": p.lidarr.cancel_command(int(body.get("id", 0)))})
                if parts == ["api", "lidarr", "queue-remove"]:
                    ids = [int(i) for i in body.get("ids", [])]
                    return self._send(200, {"ok": True, "result": p.lidarr.remove_queue(ids, bool(body.get("blocklist", True)),
                                                                                         bool(body.get("from_client", True)))})
                if parts == ["api", "lidarr", "artists"]:
                    # {"ids": "all" | [artist ids], "monitored": bool (optional), "monitor_new_items": "all" | "none" | "new"}
                    try:
                        ids = body.get("ids") or []
                        r = p.lidarr.set_artists(ids if ids == "all" else [int(i) for i in ids],
                                                 None if body.get("monitored") is None else bool(body.get("monitored")),
                                                 str(body.get("monitor_new_items") or ""))
                    except ValueError as e:
                        return self._send(400, {"ok": False, "error": str(e)})
                    return self._send(200, {"ok": True, "result": r})
                if parts == ["api", "lidarr", "metadata-profile"]:
                    # {"name", "primary": [..], "secondary": [..], "statuses": [..], "apply_to": "all" | [artist ids]}
                    try:
                        r = p.lidarr.set_metadata_profile(str(body.get("name", "")), list(body.get("primary") or []),
                                                          list(body.get("secondary") or []), list(body.get("statuses") or ["Official"]),
                                                          body.get("apply_to") or "")
                    except ValueError as e:
                        return self._send(400, {"ok": False, "error": str(e)})
                    return self._send(200, {"ok": True, "result": r})
                if parts == ["api", "lidarr", "import-list"]:
                    # {"type": "LastFmUser", "name", "fields": {..}, "monitor", "search", "metadata_profile", "quality_profile"}
                    try:
                        r = p.lidarr.add_import_list(str(body.get("type", "")), str(body.get("name", "")), dict(body.get("fields") or {}),
                                                     str(body.get("monitor") or "specificAlbum"), bool(body.get("search")),
                                                     str(body.get("metadata_profile") or ""), str(body.get("quality_profile") or ""))
                    except ValueError as e:
                        return self._send(400, {"ok": False, "error": str(e)})
                    return self._send(200, {"ok": True, "result": r})
                if len(parts) == 4 and parts[:2] == ["api", "jobs"] and parts[3] == "cover":      # {"url": ...} or {"url": ""}
                    try:
                        return self._send(200, {"ok": True, **p.set_cover(parts[2], None, str(body.get("label") or ""), str(body.get("url") or ""))})
                    except ValueError as e:
                        return self._send(400, {"ok": False, "error": str(e)})
                if len(parts) == 3 and parts[:2] == ["api", "jobs"]:
                    action = body.pop("action", "retry")
                    return self._send(200, {"ok": True, "job": summary(p.resolve(parts[2], action, **body))})
            except KeyError as e:
                msg = str(e.args[0]) if parts[1:2] == ["covers"] and e.args else "no such job"
                return self._send(404, {"ok": False, "error": msg})
            except Exception as e:  # noqa: BLE001
                return self._send(500, {"ok": False, "error": str(e)})
            self._send(404, {"ok": False, "error": "unknown path"})
    return H


def serve(cfg_path: str) -> int:
    cfg = load_config(cfg_path)
    p = Pipeline(cfg)

    def poll():
        while True:
            p.scan()
            time.sleep(float(cfg.get("poll_s", 120)))
    threading.Thread(target=poll, daemon=True).start()
    threading.Thread(target=p.run_forever, daemon=True).start()
    srv = ThreadingHTTPServer(("0.0.0.0", int(cfg.get("port", 8338))), make_handler(p, cfg.get("token", "")))
    print(f"music pipeline on :{cfg.get('port', 8338)}, jobs in {p.store.root}, music in {p.music}", flush=True)
    if missing_tools():
        print("music pipeline: MISSING " + ", ".join(missing_tools()) + " (custom-cont-init.d/50-music-pipeline-packages did not run?)", flush=True)
    srv.serve_forever()
    return 0


def once(cfg_path: str, folder: str) -> int:
    cfg = load_config(cfg_path)
    p = Pipeline(cfg)
    jobs = p.from_inbox(Path(folder))
    for j in jobs:
        p.process(j)
        j = p.store.load(j["id"])
        print(json.dumps({k: j.get(k) for k in ("id", "state", "problems", "notes", "result")}, ensure_ascii=False, indent=1))
    return 0


def main(argv: list[str]) -> int:
    cfg = "/config/pipeline/config.json"
    if "--config" in argv:
        i = argv.index("--config")
        cfg = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]
    if argv[:1] == ["serve"]:
        return serve(cfg)
    if argv[:1] == ["once"] and len(argv) == 2:
        return once(cfg, argv[1])
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
