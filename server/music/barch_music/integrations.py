"""qBittorrent, Lidarr, Plex and Telegram: the few calls the pipeline needs, standard library only."""
from __future__ import annotations

import http.cookiejar
import json
import urllib.parse
import urllib.request


class Http:
    def __init__(self, base: str, headers: dict | None = None, timeout: int = 30):
        self.base = base.rstrip("/")
        self.headers = headers or {}
        self.timeout = timeout
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

    def call(self, method: str, path: str, params: dict | None = None, body=None, form: dict | None = None,
             raw: bytes | None = None, ctype: str = ""):
        url = self.base + path + ("?" + urllib.parse.urlencode(params) if params else "")
        data, headers = None, dict(self.headers)
        if raw is not None:
            data = raw
            headers["Content-Type"] = ctype or "application/octet-stream"
        elif form is not None:
            data = urllib.parse.urlencode(form).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        elif body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        with self.opener.open(req, timeout=self.timeout) as r:
            raw = r.read()
        try:
            return json.loads(raw.decode() or "null")
        except json.JSONDecodeError:
            return raw.decode(errors="replace")


class QBit:
    """qBittorrent Web API v2. The pipeline's container is on frutuozoproxy, whitelisted in
    qBittorrent, but it logs in anyway when given credentials (it survives a whitelist change)."""

    def __init__(self, cfg: dict):
        self.h = Http(cfg.get("url", "http://qbittorrent:8080"), {"Referer": cfg.get("url", "http://qbittorrent:8080")})
        self.user, self.password = cfg.get("username", ""), cfg.get("password", "")
        self.logged = False

    def _api(self, method, path, **kw):
        if self.user and not self.logged:
            self.h.call("POST", "/api/v2/auth/login", form={"username": self.user, "password": self.password})
            self.logged = True
        return self.h.call(method, "/api/v2" + path, **kw)

    def completed(self, categories: list[str]) -> list[dict]:
        out = []
        for cat in categories:
            for t in self._api("GET", "/torrents/info", params={"category": cat, "filter": "completed"}) or []:
                out.append(t)
        return out

    def torrent(self, h: str) -> dict | None:
        r = self._api("GET", "/torrents/info", params={"hashes": h}) or []
        return r[0] if r else None

    def tag(self, h: str, add: str = "", remove: str = ""):
        if remove:
            self._api("POST", "/torrents/removeTags", form={"hashes": h, "tags": remove})
        if add:
            self._api("POST", "/torrents/addTags", form={"hashes": h, "tags": add})

    def delete(self, h: str, files: bool = True):
        self._api("POST", "/torrents/delete", form={"hashes": h, "deleteFiles": "true" if files else "false"})


class Lidarr:
    def __init__(self, cfg: dict):
        self.h = Http(cfg.get("url", "http://lidarr:8686"), {"X-Api-Key": cfg.get("api_key", "")})
        self.enabled = bool(cfg.get("api_key"))

    def album_by_group(self, group_mbid: str) -> dict | None:
        r = self.h.call("GET", "/api/v1/album", params={"foreignAlbumId": group_mbid}) or []
        return r[0] if r else None

    def refresh(self, group_mbid: str) -> str:
        """Rescan the artist so Lidarr sees the new files and stops looking for the album;
        unmonitor the album if it still counts as missing (so no new download is grabbed)."""
        if not self.enabled:
            return "Lidarr: no API key configured"
        alb = self.album_by_group(group_mbid)
        if not alb:
            return "Lidarr: album not tracked (nothing to update)"
        self.h.call("POST", "/api/v1/command", body={"name": "RefreshArtist", "artistId": alb["artistId"]})
        alb2 = self.album_by_group(group_mbid) or alb
        if alb2.get("monitored"):
            self.h.call("PUT", "/api/v1/album/monitor", body={"albumIds": [alb2["id"]], "monitored": False})
            return f"Lidarr: artist rescanned, album {alb2.get('title')!r} unmonitored"
        return f"Lidarr: artist rescanned ({alb2.get('title')!r})"

    def monitor(self, ids: list[int], monitored: bool) -> str:
        if not self.enabled:
            return "Lidarr: no API key configured"
        self.h.call("PUT", "/api/v1/album/monitor", body={"albumIds": ids, "monitored": monitored})
        return f"Lidarr: {len(ids)} album(s) {'monitored' if monitored else 'unmonitored'}"

    def search(self, ids: list[int]) -> str:
        """Lidarr looks for these albums on the indexers now (it also monitors them)."""
        if not self.enabled:
            return "Lidarr: no API key configured"
        self.h.call("PUT", "/api/v1/album/monitor", body={"albumIds": ids, "monitored": True})
        r = self.h.call("POST", "/api/v1/command", body={"name": "AlbumSearch", "albumIds": ids})
        return f"Lidarr: searching {len(ids)} album(s) (command {(r or {}).get('id', '?')})"

    def flac_only_profile(self) -> str:
        """Every quality profile: only FLAC and FLAC 24bit allowed, cutoff FLAC."""
        if not self.enabled:
            return "Lidarr: no API key configured"
        changed = []
        for p in self.h.call("GET", "/api/v1/qualityprofile") or []:
            def walk(items):
                for i in items:
                    if i.get("items"):
                        walk(i["items"])
                        i["allowed"] = any(x.get("allowed") for x in i["items"])
                    else:
                        name = (i.get("quality") or {}).get("name", "")
                        i["allowed"] = name in ("FLAC", "FLAC 24bit")
            walk(p["items"])
            flac = next((i for i in p["items"] if (i.get("quality") or {}).get("name") == "FLAC"), None)
            if flac:
                p["cutoff"] = flac["quality"]["id"]
            p["upgradeAllowed"] = True
            self.h.call("PUT", f"/api/v1/qualityprofile/{p['id']}", body=p)
            changed.append(p["name"])
        return "Lidarr: FLAC only in " + ", ".join(changed)


class Plex:
    def __init__(self, cfg: dict):
        self.h = Http(cfg.get("url", "http://100.100.0.10:32400"), {"X-Plex-Token": cfg.get("token", ""), "Accept": "application/json"})
        self.section = cfg.get("section", "")
        self.path_prefix = cfg.get("path_prefix", "/data/music")       # /music as Plex sees it
        self.enabled = bool(cfg.get("token"))

    def scan(self, folder: str) -> str:
        if not self.enabled:
            return "Plex: no token configured"
        sec = self.section
        if not sec:
            for d in (self.h.call("GET", "/library/sections") or {}).get("MediaContainer", {}).get("Directory", []):
                if d.get("type") == "artist":
                    sec = d["key"]
                    break
        self.h.call("GET", f"/library/sections/{sec}/refresh", params={"path": f"{self.path_prefix}/{folder}"})
        return f"Plex: scanning {folder}"

    def _section(self) -> str:
        if self.section:
            return self.section
        for d in (self.h.call("GET", "/library/sections") or {}).get("MediaContainer", {}).get("Directory", []):
            if d.get("type") == "artist":
                return d["key"]
        return ""

    def album_key(self, folder: str) -> str:
        """The ratingKey of the album whose tracks live in /music/<folder>."""
        sec = self._section()
        album = folder.split("/", 1)[-1]
        want = f"{self.path_prefix}/{folder}/"
        r = self.h.call("GET", f"/library/sections/{sec}/all", params={"type": 9, "title": album}) or {}
        for a in (r.get("MediaContainer") or {}).get("Metadata", []):
            t = self.h.call("GET", f"/library/metadata/{a['ratingKey']}/children") or {}
            for tr in (t.get("MediaContainer") or {}).get("Metadata", [])[:1]:
                for m in tr.get("Media", []):
                    if any((pt.get("file") or "").startswith(want) for pt in m.get("Part", [])):
                        return str(a["ratingKey"])
        return ""

    def set_poster(self, folder: str, jpeg: bytes) -> str:
        """Upload the cover as the album's poster (a scan alone keeps Plex's cached one)."""
        if not self.enabled:
            return "Plex: no token configured"
        key = self.album_key(folder)
        if not key:
            return f"Plex: {folder} not found (scanning it)" if self.scan(folder) else ""
        self.h.call("POST", f"/library/metadata/{key}/posters", raw=jpeg, ctype="image/jpeg")
        return f"Plex: poster of {folder} replaced"


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
