"""The library sweep's Reorder: files renamed and renumbered to MusicBrainz's order, ids written, undo log
kept (no network: the matcher is fed the release)."""
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
try:
    from mutagen.flac import FLAC
    from barch_music import library, matcher  # noqa: E402  (needs mutagen: in the container)
except ImportError:                       # noqa: E402
    FLAC = library = matcher = None

MB = [("Avantasia (edit version)", 10), ("Reach Out for the Light", 20), ("The Final Sacrifice", 15), ("Avantasia", 30)]
OURS = [("Avantasia", 30), ("Reach Out For the Light", 20), ("The Final Sacrifice", 15), ("Avantasia [Edit]", 10)]
REL = {"id": "949e7e97-a16b-4964-9b0a-7fba3d3ca6cb", "title": "Avantasia", "date": "2000-11-13",
       "artist-credit": [{"name": "Avantasia", "joinphrase": ""}],
       "media": [{"format": "CD", "tracks": [{"title": t, "length": l * 1000, "position": i, "recording": {"id": f"rec{i}"}}
                                              for i, (t, l) in enumerate(MB, 1)]}]}


@unittest.skipUnless(shutil.which("ffmpeg") and FLAC, "ffmpeg or mutagen missing")
class Reorder(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.album = self.tmp / "music" / "Avantasia" / "Avantasia"
        self.album.mkdir(parents=True)
        for i, (t, s) in enumerate(OURS, 1):
            f = self.album / f"1.{i:02d} - {t}.flac"
            subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", f"sine=frequency=440:duration={s}", "-ar", "44100", "-ac", "1",
                            "-sample_fmt", "s16", str(f)], check=True)
            x = FLAC(f)
            x["TITLE"], x["TRACKNUMBER"], x["ARTIST"], x["ALBUM"] = t, f"{i:02d}", "Avantasia", "Avantasia"
            x.save()
        (self.album / "cover.jpg").write_bytes(b"x")
        self.lib = library.Library(self.tmp / "music", self.tmp / "state")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_reorder(self):
        with mock.patch.object(matcher.mb, "release", return_value=REL):
            out = self.lib.reorder("Avantasia/Avantasia", REL["id"])
        self.assertIn("2 file(s) put in the order", out)
        names = sorted(p.name for p in self.album.glob("*.flac"))
        self.assertEqual(names, ["1.01 - Avantasia [Edit].flac", "1.02 - Reach Out For the Light.flac",
                                 "1.03 - The Final Sacrifice.flac", "1.04 - Avantasia.flac"])
        x = FLAC(self.album / "1.01 - Avantasia [Edit].flac")
        self.assertEqual((x["TITLE"][0], x["TRACKNUMBER"][0], x["MUSICBRAINZ_TRACKID"][0], x["MUSICBRAINZ_ALBUMID"][0]),
                         ("Avantasia [Edit]", "01", "rec1", REL["id"]))
        x = FLAC(self.album / "1.04 - Avantasia.flac")
        self.assertEqual((x["TITLE"][0], x["TRACKNUMBER"][0], x["MUSICBRAINZ_TRACKID"][0]), ("Avantasia", "04", "rec4"))
        self.assertNotIn("DISCNUMBER", x)                      # not there before: not added
        self.assertTrue((self.album / "cover.jpg").exists())
        self.assertEqual(self.lib.state["Avantasia/Avantasia"]["state"], "tagged")
        undo = json.loads(next((self.tmp / "state" / "library-undo").glob("*-reorder.json")).read_text())
        self.assertEqual(len(undo["files"]), 4)
        self.assertTrue(undo["files"][0]["path"].endswith("1.01 - Avantasia.flac"))
        self.assertTrue(undo["files"][0]["new"].endswith("1.04 - Avantasia.flac"))
        self.assertEqual(undo["files"][0]["tags"]["TRACKNUMBER"], ["01"])

    def test_other_songs_refused(self):
        rel = json.loads(json.dumps(REL))
        rel["media"][0]["tracks"][1]["title"] = "Another Song"
        with mock.patch.object(matcher.mb, "release", return_value=rel):
            with self.assertRaises(ValueError):
                self.lib.reorder("Avantasia/Avantasia", REL["id"])
        self.assertEqual(sorted(p.name for p in self.album.glob("*.flac"))[0], "1.01 - Avantasia.flac")

    def test_compare_has_the_plan(self):
        with mock.patch.object(matcher.mb, "release", return_value=REL):
            c = self.lib.compare("Avantasia/Avantasia", REL["id"])
        self.assertFalse(c["fits"])
        self.assertEqual([(r["index"], r["to_pos"]) for r in c["reorder"] if r["moves"]], [(1, 4), (4, 1)])


if __name__ == "__main__":
    unittest.main()
