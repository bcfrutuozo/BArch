"""qBittorrent, Lidarr, Plex and Telegram: the few calls the pipeline needs, standard library only."""
from __future__ import annotations

import http.cookiejar
import json
from pathlib import Path
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

    def artists(self, q: str = "") -> list[dict]:
        """Every artist Lidarr tracks (name filter, case-insensitive), compact."""
        if not self.enabled:
            return []
        out = []
        for a in self.h.call("GET", "/api/v1/artist") or []:
            if q and q.lower() not in a.get("artistName", "").lower():
                continue
            st = a.get("statistics") or {}
            out.append({"id": a["id"], "name": a.get("artistName", ""), "mbid": a.get("foreignArtistId", ""),
                        "monitored": a.get("monitored", False), "metadata_profile": a.get("metadataProfileId"),
                        "quality_profile": a.get("qualityProfileId"), "albums": st.get("albumCount", 0),
                        "tracks": st.get("totalTrackCount", 0), "files": st.get("trackFileCount", 0)})
        return sorted(out, key=lambda x: x["name"].lower())

    def albums(self, artist: str) -> list[dict]:
        """The albums of one artist (Lidarr id or exact name), with type, status and monitoring."""
        if not self.enabled:
            return []
        if not artist.isdigit():
            found = [a for a in self.artists(artist) if a["name"].lower() == artist.lower()] or self.artists(artist)
            if len(found) != 1:
                raise ValueError(f"{len(found)} artists match {artist!r}: " + ", ".join(a["name"] for a in found[:10]))
            artist = str(found[0]["id"])
        out = []
        for al in self.h.call("GET", "/api/v1/album", params={"artistId": artist, "includeAllArtistAlbums": "true"}) or []:
            st = al.get("statistics") or {}
            out.append({"id": al["id"], "title": al.get("title", ""), "type": al.get("albumType", ""),
                        "secondary": al.get("secondaryTypes") or [], "date": (al.get("releaseDate") or "")[:10],
                        "monitored": al.get("monitored", False), "tracks": st.get("totalTrackCount", 0),
                        "files": st.get("trackFileCount", 0), "mbid": al.get("foreignAlbumId", "")})
        return sorted(out, key=lambda x: (x["date"], x["title"]))

    def metadata_profiles(self) -> list[dict]:
        """Every metadata profile as Lidarr has it, with the allowed types and statuses spelled out."""
        if not self.enabled:
            return []
        out = []
        for pr in self.h.call("GET", "/api/v1/metadataprofile") or []:
            out.append({"id": pr["id"], "name": pr["name"],
                        "primary": [t["albumType"]["name"] for t in pr.get("primaryAlbumTypes", []) if t.get("allowed")],
                        "secondary": [t["albumType"]["name"] for t in pr.get("secondaryAlbumTypes", []) if t.get("allowed")],
                        "statuses": [t["releaseStatus"]["name"] for t in pr.get("releaseStatuses", []) if t.get("allowed")]})
        return out

    def set_metadata_profile(self, name: str, primary: list[str], secondary: list[str], statuses: list[str],
                             apply_to: str | list[int] = "") -> str:
        """Create or update the metadata profile `name` (only these primary types, secondary types and
        release statuses allowed; names as Lidarr shows them: Album, EP, Single, Broadcast, Other;
        Compilation, Live, Remix, Soundtrack, ...; Official, Promotion, Bootleg, Pseudo-Release) and,
        with apply_to "all" or a list of artist ids, make those artists use it."""
        if not self.enabled:
            return "Lidarr: no API key configured"
        low = lambda xs: {x.lower() for x in xs}
        profiles = self.h.call("GET", "/api/v1/metadataprofile") or []
        cur = next((pr for pr in profiles if pr["name"].lower() == name.lower()), None)
        base = cur or self.h.call("GET", "/api/v1/metadataprofile/schema")
        for t in base.get("primaryAlbumTypes", []):
            t["allowed"] = t["albumType"]["name"].lower() in low(primary)
        for t in base.get("secondaryAlbumTypes", []):
            t["allowed"] = t["albumType"]["name"].lower() in low(secondary)
        for t in base.get("releaseStatuses", []):
            t["allowed"] = t["releaseStatus"]["name"].lower() in low(statuses)
        base["name"] = name
        if cur:
            saved = self.h.call("PUT", f"/api/v1/metadataprofile/{cur['id']}", body=base)
            what = f"Lidarr: metadata profile {name!r} updated"
        else:
            base.pop("id", None)
            saved = self.h.call("POST", "/api/v1/metadataprofile", body=base)
            what = f"Lidarr: metadata profile {name!r} created"
        pid = (saved or {}).get("id") or (cur or {}).get("id")
        if apply_to and pid:
            ids = [a["id"] for a in self.h.call("GET", "/api/v1/artist") or []] if apply_to == "all" else [int(i) for i in apply_to]
            self.h.call("PUT", "/api/v1/artist/editor", body={"artistIds": ids, "metadataProfileId": pid})
            for i in ids:
                self.h.call("POST", "/api/v1/command", body={"name": "RefreshArtist", "artistId": i})
            what += f", applied to {len(ids)} artist(s) (refreshing them)"
        return what

    def unmonitor_group(self, group_mbid: str, why: str = "") -> str:
        """Stop looking for this album (a rejected one): otherwise the RSS sync grabs another release of it."""
        if not self.enabled or not group_mbid:
            return ""
        alb = self.album_by_group(group_mbid)
        if not alb or not alb.get("monitored"):
            return ""
        self.h.call("PUT", "/api/v1/album/monitor", body={"albumIds": [alb["id"]], "monitored": False})
        return f"Lidarr: {alb.get('title')!r} unmonitored" + (f" ({why})" if why else "")

    def enforce(self, profile: str, seen_file: Path | None = None) -> str:
        """The library's rule on every artist, now and for the ones added later: the metadata profile
        `profile` (every distinct album: studio, EP, live, compilation), new albums monitored as they
        appear, and every album listed without a single file monitored (once: an album Bruno unmonitors
        afterwards stays so; `seen_file` remembers the ids). Skipped while a RefreshArtist runs, since
        it would write the albums back as they were. Returns what changed."""
        if not self.enabled:
            return "Lidarr: no API key configured"
        if any(c.get("name") == "RefreshArtist" and c.get("status") in ("started", "queued") for c in self.commands()):
            return "Lidarr: a RefreshArtist is running, nothing changed"
        pid = next((pr["id"] for pr in self.metadata_profiles() if pr["name"].lower() == profile.lower()), None)
        if not pid:
            raise ValueError(f"Lidarr has no metadata profile {profile!r}")
        artists = self.h.call("GET", "/api/v1/artist") or []
        wrong = [a["id"] for a in artists if a.get("metadataProfileId") != pid or a.get("monitorNewItems") != "all"]
        out = []
        if wrong:
            self.h.call("PUT", "/api/v1/artist/editor", body={"artistIds": wrong, "metadataProfileId": pid, "monitorNewItems": "all"})
            for i in wrong:
                self.h.call("POST", "/api/v1/command", body={"name": "RefreshArtist", "artistId": i})
            out.append(f"{len(wrong)} artist(s) put on the {profile!r} profile (refreshing: their albums get listed, monitored and searched)")
        seen: set[int] = set()
        if seen_file and seen_file.exists():
            try:
                seen = set(json.loads(seen_file.read_text()))
            except (OSError, ValueError):
                seen = set()
        albums = self.h.call("GET", "/api/v1/album") or []
        new = [al["id"] for al in albums if not al.get("monitored") and (al.get("statistics") or {}).get("trackFileCount", 0) == 0
               and al["id"] not in seen and al.get("anyReleaseOk", True)]
        if new:
            self.h.call("PUT", "/api/v1/album/monitor", body={"albumIds": new, "monitored": True})
            self.h.call("POST", "/api/v1/command", body={"name": "AlbumSearch", "albumIds": new})
            out.append(f"{len(new)} album(s) without a file monitored and searched")
        if seen_file:
            seen |= {al["id"] for al in albums}
            seen_file.write_text(json.dumps(sorted(seen)))
        return "Lidarr: " + ("; ".join(out) if out else f"every artist on {profile!r}, nothing to change")

    def set_artists(self, ids: list[int] | str, monitored: bool | None = None, monitor_new_items: str = "") -> str:
        """Artist settings in bulk ("all" or Lidarr ids): `monitored`, and what Lidarr does with an album
        that appears in the artist's list later (`monitor_new_items`: all | none | new, where new = only
        albums released after the artist was added). A refresh that recreates the albums (a metadata
        profile change does) monitors every one of them under "all", which is how a whole discography
        of compilations ends up in the download queue."""
        if not self.enabled:
            return "Lidarr: no API key configured"
        if ids == "all":
            ids = [a["id"] for a in self.h.call("GET", "/api/v1/artist") or []]
        body: dict = {"artistIds": [int(i) for i in ids]}
        if monitored is not None:
            body["monitored"] = monitored
        if monitor_new_items:
            if monitor_new_items not in ("all", "none", "new"):
                raise ValueError("monitor_new_items must be all, none or new")
            body["monitorNewItems"] = monitor_new_items
        self.h.call("PUT", "/api/v1/artist/editor", body=body)
        what = [f"monitored={monitored}"] if monitored is not None else []
        if monitor_new_items:
            what.append(f"new albums: {monitor_new_items}")
        return f"Lidarr: {len(body['artistIds'])} artist(s) updated ({', '.join(what) or 'nothing changed'})"

    def commands(self) -> list[dict]:
        """Lidarr's recent and running commands (RefreshArtist, AlbumSearch, ...): a refresh of a big artist
        takes minutes and writes every album back as it was when it started, undoing a monitor change made meanwhile."""
        if not self.enabled:
            return []
        return [{"id": c["id"], "name": c.get("name", ""), "status": c.get("status", ""), "started": c.get("started", ""),
                 "ended": c.get("ended", ""), "artist_id": (c.get("body") or {}).get("artistId"), "albums": len((c.get("body") or {}).get("albumIds") or []),
                 "trigger": c.get("trigger", ""), "duration": c.get("duration", "")}
                for c in self.h.call("GET", "/api/v1/command") or []]

    def cancel_command(self, cid: int) -> str:
        """Stop a running or queued Lidarr command (an AlbumSearch over a whole discography, say)."""
        if not self.enabled:
            return "Lidarr: no API key configured"
        self.h.call("DELETE", f"/api/v1/command/{int(cid)}")
        return f"Lidarr: command {cid} cancelled"

    def queue(self) -> list[dict]:
        """What Lidarr grabbed and is still waiting for (downloading, stalled, waiting to import), compact."""
        if not self.enabled:
            return []
        r = self.h.call("GET", "/api/v1/queue", params={"page": 1, "pageSize": 1000, "includeArtist": "true",
                                                         "includeAlbum": "true", "includeUnknownArtistItems": "true"}) or {}
        out = []
        for it in r.get("records", []):
            out.append({"id": it["id"], "artist": (it.get("artist") or {}).get("artistName", ""),
                        "album": (it.get("album") or {}).get("title", ""), "album_id": it.get("albumId"),
                        "title": it.get("title", ""), "status": it.get("status", ""),
                        "state": it.get("trackedDownloadState", ""), "client": it.get("downloadClient", ""),
                        "size_gb": round((it.get("size") or 0) / 1e9, 2), "left_gb": round((it.get("sizeleft") or 0) / 1e9, 2)})
        return sorted(out, key=lambda x: (x["artist"], x["album"]))

    def remove_queue(self, ids: list[int], blocklist: bool = True, from_client: bool = True) -> str:
        """Drop these queue items: the download leaves the client with its files and the release goes to
        Lidarr's blocklist, so the same one is not grabbed again (no automatic re-search either)."""
        if not self.enabled:
            return "Lidarr: no API key configured"
        if not ids:
            return "Lidarr: nothing to remove"
        self.h.call("DELETE", "/api/v1/queue/bulk", params={"removeFromClient": str(from_client).lower(),
                                                            "blocklist": str(blocklist).lower(), "skipRedownload": "true"},
                    body={"ids": [int(i) for i in ids]})
        return f"Lidarr: {len(ids)} queue item(s) removed" + (" and blocklisted" if blocklist else "") + (", download deleted" if from_client else "")

    def import_lists(self) -> list[dict]:
        if not self.enabled:
            return []
        return [{"id": l["id"], "name": l.get("name", ""), "type": l.get("implementation", ""),
                 "enabled": l.get("enableAutomaticAdd", False), "monitor": l.get("shouldMonitor", ""),
                 "fields": {f["name"]: f.get("value") for f in l.get("fields", []) if "value" in f}}
                for l in self.h.call("GET", "/api/v1/importlist") or []]

    def add_import_list(self, implementation: str, name: str, fields: dict, monitor: str = "specificAlbum",
                        search: bool = False, metadata_profile: str = "", quality_profile: str = "") -> str:
        """An import list from Lidarr's own schema (`implementation` as Lidarr names it: LastFmUser,
        LastFmTag, SpotifyFollowedArtists, ...; Spotify ones need the OAuth step in the UI), with
        `fields` {name: value} over the schema's defaults, automatic add on, monitoring `monitor`
        (none | specificAlbum | entireArtist), the first root folder and the named profiles (or the first)."""
        if not self.enabled:
            return "Lidarr: no API key configured"
        schema = next((s for s in self.h.call("GET", "/api/v1/importlist/schema") or []
                       if s.get("implementation", "").lower() == implementation.lower()), None)
        if not schema:
            raise ValueError(f"Lidarr has no import list type {implementation!r}")
        for f in schema.get("fields", []):
            if f["name"] in fields:
                f["value"] = fields[f["name"]]
        missing = [k for k in fields if k not in {f["name"] for f in schema.get("fields", [])}]
        if missing:
            raise ValueError(f"{implementation} has no field(s) {', '.join(missing)}; it has: "
                             + ", ".join(f["name"] for f in schema.get("fields", [])))
        roots = self.h.call("GET", "/api/v1/rootfolder") or []
        qps = self.h.call("GET", "/api/v1/qualityprofile") or []
        mps = self.h.call("GET", "/api/v1/metadataprofile") or []
        pick = lambda xs, n: next((x for x in xs if n and x["name"].lower() == n.lower()), xs[0] if xs else {"id": 0})
        schema.update({"name": name, "enableAutomaticAdd": True, "shouldMonitor": monitor, "shouldSearch": search,
                       "shouldMonitorExisting": False, "monitorNewItems": "all" if monitor == "entireArtist" else "none",
                       "rootFolderPath": roots[0]["path"] if roots else "", "qualityProfileId": pick(qps, quality_profile)["id"],
                       "metadataProfileId": pick(mps, metadata_profile)["id"], "tags": []})
        schema.pop("id", None)
        saved = self.h.call("POST", "/api/v1/importlist", body=schema)
        return f"Lidarr: import list {name!r} ({implementation}) added, id {(saved or {}).get('id', '?')}; it syncs every 24 h (System > Tasks > Import List Sync runs it now)"

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
