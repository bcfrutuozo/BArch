"""Seed history: what every torrent the pipeline removes from qBittorrent gave back, kept before it goes.

qBittorrent forgets a torrent's numbers once it is deleted, and the pipeline deletes every download
once its albums are in the library (and the hourly check removes stalled ones), so without this the
only record of what was seeded would be the trackers' own profiles. One JSON line per torrent in
<jobs>/seed-history.jsonl: name, size, downloaded, uploaded, ratio, seeding and active time, when it
was added and finished, the swarm at that moment, the tracker hosts (never the announce URL: a
private tracker's carries the passkey) and why it went (imported, rejected, stalled).
"""
from __future__ import annotations

import json
import time
import urllib.parse
from pathlib import Path


def tracker_host(url: str) -> str:
    """The host of an announce URL, nothing else (the path and query of a private one hold the passkey)."""
    if not url or url.startswith("**"):           # "** [DHT] **", "** [PeX] **", "** [LSD] **"
        return ""
    try:
        return (urllib.parse.urlsplit(url).hostname or "").lower()
    except ValueError:
        return ""


def snapshot(t: dict, trackers: list[dict] | None = None) -> dict:
    """The numbers of one torrent of /torrents/info that matter for seeding, as kept in the history."""
    hosts = sorted({h for h in (tracker_host(x.get("url", "")) for x in trackers or []) if h})
    if not hosts and tracker_host(t.get("tracker", "")):
        hosts = [tracker_host(t["tracker"])]
    size = int(t.get("total_size") or t.get("size") or 0)
    down = int(t.get("downloaded") or 0)
    up = int(t.get("uploaded") or 0)
    return {"hash": (t.get("hash") or "").lower(), "name": t.get("name", ""), "category": t.get("category", ""),
            "size": size, "downloaded": down, "uploaded": up,
            "ratio": round(up / down, 3) if down else round(float(t.get("ratio") or 0), 3),
            "seeding_time": int(t.get("seeding_time") or 0), "time_active": int(t.get("time_active") or 0),
            "added_on": int(t.get("added_on") or 0), "completion_on": max(int(t.get("completion_on") or 0), 0),
            "progress": round(float(t.get("progress") or 0) * 100, 1), "state": t.get("state", ""),
            "swarm_seeds": int(t.get("num_complete") or 0), "swarm_leechers": int(t.get("num_incomplete") or 0),
            "private": t.get("private") if isinstance(t.get("private"), bool) else None,
            "trackers": hosts}


class SeedLog:
    def __init__(self, root: Path):
        self.file = root / "seed-history.jsonl"

    def record(self, qbit, h: str, reason: str, album: str = "") -> dict | None:
        """Read the torrent from qBittorrent and append it to the history; never raises (a missing
        record must not keep a download from being cleaned up), returns what was written."""
        try:
            t = qbit.torrent(h)
            if not t:
                return None
            try:
                trackers = qbit.trackers(h)
            except Exception:  # noqa: BLE001
                trackers = []
            try:
                props = qbit.properties(h) or {}
                if isinstance(props.get("is_private"), bool):
                    t = {**t, "private": props["is_private"]}
            except Exception:  # noqa: BLE001
                pass
            row = {"removed": int(time.time()), "reason": reason, "album": album, **snapshot(t, trackers)}
            with self.file.open("a") as f:
                f.write(json.dumps(row, ensure_ascii=False) + "\n")
            return row
        except Exception as e:  # noqa: BLE001
            print(f"[seeds] {h}: not recorded: {e}", flush=True)
            return None

    def rows(self, days: float = 0) -> list[dict]:
        since = time.time() - days * 86400 if days else 0
        out = []
        try:
            with self.file.open() as f:
                for line in f:
                    try:
                        r = json.loads(line)
                    except ValueError:
                        continue
                    if r.get("removed", 0) >= since:
                        out.append(r)
        except OSError:
            pass
        return out

    @staticmethod
    def totals(rows: list[dict]) -> dict:
        down = sum(r.get("downloaded", 0) for r in rows)
        up = sum(r.get("uploaded", 0) for r in rows)
        seed = [r.get("seeding_time", 0) for r in rows]
        return {"torrents": len(rows), "downloaded": down, "uploaded": up,
                "ratio": round(up / down, 3) if down else 0.0,
                "seeding_time": sum(seed), "avg_seeding_time": int(sum(seed) / len(seed)) if seed else 0,
                "below_1": sum(1 for r in rows if r.get("downloaded") and r.get("uploaded", 0) < r["downloaded"])}

    def summary(self, days: float = 0, live: list[dict] | None = None) -> dict:
        """The history (all of it, or the last `days`) in total and per tracker, the most recent rows,
        and, when given, the torrents still in the client with the same numbers."""
        rows = self.rows(days)
        per: dict[str, list[dict]] = {}
        for r in rows:
            for host in r.get("trackers") or ["(no tracker)"]:
                per.setdefault(host, []).append(r)
        out = {"file": str(self.file), "days": days, "total": self.totals(rows),
               "trackers": sorted(({"tracker": k, **self.totals(v)} for k, v in per.items()),
                                  key=lambda x: -x["uploaded"]),
               "recent": sorted(rows, key=lambda r: -r.get("removed", 0))[:50]}
        if live is not None:
            snaps = [snapshot(t) for t in live]
            out["live"] = {"total": self.totals(snaps), "torrents": sorted(snaps, key=lambda r: -r["uploaded"])}
        return out
