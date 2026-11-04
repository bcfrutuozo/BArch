"""Alignment on synthetic soundtracks: a shared 'music and effects' bed plus a 'voice' that differs
between the original and the dub, as in a real dub. No media files needed."""
import sys
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from barch_video import sync  # noqa: E402

SR = sync.SR
MIN = 30  # minutes of film


def bed(seed: int, minutes: int = MIN) -> np.ndarray:
    """Music and effects: sparse percussive hits (lows) and hiss bursts (highs), never the same twice."""
    r = np.random.default_rng(seed)
    n = minutes * 60 * SR
    x = np.zeros(n, np.float32)
    for t in r.integers(0, n - SR, size=minutes * 90):
        k = np.arange(int(SR * r.uniform(0.05, 0.4)))
        f = r.uniform(50, 200) if r.random() < 0.6 else r.uniform(3100, 3900)
        x[t:t + len(k)] += (np.sin(2 * np.pi * f * k / SR) * np.exp(-k / (SR * 0.08)) * r.uniform(0.1, 0.5)).astype(np.float32)
    return x


def voice(seed: int, n: int) -> np.ndarray:
    """A 'voice': band-limited noise in 300-3000 Hz, in phrases."""
    r = np.random.default_rng(seed)
    v = r.normal(0, 0.15, n).astype(np.float32)
    spec = np.fft.rfft(v)
    f = np.fft.rfftfreq(n, 1 / SR)
    spec[(f < 300) | (f > 3000)] = 0
    v = np.fft.irfft(spec, n).astype(np.float32)
    gate = np.repeat(r.random(n // SR + 1) < 0.5, SR)[:n]
    return v * gate


def shift(x: np.ndarray, s: float) -> np.ndarray:
    k = int(round(s * SR))
    return np.concatenate([np.zeros(k, np.float32), x])[: len(x)] if k >= 0 else np.concatenate([x[-k:], np.zeros(-k, np.float32)])


class Align(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.me = bed(1)
        cls.orig = cls.me + voice(2, len(cls.me))
        cls.dub = cls.me + voice(3, len(cls.me))     # same bed, another voice

    def test_constant_offset_dub_vs_original(self):
        a = sync.align_pcm(self.orig, shift(self.dub, 1.25))
        self.assertTrue(a.ok, a.reason)
        self.assertEqual(a.speed, "1")
        self.assertAlmostEqual(a.offset, -1.25, delta=0.02)

    def test_pal_speedup(self):
        speed = sync.SPEEDS["pal"]
        idx = np.arange(0, int(len(self.dub) / speed)) * speed      # the donor plays 4.3 % faster
        fast = np.interp(idx, np.arange(len(self.dub)), self.dub).astype(np.float32)
        a = sync.align_pcm(self.orig, shift(fast, 0.5))
        self.assertTrue(a.ok, a.reason)
        self.assertEqual(a.speed, "pal")

    def test_different_cut_is_refused(self):
        cut = np.concatenate([self.dub[: 15 * 60 * SR], self.dub[(15 * 60 + 30) * SR:]])   # 30 s missing at 15 min
        a = sync.align_pcm(self.orig, cut)
        self.assertFalse(a.ok)
        self.assertIn("cut", a.reason)

    def test_another_film_is_refused(self):
        other = bed(9) + voice(10, len(self.me))
        a = sync.align_pcm(self.orig, other)
        self.assertFalse(a.ok)


if __name__ == "__main__":
    unittest.main()
