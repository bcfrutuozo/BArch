"""What qBittorrent forgets, kept: its counters sampled into SQLite, and the questions asked of them.

qBittorrent only knows totals as they are now (and nothing of a torrent once it is deleted), so a trend
needs someone to write the numbers down. Every sample stores:

    samples   one row per sample: the client's all-time upload/download, speeds, how many torrents
    torrents  one row per torrent ever seen: what it is, its last counters, its lifetime totals
    traffic   what each torrent uploaded and downloaded per hour (the difference between two samples)

A torrent that was already there when tracking began keeps its counters of that moment as `base_*`
(traffic of an unknown date); everything after is dated. A torrent deleted from the client keeps its
rows, so the upload of a source over time stays true after the seed policy removes it. Hours older
than `keep_hours_days` are merged into one row per day. Only tracker hosts are stored, never an
announce URL (a private one carries the passkey).
"""
from __future__ import annotations

import sqlite3
import threading
from datetime import datetime, timedelta

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS samples(
    t INTEGER PRIMARY KEY, alltime_ul INTEGER, alltime_dl INTEGER, up_speed INTEGER, dl_speed INTEGER,
    torrents INTEGER, seeding INTEGER, downloading INTEGER, size INTEGER, free_space INTEGER, peers INTEGER);
CREATE TABLE IF NOT EXISTS torrents(
    hash TEXT PRIMARY KEY, name TEXT DEFAULT '', category TEXT DEFAULT '', tracker TEXT DEFAULT '',
    indexer TEXT DEFAULT '', private INTEGER, size INTEGER DEFAULT 0, added_on INTEGER DEFAULT 0,
    completion_on INTEGER DEFAULT 0, first_seen INTEGER, last_seen INTEGER, removed_at INTEGER,
    base_up INTEGER DEFAULT 0, base_down INTEGER DEFAULT 0,
    uploaded INTEGER DEFAULT 0, downloaded INTEGER DEFAULT 0,
    total_up INTEGER DEFAULT 0, total_down INTEGER DEFAULT 0,
    seeding_time INTEGER DEFAULT 0, state TEXT DEFAULT '', progress REAL DEFAULT 0);
CREATE TABLE IF NOT EXISTS traffic(
    hour INTEGER, hash TEXT, up INTEGER DEFAULT 0, down INTEGER DEFAULT 0,
    PRIMARY KEY(hour, hash)) WITHOUT ROWID;
"""

GROUPS = ("category", "indexer", "tracker")
SORTS = {"up": "r_up DESC", "down": "r_down DESC", "total_up": "total_up DESC", "total_down": "total_down DESC",
         "ratio": "ratio DESC", "ratio_asc": "ratio IS NULL, ratio ASC", "size": "size DESC",
         "added": "added_on DESC", "name": "name COLLATE NOCASE ASC", "seeding": "seeding_time DESC"}
SEEDING = ("uploading", "stalledUP", "forcedUP", "queuedUP", "checkingUP", "stoppedUP", "pausedUP")
DOWNLOADING = ("downloading", "stalledDL", "forcedDL", "metaDL", "forcedMetaDL", "queuedDL", "checkingDL", "allocating")
UNITS = {"h": 3600, "d": 86400, "w": 7 * 86400, "y": 365 * 86400}


def parse_range(s: str) -> int:
    """"24h", "7d", "12w", "1y" in seconds; 0 for "all" (everything since tracking began)."""
    s = (s or "").strip().lower()
    if s in ("", "all"):
        return 0
    if s[-1:] not in UNITS or not s[:-1].isdigit() or int(s[:-1]) <= 0:
        raise ValueError(f"range: {s!r} (24h, 7d, 12w, 1y, all)")
    return int(s[:-1]) * UNITS[s[-1]]


def bucket_kind(span_s: float) -> str:
    """The bucket that keeps a chart of this span readable (at most ~60 of them)."""
    if span_s <= 2 * 86400:
        return "hour"
    if span_s <= 62 * 86400:
        return "day"
    if span_s <= 420 * 86400:
        return "week"
    return "month"


def bucket_start(kind: str, t: float) -> int:
    """Start of the bucket holding t, in the container's local time (days begin at local midnight)."""
    d = datetime.fromtimestamp(t).replace(minute=0, second=0, microsecond=0)
    if kind != "hour":
        d = d.replace(hour=0)
    if kind == "week":
        d -= timedelta(days=d.weekday())
    elif kind == "month":
        d = d.replace(day=1)
    return int(d.timestamp())


def bucket_next(kind: str, start: int) -> int:
    d = datetime.fromtimestamp(start)
    if kind == "hour":
        return start + 3600
    if kind == "day":
        d += timedelta(days=1)
    elif kind == "week":
        d += timedelta(days=7)
    else:
        d = (d.replace(day=28) + timedelta(days=4)).replace(day=1)
    return int(d.replace(hour=0).timestamp())


def ratio(up, down):
    return round(up / down, 4) if down else None


class Store:
    def __init__(self, path: str):
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.lock = threading.RLock()
        with self.lock, self.db:
            self.db.executescript(SCHEMA)

    # ------------------------------------------------------------------------------------ writing
    def meta(self, key: str, default: str = "") -> str:
        with self.lock:
            r = self.db.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
        return r["value"] if r else default

    def set_meta(self, key: str, value) -> None:
        with self.lock, self.db:
            self.db.execute("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                            (key, str(value)))

    @property
    def start(self) -> int:
        return int(self.meta("start", "0"))

    def record(self, now: int, server: dict, torrents: dict[str, dict]) -> dict:
        """One sample: `server` is qBittorrent's server_state, `torrents` its torrents by hash.
        Returns what moved since the last one ({"up", "down", "new", "removed"})."""
        now = int(now)
        hour = now - now % 3600
        out = {"up": 0, "down": 0, "new": 0, "removed": 0}
        with self.lock, self.db:
            start = self.start
            first = not start
            if first:
                start = now
                self.db.execute("INSERT INTO meta(key, value) VALUES('start', ?)", (str(now),))
            known = {r["hash"]: r for r in self.db.execute("SELECT hash, uploaded, downloaded, removed_at FROM torrents")}
            for h, t in torrents.items():
                h = h.lower()
                up, down = int(t.get("uploaded") or 0), int(t.get("downloaded") or 0)
                private = t.get("private") if isinstance(t.get("private"), bool) else None
                facts = (t.get("name", ""), t.get("category", ""), int(t.get("total_size") or t.get("size") or 0),
                         int(t.get("added_on") or 0), max(int(t.get("completion_on") or 0), 0), now, up, down,
                         int(t.get("seeding_time") or 0), t.get("state", ""), float(t.get("progress") or 0))
                old = known.get(h)
                if old is None:
                    # there before tracking began: its counters are traffic of an unknown date
                    dated = not first and int(t.get("added_on") or 0) >= start
                    d_up, d_down = (up, down) if dated else (0, 0)
                    self.db.execute(
                        "INSERT INTO torrents(name, category, size, added_on, completion_on, last_seen, uploaded, downloaded,"
                        " seeding_time, state, progress, hash, private, first_seen, base_up, base_down, total_up, total_down)"
                        " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                        facts + (h, private, now, up - d_up, down - d_down, up, down))
                    out["new"] += 1
                else:
                    # a counter that went back is a torrent added again: it starts from zero
                    d_up = up - old["uploaded"] if up >= old["uploaded"] else up
                    d_down = down - old["downloaded"] if down >= old["downloaded"] else down
                    self.db.execute(
                        "UPDATE torrents SET name = ?, category = ?, size = ?, added_on = ?, completion_on = ?, last_seen = ?,"
                        " uploaded = ?, downloaded = ?, seeding_time = ?, state = ?, progress = ?, removed_at = NULL,"
                        " private = COALESCE(?, private), total_up = total_up + ?, total_down = total_down + ? WHERE hash = ?",
                        facts + (private, d_up, d_down, h))
                if d_up or d_down:
                    self.db.execute(
                        "INSERT INTO traffic(hour, hash, up, down) VALUES(?,?,?,?) ON CONFLICT(hour, hash)"
                        " DO UPDATE SET up = up + excluded.up, down = down + excluded.down", (hour, h, d_up, d_down))
                    out["up"] += d_up
                    out["down"] += d_down
            live = {h.lower() for h in torrents}
            gone = [h for h, r in known.items() if r["removed_at"] is None and h not in live]
            self.db.executemany("UPDATE torrents SET removed_at = ? WHERE hash = ?", [(now, h) for h in gone])
            out["removed"] = len(gone)
            states = [t.get("state", "") for t in torrents.values()]
            self.db.execute(
                "INSERT OR REPLACE INTO samples(t, alltime_ul, alltime_dl, up_speed, dl_speed, torrents, seeding, downloading,"
                " size, free_space, peers) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                (now, int(server.get("alltime_ul") or 0), int(server.get("alltime_dl") or 0),
                 int(server.get("up_info_speed") or 0), int(server.get("dl_info_speed") or 0), len(torrents),
                 sum(s in SEEDING for s in states), sum(s in DOWNLOADING for s in states),
                 sum(int(t.get("total_size") or t.get("size") or 0) for t in torrents.values()),
                 int(server.get("free_space_on_disk") or 0), int(server.get("total_peer_connections") or 0)))
        return out

    def without(self, column: str, live: bool = True) -> list[str]:
        """Hashes whose tracker (or indexer) is still unknown."""
        assert column in ("tracker", "indexer")
        with self.lock:
            return [r["hash"] for r in self.db.execute(
                f"SELECT hash FROM torrents WHERE {column} = ''" + (" AND removed_at IS NULL" if live else ""))]

    def unlabeled(self) -> list[dict]:
        """The torrents without an indexer, with what a grab can be matched on."""
        with self.lock:
            return [dict(r) for r in self.db.execute("SELECT hash, name, added_on FROM torrents WHERE indexer = ''")]

    def label(self, column: str, values: dict[str, str]) -> int:
        """Set the tracker (or indexer) of these hashes where none is known yet."""
        assert column in ("tracker", "indexer")
        with self.lock, self.db:
            cur = self.db.executemany(f"UPDATE torrents SET {column} = ? WHERE hash = ? AND {column} = ''",
                                      [(v, h.lower()) for h, v in values.items() if v])
            return cur.rowcount

    def compact(self, now: float, keep_hours_days: int = 60) -> int:
        """Hours older than `keep_hours_days` become one row per (local) day and torrent."""
        cutoff = bucket_start("day", now - keep_hours_days * 86400)
        n = 0
        with self.lock, self.db:
            for (hour,) in self.db.execute("SELECT DISTINCT hour FROM traffic WHERE hour < ?", (cutoff,)).fetchall():
                day = bucket_start("day", hour)
                if day == hour:
                    continue
                self.db.execute(
                    "INSERT INTO traffic(hour, hash, up, down) SELECT ?, hash, up, down FROM traffic WHERE hour = ?"
                    " ON CONFLICT(hour, hash) DO UPDATE SET up = up + excluded.up, down = down + excluded.down", (day, hour))
                n += self.db.execute("DELETE FROM traffic WHERE hour = ?", (hour,)).rowcount
        return n

    # ------------------------------------------------------------------------------------ reading
    def since(self, now: float, span_s: int) -> int:
        """Where the data of a range begins: `span_s` ago, never before tracking began (0 = all of it)."""
        start = self.start or int(now)
        return max(start, int(now) - span_s) if span_s else start

    def origin(self, now: float, span_s: int) -> int:
        """Where the axis of a range begins: `span_s` ago even when tracking is younger than that, so a
        chart shows the whole period asked for (0 = since tracking began)."""
        return int(now) - span_s if span_s else (self.start or int(now))

    @staticmethod
    def _filter(by: str = "", key: str = "") -> tuple[str, tuple]:
        if not by:
            return "1", ()
        if by == "hash":
            return "x.hash = ?", (key.lower(),)
        if by not in GROUPS:
            raise ValueError(f"by: {by!r} ({', '.join(GROUPS)})")
        return f"x.{by} = ?", (key,)

    def status(self) -> dict:
        with self.lock:
            s = self.db.execute("SELECT COUNT(*) n, MIN(t) first, MAX(t) last FROM samples").fetchone()
            t = self.db.execute("SELECT COUNT(*) n, SUM(removed_at IS NULL) live FROM torrents").fetchone()
            rows = self.db.execute("SELECT COUNT(*) n FROM traffic").fetchone()
        return {"samples": s["n"], "first": s["first"] or 0, "last": s["last"] or 0, "torrents": t["n"],
                "live": t["live"] or 0, "traffic_rows": rows["n"]}

    def overview(self, now: float, span_s: int, goal: float = 0) -> dict:
        since = self.since(now, span_s)
        with self.lock:
            last = self.db.execute("SELECT * FROM samples ORDER BY t DESC LIMIT 1").fetchone()
            ref = self.db.execute("SELECT * FROM samples WHERE t >= ? ORDER BY t LIMIT 1", (since,)).fetchone()
            windows = {}
            for name, start in (("range", since), ("day", int(now) - 86400), ("week", int(now) - 7 * 86400),
                                ("month", int(now) - 30 * 86400)):
                r = self.db.execute("SELECT COALESCE(SUM(up), 0) up, COALESCE(SUM(down), 0) down FROM traffic WHERE hour >= ?",
                                    (start - start % 3600,)).fetchone()
                windows[name] = {"up": r["up"], "down": r["down"], "ratio": ratio(r["up"], r["down"])}
            live = self.db.execute(
                "SELECT COUNT(*) n, COALESCE(SUM(size), 0) size, COALESCE(SUM(total_up), 0) up, COALESCE(SUM(total_down), 0) down,"
                " SUM(progress >= 1) done, SUM(progress >= 1 AND total_down > 0 AND total_up < total_down) below_1,"
                " SUM(progress >= 1 AND total_down > 0 AND total_up >= total_down * ?) at_goal"
                " FROM torrents WHERE removed_at IS NULL", (goal or 1e18,)).fetchone()
            tracked = self.db.execute("SELECT COUNT(*) n, SUM(removed_at IS NOT NULL) removed, COALESCE(SUM(total_up), 0) up,"
                                      " COALESCE(SUM(total_down), 0) down FROM torrents").fetchone()
        now_ = dict(last) if last else {}
        if last:
            now_["ratio"] = ratio(last["alltime_ul"], last["alltime_dl"])
        delta = None
        if last and ref and last["t"] > ref["t"]:
            # the client's own all-time ratio at the start of the range, to say how far it moved
            delta = {"t": ref["t"], "ratio": ratio(ref["alltime_ul"], ref["alltime_dl"]),
                     "up": max(0, last["alltime_ul"] - ref["alltime_ul"]), "down": max(0, last["alltime_dl"] - ref["alltime_dl"])}
        return {"start": self.start, "since": since, "now": now_, "then": delta, **windows, "goal": goal,
                "live": {"torrents": live["n"], "size": live["size"], "up": live["up"], "down": live["down"],
                         "ratio": ratio(live["up"], live["down"]), "done": live["done"] or 0,
                         "below_1": live["below_1"] or 0, "at_goal": (live["at_goal"] or 0) if goal else None},
                "tracked": {"torrents": tracked["n"], "removed": tracked["removed"] or 0, "up": tracked["up"],
                            "down": tracked["down"], "ratio": ratio(tracked["up"], tracked["down"])}}

    def samples(self, now: float, span_s: int, points: int = 240) -> list[dict]:
        """The client over time, averaged down to about `points`: ratio, average speeds (from the
        all-time counters, so nothing between two samples is lost), torrents, size, free space."""
        since = self.since(now, span_s)        # the points are spent on the part of the range that has data
        step = max(1, int((now - since) / points))
        with self.lock:
            rows = self.db.execute(
                "SELECT MAX(t) t, MAX(alltime_ul) ul, MAX(alltime_dl) dl, AVG(up_speed) up_speed, AVG(dl_speed) dl_speed,"
                " AVG(torrents) torrents, AVG(seeding) seeding, AVG(downloading) downloading, AVG(size) size,"
                " AVG(free_space) free_space, AVG(peers) peers FROM samples WHERE t >= ? GROUP BY (t - ?) / ? ORDER BY 1",
                (since, since, step)).fetchall()
        out, prev = [], None
        for r in rows:
            up, down = r["up_speed"], r["dl_speed"]
            if prev is not None and r["t"] > prev["t"] and r["ul"] >= prev["ul"] and r["dl"] >= prev["dl"]:
                dt = r["t"] - prev["t"]
                up, down = (r["ul"] - prev["ul"]) / dt, (r["dl"] - prev["dl"]) / dt
            out.append({"t": r["t"], "ratio": ratio(r["ul"], r["dl"]), "alltime_ul": r["ul"], "alltime_dl": r["dl"],
                        "up_speed": round(up), "dl_speed": round(down), "torrents": round(r["torrents"]),
                        "seeding": round(r["seeding"]), "downloading": round(r["downloading"]), "size": round(r["size"]),
                        "free_space": round(r["free_space"]), "peers": round(r["peers"])})
            prev = r
        return out

    def history(self, now: float, span_s: int, by: str = "", key: str = "", kind: str = "") -> dict:
        """Upload and download per bucket (hour, day, week or month by the span) of everything, one
        category/indexer/tracker or one torrent (by="hash"), with the lifetime ratio at each bucket's end.
        The buckets cover the whole span; the ones before tracking began are empty, their ratio unknown."""
        where, params = self._filter(by, key)
        since = self.origin(now, span_s)
        start = self.start
        kind = kind or bucket_kind(now - since)
        first = bucket_start(kind, since)
        with self.lock:
            base = self.db.execute(f"SELECT COALESCE(SUM(base_up), 0) up, COALESCE(SUM(base_down), 0) down FROM torrents x WHERE {where}",
                                   params).fetchone()
            rows = self.db.execute(
                f"SELECT t.hour, SUM(t.up) up, SUM(t.down) down FROM traffic t JOIN torrents x USING(hash) WHERE {where}"
                " GROUP BY t.hour ORDER BY t.hour", params).fetchall()
        tot_up, tot_down = base["up"], base["down"]
        per: dict[int, list[int]] = {}
        for r in rows:
            if r["hour"] < first:
                tot_up += r["up"]
                tot_down += r["down"]
            else:
                b = per.setdefault(bucket_start(kind, r["hour"]), [0, 0])
                b[0] += r["up"]
                b[1] += r["down"]
        buckets, t = [], first
        while t <= now:
            up, down = per.get(t, (0, 0))
            tot_up += up
            tot_down += down
            nxt = bucket_next(kind, t)
            buckets.append({"t": t, "up": up, "down": down, "total_up": tot_up, "total_down": tot_down,
                            "ratio": ratio(tot_up, tot_down) if start and nxt > start else None})
            t = nxt
        return {"kind": kind, "from": since, "to": int(now), "start": start, "buckets": buckets,
                "up": sum(b["up"] for b in buckets), "down": sum(b["down"] for b in buckets)}

    def groups(self, now: float, span_s: int, by: str) -> list[dict]:
        """Every category, indexer or tracker: its torrents, lifetime totals and what moved in the range."""
        if by not in GROUPS:
            raise ValueError(f"by: {by!r} ({', '.join(GROUPS)})")
        since = self.since(now, span_s)
        with self.lock:
            rows = self.db.execute(
                f"SELECT x.{by} key, COUNT(*) torrents, SUM(x.removed_at IS NULL) live,"
                " SUM(CASE WHEN x.removed_at IS NULL THEN x.size ELSE 0 END) size, SUM(x.total_up) total_up,"
                " SUM(x.total_down) total_down, COALESCE(SUM(r.up), 0) up, COALESCE(SUM(r.down), 0) down,"
                " SUM(x.removed_at IS NULL AND x.progress >= 1 AND x.total_down > 0 AND x.total_up < x.total_down) below_1"
                " FROM torrents x LEFT JOIN (SELECT hash, SUM(up) up, SUM(down) down FROM traffic WHERE hour >= ? GROUP BY hash) r"
                f" USING(hash) GROUP BY x.{by} ORDER BY up DESC, total_up DESC", (since - since % 3600,)).fetchall()
        return [{**dict(r), "live": r["live"] or 0, "below_1": r["below_1"] or 0,
                 "ratio": ratio(r["total_up"], r["total_down"]), "range_ratio": ratio(r["up"], r["down"])} for r in rows]

    def torrents(self, now: float, span_s: int, by: str = "", key: str = "", state: str = "all", sort: str = "up",
                 query: str = "", limit: int = 300) -> list[dict]:
        where, params = self._filter(by, key)
        if state == "live":
            where += " AND x.removed_at IS NULL"
        elif state == "removed":
            where += " AND x.removed_at IS NOT NULL"
        if query:
            where += " AND x.name LIKE ? ESCAPE '\\'"
            params += ("%" + query.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%",)
        since = self.since(now, span_s)
        with self.lock:
            rows = self.db.execute(
                "SELECT x.*, COALESCE(r.up, 0) r_up, COALESCE(r.down, 0) r_down,"
                " CASE WHEN x.total_down > 0 THEN CAST(x.total_up AS REAL) / x.total_down END ratio"
                " FROM torrents x LEFT JOIN (SELECT hash, SUM(up) up, SUM(down) down FROM traffic WHERE hour >= ? GROUP BY hash) r"
                f" USING(hash) WHERE {where} ORDER BY {SORTS.get(sort, SORTS['up'])}, total_up DESC LIMIT ?",
                (since - since % 3600,) + params + (max(1, min(int(limit), 2000)),)).fetchall()
        return [self._torrent(r) for r in rows]

    @staticmethod
    def _torrent(r) -> dict:
        d = dict(r)
        d["up"], d["down"] = d.pop("r_up", 0), d.pop("r_down", 0)
        d["ratio"] = ratio(d["total_up"], d["total_down"])
        d["private"] = None if d["private"] is None else bool(d["private"])
        for k in ("uploaded", "downloaded"):
            d.pop(k, None)
        return d

    def torrent(self, h: str) -> dict | None:
        with self.lock:
            r = self.db.execute("SELECT x.*, 0 r_up, 0 r_down FROM torrents x WHERE hash = ?", (h.lower(),)).fetchone()
        return self._torrent(r) if r else None
