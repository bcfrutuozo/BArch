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
import shutil
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


SEED_DEFAULTS = {"ratio": 3.0, "min_hours": 72, "max_days": 90, "min_free_gb": 100, "path": "/data",
                 "categories": ["radarr", "sonarr", "tv-sonarr", "barch-dub"]}


class SeedKeeper:
    """Torrents whose albums are all in the library keep seeding instead of going at once: tagged
    `pipeline:seeding` in qBittorrent and listed in <jobs>/seeding.json, and the hourly check deletes
    one (recording it in the history first) when it reached `seed.ratio` after at least `min_hours` of
    seeding, or `max_days` after it finished whatever its ratio. While the downloads disk has less than
    `min_free_gb` free, the ones past `min_hours` go first (oldest first), then the others. Lidarr does
    not follow a finished torrent, so it stays in its category without being imported again.
    The finished torrents of `categories` (Radarr's and Sonarr's, the video pipeline's PT-BR donors) are
    adopted by the same check: Radarr and Sonarr import in minutes and the donor is muxed in hours, long
    before `min_hours`, and they only remove a torrent qBittorrent stopped (it never stops one here: no
    share limits), so this is the one place a finished torrent leaves the client, through the history.
    `seed.ratio: 0` in config.json deletes at once, as before."""

    TAG = "pipeline:seeding"

    def __init__(self, root: Path, cfg: dict, qbit, log: SeedLog):
        self.file = root / "seeding.json"
        self.cfg = {**SEED_DEFAULTS, **(cfg.get("seed") or {})}
        self.qbit, self.log = qbit, log
        self.last = 0.0

    @property
    def enabled(self) -> bool:
        return float(self.cfg["ratio"]) > 0

    def _load(self) -> dict:
        try:
            return json.loads(self.file.read_text())
        except (OSError, ValueError):
            return {}

    def _save(self, d: dict) -> None:
        self.file.write_text(json.dumps(d, ensure_ascii=False, indent=1))

    def keep(self, h: str, reason: str, album: str) -> None:
        d = self._load()
        d[h.lower()] = {"reason": reason, "album": album, "since": int(time.time())}
        self._save(d)
        self.qbit.tag(h, add=self.TAG, remove="pipeline:review")

    def kept(self) -> set[str]:
        return set(self._load())

    def adopt_categories(self) -> list[str]:
        """Finished torrents of the other apps' categories, not seeding for the policy yet."""
        cats = [c for c in self.cfg.get("categories") or [] if c]
        if not cats:
            return []
        kept, out = self.kept(), []
        for c in cats:
            for t in self.qbit.completed([c]):
                h = t["hash"].lower()
                if h not in kept and float(t.get("progress") or 0) >= 1:
                    self.keep(h, c, t.get("name", ""))
                    kept.add(h)
                    out.append(f"{t.get('name', h)} ({c})")
        return out

    def remove(self, h: str, reason: str, album: str) -> dict | None:
        row = self.log.record(self.qbit, h, reason, album)
        self.qbit.delete(h, files=True)
        return row

    def verdict(self, t: dict, now: float) -> str:
        """Why this torrent may go now ("" = keep seeding)."""
        ratio = float(t.get("ratio") or 0)
        hours = int(t.get("seeding_time") or 0) / 3600
        done_at = int(t.get("completion_on") or 0)
        if ratio >= float(self.cfg["ratio"]) and hours >= float(self.cfg["min_hours"]):
            return f"ratio {ratio:.2f} after {hours:.0f} h"
        if done_at > 0 and now - done_at >= float(self.cfg["max_days"]) * 86400:
            return f"{self.cfg['max_days']} days since it finished (ratio {ratio:.2f})"
        return ""

    def free_gb(self) -> float:
        try:
            return shutil.disk_usage(self.cfg["path"]).free / 1e9
        except OSError:
            return float("inf")

    def status(self) -> list[dict]:
        """The torrents seeding for the pipeline with how far each is from going."""
        d = self._load()
        if not d:
            return []
        now = time.time()
        out = []
        for t in self.qbit.info(list(d)):
            s = snapshot(t)
            meta = d.get(s["hash"], {})
            left = max(0.0, float(self.cfg["max_days"]) - (now - s["completion_on"]) / 86400) if s["completion_on"] else None
            out.append({**s, "reason": meta.get("reason", ""), "album": meta.get("album", ""), "since": meta.get("since", 0),
                        "goal": float(self.cfg["ratio"]), "days_left": round(left, 1) if left is not None else None,
                        "would_go": self.verdict(t, now)})
        return sorted(out, key=lambda r: r["ratio"])

    def check(self, force: bool = False) -> list[str]:
        """The hourly pass: delete what reached its goal or its time, then what the disk needs."""
        if not force and time.time() - self.last < 3600:
            return []
        self.last = time.time()
        d = self._load()
        if not d:
            return []
        now, out = time.time(), []
        live = {t["hash"].lower(): t for t in self.qbit.info(list(d))}
        for h in [h for h in d if h not in live]:          # deleted by hand in qBittorrent
            d.pop(h)
        keep = []
        for h, t in live.items():
            why = self.verdict(t, now)
            if why:
                row = self.remove(h, d[h].get("reason", "imported"), d[h].get("album", ""))
                out.append(f"{t.get('name', h)}: {why}" + (f", {row['uploaded'] / 1e9:.2f} GB up" if row else ""))
                d.pop(h)
            else:
                keep.append(t)
        free, need = self.free_gb(), float(self.cfg["min_free_gb"])
        if free < need and keep:
            past = float(self.cfg["min_hours"]) * 3600
            keep.sort(key=lambda t: (int(t.get("seeding_time") or 0) < past, int(t.get("completion_on") or 0)))
            for t in keep:
                if free >= need:
                    break
                h = t["hash"].lower()
                self.remove(h, d[h].get("reason", "imported"), d[h].get("album", ""))
                free += int(t.get("total_size") or t.get("size") or 0) / 1e9
                out.append(f"{t.get('name', h)}: disk below {need:.0f} GB free (ratio {float(t.get('ratio') or 0):.2f})")
                d.pop(h)
        self._save(d)
        return out
