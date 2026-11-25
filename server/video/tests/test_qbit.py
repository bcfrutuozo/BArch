"""integrations.py: what the pipeline hands qBittorrent (hashes, torrent files) and how it reads its log."""
import base64
import hashlib
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from barch_video.integrations import magnet_hash, qbit_failure_reason, torrent_hash  # noqa: E402


def bencode(v) -> bytes:
    if isinstance(v, int):
        return b"i%de" % v
    if isinstance(v, bytes):
        return b"%d:%s" % (len(v), v)
    if isinstance(v, list):
        return b"l" + b"".join(bencode(x) for x in v) + b"e"
    return b"d" + b"".join(bencode(k) + bencode(v[k]) for k in sorted(v)) + b"e"


class Hashes(unittest.TestCase):
    def test_magnet_hex_and_base32(self):
        self.assertEqual(magnet_hash("magnet:?xt=urn:btih:BFCE8870A88C950CCFDE8347B685CDBC3D606632&dn=x"),
                         "bfce8870a88c950ccfde8347b685cdbc3d606632")
        # the same hash in base32 (what some indexers hand out)
        b32 = base64.b32encode(bytes.fromhex("bfce8870a88c950ccfde8347b685cdbc3d606632")).decode()
        self.assertEqual(magnet_hash(f"magnet:?xt=urn:btih:{b32}"), "bfce8870a88c950ccfde8347b685cdbc3d606632")
        self.assertEqual(magnet_hash("https://example.org/x"), "")

    def test_torrent_file(self):
        info = {b"name": b"Movie.mkv", b"length": 1234, b"piece length": 16384, b"pieces": b"\x00" * 20}
        data = bencode({b"announce": b"http://t/a", b"info": info, b"comment": b"c"})
        self.assertEqual(torrent_hash(data), hashlib.sha1(bencode(info)).hexdigest())
        self.assertEqual(torrent_hash(b"<html>not a torrent"), "")
        self.assertEqual(torrent_hash(b"d8:announce3:abce"), "")       # no info dict


class Log(unittest.TestCase):
    ENTRIES = [
        {"id": 1, "type": 4, "message": 'Downloading torrent... Source: "http://prowlarr:9696/1/download?x=1"'},
        {"id": 2, "type": 4, "message": 'Failed to add torrent. Source: "http://prowlarr:9696/1/download?x=1". Reason: "The remote host name was not found (invalid hostname)"'},
        {"id": 3, "type": 4, "message": 'Failed to add torrent. Source: "magnet:?xt=urn:btih:abcdef". Reason: "Torrent is already in the transfer list"'},
    ]

    def test_reason_by_source(self):
        self.assertEqual(qbit_failure_reason(self.ENTRIES, "", "http://prowlarr:9696/1/download?x=1"),
                         "The remote host name was not found (invalid hostname)")
        self.assertEqual(qbit_failure_reason(self.ENTRIES, "ABCDEF"), "Torrent is already in the transfer list")
        self.assertEqual(qbit_failure_reason(self.ENTRIES, "nothing-like-this"), "")
        self.assertEqual(qbit_failure_reason([], "x"), "")

class Existing(unittest.TestCase):
    """A torrent qBittorrent already has (409) is adopted: tagged for the job, its hash returned."""

    def test_409_adopts(self):
        import io
        import urllib.error
        from barch_video.integrations import QBit
        calls = []

        class Fake(QBit):
            def _api(self, method, path, **kw):
                calls.append(path)
                if path == "/torrents/add":
                    raise urllib.error.HTTPError("u", 409, "Conflict", {}, io.BytesIO(b""))
                if path == "/torrents/info":
                    return [{"hash": kw["params"]["hashes"]}]
                return None

        q = Fake({})
        h = q.add("magnet:?xt=urn:btih:BFCE8870A88C950CCFDE8347B685CDBC3D606632", "barch-dub", "barch-s1x1")
        self.assertEqual(h, "bfce8870a88c950ccfde8347b685cdbc3d606632")
        self.assertIn("/torrents/addTags", calls)
        self.assertNotIn("/torrents/setCategory", calls)



if __name__ == "__main__":
    unittest.main()
