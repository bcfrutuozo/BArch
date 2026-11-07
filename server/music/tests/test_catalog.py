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
                "rate": 44100, "bits": 16, "channels": 2, "lyrics": False, "picture": "Song 1" in path.name}
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
        self.assertEqual((a["artist"], a["album"], a["date"], a["genre"], a["cover"], a["length"]), ("Band", "Record", "1999-05-04", "Rock", "cover.jpg", 203.0))
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

    def test_cover_png_embedded_or_none(self):
        (self.album / "cover.jpg").unlink()
        (self.album / "Cover.PNG").write_bytes(b"\x89PNG")
        other = self.music / "Band" / "Bare"
        other.mkdir()
        (other / "1.01 - Song 1.flac").write_bytes(b"x")            # the fake reader: Song 1 has a picture
        bare = self.music / "Band" / "Nothing"
        bare.mkdir()
        (bare / "1.02 - Song 2.flac").write_bytes(b"x")
        self.cat.refresh()
        self.assertEqual(self.cat.albums["Band/Record"]["cover"], "Cover.PNG")
        self.assertEqual(self.cat.albums["Band/Bare"]["cover"], "embedded")
        self.assertEqual(self.cat.albums["Band/Nothing"]["cover"], "")
        self.assertEqual(self.cat.cover("Band/Record"), (self.album / "Cover.PNG", "image/png"))
        self.assertIsNone(self.cat.cover("Band/Nothing"))
        self.assertIsNone(self.cat.cover("../Band/Record"))
        # a cover added later changes the album's signature: read again
        v = self.cat.version
        (bare / "folder.jpg").write_bytes(b"jpeg")
        self.cat.refresh()
        self.assertEqual((self.cat.albums["Band/Nothing"]["cover"], self.cat.version), ("folder.jpg", v + 1))

    def test_old_format_is_read_again(self):
        self.cat.refresh()
        d = json.loads((self.root / "catalog.json").read_text())
        self.assertEqual(d["format"], catalog.FORMAT)
        d["format"] = 1
        (self.root / "catalog.json").write_text(json.dumps(d))
        calls = []
        again = catalog.Catalog(self.music, self.root, reader=fake_reader(calls))
        self.assertEqual(len(again.albums), 1)                      # served meanwhile
        r = again.refresh()
        self.assertEqual((r["read"], len(calls)), (1, 2))

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


class FlacHeaderTest(unittest.TestCase):
    """flac_header against a real FLAC made by the flac tool, with a cover in it (skipped by seeking)."""

    def setUp(self):
        import shutil
        if not shutil.which("flac"):
            self.skipTest("flac tool not installed")

    def test_reads_tags_and_streaminfo_past_the_picture(self):
        import struct, subprocess, zlib
        with tempfile.TemporaryDirectory() as d:
            raw = Path(d) / "a.raw"
            raw.write_bytes(bytes(44100 * 2 * 2))              # one second of 16-bit stereo silence
            # a 64x64 PNG (the cover), so the PICTURE block is there to be skipped
            row = b"\x00" + b"\xff\x00\x80" * 64
            png = Path(d) / "c.png"
            def chunk(t, b): return struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b) & 0xffffffff)
            png.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 64, 64, 8, 2, 0, 0, 0))
                            + chunk(b"IDAT", zlib.compress(row * 64)) + chunk(b"IEND", b""))
            out = Path(d) / "1.01 - Song.flac"
            subprocess.run(["flac", "-s", "--force-raw-format", "--endian=little", "--sign=signed", "--channels=2", "--bps=16",
                            "--sample-rate=44100", "-T", "TITLE=Song", "-T", "ARTIST=Band", "-T", "DATE=1999-05-04",
                            "-T", "GENRE=Rock", "-T", "TRACKNUMBER=1", "-T", "GENRE=Second", f"--picture={png}", "-o", str(out), str(raw)], check=True)
            tags, info = catalog.flac_header(out)
            self.assertEqual((tags["TITLE"], tags["ARTIST"], tags["DATE"], tags["GENRE"]), ("Song", "Band", "1999-05-04", "Rock"))
            self.assertEqual((info["rate"], info["bits"], info["channels"], round(info["length"], 2)), (44100, 16, 2, 1.0))
            self.assertTrue(info["picture"])
            t = catalog.read_track(out)
            self.assertEqual((t["title"], t["pos"], t["disc"], t["length"], t["lyrics"], t["picture"]), ("Song", 1, 1, 1.0, False, True))
            mime, data = catalog.flac_picture(out)
            self.assertEqual((mime, data), ("image/png", png.read_bytes()))
            cat = catalog.Catalog(Path(d), Path(d))
            self.assertIsNone(cat.cover("x/y"))
            album = Path(d) / "Band" / "Record"
            album.mkdir(parents=True)
            out.rename(album / out.name)
            self.assertEqual(cat.cover("Band/Record"), (data, "image/png"))
            self.assertEqual(catalog.read_album(album, "Band/Record")["cover"], "embedded")
            with self.assertRaises(ValueError):
                catalog.flac_header(png)
