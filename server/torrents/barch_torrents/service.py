"""qBittorrent statistics over time, as a service in its own container on the NAS (s6: custom-services.d).

    python3 -m barch_torrents serve [--config /config/config.json]

Every `poll_s` (5 min, on the clock) it reads qBittorrent's counters and writes them down (store.py):
the client's all-time totals, and what every torrent uploaded and downloaded since the last sample.
A new torrent gets its tracker (first announce host) and the indexer it was grabbed from: by its hash
from Lidarr's, Radarr's and Sonarr's history, else by title and time from Prowlarr's, which every grab
goes through (Shelfmark's books too). Read only: nothing is ever changed in qBittorrent.

HTTP (port 8340). GET / is the Torrents app as a page (web.html next to this file: static, it asks for the
token itself); the API wants the header X-Barch-Token or ?token=; `range` is 24h, 7d, 30d, 12w, 1y or all:
    GET  /api/status                          the sampler: last sample, how many, errors
    GET  /api/overview?range=30d              totals now, what moved in the range, the last day/week/month
    GET  /api/samples?range=7d                the client over time: ratio, speeds, torrents, size, free space
    GET  /api/history?range=30d[&by=category|indexer|tracker|hash&key=...]
                                              upload/download per hour, day, week or month + lifetime ratio
    GET  /api/groups?by=indexer&range=30d     every category, indexer or tracker
    GET  /api/torrents?range=30d[&by=&key=&state=live|removed|all&sort=up|total_up|ratio|...&q=&limit=]
    GET  /api/torrents/<hash>?range=30d       one torrent and its history
    POST /api/sample                          sample now
    POST /api/restart                         end the process: s6 starts it again (after install.sh)
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

from .integrations import Arr, Prowlarr, QBit, first_tracker, match_grabs
from .store import Store, parse_range

DEFAULTS = {"db": "/config/data/torrents.db", "port": 8340, "poll_s": 300, "goal_ratio": 3.0, "keep_hours_days": 60,
            "qbittorrent": {"url": "http://qbittorrent:8080"}, "lidarr": {"url": "http://lidarr:8686"},
            "radarr": {"url": "http://radarr:7878"}, "sonarr": {"url": "http://sonarr:8989"},
            "prowlarr": {"url": "http://prowlarr:9696"}}
ARRS = ("lidarr", "radarr", "sonarr")


def load_config(path: str) -> dict:
    cfg = json.loads(json.dumps(DEFAULTS))
    p = Path(path)
    # settings, then tokens and keys (never in the repository): secrets.json and any secrets-<name>.json
    for f in [p, p.with_name("secrets.json")] + sorted(p.parent.glob("secrets-*.json")):
        if not f.exists():
            continue
        for k, v in json.loads(f.read_text()).items():
            if isinstance(v, dict) and isinstance(cfg.get(k), dict):
                cfg[k].update(v)
            else:
                cfg[k] = v
    return cfg


class Sampler:
    def __init__(self, cfg: dict, store: Store):
        self.cfg, self.store = cfg, store
        self.qbit = QBit(cfg["qbittorrent"])
        self.arrs = [a for a in (Arr(n, cfg.get(n) or {}) for n in ARRS) if a.ok]
        self.prowlarr = Prowlarr(cfg.get("prowlarr") or {})
        self.wake = threading.Event()
        self.error = ""               # why the last sample failed ("" = it worked)
        self.last = {}                # what the last sample moved
        self.version = ""
        self.asked: set[str] = set()  # hashes the *arr history was already asked about (since this start)
        self.since: dict[str, str] = {}   # per *arr (and Prowlarr): its history was read up to here
        self.compacted = ""

    def sample(self) -> dict:
        server, torrents = self.qbit.maindata()
        moved = self.store.record(int(time.time()), server, torrents)
        self.label()
        return moved

    def label(self) -> None:
        """Tracker and indexer of the torrents that have none yet; a failure here never costs a sample."""
        for h in self.store.without("tracker")[:40]:
            try:
                self.store.label("tracker", {h: first_tracker(self.qbit.trackers(h)) or "(none)"})
            except Exception as e:  # noqa: BLE001
                print(f"[torrents] trackers of {h}: {e}", flush=True)
                break
        new = set(self.store.without("indexer", live=False)) - self.asked
        if not new or not self.sources:
            return
        asked_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 86400))
        for arr in self.arrs:
            try:
                # all of its history the first time, then only what was grabbed since the last look
                n = self.store.label("indexer", arr.indexers(self.since.get(arr.name, "2000-01-01T00:00:00Z")))
                self.since[arr.name] = asked_at
                if n:
                    print(f"[torrents] {arr.name}: indexer of {n} torrents", flush=True)
            except Exception as e:  # noqa: BLE001
                print(f"[torrents] {arr.name} history: {e}", flush=True)
                return                 # asked again at the next sample
        if self.prowlarr.ok:
            try:
                left = self.store.unlabeled()      # what no *arr grabbed, or whose *arr has no key here
                if left:
                    grabs = self.prowlarr.grabs(self.since.get("prowlarr", "2000-01-01T00:00:00Z"))
                    n = self.store.label("indexer", match_grabs(left, grabs))
                    if n:
                        print(f"[torrents] prowlarr: indexer of {n} torrents (by title and time)", flush=True)
                self.since["prowlarr"] = asked_at
            except Exception as e:  # noqa: BLE001
                print(f"[torrents] prowlarr history: {e}", flush=True)
                return
        self.asked |= new

    @property
    def sources(self) -> list[str]:
        """Where indexers come from, by name."""
        return [a.name for a in self.arrs] + (["prowlarr"] if self.prowlarr.ok else [])

    def loop(self) -> None:
        poll = max(30, int(self.cfg["poll_s"]))
        while True:
            try:
                self.last = self.sample()
                if self.error:
                    print("[torrents] sampling again", flush=True)
                self.error = ""
                if not self.version:
                    self.version = self.qbit.version()
                day = time.strftime("%Y-%m-%d")
                if day != self.compacted:
                    self.compacted = day
                    n = self.store.compact(time.time(), int(self.cfg["keep_hours_days"]))
                    if n:
                        print(f"[torrents] {n} hourly rows merged into days", flush=True)
            except Exception as e:  # noqa: BLE001
                if str(e) != self.error:
                    print(f"[torrents] sample failed: {e}", flush=True)
                self.error = str(e)
            self.wake.clear()
            self.wake.wait(poll - time.time() % poll)      # on the clock: :00, :05, :10…


def make_handler(s: Sampler, token: str):
    store, cfg = s.store, s.cfg

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _send(self, code: int, obj=None, raw: bytes | None = None, ctype: str = "application/json") -> None:
            body = raw if raw is not None else json.dumps(obj, ensure_ascii=False).encode()
            self.send_response(code)
            self.send_header("Content-Type", ctype)
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
            if not parts:                      # the app as a page: static, it asks for the token itself
                return self._send(200, raw=Path(__file__).with_name("web.html").read_bytes(), ctype="text/html; charset=utf-8")
            if parts == ["favicon.ico"]:
                return self._send(404, {"ok": False, "error": "no icon"})
            if not self._auth(q):
                return
            arg = lambda k, d="": (q.get(k) or [d])[0]  # noqa: E731
            now = time.time()
            try:
                span = parse_range(arg("range", "30d"))
                if parts == ["api", "status"]:
                    return self._send(200, {"ok": True, **store.status(), "start": store.start, "now": int(now),
                                            "poll_s": int(cfg["poll_s"]), "error": s.error, "moved": s.last,
                                            "qbittorrent": s.version, "indexers_from": s.sources,
                                            # with Prowlarr every grab is covered; without it, only these apps' are not
                                            "indexers_missing": [] if s.prowlarr.ok else [n for n in ARRS if n not in s.sources],
                                            "db_bytes": os.path.getsize(cfg["db"]) if os.path.exists(cfg["db"]) else 0})
                if parts == ["api", "overview"]:
                    return self._send(200, {"ok": True, **store.overview(now, span, float(cfg["goal_ratio"]))})
                if parts == ["api", "samples"]:
                    return self._send(200, {"ok": True, "from": store.origin(now, span), "to": int(now),
                                            "start": store.start,
                                            "samples": store.samples(now, span, int(arg("points", "240")))})
                if parts == ["api", "history"]:
                    return self._send(200, {"ok": True, **store.history(now, span, arg("by"), arg("key"), arg("bucket"))})
                if parts == ["api", "groups"]:
                    return self._send(200, {"ok": True, "by": arg("by", "indexer"),
                                            "groups": store.groups(now, span, arg("by", "indexer"))})
                if parts == ["api", "torrents"]:
                    return self._send(200, {"ok": True, "torrents": store.torrents(
                        now, span, arg("by"), arg("key"), arg("state", "all"), arg("sort", "up"), arg("q"),
                        int(arg("limit", "300")))})
                if len(parts) == 3 and parts[:2] == ["api", "torrents"]:
                    t = store.torrent(parts[2])
                    if not t:
                        return self._send(404, {"ok": False, "error": "no such torrent"})
                    return self._send(200, {"ok": True, "torrent": t, "history": store.history(now, span, "hash", parts[2])})
            except ValueError as e:
                return self._send(400, {"ok": False, "error": str(e)})
            return self._send(404, {"ok": False, "error": "not found"})

        def do_POST(self):
            u = urlparse(self.path)
            parts = [x for x in u.path.split("/") if x]
            if not self._auth(parse_qs(u.query)):
                return
            self.rfile.read(int(self.headers.get("Content-Length") or 0))
            if parts == ["api", "sample"]:
                s.wake.set()
                return self._send(200, {"ok": True})
            if parts == ["api", "restart"]:
                self._send(200, {"ok": True})
                threading.Timer(0.5, lambda: os._exit(0)).start()
                return
            return self._send(404, {"ok": False, "error": "not found"})

    return H


def serve(cfg_path: str) -> None:
    cfg = load_config(cfg_path)
    Path(cfg["db"]).parent.mkdir(parents=True, exist_ok=True)
    s = Sampler(cfg, Store(cfg["db"]))
    threading.Thread(target=s.loop, daemon=True).start()
    srv = ThreadingHTTPServer(("0.0.0.0", int(cfg["port"])), make_handler(s, cfg.get("token", "")))
    print(f"torrents: sampling {cfg['qbittorrent']['url']} every {cfg['poll_s']} s, listening on {cfg['port']}"
          f" (indexers from {', '.join(s.sources) or 'nowhere: no API key'})", flush=True)
    srv.serve_forever()


def main(argv: list[str]) -> int:
    if argv[:1] == ["serve"]:
        serve(argv[argv.index("--config") + 1] if "--config" in argv else "/config/config.json")
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
