"""The cover rules that need no network: store names, scan frames, the same artwork."""
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from barch_music import cover  # noqa: E402


class ImageNames(unittest.TestCase):
    """What a download ships: the front is a candidate, the back and the booklet never are."""

    def test_role(self):
        front = ["Front.jpg", "cover.png", "folder.jpg", "Portada.jpg", "Box-Front.PNG", "Tooth And Nail Front.png", "capa.jpg"]
        never = ["Back.jpg", "Contraportada.jpg", "Contracapa.jpg", "Booklet 2.jpg", "Folleto.jpg", "Libreto_Interior.jpg",
                 "Inlay.png", "CD.jpg", "cd1.png", "Disc 2.jpg", "Back Cover.jpg", "Trasera.jpg", "Obi.jpg"]
        other = ["Jolly Roger.png", "scan01.jpg", "image.webp"]
        for n in front:
            self.assertEqual(cover.image_role(n), "front", n)
        for n in never:
            self.assertEqual(cover.image_role(n), "none", n)
        for n in other:
            self.assertEqual(cover.image_role(n), "other", n)

    def test_front_beats_a_bigger_back(self):
        # New Live & Rare, Volume Two (2026-11-03): Contraportada.jpg (2129x2140) was chosen over Portada.jpg (2128x2129)
        a = cover.Cand("download: Portada.jpg", "download", Path("a"), 2128, 2129)
        b = cover.Cand("download: Jolly Roger.png", "other", Path("b"), 2129, 2140)
        self.assertIs(max([a, b], key=cover.rank_key), a)


class StoreNames(unittest.TestCase):
    def test_match(self):
        ok = [("Dokken", "Beast from the East", "Dokken", "Beast from the East (Live)"),
              ("Dokken", "Tooth and Nail", "Dokken", "Tooth and Nail (Remastered)"),
              ("The Beatles", "Abbey Road", "Beatles", "Abbey Road [2019 Mix]"),
              ("Motörhead", "Ace of Spades", "Motorhead", "Ace of Spades - Deluxe Edition")]
        for a in ok:
            self.assertTrue(cover.names_match(*a), a)
        bad = [("Dokken", "Tooth and Nail", "Hunter", "Without Warning + Tooth And Nail"),
               ("Dokken", "Dokken", "Dokken", "Back for the Attack"),
               ("Deep Purple", "Machine Head", "Deep Purple", "Made in Japan")]
        for a in bad:
            self.assertFalse(cover.names_match(*a), a)


@unittest.skipUnless(shutil.which("ffmpeg"), "ffmpeg missing")
class Frames(unittest.TestCase):
    """A synthetic artwork, then the same one as a scan: inside a light band."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp())
        art = "mandelbrot=s=1000x1000:end_pts=1,eq=brightness=-0.35"
        cls.clean, cls.scan, cls.other = cls.tmp / "clean.png", cls.tmp / "scan.png", cls.tmp / "other.png"
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", art, "-frames:v", "1", str(cls.clean)], check=True)
        subprocess.run(["ffmpeg", "-v", "error", "-i", str(cls.clean), "-vf",
                        "scale=940:940,pad=1000:1000:30:24:0xc8c8c0", "-frames:v", "1", str(cls.scan)], check=True)
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=s=1000x1000", "-frames:v", "1", str(cls.other)], check=True)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp)

    def test_frame(self):
        b_clean, fp_clean = cover.look(self.clean)
        b_scan, fp_scan = cover.look(self.scan)
        _, fp_other = cover.look(self.other)
        self.assertEqual(sum(1 for b in b_clean if b), 0, b_clean)
        self.assertGreaterEqual(sum(1 for b in b_scan if b), 2, b_scan)
        self.assertGreater(cover.similarity(fp_clean, fp_scan), cover.SAME_ART)
        self.assertLess(cover.similarity(fp_clean, fp_other), cover.SAME_ART)
