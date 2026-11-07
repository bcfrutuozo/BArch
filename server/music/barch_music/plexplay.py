"""What the desktop player plays, told to Plex as if a Plex client were playing it, so Plex's play counts,
"recently played", Last.fm scrobbling and Tautulli's history all see it (the files themselves come from the
share, Plex never streams them).

    POST /api/player/timeline  {"folder": "Artist/Album", "file": "1.03 - X.flac", "state": "playing|paused|stopped",
                                "time": <s>, "duration": <s>, "session": "<id per track start>", "device": "<hostname>"}

The track's Plex ratingKey is found through the album (Plex.album_key by the files' folder, then the album's
children matched by file path) and cached in plex-keys.json; the timeline goes to `/:/timeline` with a stable
client identifier per desktop (`barch-player@<device>`), product "BArch Player", so Tautulli shows one player.
Plex counts a play by itself from the timeline (a track reported near its end); the desktop keeps its own counts
too (state.json). Nothing here is on the pipeline's critical path: every error is kept in `last` and answered,
never raised into a job."""
from __future__ import annotations

import json
import threading
import time
from pathlib import Path

PRODUCT = "BArch Player"
VERSION = "1.0"


def match_children(children: list[dict], want_prefix: str) -> dict[str, dict]:
    """{file name: {"key": ratingKey, "duration": ms}} for the tracks whose file lives under want_prefix
    ("/data/music/Artist/Album/")."""
    out = {}
    for tr in children or []:
        for m in tr.get("Media") or []:
            for pt in m.get("Part") or []:
                f = pt.get("file") or ""
                if f.startswith(want_prefix):
                    out[f[len(want_prefix):]] = {"key": str(tr.get("ratingKey", "")), "duration": int(tr.get("duration") or m.get("duration") or 0)}
    return out


class PlexPlay:
    def __init__(self, plex, root: Path):
        self.plex = plex
        self.file = root / "plex-keys.json"
        self.lock = threading.Lock()
        self.last: dict = {}                      # the last report and what became of it
        self.sessions: dict[str, dict] = {}       # session id -> what is playing (for /api/player/status)
        try:
            self.keys: dict[str, dict[str, dict]] = json.loads(self.file.read_text())
        except (OSError, ValueError):
            self.keys = {}

    def save(self) -> None:
        tmp = self.file.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.keys))
        tmp.replace(self.file)

    def album_tracks(self, folder: str, refresh: bool = False) -> dict[str, dict]:
        with self.lock:
            if not refresh and folder in self.keys:
                return self.keys[folder]
        key = self.plex.album_key(folder)
        found = {}
        if key:
            t = self.plex.h.call("GET", f"/library/metadata/{key}/children") or {}
            found = match_children((t.get("MediaContainer") or {}).get("Metadata", []), f"{self.plex.path_prefix}/{folder}/")
        with self.lock:
            self.keys[folder] = found
            self.save()
        return found

    def resolve(self, folder: str, name: str) -> dict | None:
        tracks = self.album_tracks(folder)
        if name not in tracks:                    # the album was rescanned, a file renamed: look once more
            tracks = self.album_tracks(folder, refresh=True)
        return tracks.get(name)

    def report(self, body: dict) -> dict:
        folder, name = str(body.get("folder") or ""), str(body.get("file") or "")
        state = str(body.get("state") or "playing")
        if state not in ("playing", "paused", "stopped", "buffering"):
            return {"ok": False, "error": "state must be playing, paused or stopped"}
        if not self.plex.enabled:
            return {"ok": False, "error": "Plex: no token configured"}
        if not folder or not name:
            return {"ok": False, "error": "folder and file are required"}
        device = str(body.get("device") or "desktop")
        session = str(body.get("session") or f"{device}-{folder}/{name}")
        try:
            tr = self.resolve(folder, name)
            if not tr:
                self.last = {"t": time.time(), "folder": folder, "file": name, "state": state, "error": "not in Plex (not scanned yet?)"}
                return {"ok": False, "error": "track not found in Plex", "folder": folder, "file": name}
            duration = int(float(body.get("duration") or 0) * 1000) or tr["duration"]
            t_ms = max(0, int(float(body.get("time") or 0) * 1000))
            self.plex.timeline(tr["key"], state, t_ms, duration, session, device)
        except Exception as e:  # noqa: BLE001
            self.last = {"t": time.time(), "folder": folder, "file": name, "state": state, "error": f"{type(e).__name__}: {e}"}
            return {"ok": False, "error": f"Plex: {e}"}
        self.last = {"t": time.time(), "folder": folder, "file": name, "state": state, "key": tr["key"], "time": t_ms, "duration": duration}
        if state == "stopped":
            self.sessions.pop(session, None)
        else:
            self.sessions[session] = {"folder": folder, "file": name, "state": state, "time": t_ms, "duration": duration, "key": tr["key"], "device": device, "t": time.time()}
        return {"ok": True, "key": tr["key"], "state": state}

    def status(self) -> dict:
        return {"enabled": self.plex.enabled, "url": self.plex.h.base, "last": self.last, "sessions": list(self.sessions.values()),
                "albums_cached": len(self.keys)}
