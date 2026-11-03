"""The music pipeline as a service inside the beets container (s6: custom-services.d).

    python3 -m barch_music serve [--config /config/pipeline/config.json]
    python3 -m barch_music once <folder>      process one folder now, as an inbox job (testing)

HTTP API (port 8338, header X-Barch-Token or ?token=, except /done):
    GET  /api/status                     counts per state, the job running now
    GET  /api/jobs[?state=review]        summaries
    GET  /api/jobs/<id>                  everything: problems, candidates, the proposed tags
    GET  /api/jobs/<id>/cover            the proposed cover (JPEG)
    POST /api/jobs/<id>                  {"action": "retry|resolve|reject", "release": mbid or URL,
                                          "cover": URL, "overrides": {...}, "replace": bool}
    POST /api/scan                       look for new torrents and inbox folders now
    POST /api/lidarr/flac-only           set every Lidarr quality profile to FLAC / FLAC 24bit
    POST /api/lidarr/monitor             {"ids": [album ids], "monitored": bool}
    POST /api/lidarr/search              {"ids": [album ids]}: monitor them and search the indexers now
    GET  /done?hash=<hash>               qBittorrent's "run on torrent finished" (just a scan)
"""
from __future__ import annotations

import json
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
            if not self._auth(q):
                return
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
            if len(parts) == 4 and parts[:2] == ["api", "jobs"] and parts[3] == "cover":
                f = p.store.path(parts[2]) / "work" / "cover.jpg"
                return self._send(200, raw=f.read_bytes(), ctype="image/jpeg") if f.exists() else self._send(404, {"ok": False})
            self._send(404, {"ok": False, "error": "unknown path"})

        def do_POST(self):
            u = urlparse(self.path)
            q = parse_qs(u.query)
            if not self._auth(q):
                return
            n = int(self.headers.get("Content-Length") or 0)
            try:
                body = json.loads(self.rfile.read(n) or b"{}")
            except json.JSONDecodeError:
                return self._send(400, {"ok": False, "error": "bad JSON"})
            parts = [x for x in u.path.split("/") if x]
            try:
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
                if len(parts) == 3 and parts[:2] == ["api", "jobs"]:
                    action = body.pop("action", "retry")
                    return self._send(200, {"ok": True, "job": summary(p.resolve(parts[2], action, **body))})
            except KeyError:
                return self._send(404, {"ok": False, "error": "no such job"})
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
