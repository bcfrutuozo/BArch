#!/usr/bin/env python3
"""barch nas: the health of the NAS (Unraid) as this desktop sees it. Read only.

Asks Unraid's own API (GraphQL, the one Homepage's Unraid widget uses) for the array, every disk,
the pools, the containers and Unraid's unread warnings, and checks how many days the TLS
certificates of the services have left. events.py samples it (`sample_nas`) into metrics and
events; `barch nas status` prints the same snapshot.

    nas.py status [--json] [--no-certs]   the snapshot now
    nas.py setup                          write ~/.config/barch/nas.json when there is none: URL and
                                          API key from Homepage's Unraid widget on the appdata share

~/.config/barch/nas.json (mode 600, never in the repo):
    {"url": "https://<unraid>:<port>", "key": "<Unraid API key>",
     "certs": ["host:port", ...],          TLS endpoints whose expiry is watched
     "ignore_containers": ["regex", ...]}  containers that may be down without it being a problem
"""
from __future__ import annotations

import json
import os
import re
import socket
import ssl
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
CONF = Path(os.environ.get("BARCH_NAS_CONF", Path.home() / ".config/barch/nas.json"))
# Unraid's myunraid.net certificate chains to Let's Encrypt's "Root YR", which the system store does
# not carry yet (2026-11): its cross-signature by ISRG Root X1 closes the chain. Harmless once it does.
EXTRA_CA = HERE / "certs" / "root-yr-by-x1.crt"
HOMEPAGE = Path(os.environ.get("BARCH_HOMEPAGE_SERVICES", "/mnt/nasfrutuozo/appdata/homepage/services.yaml"))
# what `setup` watches besides the Unraid interface itself: the reverse proxy's wildcard, both
# firewalls (ACME) and the mail server
DEFAULT_CERTS = ["portal.example.com:443", "fw-home.example.net:443", "fw-remote.example.net:443",
                 "mail.example.com:465"]

QUERY = """{
  info { os { hostname uptime } versions { core { unraid } } }
  array { state capacity { kilobytes { free used total } }
    parityCheckStatus { status progress errors running date }
    parities { name device status temp numErrors type }
    disks { name device status temp numErrors fsSize fsUsed type }
    caches { name device status temp numErrors fsSize fsUsed type } }
  docker { containers { names state status autoStart isUpdateAvailable } }
  notifications { overview { unread { warning alert } }
    warningsAndAlerts { id title subject description importance timestamp } }
  metrics { cpu { percentTotal } memory { percentTotal } }
}"""

# a container somebody stopped (docker stop: 0, SIGTERM 143, SIGKILL 137) is not a crash; only
# counted against the ones Unraid starts by itself
STOPPED_ON_PURPOSE = {0, 137, 143}


class NasError(Exception):
    pass


def load_conf() -> dict | None:
    try:
        c = json.loads(CONF.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    return c if c.get("url") and c.get("key") else None


def tls_context() -> ssl.SSLContext:
    ctx = ssl.create_default_context()
    if EXTRA_CA.exists():
        ctx.load_verify_locations(cafile=str(EXTRA_CA))
    return ctx


def graphql(conf: dict, query: str = QUERY, timeout: float = 10) -> dict:
    req = urllib.request.Request(conf["url"].rstrip("/") + "/graphql", data=json.dumps({"query": query}).encode(),
                                 headers={"content-type": "application/json", "x-api-key": conf["key"]})
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=tls_context()) as r:
            d = json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        raise NasError(f"HTTP {e.code}" + (": the API key was refused" if e.code in (401, 403) else "")) from e
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise NasError(str(getattr(e, "reason", e))) from e
    if d.get("errors") and not d.get("data"):
        raise NasError(str(d["errors"][0].get("message", "GraphQL error"))[:200])
    return d.get("data") or {}


def _num(v) -> float:
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0


def _pct(used, total) -> float | None:
    used, total = _num(used), _num(total)
    return round(100 * used / total, 1) if total > 0 else None


def container_problem(c: dict) -> str:
    """'' when the container is fine, else stopped | crashed | restarting | unhealthy."""
    status = str(c.get("status") or "")
    state = str(c.get("state") or "")
    if state == "RUNNING":
        return "unhealthy" if "(unhealthy)" in status else ""
    if status.startswith("Restarting"):
        return "restarting"
    m = re.match(r"Exited \((\d+)\)", status)
    code = int(m.group(1)) if m else None
    if c.get("autoStart"):
        return "stopped" if code in STOPPED_ON_PURPOSE or code is None else "crashed"
    return "crashed" if code is not None and code not in STOPPED_ON_PURPOSE else ""


def summarize(data: dict, conf: dict | None = None) -> dict:
    """The API's answer as the snapshot everything else reads. Pure: no I/O."""
    ignore = [re.compile(p, re.I) for p in ((conf or {}).get("ignore_containers") or [])]
    arr = data.get("array") or {}
    kb = (arr.get("capacity") or {}).get("kilobytes") or {}
    par = arr.get("parityCheckStatus") or {}
    disks, problems = [], []
    for kind, rows in (("parity", arr.get("parities")), ("data", arr.get("disks")), ("pool", arr.get("caches"))):
        for d in rows or []:
            status = str(d.get("status") or "")
            if status in ("DISK_NP", ""):          # an empty slot
                continue
            errors = int(_num(d.get("numErrors")))
            ok = status == "DISK_OK" and errors == 0
            disks.append({"name": d.get("name") or "?", "kind": kind, "device": d.get("device") or "", "status": status,
                          "temp": d.get("temp"), "errors": errors, "pct": _pct(d.get("fsUsed"), d.get("fsSize")), "ok": ok})
            if not ok:
                problems.append(f"{d.get('name')}: {status.removeprefix('DISK_')}" + (f", {errors} errors" if errors else ""))
    state = str(arr.get("state") or "?")
    if state != "STARTED":
        problems.insert(0, f"array {state}")
    if par.get("errors"):
        problems.append(f"parity check: {par['errors']} errors")

    down, updates, running, total = [], [], 0, 0
    for c in (data.get("docker") or {}).get("containers") or []:
        name = str((c.get("names") or ["?"])[0]).lstrip("/")
        total += 1
        running += c.get("state") == "RUNNING"
        if c.get("isUpdateAvailable"):
            updates.append(name)
        problem = container_problem(c)
        if problem and not any(p.search(name) for p in ignore):
            down.append({"name": name, "problem": problem, "status": str(c.get("status") or "")})
    problems += [f"{c['name']}: {c['problem']}" for c in down]

    notif = data.get("notifications") or {}
    alerts = [{"id": str(n.get("id") or ""), "importance": str(n.get("importance") or ""), "title": n.get("title") or "",
               "subject": n.get("subject") or "", "description": n.get("description") or "", "timestamp": n.get("timestamp") or ""}
              for n in notif.get("warningsAndAlerts") or []]
    problems += [f"Unraid {a['importance'].lower()}: {a['subject'] or a['title']}" for a in alerts]

    temps = [d["temp"] for d in disks if isinstance(d["temp"], (int, float))]
    pools = [d["pct"] for d in disks if d["kind"] == "pool" and d["pct"] is not None]
    info = data.get("info") or {}
    metrics = data.get("metrics") or {}
    return {
        "host": (info.get("os") or {}).get("hostname") or "",
        "version": ((info.get("versions") or {}).get("core") or {}).get("unraid") or "",
        "up_since": (info.get("os") or {}).get("uptime") or "",
        "cpu_pct": round(_num((metrics.get("cpu") or {}).get("percentTotal")), 1),
        "ram_pct": round(_num((metrics.get("memory") or {}).get("percentTotal")), 1),
        "array": {"state": state, "pct": _pct(kb.get("used"), kb.get("total")),
                  "free_gb": round(_num(kb.get("free")) / 1e6, 1), "total_gb": round(_num(kb.get("total")) / 1e6, 1)},
        "parity": {"status": par.get("status") or "", "errors": int(_num(par.get("errors"))), "date": par.get("date") or "",
                   "running": bool(par.get("running")), "progress": int(_num(par.get("progress")))},
        "disks": disks,
        "disk_temp": max(temps) if temps else None,
        "pool_pct": max(pools) if pools else None,
        "containers": {"total": total, "running": running, "down": down, "updates": sorted(updates)},
        "alerts": alerts,
        "problems": problems,
    }


def cert_days(hostport: str, timeout: float = 5) -> dict:
    """{'host', 'days', 'error'}: days left on the certificate a TLS endpoint serves. error is
    'unreachable' (says nothing about the certificate) or why the certificate was refused."""
    host, _, port = hostport.rpartition(":")
    if not host:
        host, port = hostport, "443"
    out = {"host": hostport, "days": None, "error": ""}
    try:
        with socket.create_connection((host, int(port)), timeout=timeout) as sock:
            with tls_context().wrap_socket(sock, server_hostname=host) as s:
                out["days"] = round((ssl.cert_time_to_seconds(s.getpeercert()["notAfter"]) - time.time()) / 86400, 1)
    except ssl.SSLCertVerificationError as e:
        out["error"] = e.verify_message or "certificate refused"
    except (OSError, ValueError):
        out["error"] = "unreachable"
    return out


def check_certs(conf: dict) -> list[dict]:
    return [cert_days(h) for h in conf.get("certs") or []]


def collect(conf: dict | None = None, certs: bool = True) -> dict:
    """The whole snapshot: {'ok', 'configured', 'reachable', 'error', ...summarize(), 'certs': [...]}."""
    conf = conf or load_conf()
    if not conf:
        return {"ok": False, "configured": False, "reachable": False, "error": f"no {CONF} (barch nas setup)"}
    out: dict = {"ok": True, "configured": True, "reachable": True, "error": "", "url": conf["url"]}
    try:
        out.update(summarize(graphql(conf), conf))
    except NasError as e:
        out.update(ok=False, reachable=False, error=str(e), problems=[f"the NAS does not answer: {e}"])
    if certs:
        out["certs"] = check_certs(conf)
        out.setdefault("problems", [])
        out["problems"] += [f"certificate of {c['host']}: {c['error']}" for c in out["certs"] if c["error"] not in ("", "unreachable")]
    return out


# ---------------------------------------------------------------- what events.py samples

def metrics(s: dict) -> list[tuple[str, float]]:
    """The snapshot as metric rows (nas.*, cert.days) for metrics.db; a reachable snapshot only."""
    rows: list[tuple[str, float]] = []

    def add(name, value):
        if value is not None:
            rows.append((name, float(value)))

    add("nas.cpu.pct", s.get("cpu_pct"))
    add("nas.ram.pct", s.get("ram_pct"))
    add("nas.array.pct", (s.get("array") or {}).get("pct"))
    add("nas.pool.pct", s.get("pool_pct"))
    add("nas.disk.temp", s.get("disk_temp"))
    add("nas.disks.bad", sum(1 for d in s.get("disks") or [] if not d["ok"]))
    c = s.get("containers") or {}
    add("nas.containers.down", len(c.get("down") or []))
    add("nas.containers.updates", len(c.get("updates") or []))
    add("nas.alerts", len(s.get("alerts") or []))
    days = [x["days"] for x in s.get("certs") or [] if x["days"] is not None]
    if days:
        add("cert.days", min(days))
    return rows


def _join(parts: list[str], limit: int = 3) -> str:
    return " · ".join(parts[:limit]) + (f" (+{len(parts) - limit})" if len(parts) > limit else "")


def changes(s: dict, st: dict, now: float, grace: float = 900, cert_warn_days: float = 10) -> list[tuple[str, dict]]:
    """What a reachable snapshot holds that `st` has not reported yet, as (event, data) pairs; `st`
    (kept by the caller between samples) is brought up to date. One event per kind and sample, since
    a rule's cooldown would drop the second of two fired together; `text` (Portuguese, like the rules'
    notifications) says it all in one line.

      nas.array       state, previous                the array left or came back to STARTED
      nas.disk        names, count, text             a disk stopped being DISK_OK or counted errors
      nas.containers  names, count, text             down for longer than `grace` (a restart, an update
                                                     and the nightly backup stop them for a while)
      nas.alert       importance, count, text        Unraid's own unread warnings and alerts
      cert.expiring   hosts, count, days, text       under `cert_warn_days`, again under 3, or refused
    """
    out: list[tuple[str, dict]] = []

    state = s["array"]["state"]
    previous = st.get("array")
    if previous != state and (previous is not None or state != "STARTED"):
        out.append(("nas.array", {"state": state, "previous": previous or ""}))
    st["array"] = state

    sigs = {d["name"]: f"{d['status']}/{d['errors']}" for d in s["disks"] if not d["ok"]}
    seen = st.get("disks") or {}
    new = [d for d in s["disks"] if not d["ok"] and seen.get(d["name"]) != sigs[d["name"]]]
    if new:
        out.append(("nas.disk", {"names": ", ".join(d["name"] for d in new), "count": len(new), "text": _join(
            [f"{d['name']} ({d['device']}): {d['status'].removeprefix('DISK_')}" + (f", {d['errors']} erros" if d["errors"] else "") for d in new])}))
    st["disks"] = sigs

    bad = {c["name"]: c for c in s["containers"]["down"]}
    since = {n: t for n, t in (st.get("bad") or {}).items() if n in bad}
    for n in bad:
        since.setdefault(n, now)
    reported = [n for n in st.get("reported") or [] if n in bad]
    due = [n for n in bad if n not in reported and now - since[n] >= grace]
    if due:
        words = {"stopped": "parado", "crashed": "caiu", "restarting": "reiniciando em laço", "unhealthy": "sem saúde"}
        out.append(("nas.containers", {"names": ", ".join(due), "count": len(due), "text": _join(
            [f"{n}: {words.get(bad[n]['problem'], bad[n]['problem'])} ({bad[n]['status']})" for n in due])}))
    st["bad"], st["reported"] = since, reported + due

    known = set(st.get("alerts") or [])
    for importance in ("ALERT", "WARNING"):
        fresh = [a for a in s["alerts"] if a["importance"] == importance and a["id"] not in known]
        if fresh:
            out.append(("nas.alert", {"importance": importance, "count": len(fresh), "text": _join(
                [(a["subject"] or a["title"]) + (f": {a['description']}" if a["description"] else "") for a in fresh])[:400]}))
    st["alerts"] = sorted(known | {a["id"] for a in s["alerts"]})[-300:]

    rank = {"": 0, "soon": 1, "days": 2, "refused": 3}
    warned = dict(st.get("certs") or {})
    hits = []
    for c in s.get("certs") or []:
        if c["error"] == "unreachable":
            continue
        level = "refused" if c["error"] else "days" if c["days"] < 3 else "soon" if c["days"] < cert_warn_days else ""
        if rank[level] > rank.get(warned.get(c["host"], ""), 0):
            hits.append(c)
        if level:
            warned[c["host"]] = level
        else:
            warned.pop(c["host"], None)
    if hits:
        days = [c["days"] for c in hits if c["days"] is not None]
        out.append(("cert.expiring", {"hosts": ", ".join(c["host"] for c in hits), "count": len(hits),
                                      "days": round(min(days)) if days else 0, "text": _join(
            [f"{c['host'].removesuffix(':443')}: " + (f"recusado ({c['error']})" if c["error"] else f"vence em {c['days']:.0f} dias") for c in hits])}))
    if "certs" in s:
        st["certs"] = warned
    return out


# ---------------------------------------------------------------- CLI

def text(s: dict) -> str:
    if not s.get("configured"):
        return "nas: " + s["error"]
    lines = []
    if s.get("reachable"):
        a, p, c = s["array"], s["parity"], s["containers"]
        lines.append(f"nas: {s['host']} · Unraid {s['version']} · up since {s['up_since'][:10]} · cpu {s['cpu_pct']:.0f}% ram {s['ram_pct']:.0f}%")
        lines.append(f"array: {a['state']} · {a['pct']}% used, {a['free_gb'] / 1000:.1f} TB free of {a['total_gb'] / 1000:.1f} TB"
                     f" · parity check {p['status']}" + (f" {p['progress']}%" if p["running"] else f" {p['date'][:10]}, {p['errors']} errors"))
        bad = [d for d in s["disks"] if not d["ok"]]
        lines.append(f"disks: {len(s['disks']) - len(bad)} ok" + (f", hottest {s['disk_temp']} °C" if s["disk_temp"] is not None else "")
                     + "".join(f"\n  {d['name']} ({d['device']}): {d['status']}, {d['errors']} errors" for d in bad))
        lines.append("pools: " + " · ".join(f"{d['name']} {d['pct']}%" for d in s["disks"] if d["kind"] == "pool"))
        lines.append(f"containers: {c['running']} running of {c['total']}"
                     + (f" · update available: {', '.join(c['updates'])}" if c["updates"] else "")
                     + "".join(f"\n  {d['name']}: {d['problem']} ({d['status']})" for d in c["down"]))
        lines.append("unraid notifications: " + (" · ".join(f"[{a['importance'].lower()}] {a['subject'] or a['title']}" for a in s["alerts"]) or "none unread"))
    else:
        lines.append(f"nas: not reachable at {s.get('url', '?')} ({s['error']})")
    if s.get("certs"):
        lines.append("certificates: " + " · ".join(
            f"{c['host'].removesuffix(':443')} " + (f"{c['days']:.0f} d" if c["days"] is not None else c["error"]) for c in s["certs"]))
    lines.append("problems: " + ("; ".join(s.get("problems") or []) or "none"))
    return "\n".join(lines)


def setup() -> int:
    if load_conf():
        print(f"nas: {CONF} already has a URL and a key; nothing changed")
        return 0
    try:
        m = re.search(r"type:\s*unraid\s*\n\s*url:\s*(\S+)\s*\n\s*key:\s*(\S+)", HOMEPAGE.read_text())
    except OSError as e:
        m = None
        print(f"nas: {HOMEPAGE}: {e.strerror}", file=sys.stderr)
    if not m:
        print(f"nas: no Unraid widget in {HOMEPAGE}. Write {CONF} by hand:\n"
              '  {"url": "https://<unraid>:<port>", "key": "<API key: Unraid Settings → Management Access → API keys>"}', file=sys.stderr)
        return 1
    url = m.group(1).strip("'\"").rstrip("/")
    conf = {"url": url, "key": m.group(2).strip("'\""),
            "certs": [re.sub(r"^https?://", "", url)] + DEFAULT_CERTS, "ignore_containers": []}
    CONF.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(CONF, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(conf, f, indent=2)
        f.write("\n")
    print(f"nas: {CONF} written (URL and API key from Homepage's Unraid widget, {len(conf['certs'])} certificates watched)")
    return 0


def main(argv: list[str]) -> int:
    cmd = argv[0] if argv else "status"
    if cmd == "setup":
        return setup()
    if cmd != "status":
        print(__doc__, file=sys.stderr)
        return 2
    s = collect(certs="--no-certs" not in argv)
    print(json.dumps(s, ensure_ascii=False) if "--json" in argv else text(s))
    return 0 if s.get("reachable") else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
