"""The video pipeline as a service in its own container on the NAS (s6: custom-services.d).

    python3 -m barch_video serve [--config /config/pipeline/config.json]
    python3 -m barch_video align <reference> <donor> [ref_audio_no donor_audio_no]   print the alignment
    python3 -m barch_video mux <reference> <donor>   align + mux into <reference stem>.barch.mkv (nothing replaced)

HTTP API (port 8339, header X-Barch-Token or ?token=):
    GET  /api/status                  counts per state, what the worker is doing, missing tools
    GET  /api/jobs[?state=review]     one summary per movie
    GET  /api/jobs/<id>               everything: candidates, alignment, history
    POST /api/jobs/<id>               {"action": "retry|skip|unskip|use", "guid": candidate for "use"}
    POST /api/scan                    run the loop now
    GET  /api/digest[?days=7]         the week in one message (also sent to Telegram on Sundays at 18:00)
    POST /api/restart                 end the process: s6 starts it again (after install.sh)
"""
from __future__ import annotations

import json
import os
import shutil
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from .pipeline import STATES, Pipeline

DEFAULTS = {"jobs": "/data/video-pipeline", "poll_s": 300, "port": 8339, "category": "barch-dub",
            "download_path": "/data/completed/videos/barch-dub", "max_downloads": 3, "searches_per_tick": 4,
            "research_h": 24, "stalled_h": 24, "max_failures": 4, "max_donor_gb": 40, "max_season_donor_gb": 120,
            "subtitles": ["por", "eng"], "delete_donor": False, "digest": True, "trim": True,
            "trims_per_tick": 4}


def load_config(path: str) -> dict:
    cfg = dict(DEFAULTS)
    p = Path(path)
    if p.exists():
        cfg.update(json.loads(p.read_text()))
    # tokens and keys, never in the repository: secrets.json, then any secrets-<name>.json next to it
    # (install.sh adds secrets-sonarr.json without touching the container-owned secrets.json)
    for sec in [p.with_name("secrets.json")] + sorted(p.parent.glob("secrets-*.json")):
        if not sec.exists():
            continue
        for k, v in json.loads(sec.read_text()).items():
            if isinstance(v, dict):
                cfg.setdefault(k, {}).update(v)
            else:
                cfg[k] = v
    return cfg


def missing_tools() -> list[str]:
    out = [t for t in ("ffmpeg", "ffprobe", "mkvmerge") if not shutil.which(t)]
    for mod in ("numpy", "scipy"):
        try:
            __import__(mod)
        except ImportError:
            out.append(f"python {mod}")
    return out


def summary(j: dict) -> dict:
    keys = ("id", "kind", "movie_id", "series_id", "season", "title", "year", "original", "state", "reason", "audio",
            "updated", "done_at")
    c = next((c for c in j.get("candidates", []) if c["guid"] == j.get("donor")), None)
    return {k: j.get(k) for k in keys} | {
        "donor": (c or {}).get("title", ""), "progress": (c or {}).get("progress"),
        "candidates": len(j.get("candidates", [])), "failures": j.get("failures", 0),
        "episodes": len(j.get("episodes", {})) or None,
        "episodes_todo": sum(1 for e in j.get("episodes", {}).values() if e["state"] != "done") if j.get("episodes") else None,
        "offset_ms": (j.get("alignment") or {}).get("offset_ms") if (j.get("alignment") or {}).get("ok") else None}


def make_handler(p: Pipeline, token: str):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _send(self, code: int, obj) -> None:
            body = json.dumps(obj, ensure_ascii=False).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _auth(self, q) -> bool:
            got = self.headers.get("X-Barch-Token") or (q.get("token") or [""])[0]
            if token and got != token:
                self._send(401, {"ok": False, "error": "token"})
                return False
            return True

        def do_GET(self):
            u = urlparse(self.path)
            q = parse_qs(u.query)
            parts = [x for x in u.path.split("/") if x]
            if not self._auth(q):
                return
            if parts == ["api", "status"]:
                jobs = p.store.all()
                return self._send(200, {"ok": True, "doing": p.doing, "running": p.current, "missing": missing_tools(),
                                        "counts": {s: sum(1 for j in jobs if j["state"] == s) for s in STATES}})
            if parts == ["api", "jobs"]:
                st = (q.get("state") or [""])[0]
                return self._send(200, {"ok": True, "jobs": [summary(j) for j in p.store.all()
                                                              if not st or j["state"] == st]})
            if len(parts) == 3 and parts[:2] == ["api", "jobs"]:
                j = p.store.load(parts[2])
                return self._send(200, {"ok": True, "job": j}) if j else self._send(404, {"ok": False, "error": "no such job"})
            if parts == ["api", "digest"]:
                return self._send(200, {"ok": True, "text": p.digest(int((q.get("days") or ["7"])[0]))})
            return self._send(404, {"ok": False, "error": "not found"})

        def do_POST(self):
            u = urlparse(self.path)
            q = parse_qs(u.query)
            parts = [x for x in u.path.split("/") if x]
            if not self._auth(q):
                return
            n = int(self.headers.get("Content-Length") or 0)
            try:
                body = json.loads(self.rfile.read(n) or b"{}") if n else {}
            except json.JSONDecodeError:
                return self._send(400, {"ok": False, "error": "body is not JSON"})
            if parts == ["api", "scan"]:
                p.wake.set()
                return self._send(200, {"ok": True})
            if parts == ["api", "restart"]:
                self._send(200, {"ok": True})
                threading.Timer(0.5, lambda: os._exit(0)).start()
                return
            if len(parts) == 3 and parts[:2] == ["api", "jobs"]:
                try:
                    j = p.act(parts[2], str(body.get("action", "")), str(body.get("guid", "")))
                except KeyError as e:
                    return self._send(404, {"ok": False, "error": f"not found: {e}"})
                except ValueError as e:
                    return self._send(400, {"ok": False, "error": f"unknown action {e}"})
                return self._send(200, {"ok": True, "job": summary(j)})
            return self._send(404, {"ok": False, "error": "not found"})

    return H


def digest_loop(p: Pipeline) -> None:
    """Sundays at 18:00 (container time): the week to Telegram."""
    sent = ""
    while True:
        t = time.localtime()
        key = time.strftime("%Y-%W", t)
        if p.cfg.get("digest", True) and t.tm_wday == 6 and t.tm_hour == 18 and sent != key:
            p.tg.send(p.digest(7))
            sent = key
        time.sleep(300)


def serve(cfg_path: str) -> None:
    cfg = load_config(cfg_path)
    miss = missing_tools()
    if miss:
        print(f"video pipeline: missing {', '.join(miss)} (50-video-pipeline-packages installs them)", flush=True)
    p = Pipeline(cfg)
    threading.Thread(target=p.loop, daemon=True).start()
    threading.Thread(target=digest_loop, args=(p,), daemon=True).start()
    srv = ThreadingHTTPServer(("0.0.0.0", int(cfg["port"])), make_handler(p, cfg.get("token", "")))
    print(f"video pipeline: listening on {cfg['port']}", flush=True)
    srv.serve_forever()


def main(argv: list[str]) -> int:
    from . import sync
    if len(argv) >= 1 and argv[0] == "serve":
        cfg = argv[argv.index("--config") + 1] if "--config" in argv else "/config/pipeline/config.json"
        serve(cfg)
        return 0
    if len(argv) >= 3 and argv[0] in ("align", "mux"):
        ref, donor = argv[1], argv[2]
        ra = [s for s in sync.probe(ref)["streams"] if s["codec_type"] == "audio"]
        da = [s for s in sync.probe(donor)["streams"] if s["codec_type"] == "audio"]
        rn = int(argv[3]) if len(argv) > 3 else 0
        dn = int(argv[4]) if len(argv) > 4 else 0
        print(f"reference audio {rn}: {sync.lang(ra[rn])}   donor audio {dn}: {sync.lang(da[dn])}")
        a = sync.align(ref, ra[rn]["index"], donor, da[dn]["index"])
        print(json.dumps(a.to_dict(), indent=1))
        if argv[0] == "mux" and a.ok:
            por = [k for k, s in enumerate(da) if sync.norm_lang(sync.lang(s)) == "por"] or [dn]
            plan = sync.MuxPlan(ref=ref, donor=donor, original=[sync.lang(ra[rn])], alignment=a,
                                ref_audio_pos=[rn], donor_por_pos=por)
            out = sync.mux(plan)
            print("\n".join(plan.log))
            print("written:", out)
            print(json.dumps(sync.verify(out, 0, 1).to_dict(), indent=1))
        return 0 if a.ok else 1
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
