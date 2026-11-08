"""Radarr, Sonarr, Prowlarr, qBittorrent, Telegram and Wikidata: the few calls the video pipeline needs,
standard library only (same shape as server/music's)."""
from __future__ import annotations

import http.cookiejar
import base64
import binascii
import hashlib
import json
import os
import re
import time
import urllib.parse
import urllib.request

UA = "BArch-video/1.0 (+https://github.com/bcfrutuozo/BArch)"


def magnet_hash(magnet: str) -> str:
    """The info hash of a magnet link, lower-case hex (a base32 btih is converted); "" when there is none."""
    m = re.search(r"xt=urn:btih:([A-Za-z0-9]+)", magnet or "")
    if not m:
        return ""
    h = m.group(1)
    if len(h) == 32:
        try:
            return base64.b32decode(h.upper()).hex()
        except (binascii.Error, ValueError):
            return ""
    return h.lower() if len(h) == 40 else ""


def _bdecode(data: bytes, i: int = 0):
    """Minimal bencode decoder: returns (value, end); dicts also carry the byte span of each value."""
    c = data[i:i + 1]
    if c == b"i":
        j = data.index(b"e", i)
        return int(data[i + 1:j]), j + 1
    if c == b"l":
        out, i = [], i + 1
        while data[i:i + 1] != b"e":
            v, i = _bdecode(data, i)
            out.append(v)
        return out, i + 1
    if c == b"d":
        out, i = {}, i + 1
        while data[i:i + 1] != b"e":
            k, i = _bdecode(data, i)
            start = i
            v, i = _bdecode(data, i)
            out[k] = (v, start, i)
        return out, i + 1
    j = data.index(b":", i)
    n = int(data[i:j])
    return data[j + 1:j + 1 + n], j + 1 + n


def torrent_hash(data: bytes) -> str:
    """The v1 info hash of a .torrent file (sha1 of its bencoded `info`), lower-case hex; "" if unreadable."""
    try:
        top, _ = _bdecode(data)
        _, start, end = top[b"info"]
        return hashlib.sha1(data[start:end]).hexdigest()
    except (KeyError, ValueError, IndexError, TypeError):
        return ""


def fetch_torrent(url: str, timeout: int = 60) -> tuple[str, str | bytes]:
    """What a download link really is: ("magnet", "magnet:?...") when it redirects to or returns a magnet
    (Prowlarr's links to the public indexers 301 to one), ("torrent", bytes) when it serves the file. The
    pipeline follows the link itself: qBittorrent in a VPN container (binhex) resolves names through
    the tunnel's DNS, so `http://prowlarr:9696/...` is "remote host name not found" there, and the add
    fails after the API already said Ok (2026-11-08: eight jobs in review for that)."""
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *a, **k):
            return None
    opener = urllib.request.build_opener(NoRedirect, urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
    for _ in range(6):
        if url.startswith("magnet:"):
            return "magnet", url
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        try:
            with opener.open(req, timeout=timeout) as r:
                body, ctype = r.read(), r.headers.get("Content-Type", "")
        except urllib.error.HTTPError as e:
            if 300 <= e.code < 400 and e.headers.get("Location"):
                url = urllib.parse.urljoin(url, e.headers["Location"])
                continue
            raise RuntimeError(f"the link answered HTTP {e.code}") from e
        if body[:1] == b"d" and torrent_hash(body):
            return "torrent", body
        text = body[:300].decode(errors="replace").strip()
        if text.startswith("magnet:"):
            return "magnet", text.split()[0]
        raise RuntimeError(f"the link gave neither a torrent nor a magnet ({ctype or 'no content type'}, {len(body)} bytes)")
    raise RuntimeError("the link redirects too many times")


def qbit_failure_reason(entries: list[dict], *hints: str) -> str:
    """qBittorrent's own reason for a torrent it did not add, from `log/main` entries ("Failed to add
    torrent. Source: ... Reason: ..."), matched by any of `hints` (the source URL, the hash); "" if none."""
    hints = tuple(h.lower() for h in hints if h)
    for e in reversed(entries or []):
        msg = str(e.get("message") or "")
        if "failed to add torrent" not in msg.lower():
            continue
        if hints and not any(h in msg.lower() for h in hints):
            continue
        m = re.search(r'Reason:\s*"?(.*?)"?\s*$', msg)
        return (m.group(1) if m else msg).strip()
    return ""


class Http:
    def __init__(self, base: str, headers: dict | None = None, timeout: int = 60):
        self.base = base.rstrip("/")
        self.headers = {"User-Agent": UA, **(headers or {})}
        self.timeout = timeout
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

    def call(self, method: str, path: str, params: dict | None = None, body=None, form: dict | None = None,
             timeout: int | None = None, files: dict | None = None):
        url = self.base + path + ("?" + urllib.parse.urlencode(params, doseq=True) if params else "")
        data, headers = None, dict(self.headers)
        if files:
            # multipart/form-data: the form fields plus {field: (filename, bytes)}
            boundary = "----barch" + hashlib.sha1(os.urandom(16)).hexdigest()
            parts = []
            for k, v in (form or {}).items():
                parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n".encode())
            for k, (name, blob) in files.items():
                parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"; filename=\"{name}\"\r\n"
                             f"Content-Type: application/x-bittorrent\r\n\r\n".encode() + blob + b"\r\n")
            data = b"".join(parts) + f"--{boundary}--\r\n".encode()
            headers["Content-Type"] = f"multipart/form-data; boundary={boundary}"
        elif form is not None:
            data = urllib.parse.urlencode(form).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        elif body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        with self.opener.open(req, timeout=timeout or self.timeout) as r:
            raw = r.read()
        try:
            return json.loads(raw.decode() or "null")
        except json.JSONDecodeError:
            return raw.decode(errors="replace")


class Arr:
    """Radarr (or Sonarr) API v3."""

    def __init__(self, cfg: dict, default_url: str):
        self.h = Http(cfg.get("url", default_url), {"X-Api-Key": cfg.get("api_key", "")})

    def get(self, path: str, **params):
        return self.h.call("GET", "/api/v3" + path, params=params or None)

    def put(self, path: str, body):
        return self.h.call("PUT", "/api/v3" + path, body=body)

    def command(self, name: str, **body) -> int:
        return (self.h.call("POST", "/api/v3/command", body={"name": name, **body}) or {}).get("id", 0)

    def wait(self, cid: int, timeout_s: int = 600) -> str:
        for _ in range(timeout_s // 5):
            st = (self.get(f"/command/{cid}") or {}).get("status", "")
            if st in ("completed", "failed", "aborted"):
                return st
            time.sleep(5)
        return "timeout"

    def manual_import(self, folder: str, path: str, extra: dict) -> str:
        """Import the file at `path` where it is (the app links its record to it again): what fixed a
        movie Radarr marked MissingFromDisk during a replace and then left without a file (2026-11-05)."""
        cands = self.get("/manualimport", folder=folder, filterExistingFiles="false") or []
        c = next((x for x in cands if x.get("path") == path), None)
        if not c:
            return "not offered by manual import"
        f = {"path": path, "quality": c.get("quality"), "languages": c.get("languages") or [],
             "releaseGroup": c.get("releaseGroup") or "", "indexerFlags": c.get("indexerFlags") or 0} | extra
        return self.wait(self.command("ManualImport", importMode="auto", files=[f]), 300)

    def languages(self) -> dict[str, dict]:
        return {x["name"]: {"id": x["id"], "name": x["name"]} for x in self.get("/language") or []}


class Radarr(Arr):
    def __init__(self, cfg: dict):
        super().__init__(cfg, "http://radarr:7878")

    def movies(self) -> list[dict]:
        return self.get("/movie") or []

    def movie(self, mid: int) -> dict:
        return self.get(f"/movie/{mid}") or {}

    def rescan(self, mid: int) -> int:
        return self.command("RescanMovie", movieId=mid)

    def set_file_languages(self, file_id: int, names: list[str]) -> None:
        """The file's languages as Radarr scores them (the PT-BR custom format reads them): after a mux
        the file has the original and PT-BR, so Radarr has no reason to look for a dual release."""
        langs = self.languages()
        mf = self.get(f"/moviefile/{file_id}") or {}
        if not mf:
            return
        mf["languages"] = [langs[n] for n in names if n in langs]
        self.put(f"/moviefile/{file_id}", mf)


class Sonarr(Arr):
    def __init__(self, cfg: dict):
        super().__init__(cfg, "http://sonarr:8989")

    def all_series(self) -> list[dict]:
        return self.get("/series") or []

    def series(self, sid: int) -> dict:
        return self.get(f"/series/{sid}") or {}

    def episode_files(self, sid: int) -> list[dict]:
        return self.get("/episodefile", seriesId=sid) or []

    def episodes(self, sid: int) -> list[dict]:
        return self.get("/episode", seriesId=sid) or []

    def rescan(self, sid: int) -> int:
        return self.command("RescanSeries", seriesId=sid)

    def set_file_languages(self, file_id: int, names: list[str]) -> None:
        """Same as Radarr's: the episode file's languages, so the PT-BR custom format sees the dub."""
        langs = self.languages()
        ef = self.get(f"/episodefile/{file_id}") or {}
        if not ef:
            return
        ef["languages"] = [langs[n] for n in names if n in langs]
        self.put(f"/episodefile/{file_id}", ef)


class Prowlarr:
    def __init__(self, cfg: dict):
        self.h = Http(cfg.get("url", "http://prowlarr:9696"), {"X-Api-Key": cfg.get("api_key", "")}, timeout=180)

    def search(self, query: str, categories: tuple[int, ...] = (2000,)) -> list[dict]:
        return self.h.call("GET", "/api/v1/search", params={"query": query, "type": "search",
                                                             "categories": list(categories), "limit": 100}) or []


class QBit:
    """qBittorrent Web API v2 (the container is on frutuozoproxy, whitelisted; logs in when given credentials)."""

    def __init__(self, cfg: dict):
        url = cfg.get("url", "http://qbittorrent:8080")
        self.h = Http(url, {"Referer": url})
        self.user, self.password = cfg.get("username", ""), cfg.get("password", "")
        self.logged = False

    def _api(self, method, path, **kw):
        if self.user and not self.logged:
            self.h.call("POST", "/api/v2/auth/login", form={"username": self.user, "password": self.password})
            self.logged = True
        return self.h.call(method, "/api/v2" + path, **kw)

    def ensure_category(self, name: str, path: str) -> None:
        cats = self._api("GET", "/torrents/categories") or {}
        if name not in cats:
            self._api("POST", "/torrents/createCategory", form={"category": name, "savePath": path})

    def add(self, url: str, category: str, tag: str) -> str:
        """Adds the release behind `url` (a magnet, or a link the pipeline follows itself: fetch_torrent)
        and returns its info hash when known, so the download can be found even if the tag is lost."""
        kind, src = fetch_torrent(url) if not url.startswith("magnet:") else ("magnet", url)
        fields = {"category": category, "tags": tag}
        if kind == "magnet":
            r = self._api("POST", "/torrents/add", form={"urls": src, **fields})
            h = magnet_hash(src)
        else:
            r = self._api("POST", "/torrents/add", form=fields, files={"torrents": ("release.torrent", src)})
            h = torrent_hash(src)
        if isinstance(r, str) and "fail" in r.lower():
            raise RuntimeError(f"qBittorrent refused the torrent: {r}")
        return h

    def by_tag(self, tag: str) -> dict | None:
        r = self._api("GET", "/torrents/info", params={"tag": tag}) or []
        return r[0] if r else None

    def by_hash(self, h: str) -> dict | None:
        if not h:
            return None
        r = self._api("GET", "/torrents/info", params={"hashes": h}) or []
        return r[0] if r else None

    def failure(self, *hints: str) -> str:
        """Why qBittorrent did not keep a torrent it said Ok to (its log), "" when it says nothing."""
        try:
            entries = self._api("GET", "/log/main", params={"warning": "true", "critical": "true", "normal": "false", "info": "false"}) or []
        except Exception:  # noqa: BLE001
            return ""
        return qbit_failure_reason(entries, *hints)

    def files(self, h: str) -> list[dict]:
        return self._api("GET", "/torrents/files", params={"hash": h}) or []

    def delete(self, h: str, files: bool = True) -> None:
        self._api("POST", "/torrents/delete", form={"hashes": h, "deleteFiles": "true" if files else "false"})


class Telegram:
    def __init__(self, cfg: dict):
        self.token, self.chat = cfg.get("bot_token", ""), cfg.get("chat_id", "")

    def send(self, text: str) -> None:
        if not (self.token and self.chat):
            return
        try:
            Http(f"https://api.telegram.org/bot{self.token}").call(
                "POST", "/sendMessage", body={"chat_id": self.chat, "text": text[:4000], "disable_web_page_preview": True})
        except Exception:  # noqa: BLE001 - a notification never stops the pipeline
            pass


def portuguese_titles(imdb_id: str) -> list[str]:
    """The Brazilian (then Portuguese) title of a film and its aliases, from Wikidata by its IMDb id:
    dubbed releases are named in Portuguese ("Harry Potter e a Pedra Filosofal")."""
    if not imdb_id:
        return []
    h = Http("https://www.wikidata.org", timeout=30)
    try:
        r = h.call("GET", "/w/api.php", params={"action": "query", "list": "search", "format": "json",
                                                  "srsearch": f"haswbstatement:P345={imdb_id}"})
        hits = (r or {}).get("query", {}).get("search", [])
        if not hits:
            return []
        q = hits[0]["title"]
        e = h.call("GET", "/w/api.php", params={"action": "wbgetentities", "ids": q, "props": "labels|aliases",
                                                  "languages": "pt-br|pt", "format": "json"})["entities"][q]
    except Exception:  # noqa: BLE001 - no title is not an error, the original title is searched anyway
        return []
    out: list[str] = []
    for lang in ("pt-br", "pt"):
        v = e.get("labels", {}).get(lang, {}).get("value")
        if v and v not in out:
            out.append(v)
    for lang in ("pt-br", "pt"):
        for a in e.get("aliases", {}).get(lang, []):
            if a["value"] not in out and len(out) < 4:
                out.append(a["value"])
    return out
