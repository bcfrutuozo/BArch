#!/usr/bin/env python3
"""Rumble a gamepad for a moment, to tell which one it is (and that vibration works).

    rumble.py <bluetooth address> [milliseconds] [strength 0-100]

Finds the evdev node whose `uniq` is that address (what the kernel's HID drivers put there for a
Bluetooth device), uploads an FF_RUMBLE effect and plays it once. Standard library only: the
structs are the kernel's (linux/input.h) on a 64-bit machine. The node is reachable without root
because logind gives the seat's user an ACL on joysticks (uaccess).
"""
import fcntl
import glob
import os
import struct
import sys
import time

EV_FF = 0x15
FF_RUMBLE = 0x50
# struct ff_effect: type, id, direction, trigger{button, interval}, replay{length, delay},
# then the union, aligned to 8 (it holds a pointer); ff_rumble_effect = strong, weak magnitude.
FF_EFFECT = "HhHHHHH2xHH28x"
assert struct.calcsize(FF_EFFECT) == 48
EVIOCSFF = (1 << 30) | (48 << 16) | (ord("E") << 8) | 0x80
EVIOCRMFF = (1 << 30) | (4 << 16) | (ord("E") << 8) | 0x81
INPUT_EVENT = "qqHHi"  # struct timeval, type, code, value


def find_node(address):
    address = address.lower()
    for uniq in glob.glob("/sys/class/input/event*/device/uniq"):
        try:
            with open(uniq) as f:
                if f.read().strip().lower() == address:
                    return "/dev/input/" + uniq.split("/")[4]
        except OSError:
            pass
    return None


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: rumble.py <bluetooth address> [ms] [strength 0-100]")
    ms = int(sys.argv[2]) if len(sys.argv) > 2 else 400
    strength = int(sys.argv[3]) if len(sys.argv) > 3 else 70
    ms = max(50, min(ms, 3000))
    magnitude = int(0xFFFF * max(0, min(strength, 100)) / 100)

    node = find_node(sys.argv[1])
    if node is None:
        sys.exit(f"no input device for {sys.argv[1]} (not connected?)")
    try:
        fd = os.open(node, os.O_RDWR)
    except OSError as e:
        sys.exit(f"{node}: {e.strerror}")
    try:
        effect = bytearray(struct.pack(FF_EFFECT, FF_RUMBLE, -1, 0, 0, 0, ms, 0, magnitude, magnitude))
        try:
            fcntl.ioctl(fd, EVIOCSFF, effect)
        except OSError as e:
            sys.exit(f"{node}: no rumble ({e.strerror})")
        effect_id = struct.unpack_from("h", effect, 2)[0]
        os.write(fd, struct.pack(INPUT_EVENT, 0, 0, EV_FF, effect_id, 1))
        time.sleep(ms / 1000 + 0.1)
        fcntl.ioctl(fd, EVIOCRMFF, effect_id)
    finally:
        os.close(fd)
    print(node)


if __name__ == "__main__":
    main()
