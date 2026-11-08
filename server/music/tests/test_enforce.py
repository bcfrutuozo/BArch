"""Lidarr's enforce against the library: an album /music already holds is never monitored or searched,
whatever Lidarr's file count says; an artist the sweep has not finished waits."""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from barch_music import integrations  # noqa: E402


class Names(unittest.TestCase):
    def test_norm(self):
        self.assertEqual(integrations.norm_name("Iron Man: The Best of Black Sabbath"), "iron man the best of black sabbath")
        self.assertEqual(integrations.norm_name("Iron Man - The Best of Black Sabbath"), "iron man the best of black sabbath")
        self.assertEqual(integrations.norm_name("Greatest Hits (2008)"), "greatest hits")
        self.assertEqual(integrations.norm_name("Motörhead"), "motorhead")
        self.assertEqual(integrations.norm_name("Stevie Ray Vaughan & Double Trouble"), integrations.norm_name("Stevie Ray Vaughan and Double Trouble"))
        self.assertEqual(integrations.norm_name("It Won’t Be Soon Before Long"), "it wont be soon before long")
        self.assertEqual(integrations.norm_name("It Won't Be Soon Before Long"), integrations.norm_name("It Won’t Be Soon Before Long"))

    def test_in_library(self):
        folders = {"black sabbath": {"vol 4", "black sabbath", "greatest hits"}, "iron maiden": {"piece of mind"}}
        self.assertTrue(integrations.in_library(folders, "Black Sabbath", "Vol. 4"))
        self.assertTrue(integrations.in_library(folders, "Black Sabbath", "Greatest Hits"))
        self.assertFalse(integrations.in_library(folders, "Black Sabbath", "Sabotage"))
        self.assertFalse(integrations.in_library(folders, "Dio", "Holy Diver"))
        self.assertTrue(integrations.in_library(folders, "Iron Maiden", "Piece of Mind"))


class FakeHttp:
    def __init__(self, albums):
        self.albums = albums
        self.calls = []

    def call(self, method, path, params=None, body=None):
        self.calls.append((method, path, body))
        if path == "/api/v1/artist":
            return [{"id": 1, "artistName": "Black Sabbath", "path": "/music/Black Sabbath", "metadataProfileId": 7, "monitorNewItems": "all", "foreignArtistId": "mb-bs"},
                    {"id": 2, "artistName": "Dio", "path": "/music/Dio", "metadataProfileId": 7, "monitorNewItems": "all", "foreignArtistId": "mb-dio"}]
        if path == "/api/v1/album":
            return self.albums
        return {}


def album(i, artist, title, monitored=False, files=0, tracks=10):
    return {"id": i, "artistId": artist, "title": title, "monitored": monitored, "anyReleaseOk": True,
            "statistics": {"trackFileCount": files, "trackCount": tracks}}


class Enforce(unittest.TestCase):
    def run_enforce(self, albums, has_folder=None, sweep_done=None):
        lid = integrations.Lidarr({"api_key": "k"})
        lid.h = FakeHttp(albums)
        lid.release_rules = lambda: ""
        lid.commands = lambda: []
        lid.metadata_profiles = lambda: [{"id": 7, "name": "BArch"}]
        with tempfile.TemporaryDirectory() as d:
            seen = Path(d) / "seen.json"
            out = lid.enforce("BArch", seen, canon=None, has_folder=has_folder, sweep_done=sweep_done)
            state = json.loads(seen.read_text())
        return out, lid.h.calls, state

    def test_without_the_library_every_fileless_album_is_monitored_and_searched(self):
        out, calls, _ = self.run_enforce([album(10, 1, "Vol. 4"), album(11, 2, "Holy Diver"), album(12, 2, "Dream Evil", files=9)])
        monitor = [c for c in calls if c[1] == "/api/v1/album/monitor"]
        search = [c for c in calls if c[1] == "/api/v1/command"]
        self.assertEqual(monitor[0][2], {"albumIds": [10, 11], "monitored": True})
        self.assertEqual(search[0][2], {"name": "AlbumSearch", "albumIds": [10, 11]})
        self.assertIn("2 album(s) without a file monitored and searched", out)

    def test_an_album_with_a_folder_is_left_alone_and_unmonitored(self):
        folders = {"black sabbath": {"vol 4"}}
        has = lambda a, t: integrations.in_library(folders, a, t)  # noqa: E731
        out, calls, state = self.run_enforce([album(10, 1, "Vol. 4", monitored=True), album(11, 2, "Holy Diver")], has_folder=has)
        monitor = [c[2] for c in calls if c[1] == "/api/v1/album/monitor"]
        self.assertIn({"albumIds": [10], "monitored": False}, monitor)
        self.assertIn({"albumIds": [11], "monitored": True}, monitor)
        search = [c for c in calls if c[1] == "/api/v1/command"]
        self.assertEqual(search[0][2]["albumIds"], [11])
        self.assertIn("1 album(s) Lidarr lists as missing but /music already has", out)
        self.assertIn(10, state["dropped"])
        # monitored again (a RefreshArtist after the sweep's rescan does that): unmonitored again
        lid = integrations.Lidarr({"api_key": "k"})
        lid.h = FakeHttp([album(10, 1, "Vol. 4", monitored=True)])
        lid.release_rules = lambda: ""
        lid.commands = lambda: []
        lid.metadata_profiles = lambda: [{"id": 7, "name": "BArch"}]
        with tempfile.TemporaryDirectory() as d:
            seen = Path(d) / "seen.json"
            seen.write_text(json.dumps(state))
            lid.enforce("BArch", seen, canon=None, has_folder=has)
        self.assertEqual([c[2] for c in lid.h.calls if c[1] == "/api/v1/album/monitor"], [{"albumIds": [10], "monitored": False}])

    def test_a_partial_album_with_a_folder_is_unmonitored_too(self):
        # Lidarr's release has 137 tracks, Bruno's "On Air" 24 files: "missing" to Lidarr and Soularr
        folders = {"black sabbath": {"on air", "the end"}}
        has = lambda a, t: integrations.in_library(folders, a, t)  # noqa: E731
        out, calls, _ = self.run_enforce([album(10, 1, "On Air", monitored=True, files=24, tracks=137),
                                          album(11, 1, "The End", monitored=True, files=10, tracks=10),
                                          album(12, 2, "Holy Diver", monitored=True, files=8, tracks=9)], has_folder=has)
        monitor = [c[2] for c in calls if c[1] == "/api/v1/album/monitor"]
        self.assertEqual(monitor, [{"albumIds": [10], "monitored": False}])   # complete and no-folder partial: untouched
        self.assertIn("1 album(s) Lidarr lists as missing", out)

    def test_an_artist_the_sweep_has_not_finished_waits(self):
        out, calls, _ = self.run_enforce([album(10, 1, "Sabotage"), album(11, 2, "Holy Diver")], sweep_done=lambda a: a != "Black Sabbath")
        monitor = [c[2] for c in calls if c[1] == "/api/v1/album/monitor"]
        self.assertEqual(monitor, [{"albumIds": [11], "monitored": True}])
        self.assertIn("1 album(s) wait for the library sweep", out)


if __name__ == "__main__":
    unittest.main()
