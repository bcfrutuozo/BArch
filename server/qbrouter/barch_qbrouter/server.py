"""HTTP around proxy.Proxy: the qBittorrent Web API it answers, the backends it calls, the guard loop.

Standard library only (the container is linuxserver's Alpine base image plus python3).
"""

from __future__ import annotations

import json
import os
import secrets
import threading
import time
import uuid
from email.parser import BytesParser
from email.policy import HTTP
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.parse import parse_qsl, urlencode, urljoin, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

from .proxy import Files, HashMap, HostBook, Pairs, Proxy, Reply, Route, _log
from .torrent import host_matches, safe_url

MAX_TORRENT = 20 * 1024 * 1024


class HTTPBackend:
    """One qBittorrent. Logs in only when it has credentials and gets a 403 (a whitelisted subnet needs none)."""

    def __init__(self, name: str, url: str, username: str = "", password: str = "", timeout: float = 30):
        self.name, self.url = name, url.rstrip("/")
        self.username, self.password, self.timeout = username, password, timeout
        self.cookie = ""
        self.lock = threading.Lock()

    def _login(self) -> None:
        body = urlencode({"username": self.username, "password": self.password}).encode()
        req = Request(self.url + "/api/v2/auth/login", data=body, method="POST",
                      headers={"Content-Type": "application/x-www-form-urlencoded", "Referer": self.url})
        with build_opener().open(req, timeout=self.timeout) as r:
            cookies = [c.split(";", 1)[0] for c in r.headers.get_all("Set-Cookie") or []]
            if r.read().strip() != b"Ok." or not cookies:
                raise PermissionError(f"{self.name}: login refused")
            with self.lock:
                self.cookie = "; ".join(cookies)

    def call(self, method: str, endpoint: str, query: Pairs | None = None,
             fields: Pairs | None = None, files: Files | None = None) -> Reply:
        r = self._once(method, endpoint, query, fields, files)
        if r.status == 403 and self.username:
            self._login()
            r = self._once(method, endpoint, query, fields, files)
        return r

    def _once(self, method, endpoint, query, fields, files) -> Reply:
        url = f"{self.url}/api/v2/{endpoint}"
        if query:
            url += "?" + urlencode(query)
        headers = {"Referer": self.url}
        data = None
        if files:
            data, ctype = encode_multipart(fields or [], files)
            headers["Content-Type"] = ctype
        elif fields or method == "POST":
            data = urlencode(fields or []).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        with self.lock:
            if self.cookie:
                headers["Cookie"] = self.cookie
        req = Request(url, data=data, method=method, headers=headers)
        try:
            with build_opener().open(req, timeout=self.timeout) as resp:
                return Reply(resp.status, resp.read(), resp.headers.get("Content-Type", "text/plain"))
        except HTTPError as e:
            with e:
                return Reply(e.code, e.read(), e.headers.get("Content-Type", "text/plain") if e.headers else "text/plain")


def encode_multipart(fields: Pairs, files: Files) -> tuple[bytes, str]:
    boundary = "barch" + uuid.uuid4().hex
    out = bytearray()
    for k, v in fields:
        out += f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n'.encode()
        out += v.encode() + b"\r\n"
    for k, fname, data in files:
        fname = fname.replace('"', "'").replace("\r", " ").replace("\n", " ")
        out += (f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"; filename="{fname}"\r\n'
                "Content-Type: application/x-bittorrent\r\n\r\n").encode()
        out += data + b"\r\n"
    out += f"--{boundary}--\r\n".encode()
    return bytes(out), f"multipart/form-data; boundary={boundary}"


def decode_multipart(ctype: str, body: bytes) -> tuple[Pairs, Files]:
    msg = BytesParser(policy=HTTP).parsebytes(b"Content-Type: " + ctype.encode() + b"\r\n\r\n" + body)
    fields: Pairs = []
    files: Files = []
    for part in msg.iter_parts():
        name = part.get_param("name", header="content-disposition") or ""
        data = part.get_payload(decode=True) or b""
        fname = part.get_filename()
        if fname is not None:
            files.append((name, fname, data))
        else:
            fields.append((name, data.decode("utf-8", "replace")))
    return fields, files


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D102, ANN001
        return None


def make_fetcher(api_key: str = "", key_hosts: list[str] | None = None, timeout: float = 30):
    """GET a .torrent URL by hand, hop by hop, so a redirect to a magnet comes back as that magnet.

    Prowlarr's API key goes only to the hosts named for it (Prowlarr's own links carry it anyway)."""
    key_hosts = key_hosts or []
    opener = build_opener(_NoRedirect)

    def fetch(url: str) -> bytes | str:
        for _ in range(6):
            host = (urlsplit(url).hostname or "").lower()
            headers = {"Accept": "application/x-bittorrent", "User-Agent": "barch-qbrouter"}
            if api_key and host_matches(host, key_hosts):
                headers["X-Api-Key"] = api_key
            try:
                with opener.open(Request(url, headers=headers), timeout=timeout) as r:
                    data = r.read(MAX_TORRENT + 1)
                    if len(data) > MAX_TORRENT:
                        raise ValueError("larger than 20 MB, not a .torrent")
                    return data
            except HTTPError as e:
                e.close()
                loc = e.headers.get("Location") if e.headers else None
                if e.code in (301, 302, 303, 307, 308) and loc:
                    if loc.lower().startswith("magnet:"):
                        return loc
                    url = urljoin(url, loc)
                    continue
                raise ValueError(f"HTTP {e.code} from {safe_url(url)}") from e
        raise ValueError("too many redirects")

    return fetch


def build(config: dict, secret: dict) -> Proxy:
    creds = secret.get("backends", {})
    backends = {
        name: HTTPBackend(name, b["url"], creds.get(name, {}).get("username", ""),
                          creds.get(name, {}).get("password", ""))
        for name, b in config["backends"].items()
    }
    if config["default"] not in backends:
        raise SystemExit(f"default backend {config['default']!r} is not in backends")
    routes = [Route(r["backend"], list(r["hosts"])) for r in config.get("routes", [])]
    for r in routes:
        if r.backend not in backends:
            raise SystemExit(f"route to unknown backend {r.backend!r}")
    fetch = make_fetcher(secret.get("prowlarr_api_key", ""), config.get("fetch", {}).get("api_key_hosts", []))
    pb = config.get("private_backend")
    if pb is not None and pb not in backends:
        raise SystemExit(f"private_backend {pb!r} is not in backends")
    state = config.get("state")
    hosts = os.path.join(os.path.dirname(state), "hosts.json") if state else None
    return Proxy(backends, config["default"], routes, fetch, HashMap(state), private_backend=pb,
                 hostbook=HostBook(hosts))


def status(proxy: Proxy) -> dict:
    out = {"ok": True, "default": proxy.default, "backends": {}, "mapped": len(proxy.hashmap.map),
           "routes": [{"backend": r.backend, "hosts": r.hosts} for r in proxy.routes],
           "private_backend": proxy.private_backend, "learned_private_hosts": sorted(proxy.hostbook.private),
           "guard_last": int(proxy.guard_last), "blocked": proxy.blocked}
    for name, b in proxy.backends.items():
        v = proxy._call(name, "GET", "app/version", [], [], [])
        out["backends"][name] = {"url": getattr(b, "url", ""), "reachable": v.status == 200,
                                 "version": v.body.decode("utf-8", "replace") if v.status == 200 else ""}
        out["ok"] = out["ok"] and v.status == 200
    return out


def serve(config: dict, secret: dict) -> None:
    proxy = build(config, secret)
    sid = secrets.token_hex(16)

    class Handler(BaseHTTPRequestHandler):
        server_version = "barch-qbrouter"

        def log_message(self, fmt, *args):  # noqa: ANN001, D102 - quiet: one line per add/guard is enough
            pass

        def _reply(self, r: Reply, cookie: bool = False) -> None:
            self.send_response(r.status)
            self.send_header("Content-Type", r.ctype)
            self.send_header("Content-Length", str(len(r.body)))
            if cookie:
                self.send_header("Set-Cookie", f"SID={sid}; HttpOnly; SameSite=Strict; path=/")
            self.end_headers()
            self.wfile.write(r.body)

        def _handle(self, method: str) -> None:
            parts = urlsplit(self.path)
            if parts.path.rstrip("/") == "/barch/status":
                return self._reply(Reply.json(status(proxy)))
            if not parts.path.startswith("/api/v2/"):
                return self._reply(Reply.text("Not Found", 404))
            endpoint = parts.path[len("/api/v2/") :].strip("/")
            query = parse_qsl(parts.query, keep_blank_values=True)
            n = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(n) if n else b""
            ctype = self.headers.get("Content-Type", "")
            fields: Pairs = []
            files: Files = []
            if ctype.startswith("multipart/form-data"):
                fields, files = decode_multipart(ctype, body)
            elif body:
                fields = parse_qsl(body.decode("utf-8", "replace"), keep_blank_values=True)
            r = proxy.dispatch(method, endpoint, query, fields, files)
            self._reply(r, cookie=endpoint == "auth/login")

        def do_GET(self) -> None:  # noqa: N802, D102
            self._handle("GET")

        def do_POST(self) -> None:  # noqa: N802, D102
            self._handle("POST")

    every = float(config.get("guard_s", 60))

    def guard_loop() -> None:
        while True:
            try:
                proxy.guard()
            except Exception as e:  # noqa: BLE001 - the loop must outlive one bad answer
                _log(f"guard: {type(e).__name__}: {e}")
            time.sleep(every)

    if every > 0:
        threading.Thread(target=guard_loop, daemon=True, name="guard").start()
    host, port = config.get("listen", "0.0.0.0"), int(config.get("port", 8080))
    routes = "; ".join(f"{','.join(r.hosts)} -> {r.backend}" for r in proxy.routes) or "none"
    if proxy.private_backend:
        routes += f"; private torrents -> {proxy.private_backend}"
    _log(f"listening on {host}:{port}; default {proxy.default}; routes: {routes}; guard every {every:g}s")
    ThreadingHTTPServer((host, port), Handler).serve_forever()


def load(path: str) -> tuple[dict, dict]:
    with open(path) as f:
        config = json.load(f)
    secret: dict = {}
    sp = config.get("secrets")
    if sp:
        try:
            with open(sp) as f:
                secret = json.load(f)
        except FileNotFoundError:
            secret = {}
    return config, secret
