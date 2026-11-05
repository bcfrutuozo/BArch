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


class RegroupDiscs(unittest.TestCase):
    """slskd's loose disc folders put back together by their tags (pipeline.regroup_discs)."""

    def setUp(self):
        if pipeline is None:
            self.skipTest("mutagen missing")
        import tempfile
        self.tmp = tempfile.TemporaryDirectory()
        self.box = Path(self.tmp.name)
        self.tags = {}
        self._orig = pipeline._disc_tags
        pipeline._disc_tags = lambda f: self.tags[f.name]

    def tearDown(self):
        pipeline._disc_tags = self._orig
        self.tmp.cleanup()

    def put(self, folder, name, tags):
        d = self.box / folder
        d.mkdir(exist_ok=True)
        (d / name).write_bytes(b"x")
        self.tags[name] = tags

    def test_two_albums_mixed_in_cd02(self):
        self.put("CD 01", "a1.flac", ("Eric Clapton", "Crossroads", 1, 2))
        self.put("CD 02", "a2.flac", ("Eric Clapton", "Crossroads", 2, 2))
        self.put("CD 02", "b2.flac", ("Deep Purple", "The Battle Rages On", 2, 2))
        self.put("CD2 - Come Hell or High Water", "b1.flac", ("Deep Purple", "The Battle Rages On", 1, 2))
        made = pipeline.regroup_discs(self.box, settle=0, now=1e12)
        self.assertEqual(sorted(made), ["Deep Purple - The Battle Rages On", "Eric Clapton - Crossroads"])
        self.assertTrue((self.box / "Eric Clapton - Crossroads/CD1/a1.flac").exists())
        self.assertTrue((self.box / "Eric Clapton - Crossroads/CD2/a2.flac").exists())
        self.assertTrue((self.box / "Deep Purple - The Battle Rages On/CD2/b2.flac").exists())
        self.assertFalse((self.box / "CD 02").exists())
        self.assertEqual([str(r.relative_to(self.box)) for r in sorted(pipeline.album_roots(self.box / "Eric Clapton - Crossroads"))],
                         ["Eric Clapton - Crossroads"])

    def test_waits_for_missing_disc_and_keeps_untagged(self):
        import os
        self.put("CD 01", "a1.flac", ("Eric Clapton", "Crossroads", 1, 4))
        self.put("Disc 3", "x.flac", ("", "", 0, 0))
        now = os.stat(self.box / "CD 01/a1.flac").st_mtime + 60
        self.assertEqual(pipeline.regroup_discs(self.box, settle=30, now=now), [])
        self.assertTrue((self.box / "CD 01/a1.flac").exists())
        self.assertEqual(pipeline.regroup_discs(self.box, settle=30, now=now + 7 * 3600), ["Eric Clapton - Crossroads"])
        self.assertTrue((self.box / "Disc 3/x.flac").exists())

    def test_nothing_while_still_downloading(self):
        import os
        self.put("CD 01", "a1.flac", ("Eric Clapton", "Crossroads", 1, 1))
        now = os.stat(self.box / "CD 01/a1.flac").st_mtime + 10
        self.assertEqual(pipeline.regroup_discs(self.box, settle=1800, now=now), [])

    def test_disc_in_album_tag(self):
        self.assertEqual(pipeline.split_album_disc("Crossroads (Disc 1)"), ("Crossroads", 1))
        self.assertEqual(pipeline.split_album_disc("A Fire In The Sky : A Career Spanning Collection CD2"),
                         ("A Fire In The Sky : A Career Spanning Collection", 2))
        self.assertEqual(pipeline.split_album_disc("Red (Deluxe Edition) [Disc 1]"), ("Red (Deluxe Edition)", 1))
        self.assertEqual(pipeline.split_album_disc("Crossroads Disc 3"), ("Crossroads", 3))
        self.assertEqual(pipeline.split_album_disc("1999"), ("1999", 0))
        self.assertEqual(pipeline.split_album_disc("CD 2"), ("CD 2", 0))
        self.put("Crossroads (Disc 1)", "c1.flac", ("Eric Clapton", "Crossroads (Disc 1)", 0, 0))
        self.put("CD 02", "c2.flac", ("Eric Clapton", "Crossroads Disc 2", 0, 0))
        self.assertEqual(pipeline.regroup_discs(self.box, settle=0, now=1e12), ["Eric Clapton - Crossroads"])
        self.assertTrue((self.box / "Eric Clapton - Crossroads/CD1/c1.flac").exists())
        self.assertTrue((self.box / "Eric Clapton - Crossroads/CD2/c2.flac").exists())
