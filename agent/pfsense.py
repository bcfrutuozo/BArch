#!/usr/bin/env python3
"""barch fw: the two pfSense firewalls (omni, chaos) as this desktop sees them. Read only.

Asks each firewall's REST API (the pfSense-pkg-RESTAPI v2 package, `X-API-Key`) for the system load,
the gateways, the interfaces, the IPsec tunnel, the DHCP leases and the firewall log, and checks that
pfBlockerNG's DNSBL still answers (a real DNS query of a domain the lists block, which must come back
as the DNSBL virtual IP). events.py samples it (`sample_fw`) into metrics and events: a gateway or the
tunnel going down, a reboot, the DNSBL gone, and a device never seen before taking a lease (the
"new client on the IoT network" notification). `barch fw status` prints the same snapshot.

    pfsense.py status [site] [--json]     the snapshot now (every site, or one)
    pfsense.py clients [site] [--json]    the DHCP leases with who is online, by interface
    pfsense.py blocked [site] [n]         the last blocked connections, from the firewall log
    pfsense.py setup                      what ~/.config/barch/pfsense.json must hold and how to make the keys

~/.config/barch/pfsense.json (mode 600, never in the repo):
    {"sites": {"omni": {"url": "https://fw-home.example.net", "key": "<API key>", "dns": "100.100.0.1"},
               "chaos": {"url": "https://fw-remote.example.net", "key": "<API key>", "dns": "100.100.1.1"}},
     "dnsbl_probe": "doubleclick.net",    a domain every firewall's DNSBL blocks
     "dnsbl_vip": "100.99.0.1",           what the DNSBL answers for it (Firewall → pfBlockerNG → DNSBL → Virtual IP)
     "ignore_macs": ["^02:"]}             regexes on MACs that never count as a new client (randomized ones, say)

The API's login protection bans an address after a few refused keys, so a key that answers 401/403 is
not tried again for an hour (`fw.auth` says so once); never probe with guessed keys.
"""
from __future__ import annotations

import http.client
import ipaddress
import json
import os
import random
import re
import socket
import ssl
import struct
import sys
import time
import urllib.parse
from pathlib import Path

CONF = Path(os.environ.get("BARCH_FW_CONF", Path.home() / ".config/barch/pfsense.json"))
DEFAULT_PROBE = "doubleclick.net"
DEFAULT_VIP = "100.99.0.1"
LOG_TAIL = 3000           # firewall log lines read per sample (it rotates at 500 KB, a few minutes of a chatty log)

# what one sample asks, in this order; `optional` ones only lose their part of the snapshot when the
# key lacks that privilege (the answer says which), a 401/403 on the first one is an auth failure
ENDPOINTS = [
    ("system", "/api/v2/status/system", ""),
    ("version", "/api/v2/system/version", ""),
    ("gateways", "/api/v2/status/gateways", ""),
    ("interfaces", "/api/v2/status/interfaces", ""),
    ("ipsec", "/api/v2/status/ipsec/child_sas", ""),
    ("sas", "/api/v2/status/ipsec/sas", ""),                  # child SAs come nested here on 2.9 (child_sas is empty)
    ("leases", "/api/v2/status/dhcp_server/leases", ""),
    ("log", "/api/v2/status/logs/firewall", f"limit={LOG_TAIL}"),   # the last N lines of the log, oldest first
]
# the privilege each one needs (System → User Manager → the user's Effective Privileges)
PRIVILEGES = ["api-v2-status-system-get", "api-v2-system-version-get", "api-v2-status-gateways-get",
              "api-v2-status-interfaces-get", "api-v2-status-ipsec-child-sas-get", "api-v2-status-ipsec-sas-get",
              "api-v2-status-dhcp-server-leases-get", "api-v2-status-logs-firewall-get"]   # one per ENDPOINTS row


class FwError(Exception):
    def __init__(self, msg: str, code: int = 0):
        super().__init__(msg)
        self.code = code


def load_conf() -> dict | None:
    try:
        c = json.loads(CONF.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    sites = {k: v for k, v in (c.get("sites") or {}).items() if isinstance(v, dict) and v.get("url") and v.get("key")}
    if not sites:
        return None
    c["sites"] = sites
    return c


# ---------------------------------------------------------------- the API

class _IPv4HTTPSConnection(http.client.HTTPSConnection):
    """Connects over IPv4 when the name has an A record (the firewalls' names also have the LAN's
    delegated IPv6, which changes with the ISP's prefix and is not in the API's access list), still
    verifying the certificate against the name."""

    def connect(self):
        try:
            addr = socket.getaddrinfo(self.host, self.port, socket.AF_INET, socket.SOCK_STREAM)[0][4]
        except (socket.gaierror, IndexError):
            addr = (self.host, self.port)
        sock = socket.create_connection(addr, self.timeout)
        self.sock = self._context.wrap_socket(sock, server_hostname=self.host)


def api(site: dict, path: str, query: str = "", timeout: float = 10):
    u = urllib.parse.urlsplit(site["url"].rstrip("/"))
    if u.scheme != "https" or not u.hostname:
        raise FwError(f"the URL must be https://<host>: {site['url']}")
    conn = _IPv4HTTPSConnection(u.hostname, u.port or 443, timeout=timeout, context=ssl.create_default_context())
    try:
        conn.request("GET", u.path + path + (f"?{query}" if query else ""),
                     headers={"x-api-key": site["key"], "accept": "application/json"})
        r = conn.getresponse()
        body = r.read().decode(errors="replace")
    except (OSError, http.client.HTTPException, ValueError) as e:
        raise FwError(str(getattr(e, "reason", e))) from e
    finally:
        conn.close()
    try:
        d = json.loads(body)
    except json.JSONDecodeError:
        raise FwError(f"HTTP {r.status}: not a JSON answer" + ("" if r.status == 200 else f" ({body[:80]!r})"), r.status) from None
    if r.status != 200 or d.get("code") not in (None, 200):
        code = int(d.get("code") or r.status)
        msg = str(d.get("message") or d.get("response_id") or "")[:120]
        raise FwError(f"HTTP {code}" + (f": {msg}" if msg else "") + (" (the API key was refused)" if code in (401, 403) else ""), code)
    return d.get("data")


def fetch(site: dict) -> dict:
    """Every endpoint's answer, as {name: data}; `errors` holds the ones that failed on their own
    (a missing privilege answers 403 on that endpoint only, after the first one succeeded)."""
    out: dict = {"errors": {}}
    for i, (name, path, query) in enumerate(ENDPOINTS):
        try:
            out[name] = api(site, path, query)
        except FwError as e:
            if i == 0 or e.code in (0, 404, 500, 502, 503, 504):
                raise
            out["errors"][name] = f"no privilege ({PRIVILEGES[i]})" if e.code == 403 else str(e)
    return out


def dns_query(server: str, name: str, timeout: float = 3) -> list[str] | None:
    """The A records `server` answers for `name` (an empty list for a name without any), None when
    it does not answer. A raw UDP query: no resolver library, nothing cached."""
    qid = random.randint(0, 65535)
    qname = b"".join(bytes([len(p)]) + p.encode() for p in name.strip(".").split(".")) + b"\0"
    pkt = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0) + qname + struct.pack(">HH", 1, 1)
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.settimeout(timeout)
            s.sendto(pkt, (server, 53))
            r, _ = s.recvfrom(1024)
    except OSError:
        return None
    try:
        if struct.unpack(">H", r[:2])[0] != qid:
            return None
        an = struct.unpack(">H", r[6:8])[0]
        i = 12
        while r[i] != 0:
            i += r[i] + 1
        i += 5
        ips = []
        for _ in range(an):
            if r[i] & 0xC0 == 0xC0:
                i += 2
            else:
                while r[i] != 0:
                    i += r[i] + 1
                i += 1
            t, _c, _ttl, rl = struct.unpack(">HHIH", r[i:i + 10])
            i += 10
            if t == 1 and rl == 4:
                ips.append(".".join(map(str, r[i:i + 4])))
            i += rl
        return ips
    except (struct.error, IndexError):
        return None


def dnsbl_check(server: str, probe: str, vip: str) -> bool | None:
    """True when the firewall's resolver answers the DNSBL virtual IP for a blocked domain, False
    when it answers something else (the DNSBL is off or the domain left the lists), None when the
    resolver does not answer (says nothing about the DNSBL)."""
    ips = dns_query(server, probe)
    if ips is None:
        return None
    return vip in ips


# ---------------------------------------------------------------- the snapshot (pure)

def _num(v) -> float:
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0


def _is_ip(v) -> bool:
    try:
        ipaddress.ip_address(str(v))
        return True
    except ValueError:
        return False


def uptime_seconds(s: str) -> int | None:
    """'3 Days 04 Hours 12 Minutes 07 Seconds' (what the API gives) as seconds; None when unreadable."""
    units = {"day": 86400, "hour": 3600, "minute": 60, "second": 1}
    total, found = 0, False
    for n, unit in re.findall(r"(\d+)\s*(day|hour|minute|second)s?", str(s), re.I):
        total += int(n) * units[unit.lower()]
        found = True
    return total if found else None


# filterlog line, BSD format "Nov  7 17:00:19 omni filterlog[74491]: <csv>" or RFC 5424 (what 2.9 writes)
# "<134>1 2026-11-07T18:13:14.911345-03:00 fw-home.example.net filterlog 74491 - - <csv>";
# csv: rulenr,subrulenr,anchor,tracker,realint,reason,act,dir,ipver,... then for IPv4
# tos,ecn,ttl,id,offset,flags,proto-id,proto-name,length,src,dst,[srcport,dstport,...]
LOGLINE = re.compile(r"filterlog(?:\[\d+\]:|\s+\d+\s+-\s+-)\s*(?P<csv>.+)$")
STAMP = re.compile(r"^(?:<\d+>\d\s+)?(?:(?P<bsd>\w{3}\s+\d+\s+\d\d:\d\d:\d\d)|(?P<iso>\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:[+-]\d\d:?\d\d|Z)))")


def parse_log_line(text: str) -> dict | None:
    """One firewall log line as {stamp, tracker, interface, action, dir, proto, src, dst, sport, dport};
    None for anything that is not a filterlog line."""
    m = LOGLINE.search(text)
    if not m:
        return None
    f = m.group("csv").split(",")
    if len(f) < 9:
        return None
    st = STAMP.match(text)
    row = {"stamp": (st.group("bsd") or st.group("iso")) if st else "", "tracker": f[3], "interface": f[4],
           "reason": f[5], "action": f[6], "dir": f[7], "proto": "", "src": "", "dst": "", "sport": "", "dport": ""}
    try:
        if f[8] == "4" and len(f) >= 20:
            row.update(proto=f[16], src=f[18], dst=f[19])
            if f[16] in ("tcp", "udp") and len(f) >= 22:
                row.update(sport=f[20], dport=f[21])
        elif f[8] == "6" and len(f) >= 17:          # class, flow, hop limit, proto name, proto id, length, src, dst
            row.update(proto=f[12], src=f[15], dst=f[16])
            if f[12] in ("tcp", "udp") and len(f) >= 19:
                row.update(sport=f[17], dport=f[18])
    except IndexError:
        pass
    return row


def blocked_since(lines: list[str], cursor: str) -> tuple[list[dict], str]:
    """The connections a rule blocked (action block, reason match: not the out-of-state noise) in
    `lines` (oldest first) newer than `cursor`, the stamp of the last line counted at the previous
    sample ('' counts nothing and only sets the cursor, so a fresh start does not report the whole
    log as new). Stamps are RFC 3339 on 2.9, so they compare as text; with the BSD format (no year)
    the cursor is the whole last line and only what follows it counts. Returns (rows, new cursor)."""
    if not lines:
        return [], cursor
    parsed = [parse_log_line(t) for t in lines]
    stamps = [r["stamp"] for r in parsed if r and r["stamp"]]
    iso = bool(stamps) and all(s[:4].isdigit() for s in stamps)
    if not cursor:
        return [], (stamps[-1] if iso and stamps else lines[-1])
    rows = []
    if iso:
        for r in parsed:
            if r and r["stamp"] > cursor and r["action"] == "block" and r["reason"] == "match":
                rows.append(r)
        return rows, max(stamps[-1], cursor) if stamps else cursor
    try:
        start = lines.index(cursor) + 1
    except ValueError:
        start = 0                       # the cursor line rotated out: the whole buffer is new
    for r in parsed[start:]:
        if r and r["action"] == "block" and r["reason"] == "match":
            rows.append(r)
    return rows, lines[-1]


def summarize(raw: dict, site: str, ifnames: dict[str, str] | None = None) -> dict:
    """One firewall's answers as the snapshot everything else reads. Pure: no I/O. `ifnames` maps
    the real interface (em5.20) to its description when the log should say IOT instead."""
    sysinfo = raw.get("system") or {}
    gws = []
    for g in raw.get("gateways") or []:
        status = str(g.get("status") or "")
        gws.append({"name": g.get("name") or "?", "status": status, "rtt": round(_num(g.get("delay")), 1),
                    "loss": round(_num(g.get("loss")), 1), "monitor": g.get("monitorip") or "",
                    "ok": status.lower() in ("online", "none")})
    ifaces, names = [], {}
    for i in raw.get("interfaces") or []:          # only the assigned ones are listed; `enable` is not reliable
        status = str(i.get("status") or "")
        row = {"name": i.get("name") or "?", "descr": i.get("descr") or i.get("name") or "?", "hwif": i.get("hwif") or "",
               "status": status, "ip": i.get("ipaddr") or "", "media": i.get("media") or "",
               "inerrs": int(_num(i.get("inerrs"))), "outerrs": int(_num(i.get("outerrs"))), "up": status.lower() == "up"}
        ifaces.append(row)
        names[row["hwif"]] = row["descr"]
        names[row["name"]] = row["descr"]
    names.update(ifnames or {})
    tunnels: dict[str, dict] = {}
    children = list(raw.get("ipsec") or [])
    for sa in raw.get("sas") or []:                    # 2.9 nests the child SAs under each IKE SA
        for c in sa.get("child_sas") or []:
            children.append({**c, "name": c.get("name") or sa.get("con_id") or sa.get("name")})
    for c in children:
        name = str(c.get("name") or "?")
        t = tunnels.setdefault(name, {"name": name, "up": False, "local": [], "remote": [], "bytes_in": 0, "bytes_out": 0})
        if str(c.get("state") or "").upper() == "INSTALLED":
            t["up"] = True
            t["bytes_in"] += int(_num(c.get("bytes_in")))
            t["bytes_out"] += int(_num(c.get("bytes_out")))
            for k in ("local", "remote"):
                for ts in c.get(f"{k}_ts") or []:
                    if ts not in t[k]:
                        t[k].append(ts)
    nets = [(ipaddress.ip_network(f"{i.get('ipaddr')}/{i.get('subnet') or 24}", strict=False), i.get("descr") or i.get("name"))
            for i in raw.get("interfaces") or [] if i.get("ipaddr") and _is_ip(i.get("ipaddr"))]

    def iface_of(ip: str, given: str) -> str:
        if given:
            return names.get(given, given)
        if _is_ip(ip):
            for net, descr in nets:
                if ipaddress.ip_address(ip) in net:
                    return descr
        return "?"

    clients = []
    for l in raw.get("leases") or []:
        mac = str(l.get("mac") or "").lower()
        if not mac:
            continue
        clients.append({"mac": mac, "ip": l.get("ip") or "", "hostname": l.get("hostname") or "", "if": l.get("if") or "",
                        "ifdescr": iface_of(l.get("ip") or "", l.get("if") or ""),
                        "online": "online" in str(l.get("online_status") or "").lower(),     # "active/online"
                        "active": str(l.get("active_status") or "").lower() in ("active", "static"),
                        "static": str(l.get("active_status") or "").lower() == "static"})
    log = [str(x.get("text") or "") for x in raw.get("log") or [] if isinstance(x, dict)]
    blocked: dict[str, int] = {}
    for r in (parse_log_line(t) for t in log):
        if r and r["action"] == "block" and r["reason"] == "match":
            n = names.get(r["interface"], r["interface"])
            blocked[n] = blocked.get(n, 0) + 1
    problems = [f"gateway {g['name']}: {g['status']}" + (f", {g['loss']:.0f}% loss" if g["loss"] else "") for g in gws if not g["ok"]]
    problems += [f"interface {i['descr']}: {i['status']}" for i in ifaces if not i["up"]]
    problems += [f"IPsec {t['name']}: down" for t in tunnels.values() if not t["up"]]
    # an endpoint the key may not read is said in `errors` (and by `barch fw status`), not as a problem
    problems += [f"{k}: {v}" for k, v in (raw.get("errors") or {}).items() if "403" not in str(v) and "no privilege" not in str(v)]
    return {
        "site": site,
        "version": str((raw.get("version") or {}).get("version") or ""),
        "uptime": str(sysinfo.get("uptime") or ""),
        "uptime_s": uptime_seconds(sysinfo.get("uptime") or ""),
        "cpu_pct": round(_num(sysinfo.get("cpu_usage")), 1),
        "ram_pct": round(_num(sysinfo.get("mem_usage")), 1),
        "disk_pct": round(_num(sysinfo.get("disk_usage")), 1),
        "temp": sysinfo.get("temp_c") if isinstance(sysinfo.get("temp_c"), (int, float)) and sysinfo.get("temp_c") else None,
        "gateways": gws,
        "interfaces": ifaces,
        "ipsec": list(tunnels.values()),
        "clients": clients,
        "clients_online": sum(1 for c in clients if c["online"]),
        "log": log,
        "log_lines": len(log),
        "blocked": blocked,                       # by interface, in the log lines read (not per sample)
        "ifnames": names,
        "errors": dict(raw.get("errors") or {}),
        "problems": problems,
    }


def collect_site(site: str, conf: dict, probe: str, vip: str) -> dict:
    """{'ok', 'reachable', 'auth', 'error', ...summarize(), 'dnsbl'}. `auth` False means the key was
    refused: the caller must not retry for a while."""
    s = conf["sites"][site]
    out: dict = {"site": site, "ok": True, "reachable": True, "auth": True, "error": "", "url": s["url"]}
    try:
        out.update(summarize(fetch(s), site))
    except FwError as e:
        out.update(ok=False, reachable=False, auth=e.code not in (401, 403), error=str(e),
                   problems=[f"{site} does not answer: {e}"])
        return out
    dns = s.get("dns") or ""
    if not dns:                                 # the firewall itself, over IPv4 (the name also has an IPv6)
        try:
            dns = socket.getaddrinfo(urllib.parse.urlsplit(s["url"]).hostname, 53, socket.AF_INET, socket.SOCK_DGRAM)[0][4][0]
        except (socket.gaierror, IndexError, TypeError):
            dns = ""
    out["dnsbl"] = dnsbl_check(dns, probe, vip) if dns else None
    if out["dnsbl"] is False:
        out["problems"].append(f"DNSBL: {probe} is not blocked ({dns} answers the real address)")
    out["ok"] = not out["problems"]
    return out


def collect(conf: dict | None = None, only: str | None = None) -> dict:
    """Every site: {'configured', 'sites': {name: collect_site()}}."""
    conf = conf or load_conf()
    if not conf:
        return {"configured": False, "sites": {}, "error": f"no {CONF} (barch fw setup)"}
    probe, vip = conf.get("dnsbl_probe") or DEFAULT_PROBE, conf.get("dnsbl_vip") or DEFAULT_VIP
    names = [only] if only else list(conf["sites"])
    if only and only not in conf["sites"]:
        return {"configured": True, "sites": {}, "error": f"no site '{only}' in {CONF} ({', '.join(conf['sites'])})"}
    return {"configured": True, "error": "", "sites": {n: collect_site(n, conf, probe, vip) for n in names}}


# ---------------------------------------------------------------- what events.py samples

def _key(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", s.lower()).strip("_") or "x"


def metrics(s: dict) -> list[tuple[str, float]]:
    """A reachable site's snapshot as metric rows: fw.<site>.cpu.pct, ram.pct, temp, clients, ipsec.up,
    dnsbl, gw.<name>.rtt / loss (gateways with a monitor), and blocked / blocked.<interface> only once
    `blocked_since` ran (the caller adds those)."""
    site = _key(s["site"])
    rows: list[tuple[str, float]] = [(f"fw.{site}.cpu.pct", s["cpu_pct"]), (f"fw.{site}.ram.pct", s["ram_pct"]),
                                     (f"fw.{site}.clients", float(s["clients_online"]))]
    if s.get("temp") is not None:
        rows.append((f"fw.{site}.temp", float(s["temp"])))
    for g in s["gateways"]:
        if g["monitor"] and g["monitor"] != "none":
            rows.append((f"fw.{site}.gw.{_key(g['name'])}.rtt", g["rtt"]))
            rows.append((f"fw.{site}.gw.{_key(g['name'])}.loss", g["loss"]))
    if s["ipsec"]:
        rows.append((f"fw.{site}.ipsec.up", 1.0 if all(t["up"] for t in s["ipsec"]) else 0.0))
    if s.get("dnsbl") is not None:
        rows.append((f"fw.{site}.dnsbl", 1.0 if s["dnsbl"] else 0.0))
    return rows


def _join(parts: list[str], limit: int = 3) -> str:
    return " · ".join(parts[:limit]) + (f" (+{len(parts) - limit})" if len(parts) > limit else "")


def changes(s: dict, st: dict, now: float, ignore_macs: list[str] | None = None) -> tuple[list[tuple[str, dict]], list[tuple[str, float]]]:
    """What a reachable snapshot holds that `st` (this site's state, kept by the caller) has not
    reported yet, as (event, data) pairs, plus the blocked-connection metrics of this sample; `st`
    is brought up to date. Every event carries `site` and a one-line `text` in Portuguese.

      fw.boot      uptime                  the firewall rebooted (uptime went down)
      fw.gateway   name, status, ok        a gateway left or came back to online
      fw.interface name, status, up        an enabled interface went down or came back
      fw.ipsec     name, up                the tunnel's child SA left or came back to INSTALLED
      fw.dnsbl     ok                      the DNSBL stopped (or started again) answering its VIP
      fw.client    mac, ip, hostname, if   a MAC never seen on this site took a lease (the first
                                           sample only learns what is there, and says nothing)
    """
    site = s["site"]
    key = _key(site)
    out: list[tuple[str, dict]] = []
    first = not st.get("seen")

    up = s.get("uptime_s")
    prev_up, prev_at = st.get("uptime_s"), st.get("uptime_at")
    if up is not None and prev_up is not None and prev_at is not None and up < prev_up + (now - prev_at) - 600:
        out.append(("fw.boot", {"site": site, "uptime": s["uptime"], "text": f"O pfSense {site} reiniciou (ligado há {s['uptime']})."}))
    if up is not None:
        st["uptime_s"], st["uptime_at"] = up, now

    gw_prev = st.get("gateways") or {}
    gw_now = {g["name"]: g["ok"] for g in s["gateways"]}
    for g in s["gateways"]:
        if g["name"] in gw_prev and gw_prev[g["name"]] != g["ok"] or (first and not g["ok"]):
            out.append(("fw.gateway", {"site": site, "name": g["name"], "status": g["status"], "ok": "yes" if g["ok"] else "no",
                                       "text": f"Gateway {g['name']} do {site}: {g['status']}" + ("" if g["ok"] else f" ({g['loss']:.0f}% de perda, {g['rtt']:.0f} ms)")}))
    st["gateways"] = gw_now

    if_prev = st.get("interfaces") or {}
    if_now = {i["descr"]: i["up"] for i in s["interfaces"]}
    for i in s["interfaces"]:
        if i["descr"] in if_prev and if_prev[i["descr"]] != i["up"] or (first and not i["up"]):
            out.append(("fw.interface", {"site": site, "name": i["descr"], "status": i["status"], "up": "yes" if i["up"] else "no",
                                         "text": f"Interface {i['descr']} do {site}: {i['status']}"}))
    st["interfaces"] = if_now

    ip_prev = st.get("ipsec") or {}
    ip_now = {t["name"]: t["up"] for t in s["ipsec"]}
    for t in s["ipsec"]:
        if t["name"] in ip_prev and ip_prev[t["name"]] != t["up"] or (first and not t["up"]):
            out.append(("fw.ipsec", {"site": site, "name": t["name"], "up": "yes" if t["up"] else "no",
                                     "text": f"Túnel IPsec {t['name']} do {site}: " + ("de volta" if t["up"] else "caiu")}))
    st["ipsec"] = ip_now

    dnsbl = s.get("dnsbl")
    if dnsbl is not None:
        prev = st.get("dnsbl")
        if (prev is not None and prev != dnsbl) or (prev is None and dnsbl is False):
            out.append(("fw.dnsbl", {"site": site, "ok": "yes" if dnsbl else "no",
                                     "text": f"DNSBL do {site}: " + ("voltou a bloquear" if dnsbl else "não está bloqueando (pfBlockerNG parado ou desligado)")}))
        st["dnsbl"] = dnsbl

    ignore = [re.compile(p, re.I) for p in ignore_macs or []]
    seen = set(st.get("seen") or [])
    fresh = [c for c in s["clients"] if c["mac"] not in seen and not any(p.search(c["mac"]) for p in ignore)]
    if not first:
        for c in fresh:
            out.append(("fw.client", {"site": site, "mac": c["mac"], "ip": c["ip"], "hostname": c["hostname"] or "sem nome",
                                      "if": c["ifdescr"], "online": "yes" if c["online"] else "no",
                                      "text": f"Aparelho novo na rede {c['ifdescr']} do {site}: {c['hostname'] or 'sem nome'} ({c['ip']}, {c['mac']})"}))
    st["seen"] = sorted(seen | {c["mac"] for c in s["clients"]})[-2000:]

    had_cursor = bool(st.get("log_cursor"))
    rows, st["log_cursor"] = blocked_since(s.get("log") or [], st.get("log_cursor") or "")
    counts: dict[str, int] = {}
    for r in rows:
        name = s["ifnames"].get(r["interface"], r["interface"])
        counts[name] = counts.get(name, 0) + 1
    mrows: list[tuple[str, float]] = [(f"fw.{key}.blocked", float(len(rows)))] if had_cursor else []
    mrows += [(f"fw.{key}.blocked.{_key(n)}", float(v)) for n, v in counts.items()]
    return out, mrows


# ---------------------------------------------------------------- CLI

def text(s: dict) -> str:
    if not s.get("reachable"):
        return f"{s['site']}: not reachable at {s.get('url', '?')} ({s['error']})" + ("" if s.get("auth", True) else " — the key was refused, not retried for an hour")
    lines = [f"{s['site']}: pfSense {s['version']} · up {s['uptime']} · cpu {s['cpu_pct']:.0f}% ram {s['ram_pct']:.0f}%"
             + (f" · {s['temp']:.0f} °C" if s.get("temp") is not None else "") + f" · {s['clients_online']} clients online"]
    lines.append("gateways: " + (" · ".join(f"{g['name']} {g['status']}" + (f" {g['rtt']:.0f} ms {g['loss']:.0f}% loss" if g["monitor"] not in ("", "none") else "") for g in s["gateways"]) or "none"))
    lines.append("interfaces: " + " · ".join(f"{i['descr']} {'up' if i['up'] else i['status']}" + (f" {i['ip']}" if i["ip"] else "") + (f" ({i['inerrs']}+{i['outerrs']} errors)" if i["inerrs"] or i["outerrs"] else "") for i in s["interfaces"]))
    lines.append("ipsec: " + (" · ".join(f"{t['name']} {'up' if t['up'] else 'DOWN'}" + (f" {', '.join(t['local'])} ↔ {', '.join(t['remote'])}" if t["up"] else "") for t in s["ipsec"]) or "none"))
    d = s.get("dnsbl")
    lines.append("dnsbl: " + ("blocking" if d else "NOT blocking" if d is False else "resolver did not answer"))
    by_if = s.get("blocked") or {}
    lines.append(f"log: {s.get('log_lines', 0)} lines read, {sum(by_if.values())} blocked" + (": " + " · ".join(f"{k} {v}" for k, v in sorted(by_if.items(), key=lambda kv: -kv[1])) if by_if else ""))
    if s.get("errors"):
        lines.append("not readable with this key: " + ", ".join(f"{k} ({v})" for k, v in s["errors"].items()))
    lines.append("problems: " + ("; ".join(s.get("problems") or []) or "none"))
    return "\n".join(lines)


def clients_text(s: dict) -> str:
    if not s.get("reachable"):
        return text(s)
    lines = [f"{s['site']}: {len(s['clients'])} leases, {s['clients_online']} online"]
    for ifd in sorted({c["ifdescr"] for c in s["clients"]}):
        lines.append(f"  {ifd}:")
        for c in sorted((c for c in s["clients"] if c["ifdescr"] == ifd), key=lambda c: [int(x) if x.isdigit() else 0 for x in c["ip"].split(".")]):
            lines.append(f"    {c['ip']:15} {c['mac']}  {'online ' if c['online'] else 'offline'}  {c['hostname']}")
    return "\n".join(lines)


def blocked_text(s: dict, n: int) -> str:
    if not s.get("reachable"):
        return text(s)
    rows = [r for r in (parse_log_line(x) for x in s.get("log") or []) if r and r["action"] == "block" and r["reason"] == "match"]
    lines = [f"{s['site']}: last {min(n, len(rows))} of {len(rows)} blocked connections in the log read"]
    for r in rows[-n:]:
        lines.append(f"  {r['stamp'][:19].replace('T', ' '):19} {s['ifnames'].get(r['interface'], r['interface']):10} {r['proto']:6} {r['src']}:{r['sport']} → {r['dst']}:{r['dport']}")
    return "\n".join(lines)


def setup() -> int:
    print(f"""barch fw: {CONF} {'exists' if CONF.exists() else 'does not exist'}.

On each pfSense (both run the REST API package, System → REST API):
  1. System → User Manager → Users → Add: username barch, a password, scope User. In "Effective
     Privileges" → Add, tick exactly these (filter the list by "api-v2"):
{chr(10).join('       ' + p for p in PRIVILEGES)}
     That user can read those seven things and nothing else; it cannot log in to the GUI pages.
  2. Log out, log in as barch, System → REST API → Keys → Add (name: desktop). The key is shown once.
  3. System → REST API → Settings: if "Access List" is on, add this desktop ({socket.gethostname()}) or
     100.100.0.0/24; the API's login protection bans an address after a few refused keys, so write
     the key right the first time.
Then write {CONF} (chmod 600):
  {{"sites": {{"omni": {{"url": "https://fw-home.example.net", "key": "<omni key>", "dns": "100.100.0.1"}},
             "chaos": {{"url": "https://fw-remote.example.net", "key": "<chaos key>", "dns": "100.100.1.1"}}}},
   "dnsbl_probe": "{DEFAULT_PROBE}", "dnsbl_vip": "{DEFAULT_VIP}", "ignore_macs": []}}
and run `barch fw status`. barch-events picks it up by itself (fw_every_s in agent/rules.json).""")
    return 0 if load_conf() else 1


def main(argv: list[str]) -> int:
    args = [a for a in argv if not a.startswith("--")]
    as_json = "--json" in argv
    cmd = args[0] if args else "status"
    if cmd == "setup":
        return setup()
    if cmd not in ("status", "clients", "blocked"):
        print(__doc__, file=sys.stderr)
        return 2
    site = args[1] if len(args) > 1 and not args[1].isdigit() else None
    n = int(args[-1]) if cmd == "blocked" and args[-1].isdigit() else 20
    out = collect(only=site)
    if not out["configured"] or out.get("error"):
        print("fw: " + out["error"], file=sys.stderr)
        return 1
    if as_json:
        for s in out["sites"].values():
            s.pop("log", None)
        print(json.dumps(out, ensure_ascii=False))
    else:
        f = {"status": text, "clients": clients_text, "blocked": lambda s: blocked_text(s, n)}[cmd]
        print("\n\n".join(f(s) for s in out["sites"].values()))
    return 0 if all(s.get("reachable") for s in out["sites"].values()) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
