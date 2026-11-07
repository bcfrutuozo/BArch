"""catalog.py: the player's index is read again only for the albums whose files changed, and the file
paths it hands out never leave /music."""
import json
import os
import tempfile
import time
import unittest
from pathlib import Path

from barch_music import catalog


def fake_reader(calls):
    def read(path: Path) -> dict:
        calls.append(str(path))
        n = int(path.name.split(".")[1].split(" ")[0])
        return {"file": path.name, "title": path.stem.split(" - ", 1)[1], "artist": "Band", "album": "Record",
                "albumartist": "", "date": "1999-05-04", "genre": "Rock", "disc": 1, "pos": n, "length": 100.0 + n,
                "rate": 44100, "bits": 16, "channels": 2, "lyrics": False}
    return read


class CatalogTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.music = Path(self.tmp.name) / "music"
        self.root = Path(self.tmp.name) / "data"
        self.root.mkdir()
        self.album = self.music / "Band" / "Record"
        self.album.mkdir(parents=True)
        for n in (1, 2):
            (self.album / f"1.0{n} - Song {n}.flac").write_bytes(b"x" * (10 + n))
        (self.album / "cover.jpg").write_bytes(b"jpeg")
        self.calls = []
        self.cat = catalog.Catalog(self.music, self.root, reader=fake_reader(self.calls))

    def tearDown(self):
        self.tmp.cleanup()

    def test_reads_once_then_only_what_changed(self):
        r = self.cat.refresh()
        self.assertEqual((r["read"], r["albums"]), (1, 1))
        self.assertEqual(len(self.calls), 2)
        a = self.cat.albums["Band/Record"]
        self.assertEqual((a["artist"], a["album"], a["date"], a["genre"], a["cover"], a["length"]), ("Band", "Record", "1999-05-04", "Rock", True, 203.0))
        self.assertEqual([t["title"] for t in a["tracks"]], ["Song 1", "Song 2"])
        self.assertNotIn("artist", a["tracks"][0])          # same as the album's: not repeated
        v = self.cat.version
        # nothing changed: no file read, same version
        r = self.cat.refresh()
        self.assertEqual((r["read"], self.cat.version, len(self.calls)), (0, v, 2))
        # a file changed (size): that album is read again, the version moves
        f = self.album / "1.02 - Song 2.flac"
        f.write_bytes(b"y" * 40)
        os.utime(f, ns=(time.time_ns(), time.time_ns() + 10 ** 9))
        r = self.cat.refresh()
        self.assertEqual((r["read"], len(self.calls)), (1, 4))
        self.assertEqual(self.cat.version, v + 1)
        # survives a restart from catalog.json
        again = catalog.Catalog(self.music, self.root, reader=fake_reader([]))
        self.assertEqual(again.version, v + 1)
        self.assertIn("Band/Record", again.albums)
        # a removed album goes away
        for x in self.album.iterdir():
            x.unlink()
        self.album.rmdir()
        r = again.refresh()
        self.assertEqual((r["removed"], r["albums"]), (1, 0))

    def test_payload_has_no_signature_and_gzips(self):
        self.cat.refresh()
        d = json.loads(self.cat.payload(False))
        self.assertTrue(d["ok"] and d["changed"])
        self.assertNotIn("sig", d["albums"][0])
        import gzip
        self.assertEqual(gzip.decompress(self.cat.payload(True)), self.cat.payload(False))

    def test_paths_stay_inside_music(self):
        self.cat.refresh()
        self.assertTrue(self.cat.path("Band/Record", "cover.jpg"))
        self.assertTrue(self.cat.path("Band/Record", "1.01 - Song 1.flac"))
        self.assertIsNone(self.cat.path("Band/../Record", "cover.jpg"))
        self.assertIsNone(self.cat.path("Band/Record", "../../data/catalog.json"))
        self.assertIsNone(self.cat.path("Band", "cover.jpg"))
        self.assertIsNone(self.cat.path("Band/Record", "nope.flac"))

    def test_lyrics_from_lrc(self):
        (self.album / "1.01 - Song 1.lrc").write_text("[00:01.00]hello\n")
        self.assertEqual(self.cat.lyrics("Band/Record", "1.01 - Song 1.flac")["synced"], "[00:01.00]hello\n")
        self.assertFalse(self.cat.lyrics("Band/Record", "zz.flac")["ok"])


if __name__ == "__main__":
    unittest.main()
