#!/usr/bin/env python3
"""barch rgb: the Corsair keyboard and mouse lit in the theme's colors, through ckb-next's daemon.

ckb-next-daemon (system service, package ckb-next) exposes every device as /dev/input/ckbN/ with a
`cmd` pipe; `active` takes the device out of its hardware profile and `rgb rrggbb` paints every
LED. Nothing else may write lighting at the same time: the ckb-next GUI would apply its own profile
on top, so it is not autostarted here (its G-key and button bindings still work through it).

    rgb.py watch                 the service (barch-rgb.service): paints the theme's color, and again
                                 when the theme or the settings change, when the daemon or a device
                                 comes back, and after a resume; the keyboard's light key steps the
                                 brightness (100, 66, 33, off), which software mode leaves to us
    rgb.py apply                 paint now
    rgb.py status [--json]       devices, color, settings
    rgb.py on|off                lights on in the theme's color / off (kept across restarts)
    rgb.py color <tone|#hex>     which color: a tone of the palette (accent, green, red...) or a hex
    rgb.py brightness <0-100>
    rgb.py flash [tone|#hex] [times]   blink, then back to the theme (returns at once, blinks in
                                       the background; the rules of agent/rules.json use it)

The theme comes from ~/.local/state/quickshell/theme.json (written by the bar, previews included);
the settings live in ~/.local/state/barch/rgb.json.
"""
from __future__ import annotations

import fcntl
import json
import os
import re
import select
import sys
import time
from pathlib import Path

HOME = Path.home()
STATE_HOME = Path(os.environ.get("XDG_STATE_HOME", HOME / ".local/state"))
THEME = STATE_HOME / "quickshell/theme.json"
SETTINGS = STATE_HOME / "barch/rgb.json"
FLASH_LOCK = STATE_HOME / "barch/rgb.flash.lock"
CKB = Path("/dev/input")
DEFAULTS = {"enabled": True, "color": "accent", "brightness": 100}
HEX = re.compile(r"^#?([0-9a-fA-F]{6})$")


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def settings() -> dict:
    try:
        s = json.loads(SETTINGS.read_text())
    except (OSError, ValueError):
        s = {}
    return {**DEFAULTS, **{k: s[k] for k in DEFAULTS if k in s}}


def save_settings(s: dict):
    SETTINGS.parent.mkdir(parents=True, exist_ok=True)
    tmp = SETTINGS.with_suffix(".tmp")
    tmp.write_text(json.dumps(s, indent=2) + "\n")
    tmp.replace(SETTINGS)


def palette() -> dict:
    try:
        return json.loads(THEME.read_text()).get("colors", {})
    except (OSError, ValueError):
        return {}


def resolve(color: str, pal: dict | None = None) -> str | None:
    """A palette tone or a hex → 'rrggbb'."""
    pal = palette() if pal is None else pal
    m = HEX.match(pal.get(color, "") or color)
    return m.group(1).lower() if m else None


def scale(hexrgb: str, pct: int) -> str:
    pct = max(0, min(100, int(pct)))
    return "".join(f"{int(hexrgb[i:i + 2], 16) * pct // 100:02x}" for i in (0, 2, 4))


def devices() -> list[Path]:
    """Every ckb-next device (ckb0 is the daemon's root controller, without a cmd pipe)."""
    return sorted(d for d in CKB.glob("ckb[1-9]*") if (d / "cmd").exists())


def read(p: Path) -> str:
    try:
        return p.read_text().strip()
    except OSError:
        return ""


def send(dev: Path, line: str) -> bool:
    # non-blocking: a pipe left behind by a dead daemon has no reader, and a plain open would hang
    try:
        fd = os.open(dev / "cmd", os.O_WRONLY | os.O_NONBLOCK)
    except OSError:
        return False
    try:
        os.write(fd, (line + "\n").encode())
        return True
    except OSError:
        return False
    finally:
        os.close(fd)


def paint(hexrgb: str, settle: bool = True) -> int:
    """Every LED of every device. The Scimitar Elite's side keypad only takes a color that keeps
    arriving (the ckb-next GUI streams frames; one write leaves the keypad on its old color), so
    `active` goes first and the color is then repeated for a second, as frames would."""
    devs = devices()
    if not settle:
        return sum(send(d, f"rgb {hexrgb}") for d in devs)
    if not sum(send(d, "active") for d in devs):
        return 0
    time.sleep(0.3)
    n = 0
    end = time.monotonic() + 1.0
    while time.monotonic() < end:
        n = sum(send(d, f"rgb {hexrgb}") for d in devs)
        time.sleep(1 / 30)
    return n


def target() -> str:
    """What the lights should show now."""
    s = settings()
    if not s["enabled"]:
        return "000000"
    base = resolve(str(s["color"])) or resolve("accent") or "ffffff"
    return scale(base, s["brightness"])


def apply() -> int:
    return paint(target())


def status() -> dict:
    s = settings()
    return {"ok": True, **s, "rgb": target(), "daemon": bool(read(CKB / "ckb0/pid")),
            "devices": [{"path": str(d), "model": read(d / "model"), "dpi": read(d / "dpi")}
                        for d in devices()]}


def flash(color: str, times: int):
    hexrgb = resolve(color)
    if not hexrgb:
        raise SystemExit(f"rgb: unknown color '{color}'")
    if os.fork():                       # the caller (a rule, a script) does not wait for the blinking
        return
    os.setsid()
    FLASH_LOCK.parent.mkdir(parents=True, exist_ok=True)
    with open(FLASH_LOCK, "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os._exit(0)                 # already blinking
        for _ in range(max(1, min(times, 20))):
            paint(hexrgb, settle=False)
            time.sleep(0.25)
            paint("000000", settle=False)
            time.sleep(0.2)
        apply()
    os._exit(0)


def boot_gap() -> float:
    # CLOCK_BOOTTIME runs through a suspend, CLOCK_MONOTONIC does not: a jump between them is a resume
    return time.clock_gettime(time.CLOCK_BOOTTIME) - time.monotonic()


def mtime(p: Path) -> int:
    try:
        return p.stat().st_mtime_ns
    except OSError:
        return 0


LEVELS = (100, 66, 33, 0)              # the light key's steps, as the keyboard does them by itself
STREAM_S = 1.0                         # how long a new color is repeated (see paint)


def step_brightness(presses: int) -> int:
    s = settings()
    level = int(s["brightness"])
    for _ in range(presses):
        level = next((l for l in LEVELS if l < level), LEVELS[0])
    s["brightness"] = level
    s["enabled"] = True
    save_settings(s)
    return level


def open_notify(devs: list[Path]) -> dict[int, Path]:
    """In software mode the light key does nothing on the keyboard: the daemon only reports it
    (`notify light` → "key +light" on notifyN), and the brightness is ours to change.
    The device has to be `active` first: in hardware mode ckb-next-daemon drops every command but
    `active` (and a few queries), so a `notify` sent before it is lost and the key stays dead
    until the next time the pipes are opened (that is what happened at every boot)."""
    fds = {}
    for d in devs:
        if not (send(d, "active") and send(d, "notify light")):
            continue
        try:
            fd = os.open(d / "notify0", os.O_RDONLY | os.O_NONBLOCK)
        except OSError:
            continue
        try:
            while os.read(fd, 4096):    # presses left in the pipe from before (a restart) are old news
                pass
        except OSError:
            pass
        fds[fd] = d
    return fds


def signature() -> tuple:
    return (mtime(THEME), mtime(SETTINGS), read(CKB / "ckb0/pid"),
            tuple((str(d), mtime(d)) for d in devices()))


def watch():
    """paint() without blocking: the color is repeated from this loop, so a key press in the
    middle of a repaint is answered at once instead of a second later."""
    seen = None
    gap = boot_gap()
    fds: dict[int, Path] = {}
    color, until = "", 0.0              # what is being repeated, and until when
    while True:
        sig = signature()
        g = boot_gap()
        resumed = g - gap > 3
        gap = g
        if resumed:
            time.sleep(3)               # the devices come back on the USB bus a moment after
        if sig != seen or resumed:
            if seen is not None and sig[3] != seen[3]:
                time.sleep(1)           # a device that just appeared answers after a moment
            color = target()
            n = sum(send(d, "active") for d in devices())
            if seen is None or sig[2:] != seen[2:] or resumed:
                for fd in fds:
                    os.close(fd)
                fds = open_notify(devices())    # after `active`, or the daemon ignores the notify
            until = time.monotonic() + 0.3 + STREAM_S
            log(f"rgb: {color} on {n} device(s)" + (" after resume" if resumed else ""))
            seen = sig
        streaming = time.monotonic() < until
        if streaming:
            for d in devices():
                send(d, f"rgb {color}")
        timeout = 1 / 30 if streaming else 1
        ready = select.select(list(fds), [], [], timeout)[0] if fds else time.sleep(timeout) or []
        presses = 0
        for fd in ready:
            try:
                data = os.read(fd, 4096).decode(errors="replace")
            except OSError:
                data = ""
            if not data:                # the daemon closed its end: reopen, or select spins on EOF
                d = fds.pop(fd)
                os.close(fd)
                fds.update(open_notify([d]))
                time.sleep(0.2)
                continue
            presses += data.count("key +light")
        if presses:
            level = step_brightness(presses)
            color = target()
            until = time.monotonic() + STREAM_S
            seen = signature()          # our own settings write: no second repaint
            log(f"rgb: light key ×{presses} → {level}% ({color})")


def main(argv: list[str]) -> int:
    as_json = "--json" in argv
    argv = [a for a in argv if a != "--json"]
    cmd = argv[0] if argv else "status"
    args = argv[1:]
    out = None
    if cmd == "watch":
        watch()
    elif cmd == "apply":
        out = {"ok": True, "rgb": target(), "devices": apply()}
    elif cmd == "status":
        out = status()
        if not as_json:
            print(f"{'on' if out['enabled'] else 'off'} · {out['color']} #{out['rgb']} · brightness "
                  f"{out['brightness']}% · daemon {'running' if out['daemon'] else 'NOT running'}")
            for d in out["devices"]:
                print(f"  {d['model']}  ({d['path']}, {d['dpi'] or '-'} dpi)")
            return 0 if out["daemon"] else 1
    elif cmd in ("on", "off"):
        s = settings()
        s["enabled"] = cmd == "on"
        save_settings(s)
        out = {"ok": True, "enabled": s["enabled"], "devices": apply()}
    elif cmd == "color" and args:
        if not resolve(args[0]):
            print(f"rgb: unknown color '{args[0]}' (a palette tone or #rrggbb)", file=sys.stderr)
            return 2
        s = settings()
        s["color"] = args[0] if args[0] in palette() else "#" + resolve(args[0])
        s["enabled"] = True
        save_settings(s)
        out = {"ok": True, "color": s["color"], "devices": apply()}
    elif cmd == "brightness" and args and args[0].isdigit():
        s = settings()
        s["brightness"] = max(0, min(100, int(args[0])))
        save_settings(s)
        out = {"ok": True, "brightness": s["brightness"], "devices": apply()}
    elif cmd == "flash":
        color = args[0] if args else "red"
        times = int(args[1]) if len(args) > 1 and args[1].isdigit() else 3
        flash(color, times)
        out = {"ok": True, "flash": color, "times": times}
    else:
        print(__doc__.split("\n\n")[2], file=sys.stderr)
        return 2
    if out is not None:
        print(json.dumps(out) if as_json else ("ok" if out.get("ok") else json.dumps(out)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
