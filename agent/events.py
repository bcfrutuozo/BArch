#!/usr/bin/env python3
"""barch-events: the desktop's event bus, metrics history and reactive rules.

One daemon (barch-events.service) does three things:
  * samples the machine every `interval_s` (CPU/GPU temperatures and load, RAM, disks, VPN and
    network latency, AirPods battery, health issues) into ~/.local/state/barch/metrics.db;
  * turns what changes into events: Hyprland's socket2 (windows opened/closed, monitors,
    fullscreen), VPN and Anonymous Mode up/down, network down/up, AirPods connected, session
    locked/unlocked, a new failure log, a boot, what Claude cost (agent tasks, voice), an album of
    the music pipeline landing in the review queue, the NAS (agent/nas.py, Unraid's API: down,
    array, disks, containers, Unraid's own warnings, certificates about to expire) and the two
    pfSense firewalls (agent/pfsense.py, their REST API: down, reboot, gateway, interface, IPsec,
    DNSBL, a device never seen before taking a lease);
  * runs the rules of agent/rules.json: "when <event or metric threshold>, do <commands>", with
    notification, spoken sentence, cooldown and an optional "ask first" button.

    events.py                       the daemon (what the service runs)
    events.py status|events|rules|test|fire|enable|disable|metrics|series|summary   the CLI (JSON);
                                    `barch rules|events|metrics` wrap them
"""
from __future__ import annotations

import glob
import json
import os
import re
import shlex
import signal
import socket
import sqlite3
import subprocess
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

HOME = Path.home()
HERE = Path(__file__).resolve().parent                     # agent/
RULES_FILE = HERE / "rules.json"
STATE_DIR = Path(os.environ.get("XDG_STATE_HOME", HOME / ".local/state")) / "barch"
EVENTS_DIR = STATE_DIR / "events"
DB_FILE = STATE_DIR / "metrics.db"
STATE_FILE = EVENTS_DIR / "state.json"
COST_LOG = STATE_DIR / "claude-cost.log"
FAILURES = STATE_DIR / "failures"
REPORTS = STATE_DIR / "reports"
BARCH = HOME / ".local/bin/barch"

sys.path.insert(0, str(HERE))        # python -I (the service, barch) leaves the script's folder out
import nas  # noqa: E402  agent/nas.py
import pfsense  # noqa: E402  agent/pfsense.py
RUNTIME = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"))

DEFAULTS = {
    "interval_s": 30,
    "health_every_s": 300,
    "disks": ["/", "/home"],
    "ping": "1.1.1.1",
    "raw_days": 7,          # raw samples kept this long; hourly averages for a year
    "events_days": 180,
    "nas_every_s": 300,          # the NAS (agent/nas.py); its certificates every nas_certs_every_s
    "nas_certs_every_s": 21600,
    "nas_grace_s": 900,          # a container down for less than this is a restart, not a problem
    "cert_warn_days": 10,
    "fw_every_s": 300,           # the firewalls (agent/pfsense.py)
    "fw_auth_backoff_s": 3600,   # a refused key is not tried again for this long (the API bans a burst)
}


def log(*a):
    print(datetime.now().strftime("%H:%M:%S"), *a, file=sys.stderr, flush=True)


def run(cmd, timeout=10, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, **kw)


def duration(s, default=60) -> int:
    """'30s', '5m', '2h', '1d' → seconds."""
    if s is None:
        return default
    if isinstance(s, (int, float)):
        return int(s)
    m = re.fullmatch(r"\s*(\d+)\s*([smhd]?)\s*", str(s))
    if not m:
        return default
    return int(m.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}[m.group(2)]


def since_arg(s: str) -> int:
    """'24h' / '7d' / an epoch → epoch seconds."""
    if re.fullmatch(r"\d{9,}", s):
        return int(s)
    return int(time.time()) - duration(s, 86400)


def fmt_value(v) -> str:
    if v is None:
        return ""
    if isinstance(v, float):
        return str(int(v)) if v.is_integer() else f"{v:.1f}"
    return str(v)


# ---------------------------------------------------------------- storage

class Store:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(str(path), check_same_thread=False, timeout=10)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=NORMAL")
        self.lock = threading.Lock()
        with self.lock:
            self.db.executescript("""
                CREATE TABLE IF NOT EXISTS samples (ts INTEGER NOT NULL, metric TEXT NOT NULL, value REAL NOT NULL);
                CREATE INDEX IF NOT EXISTS samples_metric_ts ON samples (metric, ts);
                CREATE TABLE IF NOT EXISTS hourly (ts INTEGER NOT NULL, metric TEXT NOT NULL, avg REAL, min REAL, max REAL, n INTEGER,
                                                   PRIMARY KEY (metric, ts));
                CREATE TABLE IF NOT EXISTS events (ts INTEGER NOT NULL, event TEXT NOT NULL, data TEXT);
                CREATE INDEX IF NOT EXISTS events_ts ON events (ts);
                CREATE INDEX IF NOT EXISTS events_event_ts ON events (event, ts);
            """)

    def sample(self, metric: str, value: float, ts: int | None = None):
        with self.lock:
            self.db.execute("INSERT INTO samples VALUES (?, ?, ?)", (ts or int(time.time()), metric, float(value)))

    def samples(self, rows: list[tuple[str, float]], ts: int | None = None):
        ts = ts or int(time.time())
        with self.lock:
            self.db.executemany("INSERT INTO samples VALUES (?, ?, ?)", [(ts, m, float(v)) for m, v in rows])
            self.db.commit()

    def event(self, name: str, data: dict | None = None, ts: int | None = None):
        with self.lock:
            self.db.execute("INSERT INTO events VALUES (?, ?, ?)",
                            (ts or int(time.time()), name, json.dumps(data or {}, ensure_ascii=False)))
            self.db.commit()

    def prune(self, raw_days: int, events_days: int):
        """Fold raw samples older than raw_days into hourly averages, drop old events."""
        now = int(time.time())
        cutoff = now - raw_days * 86400
        with self.lock:
            self.db.execute("""
                INSERT OR REPLACE INTO hourly
                SELECT (ts / 3600) * 3600, metric, avg(value), min(value), max(value), count(*)
                FROM samples WHERE ts < ? GROUP BY metric, ts / 3600""", (cutoff,))
            self.db.execute("DELETE FROM samples WHERE ts < ?", (cutoff,))
            self.db.execute("DELETE FROM hourly WHERE ts < ?", (now - 400 * 86400,))
            self.db.execute("DELETE FROM events WHERE ts < ? AND event NOT IN ('boot')", (now - events_days * 86400,))
            self.db.commit()
            self.db.execute("PRAGMA wal_checkpoint(TRUNCATE)")

    # -- queries
    def metrics(self) -> list[dict]:
        with self.lock:
            cur = self.db.execute("""
                SELECT metric, value, ts FROM samples s WHERE ts = (SELECT max(ts) FROM samples WHERE metric = s.metric)
                GROUP BY metric ORDER BY metric""")
            rows = [{"metric": m, "value": v, "ts": ts} for m, v, ts in cur.fetchall()]
            known = {r["metric"] for r in rows}
            for (m,) in self.db.execute("SELECT DISTINCT metric FROM hourly ORDER BY metric"):
                if m not in known:
                    rows.append({"metric": m, "value": None, "ts": None})
        return rows

    def series(self, metric: str, since: int, points: int = 240) -> dict:
        now = int(time.time())
        span = max(60, now - since)
        bucket = max(1, span // max(10, points))
        with self.lock:
            raw = self.db.execute("""
                SELECT (ts / ?) * ?, avg(value), min(value), max(value) FROM samples
                WHERE metric = ? AND ts >= ? GROUP BY ts / ? ORDER BY 1""", (bucket, bucket, metric, since, bucket)).fetchall()
            first_raw = self.db.execute("SELECT min(ts) FROM samples WHERE metric = ?", (metric,)).fetchone()[0]
            hourly = []
            if first_raw is None or since < first_raw:
                upto = first_raw or now
                hourly = self.db.execute("""
                    SELECT (ts / ?) * ?, sum(avg * n) / sum(n), min(min), max(max) FROM hourly
                    WHERE metric = ? AND ts >= ? AND ts < ? GROUP BY ts / ? ORDER BY 1""",
                                         (bucket, bucket, metric, since, upto, bucket)).fetchall()
        pts = [{"t": int(t), "v": round(a, 2), "min": round(lo, 2), "max": round(hi, 2)} for t, a, lo, hi in hourly + raw]
        vals = [p["v"] for p in pts]
        return {"metric": metric, "since": since, "bucket": bucket, "points": pts,
                "min": min(vals) if vals else None, "max": max(vals) if vals else None,
                "avg": round(sum(vals) / len(vals), 2) if vals else None, "last": vals[-1] if vals else None}

    def events(self, n: int = 50, pattern: str | None = None, since: int | None = None) -> list[dict]:
        q, args = "SELECT ts, event, data FROM events", []
        conds = []
        if since:
            conds.append("ts >= ?")
            args.append(since)
        if pattern:
            conds.append("(event LIKE ? OR data LIKE ?)")
            args += [f"%{pattern}%", f"%{pattern}%"]
        if conds:
            q += " WHERE " + " AND ".join(conds)
        q += " ORDER BY ts DESC LIMIT ?"
        args.append(n)
        with self.lock:
            rows = self.db.execute(q, args).fetchall()
        out = []
        for ts, ev, data in rows:
            try:
                d = json.loads(data or "{}")
            except json.JSONDecodeError:
                d = {}
            out.append({"ts": ts, "event": ev, "data": d})
        return out

    def count(self, event: str, since: int, until: int | None = None) -> int:
        with self.lock:
            if until:
                return self.db.execute("SELECT count(*) FROM events WHERE event = ? AND ts >= ? AND ts < ?",
                                       (event, since, until)).fetchone()[0]
            return self.db.execute("SELECT count(*) FROM events WHERE event = ? AND ts >= ?", (event, since)).fetchone()[0]

    def sum_field(self, event: str, field: str, since: int) -> float:
        total = 0.0
        for e in self.events(100000, since=since):
            if e["event"] == event:
                try:
                    total += float(e["data"].get(field) or 0)
                except (TypeError, ValueError):
                    pass
        return round(total, 4)

    def last_event(self, event: str) -> dict | None:
        with self.lock:
            row = self.db.execute("SELECT ts, event, data FROM events WHERE event = ? ORDER BY ts DESC LIMIT 1", (event,)).fetchone()
        if not row:
            return None
        try:
            return {"ts": row[0], "event": row[1], "data": json.loads(row[2] or "{}")}
        except json.JSONDecodeError:
            return {"ts": row[0], "event": row[1], "data": {}}


# ---------------------------------------------------------------- rules

def load_rules() -> dict:
    try:
        data = json.loads(RULES_FILE.read_text())
    except (OSError, json.JSONDecodeError) as e:
        log("rules.json not used:", e)
        data = {}
    cfg = dict(DEFAULTS)
    cfg.update({k: v for k, v in data.items() if k != "rules"})
    rules = [r for r in data.get("rules", []) if isinstance(r, dict) and r.get("id")]
    return {"cfg": cfg, "rules": rules}


def save_rules_enabled(rule_id: str, enabled: bool) -> bool:
    data = json.loads(RULES_FILE.read_text())
    hit = False
    for r in data.get("rules", []):
        if r.get("id") == rule_id:
            r["enabled"] = enabled
            hit = True
    if hit:
        tmp = RULES_FILE.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
        tmp.replace(RULES_FILE)
    return hit


class Rules:
    """Matches events and metric crossings against rules.json and runs what they say."""

    def __init__(self, store: Store, say_hook=None):
        self.store = store
        self.rules: list[dict] = []
        self.cfg = dict(DEFAULTS)
        self.mtime = 0.0
        self.lock = threading.Lock()
        self.state = {"fired": {}, "armed": {}, "offsets": {}}
        try:
            self.state.update(json.loads(STATE_FILE.read_text()))
        except (OSError, json.JSONDecodeError):
            pass
        self.reload()

    def reload(self) -> int:
        data = load_rules()
        with self.lock:
            self.cfg = data["cfg"]
            self.rules = data["rules"]
            try:
                self.mtime = RULES_FILE.stat().st_mtime
            except OSError:
                self.mtime = 0
        return len(self.rules)

    def maybe_reload(self):
        try:
            if RULES_FILE.stat().st_mtime != self.mtime:
                log(f"rules.json changed: {self.reload()} rules")
        except OSError:
            pass

    def save_state(self):
        try:
            EVENTS_DIR.mkdir(parents=True, exist_ok=True)
            tmp = STATE_FILE.with_suffix(".json.tmp")
            tmp.write_text(json.dumps(self.state))
            tmp.replace(STATE_FILE)
        except OSError as e:
            log("state:", e)

    # -- matching
    @staticmethod
    def matches_event(rule: dict, name: str, data: dict) -> bool:
        when = rule.get("when") or {}
        if when.get("event") != name:
            return False
        for k, pat in when.items():
            if k in ("event",):
                continue
            val = str(data.get(k, ""))
            try:
                if not re.search(str(pat), val, re.IGNORECASE):
                    return False
            except re.error:
                if str(pat) != val:
                    return False
        return True

    def on_event(self, name: str, data: dict, dry=False) -> list[dict]:
        hits = []
        with self.lock:
            rules = list(self.rules)
        for rule in rules:
            if rule.get("enabled", True) is False or not self.matches_event(rule, name, data):
                continue
            hits.append(rule)
            if not dry:
                self.fire(rule, dict(data, event=name))
        return hits

    def on_sample(self, metric: str, value: float):
        with self.lock:
            rules = list(self.rules)
        for rule in rules:
            when = rule.get("when") or {}
            if rule.get("enabled", True) is False or when.get("metric") != metric:
                continue
            rid = rule["id"]
            above, below = when.get("above"), when.get("below")
            if above is None and below is None:
                continue
            crossed = (above is not None and value > float(above)) or (below is not None and value < float(below))
            clear = when.get("clear")
            if clear is None:
                clear = above if above is not None else below
            back = (above is not None and value <= float(clear)) or (below is not None and value >= float(clear))
            armed = self.state["armed"].get(rid, True)
            if crossed and armed:
                self.state["armed"][rid] = False
                self.save_state()
                self.fire(rule, {"event": "metric", "metric": metric, "value": value,
                                 "threshold": above if above is not None else below})
            elif back and not armed:
                self.state["armed"][rid] = True
                self.save_state()

    # -- acting
    def expand(self, text: str, data: dict, quote: bool) -> str:
        def sub(m):
            v = data.get(m.group(1), "")
            s = fmt_value(v) if isinstance(v, float) else str(v)
            return shlex.quote(s) if quote else s
        return re.sub(r"\{(\w+)\}", sub, text)

    def fire(self, rule: dict, data: dict, manual=False) -> dict:
        rid = rule["id"]
        now = time.time()
        last = float(self.state["fired"].get(rid, 0))
        cooldown = duration(rule.get("cooldown"), 60)
        if not manual and now - last < cooldown:
            log(f"rule {rid}: in cooldown ({int(now - last)}s < {cooldown}s)")
            return {"rule": rid, "skipped": "cooldown"}
        self.state["fired"][rid] = now
        self.save_state()
        env = dict(os.environ)
        for k, v in data.items():
            env["EVENT_" + re.sub(r"\W", "_", str(k)).upper()] = fmt_value(v) if isinstance(v, float) else str(v)
        title = rule.get("title") or rule.get("description") or rid
        results = []
        asked = False
        if rule.get("ask") and not manual:
            body = self.expand(str(rule["ask"]), data, quote=False)
            self._run([str(BARCH), "notify", title, body, "--app", "Automation",
                       "--action", f"Run={shlex.quote(str(BARCH))} rules fire {shlex.quote(rid)}"], env)
            asked = True
        else:
            for cmd in rule.get("do") or []:
                line = self.expand(str(cmd), data, quote=True)
                r = self._run(["sh", "-c", line], env, timeout=duration(rule.get("timeout"), 120))
                results.append({"cmd": line, "rc": r})
                if r != 0 and rule.get("stop_on_error", True):
                    break
        if rule.get("notify") and not asked:
            body = self.expand(str(rule["notify"]), data, quote=False)
            args = [str(BARCH), "notify", title, body, "--app", "Automation"]
            if rule.get("critical"):
                args.append("--critical")
            self._run(args, env)
        if rule.get("say") and not asked:
            self._run([str(BARCH), "voice", "say", self.expand(str(rule["say"]), data, quote=False)], env, timeout=30)
        ok = all(r["rc"] == 0 for r in results)
        rec = {"rule": rid, "event": data.get("event"), "ok": ok, "asked": asked, "manual": manual,
               "ran": [r["cmd"] for r in results], "failed": [r["cmd"] for r in results if r["rc"] != 0]}
        self.store.event("rule:" + rid, {k: v for k, v in data.items() if k != "event"} | {"ok": ok, "asked": asked, "manual": manual,
                                                                                           "failed": rec["failed"]})
        log(f"rule {rid}: {'asked' if asked else ('ok' if ok else 'FAILED')} on {data.get('event')}")
        return rec

    @staticmethod
    def _run(cmd: list[str], env: dict, timeout=120) -> int:
        try:
            r = subprocess.run(cmd, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                               timeout=timeout, cwd=str(HOME))
            if r.returncode != 0:
                log("  ", cmd[0], "→", r.returncode, (r.stderr or r.stdout).strip()[-200:])
            return r.returncode
        except subprocess.TimeoutExpired:
            log("  ", cmd[0], "→ timeout")
            return 124
        except OSError as e:
            log("  ", cmd[0], "→", e)
            return 127


# ---------------------------------------------------------------- the daemon

class Daemon:
    def __init__(self):
        EVENTS_DIR.mkdir(parents=True, exist_ok=True)
        self.store = Store(DB_FILE)
        self.rules = Rules(self.store)
        self.cfg = self.rules.cfg
        self.stop = threading.Event()
        self.prev_cpu = None
        self.last_health = 0.0
        self.last_music = 0.0
        self.last_video = 0.0
        self.last_claude = 0.0
        self.next_nas = 0.0
        self.last_certs = 0.0
        self.nas_fails = 0
        self.next_fw: dict[str, float] = {}       # per site
        self.fw_fails: dict[str, int] = {}
        self.last_prune = 0.0
        self.flags: dict[str, object] = {}        # last known state of the things that transition
        self.hwmon = self._hwmon()
        self.nvidia = bool(run(["sh", "-c", "command -v nvidia-smi"]).stdout.strip())
        self.pods_ctl = HOME / ".local/bin/librepods-ctl"
        self.windows: dict[str, dict] = {}        # address → {class, title, workspace}
        self.boot_id = Path("/proc/sys/kernel/random/boot_id").read_text().strip()

    # -- helpers
    @staticmethod
    def _hwmon() -> dict[str, Path]:
        out = {}
        for d in glob.glob("/sys/class/hwmon/hwmon*"):
            try:
                name = (Path(d) / "name").read_text().strip()
            except OSError:
                continue
            p = Path(d) / "temp1_input"
            if p.exists():
                out[name] = p
        return out

    def emit(self, name: str, data: dict | None = None):
        data = data or {}
        self.store.event(name, data)
        log("event", name, json.dumps(data, ensure_ascii=False)[:160])
        try:
            self.rules.on_event(name, data)
        except Exception as e:  # noqa: BLE001
            log("rules failed on", name, e)

    def transition(self, key: str, value, up: str, down: str, data: dict | None = None):
        """Remember `value` for `key`; emit `up` when it turns true, `down` when it turns false."""
        old = self.flags.get(key)
        self.flags[key] = value
        if old is None or old == value:
            return
        self.emit(up if value else down, data or {})

    def vpn_transition(self, on: bool, d: dict, armed: bool):
        """vpn.up; vpn.off when the tunnel was turned off (pia.sh disconnect ran after it came up:
        the bar's Disconnect, Anonymous Mode off, a voice command); vpn.down only when it dropped.
        The down events carry the tunnel that went away (the status after it is empty) and
        whether the kill switch is holding the traffic."""
        old = self.flags.get("vpn")
        self.flags["vpn"] = on
        if on:
            self.vpn_up = {"region": d.get("region", ""), "name": d.get("name", ""), "country": d.get("country", ""),
                           "preferred": d.get("preferred", "")}
            if old is not True:
                self.vpn_up_at = time.time()
            if old is False:
                self.emit("vpn.up", dict(self.vpn_up))
            return
        if old is not True:
            return
        last = getattr(self, "vpn_up", {}) or {}
        data = {**last, "preferred": d.get("preferred", last.get("preferred", "")),
                "killswitch": "armed" if armed else "off",
                "note": "O kill switch está segurando o tráfego." if armed else "O tráfego está saindo sem a VPN."}
        stopped = float(d.get("stopped") or 0)
        if stopped and stopped > getattr(self, "vpn_up_at", 0):
            self.emit("vpn.off", data)
        else:
            self.emit("vpn.down", data)

    # -- samplers
    def sample_system(self) -> list[tuple[str, float]]:
        rows = []
        try:
            with open("/proc/stat") as f:
                parts = f.readline().split()[1:]
            vals = list(map(int, parts))
            idle = vals[3] + vals[4]
            total = sum(vals)
            if self.prev_cpu:
                dt, di = total - self.prev_cpu[0], idle - self.prev_cpu[1]
                if dt > 0:
                    rows.append(("cpu.pct", 100.0 * (dt - di) / dt))
            self.prev_cpu = (total, idle)
            rows.append(("cpu.load1", os.getloadavg()[0]))
        except OSError:
            pass
        try:
            mem = {}
            with open("/proc/meminfo") as f:
                for line in f:
                    k, v = line.split(":", 1)
                    mem[k] = int(v.split()[0])
            rows.append(("ram.pct", 100.0 * (mem["MemTotal"] - mem["MemAvailable"]) / mem["MemTotal"]))
            rows.append(("ram.used_gb", (mem["MemTotal"] - mem["MemAvailable"]) / 1048576))
            if mem.get("SwapTotal"):
                rows.append(("swap.pct", 100.0 * (mem["SwapTotal"] - mem["SwapFree"]) / mem["SwapTotal"]))
        except (OSError, KeyError, ValueError):
            pass
        for name, p in self.hwmon.items():
            try:
                v = int(p.read_text()) / 1000
                rows.append((f"temp.{name}", v))
                if name == "k10temp":
                    rows.append(("cpu.temp", v))
            except (OSError, ValueError):
                pass
        for mnt in self.cfg.get("disks", []):
            try:
                st = os.statvfs(mnt)
                used = 1 - st.f_bavail / st.f_blocks if st.f_blocks else 0
                label = "root" if mnt == "/" else Path(mnt).name
                rows.append((f"disk.{label}.pct", 100.0 * used))
                rows.append((f"disk.{label}.free_gb", st.f_bavail * st.f_frsize / 1e9))
            except OSError:
                pass
        return rows

    def sample_gpu(self) -> list[tuple[str, float]]:
        if not self.nvidia:
            return []
        try:
            r = run(["nvidia-smi", "--query-gpu=temperature.gpu,utilization.gpu,power.draw,memory.used,memory.total",
                     "--format=csv,noheader,nounits"], timeout=8)
            t, u, p, mu, mt = [x.strip() for x in r.stdout.strip().splitlines()[0].split(",")]
            rows = [("gpu.temp", float(t)), ("gpu.util", float(u)), ("gpu.power", float(p)),
                    ("gpu.vram_gb", float(mu) / 1024)]
            if float(mt) > 0:
                rows.append(("gpu.vram_pct", 100.0 * float(mu) / float(mt)))
            return rows
        except Exception:  # noqa: BLE001
            return []

    def sample_net(self) -> list[tuple[str, float]]:
        rows = []
        try:
            r = run(["ip", "-j", "route", "show", "default"], timeout=5)
            routes = json.loads(r.stdout or "[]")
            self.transition("net", bool(routes), "net.up", "net.down",
                            {"dev": routes[0].get("dev", "") if routes else ""})
        except Exception:  # noqa: BLE001
            pass
        host = self.cfg.get("ping")
        if host:
            try:
                r = run(["ping", "-n", "-c", "1", "-W", "2", host], timeout=6)
                m = re.search(r"time=([\d.]+)", r.stdout)
                if m:
                    rows.append(("net.latency_ms", float(m.group(1))))
                    if self.flags.get("vpn"):
                        rows.append(("vpn.latency_ms", float(m.group(1))))
            except Exception:  # noqa: BLE001
                pass
        return rows

    def sample_bar(self) -> list[tuple[str, float]]:
        """What only the bar knows: VPN, Anonymous Mode, the health check (every few minutes)."""
        rows = []
        armed = False
        try:
            r = run([str(BARCH), "--json", "anon", "status"], timeout=10)
            if r.returncode in (0, 1) and r.stdout.strip():
                d = json.loads(r.stdout)
                on = bool(d.get("on") if "on" in d else d.get("active") if "active" in d else d.get("enabled"))
                armed = bool((d.get("killswitch") or {}).get("armed"))
                self.transition("anon", on, "anon.on", "anon.off", {})
        except Exception:  # noqa: BLE001
            pass
        try:
            r = run([str(BARCH), "--json", "vpn", "status"], timeout=10)
            if r.returncode in (0, 1) and r.stdout.strip():
                d = json.loads(r.stdout)
                on = bool(d.get("connected"))
                rows.append(("vpn.connected", 1.0 if on else 0.0))
                self.vpn_transition(on, d, armed)
        except Exception:  # noqa: BLE001
            pass
        now = time.time()
        if now - self.last_health >= float(self.cfg.get("health_every_s", 300)):
            self.last_health = now
            try:
                r = run([str(BARCH), "--json", "health"], timeout=20)
                if r.returncode in (0, 1) and r.stdout.strip():
                    d = json.loads(r.stdout)
                    if d.get("loaded"):
                        rows.append(("health.issues", float(d.get("issues") or 0)))
                        failed = (d.get("failed") or {})
                        rows.append(("health.failed_units", float(len(failed.get("system") or []) + len(failed.get("user") or []))))
            except Exception:  # noqa: BLE001
                pass
        return rows

    def sample_pods(self) -> list[tuple[str, float]]:
        if not self.pods_ctl.exists():
            return []
        rows = []
        try:
            r = run([str(self.pods_ctl), "status"], timeout=6)
            d = json.loads(r.stdout) if r.stdout.strip() else {}
            on = bool(d.get("connected"))
            self.transition("pods", on, "pods.connected", "pods.disconnected", {"name": d.get("device_name", "")})
            if on:
                for side in ("left", "right", "case"):
                    s = d.get(side) or {}
                    if s.get("available"):
                        rows.append((f"pods.{side}.pct", float(s.get("level") or 0)))
        except Exception:  # noqa: BLE001
            pass
        return rows

    def sample_lock(self):
        try:
            r = run(["qs", "-p", str(HOME / ".config/quickshell/lock"), "ipc", "call", "lock", "state"], timeout=5)
            d = json.loads(r.stdout) if r.stdout.strip() else {}
            self.transition("locked", bool(d.get("locked")), "session.locked", "session.unlocked", {})
        except Exception:  # noqa: BLE001
            pass

    def sample_music(self):
        """The music pipeline on the NAS (server/music): an album that lands in the review queue is an
        event, music.review (id, name, problem, cover_only), once per job (`music_seen` in the state).
        Needs ~/.config/barch/music.json (barch music install); every `music_every_s`, 120 by default."""
        conf = HOME / ".config/barch/music.json"
        now = time.time()
        if not conf.exists() or now - self.last_music < float(self.cfg.get("music_every_s", 120)):
            return
        self.last_music = now
        try:
            c = json.loads(conf.read_text())
            import urllib.request
            req = urllib.request.Request(c["url"].rstrip("/") + "/api/jobs?state=review", headers={"X-Barch-Token": c.get("token", "")})
            with urllib.request.urlopen(req, timeout=8) as r:
                jobs = json.loads(r.read().decode()).get("jobs") or []
        except Exception:  # noqa: BLE001 - the NAS or the pipeline is down: nothing to say
            return
        st = self.rules.state
        seen = set(st.get("music_seen") or [])
        first = not seen and "music_seen" not in st
        new = [j for j in jobs if j.get("id") and j["id"] not in seen]
        for j in new:
            problems = [str(x) for x in (j.get("problems") or [])]
            data = {"id": j["id"], "name": j.get("name", ""), "folder": j.get("folder") or "", "problem": problems[0][:200] if problems else "",
                    "problems": len(problems), "cover_only": "yes" if problems and all(x.startswith("no cover") for x in problems) else "no"}
            if first:
                self.store.event("music.review", data | {"imported": True}, ts=int(j.get("updated") or now))
            else:
                self.emit("music.review", data)
        if new or first:
            st["music_seen"] = sorted((seen | {j["id"] for j in jobs}))[-500:]
            self.rules.save_state()

    def sample_claude(self) -> list[tuple[str, float]]:
        """The Claude plan's limits as the bar reads them (quickshell/claude/usage.py, `barch claude`): metrics
        claude.session.pct (the five-hour window), claude.week.pct and claude.<model>.pct (the top model's weekly
        share, "fable" today), every `claude_every_s` (300), so the History page shows how the agents eat the plan."""
        now = time.time()
        if now - self.last_claude < float(self.cfg.get("claude_every_s", 300)):
            return []
        self.last_claude = now
        rows = []
        try:
            r = run([str(BARCH), "--json", "claude"], timeout=20)
            if r.returncode in (0, 1) and r.stdout.strip():
                d = json.loads(r.stdout)
                if d.get("ok"):
                    for lim in d.get("limits") or []:
                        if lim.get("percent") is None:
                            continue
                        name = {"session": "session", "weekly_all": "week"}.get(lim.get("kind")) or \
                            re.sub(r"[^a-z0-9]+", "", (lim.get("label") or lim.get("kind") or "").lower()) or "scoped"
                        rows.append((f"claude.{name}.pct", float(lim["percent"])))
        except Exception:  # noqa: BLE001
            pass
        return rows

    def sample_video(self):
        """The video pipeline on the NAS (server/video): a file whose audio goes beyond the original language
        and PT-BR (a German DL release of an English series, a MULTi) is an event, video.foreign (id, title,
        file, original, audio, extra, trim: what the pipeline's trim is doing about it), once per file
        (`video_seen` in the state, by path and size). Needs ~/.config/barch/video.json (barch video
        install); every `video_every_s`, 300 by default."""
        conf = HOME / ".config/barch/video.json"
        now = time.time()
        if not conf.exists() or now - self.last_video < float(self.cfg.get("video_every_s", 300)):
            return
        self.last_video = now
        try:
            c = (json.loads(conf.read_text()).get("pipeline") or {})
            import urllib.request
            req = urllib.request.Request(c["url"].rstrip("/") + "/api/foreign", headers={"X-Barch-Token": c.get("token", "")})
            with urllib.request.urlopen(req, timeout=8) as r:
                files = json.loads(r.read().decode()).get("files") or []
        except Exception:  # noqa: BLE001 - the NAS or the pipeline is down: nothing to say
            return
        st = self.rules.state
        seen = set(st.get("video_seen") or [])
        first = not seen and "video_seen" not in st
        keys = {f"{f.get('file')}:{f.get('size')}": f for f in files if f.get("file")}
        trim_text = {"pending": "o pipeline vai tirar as faixas que sobram", "waiting": "aparado quando o torrent parar de semear",
                     "failed": "o trim falhou", "skipped": "o job está skipped", "none": "nada a fazer por aqui"}
        for k, f in keys.items():
            if k in seen:
                continue
            data = {"id": f.get("id", ""), "kind": f.get("kind", ""), "title": f.get("title", ""), "file": f.get("file", ""),
                    "original": f.get("original", ""), "audio": ", ".join(f.get("audio") or []), "extra": ", ".join(f.get("extra") or []),
                    "por": "yes" if f.get("por") else "no", "trim": f.get("trim", ""),
                    "text": f"{f.get('title', '')}: áudio em {', '.join(f.get('extra') or [])} (original {f.get('original', '')}); "
                            + trim_text.get(f.get("trim", ""), "")}
            if first:
                self.store.event("video.foreign", data | {"imported": True})
            else:
                self.emit("video.foreign", data)
        if first or set(keys) - seen:
            st["video_seen"] = sorted((seen | set(keys)))[-2000:]
            self.rules.save_state()

    def sample_nas(self) -> list[tuple[str, float]]:
        """The NAS through Unraid's API (agent/nas.py; needs ~/.config/barch/nas.json, `barch nas
        setup`), every `nas_every_s`: metrics nas.* and cert.days, and the events of nas.changes()
        (nas.array, nas.disk, nas.containers, nas.alert, cert.expiring) plus nas.down after three
        misses in a row (retried every 30 s: one miss is a wake-up or a restart) and nas.up when it
        answers again. What was already reported lives in the rules' state, so a restart of the
        daemon repeats nothing. Nothing is asked while this machine itself has no network."""
        now = time.time()
        if now < self.next_nas or self.flags.get("net") is False:
            return []
        self.next_nas = now + float(self.cfg.get("nas_every_s", 300))
        conf = nas.load_conf()
        if not conf:
            return []
        snap = nas.collect(conf, certs=False)
        st = self.rules.state.setdefault("nas", {})
        if not snap["reachable"]:
            self.nas_fails += 1
            if self.nas_fails < 3:
                self.next_nas = now + 30
            elif st.get("up") is not False:
                st["up"] = False
                self.rules.save_state()
                self.emit("nas.down", {"error": str(snap["error"])[:200]})
            return [("nas.up", 0.0)]
        self.nas_fails = 0
        self.next_fw: dict[str, float] = {}       # per site
        self.fw_fails: dict[str, int] = {}
        if st.get("up") is False:
            self.emit("nas.up", {})
        st["up"] = True
        if now - self.last_certs >= float(self.cfg.get("nas_certs_every_s", 21600)):
            self.last_certs = now
            snap["certs"] = nas.check_certs(conf)
        for name, data in nas.changes(snap, st, now, float(self.cfg.get("nas_grace_s", 900)),
                                      float(self.cfg.get("cert_warn_days", 10))):
            self.emit(name, data)
        self.rules.save_state()
        return [("nas.up", 1.0)] + nas.metrics(snap)

    def sample_fw(self) -> list[tuple[str, float]]:
        """The firewalls through their REST API (agent/pfsense.py; needs ~/.config/barch/pfsense.json,
        `barch fw setup`), each every `fw_every_s`: metrics fw.<site>.* and the events of
        pfsense.changes() (fw.boot, fw.gateway, fw.interface, fw.ipsec, fw.dnsbl, fw.client), plus
        fw.down after three misses in a row (retried every 30 s) and fw.up when it answers again. A
        key the API refuses gives fw.auth once and is left alone for `fw_auth_backoff_s`: a burst of
        refused keys gets this desktop banned by the API's login protection. What was already
        reported lives in the rules' state, so a restart of the daemon repeats nothing."""
        now = time.time()
        if self.flags.get("net") is False:
            return []
        conf = pfsense.load_conf()
        if not conf:
            return []
        rows: list[tuple[str, float]] = []
        dirty = False
        probe, vip = conf.get("dnsbl_probe") or pfsense.DEFAULT_PROBE, conf.get("dnsbl_vip") or pfsense.DEFAULT_VIP
        for site in conf["sites"]:
            if now < self.next_fw.get(site, 0.0):
                continue
            dirty = True
            self.next_fw[site] = now + float(self.cfg.get("fw_every_s", 300))
            snap = pfsense.collect_site(site, conf, probe, vip)
            st = self.rules.state.setdefault("fw", {}).setdefault(site, {})
            key = pfsense._key(site)
            if not snap["reachable"]:
                if not snap["auth"]:
                    self.next_fw[site] = now + float(self.cfg.get("fw_auth_backoff_s", 3600))
                    if st.get("auth") is not False:
                        st["auth"] = False
                        self.emit("fw.auth", {"site": site, "error": str(snap["error"])[:200],
                                              "text": f"O pfSense {site} recusou a chave da API ({snap['error'][:80]}); nova tentativa em uma hora."})
                    continue
                self.fw_fails[site] = self.fw_fails.get(site, 0) + 1
                if self.fw_fails[site] < 3:
                    self.next_fw[site] = now + 30
                elif st.get("up") is not False:
                    st["up"] = False
                    self.emit("fw.down", {"site": site, "error": str(snap["error"])[:200],
                                          "text": f"O pfSense {site} não responde ({snap['error'][:80]})."})
                rows.append((f"fw.{key}.up", 0.0))
                continue
            self.fw_fails[site] = 0
            st["auth"] = True
            if st.get("up") is False:
                self.emit("fw.up", {"site": site, "text": f"O pfSense {site} voltou a responder."})
            st["up"] = True
            events, blocked = pfsense.changes(snap, st, now, conf.get("ignore_macs") or [])
            for name, data in events:
                self.emit(name, data)
            rows += [(f"fw.{key}.up", 1.0)] + pfsense.metrics(snap) + blocked
        if dirty:
            self.rules.save_state()
        return rows

    # -- files that grow: failure logs, the Claude cost log, agent reports
    def watch_files(self, first=False):
        st = self.rules.state
        seen = float(st.get("failures_seen", 0))
        newest = seen
        if FAILURES.is_dir():
            for p in sorted(FAILURES.glob("*.log"), key=lambda p: p.stat().st_mtime):
                mt = p.stat().st_mtime
                if mt <= seen:
                    continue
                newest = max(newest, mt)
                unit = re.sub(r"-\d{8}-\d{6}\.log$", "", p.name)
                if first:
                    # the logs that were already there go in as history, dated by their name
                    m = re.search(r"(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})\.log$", p.name)
                    ts = int(datetime(*map(int, m.groups())).timestamp()) if m else int(mt)
                    self.store.event("failure", {"unit": unit, "path": str(p), "imported": True}, ts=ts)
                else:
                    self.emit("failure", {"unit": unit, "path": str(p)})
            if newest != seen:
                st["failures_seen"] = newest
                self.rules.save_state()
        # claude-cost.log: "<epoch> <source> <usd> [note]"
        off = int(st.get("cost_offset", 0))
        try:
            size = COST_LOG.stat().st_size
            if size < off:
                off = 0
            if size > off:
                with COST_LOG.open() as f:
                    f.seek(off)
                    for line in f:
                        parts = line.split(None, 3)
                        if len(parts) >= 3:
                            try:
                                ts, src, usd = int(float(parts[0])), parts[1], float(parts[2])
                            except ValueError:
                                continue
                            data = {"source": src, "usd": round(usd, 4)}
                            if len(parts) == 4:
                                data["note"] = parts[3].strip()[:120]
                            self.store.event("claude.cost", data, ts=ts)
                            self.rules.on_event("claude.cost", data)
                    off = f.tell()
                st["cost_offset"] = off
                self.rules.save_state()
        except OSError:
            pass
        # older agent reports, once: their cost is history too
        if not st.get("reports_imported") and REPORTS.is_dir():
            n = 0
            for p in REPORTS.glob("*/*.json"):
                if p.name == "latest.json":
                    continue
                try:
                    d = json.loads(p.read_text())
                    ts = int(datetime.fromisoformat(d["time"]).timestamp())
                    if d.get("cost") is not None:
                        self.store.event("claude.cost", {"source": d.get("task", p.parent.name), "usd": round(float(d["cost"]), 4),
                                                         "note": d.get("title", "")[:120]}, ts=ts)
                        n += 1
                except (OSError, KeyError, ValueError, json.JSONDecodeError):
                    continue
            st["reports_imported"] = True
            self.rules.save_state()
            log(f"imported the cost of {n} agent reports")

    def boot_once(self):
        st = self.rules.state
        if st.get("boot_id") == self.boot_id:
            return
        try:
            r = run(["systemd-analyze"], timeout=10)
            m = re.search(r"= ([\d.]+)s", r.stdout)
            if not m:
                # too early in the boot for systemd-analyze: try again next time
                return
            secs = float(m.group(1))
            with open("/proc/uptime") as f:
                up = float(f.readline().split()[0])
            ts = int(time.time() - up)
            data = {"seconds": secs, "text": r.stdout.strip().splitlines()[0], "kernel": os.uname().release}
            self.store.event("boot", data, ts=ts)
            self.store.sample("boot.seconds", secs, ts=ts)
            st["boot_id"] = self.boot_id
            self.rules.save_state()
            log(f"boot: {secs}s ({data['kernel']})")
            self.rules.on_event("boot", data)
        except Exception as e:  # noqa: BLE001
            log("boot:", e)

    # -- Hyprland socket2
    def hypr_thread(self):
        while not self.stop.is_set():
            path = self._hypr_socket()
            if not path:
                time.sleep(5)
                continue
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                    s.connect(path)
                    s.settimeout(1.0)
                    log("hyprland events:", path)
                    buf = b""
                    while not self.stop.is_set():
                        try:
                            chunk = s.recv(4096)
                        except socket.timeout:
                            continue
                        if not chunk:
                            break
                        buf += chunk
                        while b"\n" in buf:
                            line, buf = buf.split(b"\n", 1)
                            self.hypr_line(line.decode(errors="replace"))
            except OSError as e:
                log("hyprland socket:", e)
            time.sleep(3)

    @staticmethod
    def _hypr_socket() -> str | None:
        sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")
        cands = [RUNTIME / "hypr" / sig / ".socket2.sock"] if sig else []
        cands += sorted((Path(p) for p in glob.glob(str(RUNTIME / "hypr/*/.socket2.sock"))),
                        key=lambda p: p.stat().st_mtime, reverse=True)
        for c in cands:
            if c.exists():
                return str(c)
        return None

    def hypr_line(self, line: str):
        if ">>" not in line:
            return
        ev, _, arg = line.partition(">>")
        if ev == "openwindow":
            addr, ws, cls, title = (arg.split(",", 3) + ["", "", ""])[:4]
            self.windows[addr] = {"class": cls, "title": title, "workspace": ws}
            self.emit("window.open", {"address": "0x" + addr, "class": cls, "title": title, "workspace": ws})
        elif ev == "closewindow":
            w = self.windows.pop(arg, {})
            self.emit("window.close", {"address": "0x" + arg, "class": w.get("class", ""), "title": w.get("title", ""),
                                       "workspace": w.get("workspace", "")})
        elif ev == "monitoraddedv2":
            mid, name, desc = (arg.split(",", 2) + ["", ""])[:3]
            self.emit("monitor.added", {"name": name, "description": desc})
        elif ev == "monitorremovedv2":
            mid, name, desc = (arg.split(",", 2) + ["", ""])[:3]
            self.emit("monitor.removed", {"name": name, "description": desc})
        elif ev == "fullscreen":
            self.emit("window.fullscreen", {"on": arg.strip() == "1"})
        elif ev == "urgent":
            w = self.windows.get(arg, {})
            self.emit("window.urgent", {"address": "0x" + arg, "class": w.get("class", ""), "title": w.get("title", "")})

    # -- control
    def hup(self, *_):
        log(f"reload: {self.rules.reload()} rules")
        self.cfg = self.rules.cfg

    def loop(self):
        log(f"{len(self.rules.rules)} rules, sampling every {self.cfg['interval_s']}s → {DB_FILE}")
        threading.Thread(target=self.hypr_thread, daemon=True).start()
        self.watch_files(first=True)
        self.emit("startup", {"boot_age_s": int(float(open('/proc/uptime').readline().split()[0]))})
        while not self.stop.is_set():
            t0 = time.time()
            try:
                self.rules.maybe_reload()
                self.cfg = self.rules.cfg
                rows = []
                for fn in (self.sample_system, self.sample_gpu, self.sample_net, self.sample_bar, self.sample_pods,
                           self.sample_nas, self.sample_fw, self.sample_claude):
                    try:
                        rows += fn()
                    except Exception as e:  # noqa: BLE001
                        log(fn.__name__, "failed:", e)
                self.sample_lock()
                self.sample_music()
                self.sample_video()
                if rows:
                    self.store.samples(rows)
                    for m, v in rows:
                        self.rules.on_sample(m, v)
                self.watch_files()
                self.boot_once()
                if time.time() - self.last_prune > 6 * 3600:
                    self.last_prune = time.time()
                    self.store.prune(int(self.cfg["raw_days"]), int(self.cfg["events_days"]))
            except Exception as e:  # noqa: BLE001
                log("loop:", e)
            self.stop.wait(max(5.0, float(self.cfg["interval_s"]) - (time.time() - t0)))


# ---------------------------------------------------------------- CLI

def cli(argv: list[str]) -> int:
    cmd = argv[0] if argv else "run"
    args = argv[1:]
    if cmd == "run":
        d = Daemon()
        signal.signal(signal.SIGHUP, d.hup)
        signal.signal(signal.SIGTERM, lambda *_: d.stop.set())
        signal.signal(signal.SIGINT, lambda *_: d.stop.set())
        d.loop()
        return 0

    store = Store(DB_FILE)
    out: object
    if cmd == "status":
        active = run(["systemctl", "--user", "is-active", "barch-events.service"]).stdout.strip()
        metrics = store.metrics()
        last = max((m["ts"] or 0 for m in metrics), default=0)
        rules = load_rules()
        out = {"ok": True, "service": active, "metrics": len(metrics), "last_sample": last,
               "rules": len(rules["rules"]), "enabled": sum(1 for r in rules["rules"] if r.get("enabled", True) is not False),
               "events_24h": len(store.events(100000, since=int(time.time()) - 86400)), "db": str(DB_FILE),
               "db_bytes": DB_FILE.stat().st_size if DB_FILE.exists() else 0}
    elif cmd in ("rules", "list"):
        data = load_rules()
        rows = []
        for r in data["rules"]:
            last = store.last_event("rule:" + r["id"])
            rows.append({"id": r["id"], "description": r.get("description", ""), "when": r.get("when", {}),
                         "do": r.get("do", []), "notify": r.get("notify", ""), "say": r.get("say", ""), "ask": r.get("ask", ""),
                         "cooldown": r.get("cooldown", "60s"), "enabled": r.get("enabled", True) is not False,
                         "last": last["ts"] if last else None, "last_ok": last["data"].get("ok") if last else None,
                         "fired_7d": store.count("rule:" + r["id"], int(time.time()) - 7 * 86400)})
        out = {"ok": True, "rules": rows, "file": str(RULES_FILE)}
    elif cmd in ("enable", "disable"):
        if not args:
            print(json.dumps({"ok": False, "error": f"usage: {cmd} <rule id>"}))
            return 2
        hit = save_rules_enabled(args[0], cmd == "enable")
        out = {"ok": hit, "id": args[0], "enabled": cmd == "enable"} if hit else {"ok": False, "error": f"no rule {args[0]}"}
        if hit:
            run(["systemctl", "--user", "kill", "-s", "HUP", "barch-events.service"], timeout=5)
    elif cmd == "test":
        # test <event> [key=value ...] | test metric <name> <value>
        if not args:
            print(json.dumps({"ok": False, "error": "usage: test <event> [key=value...] | test metric <name> <value>"}))
            return 2
        rules = Rules(store)
        if args[0] == "metric" and len(args) >= 3:
            metric, value = args[1], float(args[2])
            hits = []
            for r in rules.rules:
                w = r.get("when") or {}
                if w.get("metric") != metric or r.get("enabled", True) is False:
                    continue
                if (w.get("above") is not None and value > float(w["above"])) or (w.get("below") is not None and value < float(w["below"])):
                    hits.append(r["id"])
            out = {"ok": True, "metric": metric, "value": value, "rules": hits}
        else:
            data = {}
            for kv in args[1:]:
                k, _, v = kv.partition("=")
                data[k] = v
            hits = rules.on_event(args[0], data, dry=True)
            out = {"ok": True, "event": args[0], "data": data, "rules": [r["id"] for r in hits]}
    elif cmd == "fire":
        if not args:
            print(json.dumps({"ok": False, "error": "usage: fire <rule id> [key=value...]"}))
            return 2
        rules = Rules(store)
        rule = next((r for r in rules.rules if r["id"] == args[0]), None)
        if not rule:
            print(json.dumps({"ok": False, "error": f"no rule {args[0]}"}))
            return 1
        data = {"event": "manual"}
        for kv in args[1:]:
            k, _, v = kv.partition("=")
            data[k] = v
        rec = rules.fire(rule, data, manual=True)
        out = dict(rec, ok=rec.get("ok", True))
    elif cmd == "events":
        n, pattern, since = 50, None, None
        it = iter(args)
        for a in it:
            if a == "--filter":
                pattern = next(it, None)
            elif a == "--since":
                since = since_arg(next(it, "24h"))
            elif a.isdigit():
                n = int(a)
        out = {"ok": True, "events": store.events(n, pattern, since)}
    elif cmd == "metrics":
        out = {"ok": True, "metrics": store.metrics()}
    elif cmd == "series":
        if not args:
            print(json.dumps({"ok": False, "error": "usage: series <metric> [--since 24h] [--points N]"}))
            return 2
        since, points = int(time.time()) - 86400, 240
        it = iter(args[1:])
        for a in it:
            if a == "--since":
                since = since_arg(next(it, "24h"))
            elif a == "--points":
                points = int(next(it, "240"))
        out = dict(ok=True, **store.series(args[0], since, points))
    elif cmd == "summary":
        now = int(time.time())
        day = now - 86400
        week = now - 7 * 86400
        month = now - 30 * 86400
        boot = store.last_event("boot")
        boots = [e for e in store.events(20, since=now - 90 * 86400) if e["event"] == "boot"]
        boot_avg = round(sum(float(b["data"].get("seconds") or 0) for b in boots) / len(boots), 1) if boots else None
        latest = {m["metric"]: m["value"] for m in store.metrics() if m["value"] is not None}
        with open("/proc/uptime") as f:
            uptime = float(f.readline().split()[0])
        cost_sources: dict[str, float] = {}
        for e in store.events(100000, since=month):
            if e["event"] == "claude.cost":
                src = str(e["data"].get("source", "?"))
                cost_sources[src] = round(cost_sources.get(src, 0) + float(e["data"].get("usd") or 0), 4)
        out = {
            "ok": True,
            "boot": {"seconds": boot["data"].get("seconds") if boot else None, "text": boot["data"].get("text") if boot else "",
                     "kernel": boot["data"].get("kernel") if boot else "", "at": boot["ts"] if boot else None,
                     "avg_seconds": boot_avg, "count_90d": len(boots), "uptime_s": int(uptime)},
            "failures": {"today": store.count("failure", day), "week": store.count("failure", week),
                         "last_week": store.count("failure", week - 7 * 86400, week), "month": store.count("failure", month)},
            "claude": {"today": store.sum_field("claude.cost", "usd", day), "week": store.sum_field("claude.cost", "usd", week),
                       "month": store.sum_field("claude.cost", "usd", month), "by_source_30d": cost_sources},
            "rules": {"fired_24h": sum(1 for e in store.events(100000, since=day) if e["event"].startswith("rule:")),
                      "fired_7d": sum(1 for e in store.events(100000, since=week) if e["event"].startswith("rule:"))},
            "vpn": {"connected": latest.get("vpn.connected") == 1.0, "latency_ms": latest.get("vpn.latency_ms"),
                    "drops_7d": store.count("vpn.down", week)},
            "now": {k: latest.get(k) for k in ("cpu.temp", "gpu.temp", "cpu.pct", "gpu.util", "ram.pct", "gpu.vram_pct",
                                                "net.latency_ms", "disk.root.pct", "disk.home.pct", "health.issues")},
            "events_24h": len(store.events(100000, since=day)),
        }
    else:
        print(json.dumps({"ok": False, "error": f"unknown command {cmd}"}))
        return 2
    print(json.dumps(out, ensure_ascii=False))
    return 0 if (not isinstance(out, dict) or out.get("ok", True)) else 1


if __name__ == "__main__":
    sys.exit(cli(sys.argv[1:]))
