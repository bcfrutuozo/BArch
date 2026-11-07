#!/usr/bin/env python3
"""The visualizer's ears (quickshell/player/Viz.qml): the player's own PipeWire stream (the mpv node
`barch-player`, nothing else on the desktop and never the microphone) captured with pw-record, cut into
FFT frames, folded into log-spaced bands and printed as one line per frame:

    <level> <band0> <band1> ... <bandN-1>        integers 0..1000, `fps` lines per second

The capture stream is `barch-player-viz` (the privacy indicator ignores it: it is not a microphone).
pw-record is only started while the mpv node exists (otherwise PipeWire would hand it the default
source, the microphone) and told not to reconnect elsewhere when the node goes away; while there is
nothing to listen to, a line of zeros goes out twice a second so the bars fall.

    viz.py [--bands 64] [--fps 30] [--target barch-player]
"""
from __future__ import annotations

import argparse
import json
import math
import subprocess
import sys
import threading
import time

import numpy as np

RATE = 48000
WINDOW = 2048
F_LO, F_HI = 30.0, 16000.0


def node_exists(name: str) -> bool:
    try:
        out = subprocess.run(["pw-dump"], capture_output=True, text=True, timeout=5).stdout
        for o in json.loads(out):
            p = (o.get("info") or {}).get("props") or {}
            if p.get("node.name") == name and p.get("media.class") == "Stream/Output/Audio":
                return True
    except Exception:  # noqa: BLE001
        pass
    return False


class Bands:
    """FFT bins folded into `n` bands spaced evenly in log frequency, with a dB scale and smoothing."""

    def __init__(self, n: int, fps: int):
        self.n = n
        self.window = np.hanning(WINDOW).astype(np.float32)
        freqs = np.fft.rfftfreq(WINDOW, 1 / RATE)
        edges = np.geomspace(F_LO, F_HI, n + 1)
        self.idx = [np.where((freqs >= lo) & (freqs < hi))[0] for lo, hi in zip(edges[:-1], edges[1:])]
        # a band narrower than a bin takes the nearest bin
        for i, (lo, hi) in enumerate(zip(edges[:-1], edges[1:])):
            if len(self.idx[i]) == 0:
                self.idx[i] = np.array([int(np.argmin(np.abs(freqs - math.sqrt(lo * hi))))])
        # the high bands have more bins and less energy per bin: a gentle tilt keeps the picture level
        self.tilt = np.linspace(0.0, 10.0, n).astype(np.float32)
        self.smooth = np.zeros(n, dtype=np.float32)
        self.peak = 0.0
        self.attack = 1 - math.exp(-1.0 / (fps * 0.03))
        self.decay = 1 - math.exp(-1.0 / (fps * 0.18))

    def frame(self, samples: np.ndarray, floor_db: float) -> tuple[float, np.ndarray]:
        spec = np.abs(np.fft.rfft(samples * self.window)) / (WINDOW / 4)
        db = 20 * np.log10(np.array([spec[i].mean() for i in self.idx]) + 1e-9) + self.tilt
        target = np.clip((db - floor_db) / -floor_db, 0, 1).astype(np.float32)
        up = target > self.smooth
        self.smooth += np.where(up, self.attack, self.decay) * (target - self.smooth)
        rms = float(np.sqrt(np.mean(samples * samples)))
        level = max(0.0, min(1.0, (20 * math.log10(rms + 1e-9) - floor_db) / -floor_db))
        self.peak += (self.attack if level > self.peak else self.decay) * (level - self.peak)
        return self.peak, self.smooth


def emit(level: float, bands: np.ndarray) -> None:
    sys.stdout.write(f"{int(level * 1000)} " + " ".join(str(int(v * 1000)) for v in bands) + "\n")
    sys.stdout.flush()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bands", type=int, default=64)
    ap.add_argument("--fps", type=int, default=30)
    ap.add_argument("--target", default="barch-player")
    ap.add_argument("--floor", type=float, default=-60.0, help="dB that counts as silence (sensitivity)")
    a = ap.parse_args()
    bands = Bands(max(8, min(256, a.bands)), a.fps)
    hop = RATE // a.fps
    zeros = np.zeros(bands.n, dtype=np.float32)

    # the sensitivity can be changed while running: a number on stdin is the new floor
    floor = [-abs(a.floor)]

    def stdin_watch():
        for line in sys.stdin:
            try:
                floor[0] = -abs(float(line.strip()))
            except ValueError:
                pass
    threading.Thread(target=stdin_watch, daemon=True).start()

    while True:
        if not node_exists(a.target):
            bands.smooth *= 0.6
            bands.peak *= 0.6
            emit(bands.peak, bands.smooth)
            time.sleep(0.5)
            continue
        proc = subprocess.Popen(
            ["pw-record", "-P", '{ application.name = "barch-player-viz" node.name = "barch-player-viz" stream.dont-reconnect = true }',
             "--target", a.target, "--raw", "--format", "f32", "--rate", str(RATE), "--channels", "1", "-"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        buf = np.zeros(WINDOW, dtype=np.float32)
        try:
            while True:
                chunk = proc.stdout.read(hop * 4)
                if not chunk:
                    break
                new = np.frombuffer(chunk[:len(chunk) - len(chunk) % 4], dtype=np.float32)
                if not len(new):
                    continue
                if len(new) >= WINDOW:
                    buf = new[-WINDOW:].copy()
                else:
                    buf = np.concatenate([buf[len(new):], new])
                emit(*bands.frame(buf, floor[0]))
        except (BrokenPipeError, KeyboardInterrupt):
            proc.kill()
            return 0
        finally:
            if proc.poll() is None:
                proc.kill()
        emit(0.0, zeros)
        time.sleep(0.5)


if __name__ == "__main__":
    sys.exit(main())
