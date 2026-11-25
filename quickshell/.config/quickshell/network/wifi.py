#!/usr/bin/env python3
"""Wi-Fi through iwd's D-Bus API, for the bar's Wi-Fi widget (WifiWidget.qml).

    wifi.py status                 JSON {device, radio, networks: [{ssid, signal, secure, active, known}], saved}
    wifi.py scan                   ask the station to scan (the next status shows the result)
    wifi.py connect SSID [PASS]    join a network: a saved or open one through D-Bus, a new one with its
                                   passphrase through iwctl (which answers iwd's agent for us)
    wifi.py disconnect             leave the current network
    wifi.py radio on|off           power the Wi-Fi device on or off
    wifi.py forget SSID            drop a saved network (its passphrase in /var/lib/iwd)

Only `busctl` (systemd) and `iwctl` (iwd) are called; iwd lets wheel users talk to it. Signal is
iwd's dBm turned into the 0-100 scale the widget used with NetworkManager. `summarize()` is pure and
covered by tests/test_wifi.py. Errors go to stderr with exit 1, so the widget shows them.
"""
from __future__ import annotations

import json
import subprocess
import sys

IWD = "net.connman.iwd"


def busctl(*args: str, timeout: int = 10) -> dict | None:
    r = subprocess.run(["busctl", "--system", "--json=short", *args], capture_output=True, text=True, timeout=timeout + 5)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or f"busctl {' '.join(args)} failed")
    return json.loads(r.stdout) if r.stdout.strip() else None


def objects() -> dict:
    """iwd's object tree: {path: {interface: {property: value}}} with the D-Bus variants unwrapped."""
    raw = busctl("call", IWD, "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects")
    tree = raw["data"][0] if raw else {}
    return {path: {iface: {k: v.get("data") if isinstance(v, dict) else v for k, v in props.items()}
                   for iface, props in ifaces.items()}
            for path, ifaces in tree.items()}


def ordered(station: str) -> list[tuple[str, int]]:
    """The station's networks by signal: [(network path, signal in 100 * dBm)]."""
    raw = busctl("call", IWD, station, f"{IWD}.Station", "GetOrderedNetworks")
    return [(p, int(s)) for p, s in (raw["data"][0] if raw else [])]


def percent(signal_mbm: int) -> int:
    """100 * dBm → 0-100: -50 dBm or better is 100, -100 dBm or worse is 0 (NetworkManager's scale)."""
    return max(0, min(100, 2 * (signal_mbm // 100 + 100)))


def summarize(tree: dict, order: list[tuple[str, int]]) -> dict:
    """What the widget shows, from the object tree and the station's ordered networks (pure)."""
    device = station = ""
    radio = False
    for path, ifaces in sorted(tree.items()):
        dev = ifaces.get(f"{IWD}.Device")
        if dev and dev.get("Mode", "station") == "station":
            device, radio = dev.get("Name", ""), bool(dev.get("Powered"))
            station = path if f"{IWD}.Station" in ifaces else ""
            break
    saved = sorted(k.get("Name", "") for i in tree.values() if (k := i.get(f"{IWD}.KnownNetwork")))
    seen: dict[str, dict] = {}
    signals = dict(order)
    for path, ifaces in tree.items():
        net = ifaces.get(f"{IWD}.Network")
        if not net or not net.get("Name") or (station and net.get("Device") not in (None, station)):
            continue
        n = {"ssid": net["Name"], "signal": percent(signals[path]) if path in signals else 0,
             "secure": net.get("Type", "open") != "open", "active": bool(net.get("Connected")),
             "known": bool(net.get("KnownNetwork")) and net.get("KnownNetwork") != "/", "path": path}
        prev = seen.get(n["ssid"])
        if not prev or n["active"] or (not prev["active"] and n["signal"] > prev["signal"]):
            seen[n["ssid"]] = n
    networks = sorted(seen.values(), key=lambda n: (not n["active"], -n["signal"], n["ssid"].lower()))
    return {"device": device, "station": station, "radio": radio, "networks": networks, "saved": saved}


def state() -> dict:
    tree = objects()
    s = summarize(tree, [])
    if s["station"]:
        s = summarize(tree, ordered(s["station"]))
    return s


def device_path(tree: dict) -> str:
    for path, ifaces in sorted(tree.items()):
        if f"{IWD}.Device" in ifaces:
            return path
    raise RuntimeError("no Wi-Fi device (is iwd running?)")


def main(argv: list[str]) -> int:
    cmd = argv[1] if len(argv) > 1 else ""
    try:
        if cmd == "status":
            print(json.dumps(state()))
        elif cmd == "scan":
            s = state()
            if not s["station"]:
                raise RuntimeError("Wi-Fi is off")
            try:
                busctl("call", IWD, s["station"], f"{IWD}.Station", "Scan")
            except RuntimeError as e:
                if "InProgress" not in str(e) and "Busy" not in str(e):
                    raise
        elif cmd == "connect" and len(argv) >= 3:
            ssid, password = argv[2], (argv[3] if len(argv) > 3 else "")
            s = state()
            net = next((n for n in s["networks"] if n["ssid"] == ssid), None)
            if not s["station"]:
                raise RuntimeError("Wi-Fi is off")
            if net is None:
                raise RuntimeError(f"{ssid} is not in range")
            if password or (net["secure"] and not net["known"]):
                if not password:
                    raise RuntimeError(f"{ssid} needs a password")
                r = subprocess.run(["iwctl", "--passphrase", password, "station", s["device"], "connect", ssid],
                                   capture_output=True, text=True, timeout=40)
                if r.returncode != 0:
                    raise RuntimeError((r.stdout + r.stderr).strip() or "connection failed (wrong password?)")
            else:
                busctl("--timeout=35", "call", IWD, net["path"], f"{IWD}.Network", "Connect", timeout=35)
        elif cmd == "disconnect":
            s = state()
            if s["station"]:
                busctl("call", IWD, s["station"], f"{IWD}.Station", "Disconnect")
        elif cmd == "radio" and len(argv) >= 3 and argv[2] in ("on", "off"):
            busctl("set-property", IWD, device_path(objects()), f"{IWD}.Device", "Powered", "b",
                   "true" if argv[2] == "on" else "false")
        elif cmd == "forget" and len(argv) >= 3:
            tree = objects()
            path = next((p for p, i in tree.items() if i.get(f"{IWD}.KnownNetwork", {}).get("Name") == argv[2]), "")
            if not path:
                raise RuntimeError(f"{argv[2]} is not saved")
            busctl("call", IWD, path, f"{IWD}.KnownNetwork", "Forget")
        else:
            print(__doc__.split("\n\n")[1], file=sys.stderr)
            return 2
    except (RuntimeError, subprocess.TimeoutExpired, json.JSONDecodeError) as e:
        print(str(e), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
