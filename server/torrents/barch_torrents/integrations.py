"""qBittorrent, the *arr history and Prowlarr's: the few read-only calls the torrent statistics need,
standard library only (same shape as server/music's and server/video's)."""
from __future__ import annotations

import http.cookiejar
import json
import re
from datetime import datetime
import urllib.error
import urllib.parse
import urllib.request

UA = "BArch-torrents/1.0 (+https://github.com/bcfrutuozo/BArch)"
SECOND_LEVEL = {"co", "com", "org", "net", "gov", "edu", "ac"}
SHARED = {"eu.org", "duckdns.org", "dedyn.io", "ddns.net"}       # domains whose subdomains belong to different people


def tracker_host(url: str) -> str:
    """The host of an announce URL, nothing else (the path and query of a private one hold the passkey)."""
    if not url or url.startswith("**"):           # "** [DHT] **", "** [PeX] **", "** [LSD] **"
        return ""
    try:
        return (urllib.parse.urlsplit(url).hostname or "").lower()
    except ValueError:
        return ""


def tracker_site(host: str) -> str:
    """bt2.t-ru.org, bt3.t-ru.org -> t-ru.org: the announce hosts of one tracker count as one."""
    parts = host.split(".")
    if len(parts) <= 2 or parts[-1].isdigit() or ":" in host:      # short already, or an IP address
        return host
    keep = 3 if (len(parts[-1]) == 2 and parts[-2] in SECOND_LEVEL) or ".".join(parts[-2:]) in SHARED else 2
    return ".".join(parts[-keep:])


def first_tracker(trackers: list[dict]) -> str:
    """The site of a torrent's first announce URL (lowest tier, the torrent's own order): where it was
    published, for what that is worth on a public torrent carrying twenty open trackers."""
    real = [(int(x.get("tier") or 0), n, tracker_host(x.get("url", ""))) for n, x in enumerate(trackers or [])]
    real = sorted(x for x in real if x[2])
    return tracker_site(real[0][2]) if real else ""


class Http:
    def __init__(self, base: str, headers: dict | None = None, timeout: int = 60):
        self.base = base.rstrip("/")
        self.headers = {"User-Agent": UA, **(headers or {})}
        self.timeout = timeout
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

    def call(self, method: str, path: str, params: dict | None = None, form: dict | None = None):
        url = self.base + path + ("?" + urllib.parse.urlencode(params, doseq=True) if params else "")
        data, headers = None, dict(self.headers)
        if form is not None:
            data = urllib.parse.urlencode(form).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        with self.opener.open(req, timeout=self.timeout) as r:
            raw = r.read()
        try:
            return json.loads(raw.decode() or "null")
        except json.JSONDecodeError:
            return raw.decode(errors="replace")


class QBit:
    """qBittorrent Web API v2, read only. The container is on frutuozoproxy, whitelisted in
    qBittorrent, but it logs in anyway when given credentials (it survives a whitelist change)."""

    def __init__(self, cfg: dict):
        url = cfg.get("url", "http://qbittorrent:8080")
        self.h = Http(url, {"Referer": url})
        self.user, self.password = cfg.get("username", ""), cfg.get("password", "")
        self.logged = False

    def _api(self, path: str, **params):
        if self.user and not self.logged:
            self.h.call("POST", "/api/v2/auth/login", form={"username": self.user, "password": self.password})
            self.logged = True
        try:
            return self.h.call("GET", "/api/v2" + path, params=params or None)
        except urllib.error.HTTPError as e:
            if e.code == 403:                      # the session expired: log in again next time
                self.logged = False
            raise

    def maindata(self) -> tuple[dict, dict[str, dict]]:
        """(server_state, torrents by hash): everything a sample needs in one call."""
        d = self._api("/sync/maindata", rid=0)
        if not isinstance(d, dict) or "server_state" not in d:
            raise RuntimeError(f"qBittorrent answered: {str(d)[:120]}")
        return d["server_state"], d.get("torrents") or {}

    def trackers(self, h: str) -> list[dict]:
        return self._api("/torrents/trackers", hash=h) or []

    def version(self) -> str:
        return str(self._api("/app/version") or "")


class Arr:
    """Lidarr (API v1), Radarr or Sonarr (v3): which indexer every grabbed download came from."""

    def __init__(self, name: str, cfg: dict):
        self.name = name
        self.v = "v1" if name == "lidarr" else "v3"
        self.h = Http(cfg.get("url", ""), {"X-Api-Key": cfg.get("api_key", "")})
        self.ok = bool(cfg.get("url") and cfg.get("api_key"))

    def indexers(self, since: str = "2000-01-01T00:00:00Z") -> dict[str, str]:
        """{torrent hash: indexer name} of the downloads grabbed since `since` (eventType 1 = grabbed)."""
        rows = self.h.call("GET", f"/api/{self.v}/history/since", params={"date": since, "eventType": 1}) or []
        out = {}
        for r in rows if isinstance(rows, list) else []:
            h = (r.get("downloadId") or "").lower()
            name = ((r.get("data") or {}).get("indexer") or "").removesuffix(" (Prowlarr)").strip()
            if len(h) in (40, 64) and name:        # a torrent's info hash (a Usenet id is shorter)
                out[h] = name
        return out


def norm_title(s: str) -> str:
    """A release title or torrent name as words only: "Bon.Jovi-Best_Ballads [FLAC]" -> "bon jovi best ballads flac"."""
    return " ".join(re.sub(r"[^a-z0-9]+", " ", (s or "").lower()).split())


def match_grabs(torrents: list[dict], grabs: list[dict], exact_s: int = 5, near_s: int = 120) -> dict[str, str]:
    """{hash: indexer} for the torrents ({hash, name, added_on}) a Prowlarr grab ({t, title, indexer})
    explains. Prowlarr's history has no info hash, so a torrent is tied to a grab by what they share:
    the same title (as words), the nearest in time when it was grabbed more than once; or, when the name
    inside the torrent is not the indexer's title (or still the hash of a magnet), the moment: the client
    gets the torrent the second it is grabbed. Among the grabs within `near_s` the one whose words overlap
    most wins; it needs `exact_s` or some overlap, and two indexers equally near with nothing to tell them
    apart is no answer."""
    by_title: dict[str, list[dict]] = {}
    for g in grabs:
        g["_n"] = norm_title(g["title"])
        by_title.setdefault(g["_n"], []).append(g)
    out = {}
    for t in torrents:
        name, added = norm_title(t.get("name", "")), int(t.get("added_on") or 0)
        same = by_title.get(name) if name else None
        if same:
            out[t["hash"]] = min(same, key=lambda g: abs(g["t"] - added))["indexer"]
            continue
        words = set(name.split())
        scored = []
        for g in grabs:
            dt = abs(g["t"] - added)
            if dt <= near_s:
                gw = set(g["_n"].split())
                scored.append((len(words & gw) / max(1, len(words | gw)), -dt, g["indexer"]))
        if not scored:
            continue
        scored.sort(reverse=True)
        overlap, dt, indexer = scored[0]
        tied = [x for x in scored[1:] if x[:2] == (overlap, dt) and x[2] != indexer]
        if (-dt <= exact_s or overlap >= 0.3) and not tied:
            out[t["hash"]] = indexer
    return out


class Prowlarr:
    """Every grab of every app goes through Prowlarr (Lidarr, Radarr, Sonarr, Shelfmark): its history is
    the one place that knows the indexer of a torrent no *arr grabbed, by title and time (match_grabs)."""

    def __init__(self, cfg: dict):
        self.name = "prowlarr"
        self.h = Http(cfg.get("url", ""), {"X-Api-Key": cfg.get("api_key", "")})
        self.ok = bool(cfg.get("url") and cfg.get("api_key"))

    def grabs(self, since: str = "2000-01-01T00:00:00Z") -> list[dict]:
        """[{t, title, indexer}] of the releases grabbed since `since` (eventType 1 = releaseGrabbed)."""
        # torrent indexers only: a Usenet grab of the same second is not where a torrent came from
        names = {i["id"]: i.get("name", "") for i in self.h.call("GET", "/api/v1/indexer") or []
                 if i.get("protocol", "torrent") == "torrent"}
        rows = self.h.call("GET", "/api/v1/history/since", params={"date": since, "eventType": 1}) or []
        out = []
        for r in rows if isinstance(rows, list) else []:
            title, name = (r.get("data") or {}).get("grabTitle") or "", names.get(r.get("indexerId"), "")
            try:
                t = datetime.fromisoformat((r.get("date") or "").replace("Z", "+00:00")).timestamp()
            except ValueError:
                continue
            if name:
                out.append({"t": int(t), "title": title, "indexer": name})
        return out
