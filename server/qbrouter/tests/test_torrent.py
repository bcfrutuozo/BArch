import base64
import hashlib
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from barch_qbrouter.torrent import (  # noqa: E402
    TorrentError, host_matches, host_of, parse_magnet, parse_torrent, safe_url,
)


def benc(v) -> bytes:
    if isinstance(v, int):
        return b"i%de" % v
    if isinstance(v, str):
        v = v.encode()
    if isinstance(v, bytes):
        return b"%d:%s" % (len(v), v)
    if isinstance(v, list):
        return b"l" + b"".join(benc(x) for x in v) + b"e"
    if isinstance(v, dict):
        return b"d" + b"".join(benc(k) + benc(v[k]) for k in sorted(v)) + b"e"
    raise TypeError(v)


INFO = {"name": "Livro - Autor [2026]", "piece length": 16384, "pieces": b"\x01" * 20, "length": 10, "private": 1}


def torrent(announce=None, announce_list=None, info=None) -> bytes:
    d = {"info": info or INFO}
    if announce:
        d["announce"] = announce
    if announce_list:
        d["announce-list"] = announce_list
    return benc(d)


class TorrentFile(unittest.TestCase):
    def test_hash_is_sha1_of_the_raw_info(self):
        t = parse_torrent(torrent("https://sapibr.com/announce/PASSKEY"))
        self.assertEqual(t.hash, hashlib.sha1(benc(INFO)).hexdigest())
        self.assertEqual(t.trackers, ["https://sapibr.com/announce/PASSKEY"])
        self.assertEqual(t.name, "Livro - Autor [2026]")

    def test_announce_list_merged_without_duplicates(self):
        t = parse_torrent(torrent("udp://a.org:1/x", [["udp://a.org:1/x", "http://b.org/a"], ["http://c.org/a"]]))
        self.assertEqual(t.trackers, ["udp://a.org:1/x", "http://b.org/a", "http://c.org/a"])

    def test_v2_only_uses_truncated_sha256(self):
        info = {"name": "x", "piece length": 16384, "meta version": 2, "file tree": {}}
        t = parse_torrent(torrent("http://a.org/", info=info))
        self.assertEqual(t.hash, hashlib.sha256(benc(info)).hexdigest()[:40])

    def test_hybrid_knows_both_ids(self):
        info = dict(INFO, **{"meta version": 2, "file tree": {}})
        t = parse_torrent(torrent("http://a.org/", info=info))
        self.assertEqual(t.hash, hashlib.sha1(benc(info)).hexdigest())
        self.assertIn(hashlib.sha256(benc(info)).hexdigest()[:40], t.hashes)

    def test_private_flag(self):
        self.assertTrue(parse_torrent(torrent("http://a.org/")).private)
        self.assertFalse(parse_torrent(torrent("http://a.org/", info=dict(INFO, private=0))).private)
        no_flag = {k: v for k, v in INFO.items() if k != "private"}
        self.assertFalse(parse_torrent(torrent("http://a.org/", info=no_flag)).private)

    def test_garbage_is_refused(self):
        for data in (b"", b"<html>login</html>", b"d4:infoi1ee", torrent("http://a/")[:-3], b"d3:abc"):
            with self.assertRaises(TorrentError):
                parse_torrent(data)


class Magnet(unittest.TestCase):
    H = "c12fe1c06bba254a9dc9f519b335aa7c1367a88a"

    def test_hex_and_trackers(self):
        t = parse_magnet(f"magnet:?xt=urn:btih:{self.H.upper()}&dn=X&tr=https%3A%2F%2Fsapibr.com%2Fannounce%2FK")
        self.assertEqual(t.hash, self.H)
        self.assertEqual(t.trackers, ["https://sapibr.com/announce/K"])

    def test_base32(self):
        b32 = base64.b32encode(bytes.fromhex(self.H)).decode()
        self.assertEqual(parse_magnet(f"magnet:?xt=urn:btih:{b32}").hash, self.H)

    def test_no_hash(self):
        with self.assertRaises(TorrentError):
            parse_magnet("magnet:?dn=nothing")


class Hosts(unittest.TestCase):
    def test_match_domain_and_subdomains_only(self):
        self.assertTrue(host_matches("sapibr.com", ["sapibr.com"]))
        self.assertTrue(host_matches("tracker.sapibr.com", ["sapibr.com"]))
        self.assertFalse(host_matches("notsapibr.com", ["sapibr.com"]))
        self.assertFalse(host_matches("sapibr.com.evil.org", ["sapibr.com"]))

    def test_host_of(self):
        self.assertEqual(host_of("udp://Tracker.Example.org:6969/announce"), "tracker.example.org")
        self.assertEqual(host_of("garbage"), "")

    def test_safe_url_drops_passkey_and_apikey(self):
        self.assertEqual(safe_url("https://sapibr.com/announce/SECRET"), "https://sapibr.com/…")
        self.assertNotIn("KEY", safe_url("http://prowlarr:9696/1/download?apikey=KEY&link=x"))


if __name__ == "__main__":
    unittest.main()
