"""qBittorrent, Lidarr, Plex and Telegram: the few calls the pipeline needs, standard library only."""
from __future__ import annotations

import http.cookiejar
import json
import time
import unicodedata
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

    def info(self, hashes: list[str]) -> list[dict]:
        return self._api("GET", "/torrents/info", params={"hashes": "|".join(hashes)}) or [] if hashes else []

    def torrent(self, h: str) -> dict | None:
        r = self._api("GET", "/torrents/info", params={"hashes": h}) or []
        return r[0] if r else None

    def all(self) -> list[dict]:
        return self._api("GET", "/torrents/info") or []

    def trackers(self, h: str) -> list[dict]:
        return self._api("GET", "/torrents/trackers", params={"hash": h}) or []

    def properties(self, h: str) -> dict:
        return self._api("GET", "/torrents/properties", params={"hash": h}) or {}

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

    def rescan_ids(self, artist_ids: list[int]) -> int:
        """One RescanFolders of just these artists' folders. Lidarr's "Rescan Artist Folder after Refresh"
        is Never here (2026-11-04): with Always every RefreshArtist queued a rescan of the whole root
        folder for that artist (about 40 min each over this library, run one at a time), so a refresh
        no longer reads files and whoever needs the files read asks for this."""
        if not self.enabled or not artist_ids:
            return 0
        want = set(artist_ids)
        paths = [a["path"] for a in self.h.call("GET", "/api/v1/artist") or [] if a.get("id") in want and a.get("path")]
        if paths:
            self.h.call("POST", "/api/v1/command", body={"name": "RescanFolders", "folders": paths})
        return len(paths)

    def refresh(self, group_mbid: str) -> str:
        """Rescan the artist's folder so Lidarr sees the new files and stops looking for the album
        (a rescan, not a RefreshArtist: the files changed, the metadata did not); unmonitor the album
        if it still counts as missing (so no new download is grabbed)."""
        if not self.enabled:
            return "Lidarr: no API key configured"
        alb = self.album_by_group(group_mbid)
        if not alb:
            return "Lidarr: album not tracked (nothing to update)"
        self.rescan_ids([alb["artistId"]])
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

    @staticmethod
    def name_key(s: str) -> str:
        """A name as typed: NFKC, case folded, every Unicode dash a plain "-" (MusicBrainz writes
        "T‐SQUARE" with U+2010, nobody types that)."""
        s = unicodedata.normalize("NFKC", s).casefold()
        return "".join("-" if unicodedata.category(c) == "Pd" else c for c in s)

    def artists(self, q: str = "") -> list[dict]:
        """Every artist Lidarr tracks (name filter: case and dash insensitive), compact."""
        if not self.enabled:
            return []
        out, key = [], self.name_key(q)
        for a in self.h.call("GET", "/api/v1/artist") or []:
            if q and key not in self.name_key(a.get("artistName", "")):
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
            found = [a for a in self.artists(artist) if self.name_key(a["name"]) == self.name_key(artist)] or self.artists(artist)
            if len(found) != 1:
                raise ValueError(f"{len(found)} artists match {artist!r}: " + ", ".join(a["name"] for a in found[:10]))
            artist = str(found[0]["id"])
        out = []
        for al in self.h.call("GET", "/api/v1/album", params={"artistId": artist, "includeAllArtistAlbums": "true"}) or []:
            st = al.get("statistics") or {}
            out.append({"id": al["id"], "artist_id": al.get("artistId"), "title": al.get("title", ""), "type": al.get("albumType", ""),
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
            self.rescan_ids(ids)   # the albums the new profile lists get their files (refresh reads none)
            what += f", applied to {len(ids)} artist(s) (refreshing them)"
        return what

    def unmonitor_group(self, group_mbid: str, why: str = "") -> str:
        """Stop looking for this album (a rejected one): otherwise the RSS sync grabs another release of it."""
        if not self.enabled or not group_mbid:
            return ""
        alb = self.album_by_group(group_mbid)
        if not alb or not alb.get("monitored"):
            return ""
        if (alb.get("statistics") or {}).get("trackFileCount", 0) > 0:
            return ""                      # the album is in the library already: its monitoring is not this download's business
        self.h.call("PUT", "/api/v1/album/monitor", body={"albumIds": [alb["id"]], "monitored": False})
        return f"Lidarr: {alb.get('title')!r} unmonitored" + (f" ({why})" if why else "")

    def enforce(self, profile: str, seen_file: Path | None = None, canon=None, budget: float = 300) -> str:
        """The library's rule on every artist, now and for the ones added later: the metadata profile
        `profile` (every distinct album: studio, EP, live, compilation) and every album listed without a
        single file monitored and searched (once: an album Bruno unmonitors afterwards stays so).

        With `canon` (canon.Canon) only the canonical albums: an EP, live album or compilation Wikipedia
        does not know is never monitored, and one monitored before is unmonitored (once too: monitored
        again by hand, it stays). Lidarr's own "monitor new items" is then off, since this check is what
        monitors a new album, within the hour. Artists are judged within `budget` seconds per run (the
        oldest verdicts first, a week of cache); the albums of an artist not judged yet wait for it.
        `seen_file` remembers the album ids monitored and unmonitored here. Skipped while a RefreshArtist
        runs, since it would write the albums back as they were. Returns what changed."""
        if not self.enabled:
            return "Lidarr: no API key configured"
        rules = self.release_rules()                    # never touched by a refresh: always kept as it should be
        if any(c.get("name") == "RefreshArtist" and c.get("status") in ("started", "queued") for c in self.commands()):
            return "Lidarr: " + (rules + "; " if rules else "") + "a RefreshArtist is running, nothing else changed"
        pid = next((pr["id"] for pr in self.metadata_profiles() if pr["name"].lower() == profile.lower()), None)
        if not pid:
            raise ValueError(f"Lidarr has no metadata profile {profile!r}")
        new_items = "none" if canon else "all"
        artists = self.h.call("GET", "/api/v1/artist") or []
        out = [rules] if rules else []
        wrong = [a["id"] for a in artists if a.get("metadataProfileId") != pid]
        if wrong:
            self.h.call("PUT", "/api/v1/artist/editor", body={"artistIds": wrong, "metadataProfileId": pid, "monitorNewItems": new_items})
            for i in wrong:
                self.h.call("POST", "/api/v1/command", body={"name": "RefreshArtist", "artistId": i})
            self.rescan_ids(wrong)   # the albums the profile lists get their files (refresh reads none)
            out.append(f"{len(wrong)} artist(s) put on the {profile!r} profile (refreshing: their albums get listed)")
        loose = [a["id"] for a in artists if a["id"] not in wrong and a.get("monitorNewItems") != new_items]
        if loose:
            self.h.call("PUT", "/api/v1/artist/editor", body={"artistIds": loose, "monitorNewItems": new_items})
            out.append(f"{len(loose)} artist(s) set to monitor new albums: {new_items}")
        state = {"seen": [], "dropped": []}
        if seen_file and seen_file.exists():
            try:
                raw = json.loads(seen_file.read_text())
                state = {"seen": raw, "dropped": []} if isinstance(raw, list) else {**state, **raw}
            except (OSError, ValueError):
                pass
        seen, dropped = set(state["seen"]), set(state["dropped"])
        mbid_of = {a["id"]: a.get("foreignArtistId", "") for a in artists}
        if canon:
            t0, judged = time.time(), 0
            for m in sorted(set(mbid_of.values()) - {""}, key=lambda m: (canon.cache.get(m) or {}).get("t", 0)):
                if canon.fresh(m) or time.time() - t0 > budget:
                    continue
                try:
                    canon.refresh(m)
                    judged += 1
                except Exception as e:  # noqa: BLE001
                    print(f"[canon] {m}: {e}", flush=True)
            if judged:
                out.append(f"{judged} artist(s) judged against Wikipedia")
        albums = self.h.call("GET", "/api/v1/album") or []
        add, drop = [], []
        for al in albums:
            if (al.get("statistics") or {}).get("trackFileCount", 0) > 0:
                continue
            v = canon.verdict(mbid_of.get(al.get("artistId"), ""), al.get("foreignAlbumId", "")) if canon else "any"
            if v is None:
                continue                                   # its artist is not judged yet
            if v and not al.get("monitored") and al["id"] not in seen and al.get("anyReleaseOk", True):
                add.append(al["id"])
            elif not v and al.get("monitored") and al["id"] not in dropped:
                drop.append(al["id"])
        if drop:
            self.h.call("PUT", "/api/v1/album/monitor", body={"albumIds": drop, "monitored": False})
            out.append(f"{len(drop)} album(s) Wikipedia does not know unmonitored (unofficial EPs, live albums, compilations)")
        if add:
            self.h.call("PUT", "/api/v1/album/monitor", body={"albumIds": add, "monitored": True})
            self.h.call("POST", "/api/v1/command", body={"name": "AlbumSearch", "albumIds": add})
            out.append(f"{len(add)} album(s) without a file monitored and searched")
        if seen_file:
            seen = (seen | set(add) | {al["id"] for al in albums if al.get("monitored")}) - set(drop)
            dropped |= set(drop)           # monitored again by hand, it stays; Wikipedia learning it later monitors it
            seen_file.write_text(json.dumps({"seen": sorted(seen), "dropped": sorted(dropped)}))
        return "Lidarr: " + ("; ".join(out) if out else f"every artist on {profile!r}, nothing to change")

    def rescan_artists(self, folders: list[str]) -> str:
        """Lidarr reads these artist folders of /music again (their files got MusicBrainz ids), without a
        full refresh of the artists (which would rewrite their albums' monitoring)."""
        if not self.enabled or not folders:
            return ""
        want = set(folders)
        paths = [a["path"] for a in self.h.call("GET", "/api/v1/artist") or [] if Path(a.get("path", "")).name in want]
        if paths:
            self.h.call("POST", "/api/v1/command", body={"name": "RescanFolders", "folders": paths})
        return f"Lidarr: {len(paths)} artist folder(s) rescanned"

    # What Lidarr must never grab (the review rejected these, 2026-11-04): a box set split per disc,
    # a discography, a "complete albums" pack. Lidarr matches each term against the release title,
    # /regex/i allowed; one release profile holds them, recognized by its first term.
    BLOCK = ["/\\b(box ?set|boxset|\\d+ ?(cd|disc)s? ?box|box of fire|collector'?s box)\\b/i",
             "/\\b(discography|discografia|diskografie)\\b/i",
             "/\\bcomplete (albums|studio albums|studio recordings|album collection|collection)\\b/i",
             "/\\b(original album classics|original album series|the album collection|triple album collection)\\b/i"]

    def release_rules(self) -> str:
        """The release profile with BLOCK as ignored terms, created or brought back as it should be."""
        if not self.enabled:
            return ""
        profiles = self.h.call("GET", "/api/v1/releaseprofile") or []
        mine = next((r for r in profiles if (r.get("ignored") or [None])[0] == self.BLOCK[0]), None)
        if mine and mine.get("ignored") == self.BLOCK and mine.get("enabled", True):
            return ""
        body = {**(mine or {}), "enabled": True, "required": (mine or {}).get("required") or [], "ignored": self.BLOCK,
                "indexerId": 0, "tags": (mine or {}).get("tags") or []}
        if mine:
            self.h.call("PUT", f"/api/v1/releaseprofile/{mine['id']}", body=body)
            return "release profile updated (box sets, discographies, complete collections ignored)"
        self.h.call("POST", "/api/v1/releaseprofile", body=body)
        return "release profile created (box sets, discographies, complete collections ignored)"

    def targeted_rescans(self, artist_ids: list[int]) -> str:
        """Adding an artist makes Lidarr queue a RescanFolders of the whole root folder for it (about 40 min
        each over this library, run one at a time): the queued ones of these artists are cancelled and one
        rescan of just their folders takes their place."""
        if not self.enabled or not artist_ids:
            return ""
        want = set(artist_ids)
        cancelled = 0
        for c in self.h.call("GET", "/api/v1/command") or []:
            body = c.get("body") or {}
            if c.get("name") == "RescanFolders" and c.get("status") == "queued" and want & set(body.get("artistIds") or []):
                try:
                    self.h.call("DELETE", f"/api/v1/command/{c['id']}")
                    cancelled += 1
                except Exception:  # noqa: BLE001
                    pass
        paths = [a["path"] for a in self.h.call("GET", "/api/v1/artist") or [] if a["id"] in want]
        if paths:
            self.h.call("POST", "/api/v1/command", body={"name": "RescanFolders", "folders": paths})
        return f"Lidarr: {cancelled} whole-library rescan(s) replaced by one of {len(paths)} artist folder(s)"

    def add_artist(self, mbid: str, folder: str, profile: str = "BArch", monitor: bool = True) -> str:
        """Track an artist the library already has: the MusicBrainz artist `mbid` at the existing folder
        `folder` of the root folder the other artists use (so the files there map), with the most used
        quality profile and the metadata profile `profile`. Nothing is monitored or searched on adding
        ("monitor new items: none"): the hourly enforce monitors and searches its official missing albums."""
        if not self.enabled:
            return "Lidarr: no API key configured"
        artists = self.h.call("GET", "/api/v1/artist") or []
        if any(a.get("foreignArtistId") == mbid for a in artists):
            return f"Lidarr: {folder} is tracked already"
        roots = [r["path"] for r in (self.h.call("GET", "/api/v1/rootfolder") or [])]
        if not roots:
            raise ValueError("Lidarr has no root folder")
        used = [a.get("rootFolderPath") or str(Path(a.get("path", "")).parent) for a in artists]
        root = max(roots, key=lambda r: sum(1 for u in used if u.rstrip("/") == r.rstrip("/")))
        qp = [a.get("qualityProfileId") for a in artists if a.get("qualityProfileId")]
        quality = max(set(qp), key=qp.count) if qp else (self.h.call("GET", "/api/v1/qualityprofile") or [{}])[0].get("id")
        pid = next((pr["id"] for pr in self.metadata_profiles() if pr["name"].lower() == profile.lower()), None)
        if not pid:
            raise ValueError(f"Lidarr has no metadata profile {profile!r}")
        found = self.h.call("GET", "/api/v1/artist/lookup", params={"term": f"lidarr:{mbid}"}) or []
        art = next((a for a in found if a.get("foreignArtistId") == mbid), None)
        if not art:
            raise ValueError(f"Lidarr's metadata server does not know the artist {mbid}")
        art.update({"qualityProfileId": quality, "metadataProfileId": pid, "rootFolderPath": root,
                    "path": root.rstrip("/") + "/" + folder, "monitored": True, "monitorNewItems": "none",
                    "addOptions": {"monitor": "none", "searchForMissingAlbums": False}})
        saved = self.h.call("POST", "/api/v1/artist", body=art) or {}
        if monitor and saved.get("id") and not saved.get("monitored"):     # a batch does it once at the end
            # addOptions "none" leaves the artist itself unmonitored, and Lidarr searches no album of it then
            self.h.call("PUT", "/api/v1/artist/editor", body={"artistIds": [saved["id"]], "monitored": True})
        return f"Lidarr: {art.get('artistName', folder)} added at {art['path']} (id {saved.get('id', '?')})"

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

    def stalled(self, qbit, hours: float = 48) -> list[dict]:
        """Queue items whose torrent has not moved for `hours`: stalled or still fetching metadata (no
        seeders), or in error, with no activity since; finished ones are the pipeline's, never listed."""
        if not self.enabled:
            return []
        r = self.h.call("GET", "/api/v1/queue", params={"page": 1, "pageSize": 1000, "includeAlbum": "true"}) or {}
        recs = [x for x in r.get("records", []) if x.get("downloadId") and (x.get("downloadClient") or "").lower().startswith("qbit")]
        if not recs:
            return []
        info = {t["hash"].lower(): t for t in qbit.info([x["downloadId"].lower() for x in recs])}
        now, out = time.time(), []
        for x in recs:
            t = info.get(x["downloadId"].lower())
            if not t or t.get("progress", 0) >= 1:
                continue
            quiet = now - max(t.get("last_activity") or 0, t.get("added_on") or 0)
            if t.get("state") in ("stalledDL", "metaDL", "error", "missingFiles") and quiet > hours * 3600:
                out.append({"id": x["id"], "hash": t["hash"].lower(), "title": x.get("title", ""), "album": (x.get("album") or {}).get("title", ""),
                            "state": t.get("state"), "progress": round(t.get("progress", 0) * 100), "quiet_h": round(quiet / 3600)})
        return out

    def remove_queue(self, ids: list[int], blocklist: bool = True, from_client: bool = True, redownload: bool = False) -> str:
        """Drop these queue items: the download leaves the client with its files and the release goes to
        Lidarr's blocklist, so the same one is not grabbed again (with `redownload`, Lidarr looks for
        another release of the album at once)."""
        if not self.enabled:
            return "Lidarr: no API key configured"
        if not ids:
            return "Lidarr: nothing to remove"
        self.h.call("DELETE", "/api/v1/queue/bulk", params={"removeFromClient": str(from_client).lower(),
                                                            "blocklist": str(blocklist).lower(), "skipRedownload": str(not redownload).lower()},
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
