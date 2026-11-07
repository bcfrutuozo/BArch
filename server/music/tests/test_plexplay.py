"""plexplay.py: the desktop player's tracks found among a Plex album's children by file path, and a report
that goes to Plex's timeline (a fake Plex here)."""
import tempfile
import unittest
from pathlib import Path

from barch_music import plexplay


class FakePlex:
    path_prefix = "/data/music"
    enabled = True

    def __init__(self):
        self.calls = []
        self.h = self
        self.base = "https://plex"

    def album_key(self, folder):
        return "77" if folder == "Band/Record" else ""

    def call(self, method, path, params=None, **kw):
        self.calls.append((path, params))
        if path == "/library/metadata/77/children":
            return {"MediaContainer": {"Metadata": [
                {"ratingKey": "101", "duration": 200000, "Media": [{"Part": [{"file": "/data/music/Band/Record/1.01 - One.flac"}]}]},
                {"ratingKey": "102", "duration": 180000, "Media": [{"Part": [{"file": "/data/music/Band/Record/1.02 - Two.flac"}]}]},
                {"ratingKey": "999", "duration": 1, "Media": [{"Part": [{"file": "/data/music/Other/Record/1.01 - One.flac"}]}]}]}}
        return {}

    def timeline(self, key, state, t, d, session, device):
        self.calls.append(("timeline", key, state, t, d, session, device))


class PlexPlayTest(unittest.TestCase):
    def test_match_children_by_path(self):
        got = plexplay.match_children([{"ratingKey": "5", "duration": 10, "Media": [{"Part": [{"file": "/m/A/B/x.flac"}]}]},
                                       {"ratingKey": "6", "Media": [{"Part": [{"file": "/m/A/C/x.flac"}]}]}], "/m/A/B/")
        self.assertEqual(got, {"x.flac": {"key": "5", "duration": 10}})

    def test_report_resolves_caches_and_sends(self):
        with tempfile.TemporaryDirectory() as d:
            plex = FakePlex()
            pp = plexplay.PlexPlay(plex, Path(d))
            r = pp.report({"folder": "Band/Record", "file": "1.02 - Two.flac", "state": "playing", "time": 12.5, "duration": 180, "session": "s1", "device": "desk"})
            self.assertEqual((r["ok"], r["key"]), (True, "102"))
            self.assertEqual(plex.calls[-1], ("timeline", "102", "playing", 12500, 180000, "s1", "desk"))
            self.assertEqual(len(pp.sessions), 1)
            # the second track of the album needs no Plex lookup (cached), a stop clears the session
            n = len(plex.calls)
            r = pp.report({"folder": "Band/Record", "file": "1.01 - One.flac", "state": "stopped", "time": 199, "duration": 200, "session": "s1", "device": "desk"})
            self.assertTrue(r["ok"])
            self.assertEqual([c for c in plex.calls[n:] if c[0] != "timeline"], [])
            self.assertEqual(pp.sessions, {})
            # survives a restart
            again = plexplay.PlexPlay(plex, Path(d))
            self.assertEqual(again.keys["Band/Record"]["1.01 - One.flac"]["key"], "101")
            # an unknown file is looked up once more, then reported as missing
            r = pp.report({"folder": "Band/Record", "file": "1.03 - Nope.flac", "state": "playing"})
            self.assertFalse(r["ok"])
            self.assertIn("not found", r["error"])
            r = pp.report({"folder": "Band/Record", "file": "1.01 - One.flac", "state": "dancing"})
            self.assertFalse(r["ok"])


if __name__ == "__main__":
    unittest.main()
