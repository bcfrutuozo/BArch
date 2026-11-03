"""Which folders of a download are albums and which are discs of one (pipeline.album_roots)."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
try:
    from barch_music import pipeline  # noqa: E402  (needs mutagen: in the container)
except ImportError:
    pipeline = None


class DiscFolders(unittest.TestCase):
    def test_names(self):
        if pipeline is None:
            self.skipTest("mutagen missing")
        yes = ["CD1", "CD 2", "Disc 2", "Disc 2 - The Battle Rages On", "cd3 - bonus", "DVD1",
               "Deep Purple - The platinum collection, disc 2", "The Wall (CD 1)", "Album [Disc 2]", "Vol. 2", "Volume 12"]
        no = ["Deep Purple - Stormbringer", "2 Hearts", "CD", "Disc", "1984 Tooth And Nail", "Made in Japan 2014", "Covers"]
        for n in yes:
            self.assertTrue(pipeline.is_disc_folder(n), n)
        for n in no:
            self.assertFalse(pipeline.is_disc_folder(n), n)
