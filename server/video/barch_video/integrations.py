"""Radarr, Prowlarr, qBittorrent, Telegram and Wikidata: the few calls the video pipeline needs,
standard library only (same shape as server/music's)."""
from __future__ import annotations

import http.cookiejar
import json
import urllib.parse
import urllib.request

UA = "BArch-video/1.0 (+https://github.com/bcfrutuozo/BArch)"


class Http:
    def __init__(self, base: str, headers: dict | None = None, timeout: int = 60):
        self.base = base.rstrip("/")
        self.headers = {"User-Agent": UA, **(headers or {})}
        self.timeout = timeout
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

    def call(self, method: str, path: str, params: dict | None = None, body=None, form: dict | None = None,
             timeout: int | None = None):
        url = self.base + path + ("?" + urllib.parse.urlencode(params, doseq=True) if params else "")
        data, headers = None, dict(self.headers)
        if form is not None:
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

    def add(self, url: str, category: str, tag: str) -> None:
        r = self._api("POST", "/torrents/add", form={"urls": url, "category": category, "tags": tag})
        if isinstance(r, str) and "fail" in r.lower():
            raise RuntimeError(f"qBittorrent refused the torrent: {r}")

    def by_tag(self, tag: str) -> dict | None:
        r = self._api("GET", "/torrents/info", params={"tag": tag}) or []
        return r[0] if r else None

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
