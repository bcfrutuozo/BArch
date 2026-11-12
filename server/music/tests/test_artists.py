"""The artist folders of /music against Lidarr's artists (artists.classify) and the credits of a folder's
releases (artists.count_credits)."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from barch_music import artists  # noqa: E402


def lid(i, name, path, files=0, mbid="", albums=0):
    return {"id": i, "name": name, "path": path, "files": files, "albums": albums, "mbid": mbid or f"{i:08d}-0000-0000-0000-000000000000"}


class Classify(unittest.TestCase):
    def rows(self, folders, tagged, lidarr, pending=(), skipped=(), credited=None):
        return {r["key"]: r for r in artists.classify(folders, tagged, lidarr, list(pending), set(skipped), credited)}

    def test_linked_and_suspect(self):
        r = self.rows([{"name": "Dio", "albums": 3}, {"name": "Ghost", "albums": 2}, {"name": "Rush", "albums": 1}],
                      {"Dio": 3, "Ghost": 2},
                      [lid(1, "Dio", "/music/Dio", files=30), lid(2, "Ghost", "/music/Ghost", albums=12), lid(3, "Rush", "/music/Rush")])
        self.assertEqual(r["Dio"]["state"], "linked")
        self.assertEqual(r["Ghost"]["state"], "suspect")          # tagged albums, nothing mapped, credits unknown yet
        self.assertEqual(r["Rush"]["state"], "linked")            # nothing tagged yet: no reason to doubt it

    def test_credits_settle_it(self):
        folders = [{"name": "Ghost", "albums": 2}, {"name": "Glenn Stafford", "albums": 1}, {"name": "Ozzy", "albums": 4}]
        lidarr = [lid(2, "Ghost", "/music/Ghost", albums=12, mbid="ghost-swe"), lid(3, "Glenn Stafford", "/music/Glenn Stafford", mbid="gs"),
                  lid(4, "Ozzy", "/music/Ozzy", albums=20, mbid="ozzy")]
        r = self.rows(folders, {"Ghost": 2, "Glenn Stafford": 1, "Ozzy": 4}, lidarr,
                      credited={"Ghost": {"ghost-usa"}, "Glenn Stafford": {"gs"}, "Ozzy": {"ozzy"}})
        self.assertEqual(r["Ghost"]["state"], "suspect")          # credited to a namesake
        self.assertEqual(r["Glenn Stafford"]["state"], "linked")  # right artist, no album in Lidarr (a Soundtrack)
        self.assertIn("metadata profile", r["Glenn Stafford"]["why"])
        self.assertEqual(r["Ozzy"]["state"], "linked")            # right artist, not rescanned yet
        self.assertIn("not mapped", r["Ozzy"]["why"])

    def test_missing_names_the_artist_lidarr_has_elsewhere(self):
        r = self.rows([{"name": "Ghost B.C", "albums": 1}, {"name": "Ghost", "albums": 4}], {},
                      [lid(2, "Ghost B.C.", "/music/Ghost", files=40)])
        self.assertEqual(r["Ghost B.C"]["state"], "missing")
        self.assertIn("/music/Ghost", r["Ghost B.C"]["why"])
        self.assertEqual(r["Ghost"]["state"], "linked")

    def test_pending_skipped_and_no_folder(self):
        r = self.rows([{"name": "THE SQUARE", "albums": 5}, {"name": "Дип Пёрпл", "albums": 1}], {},
                      [lid(7, "Mark Knopfler", "/music/Mark Knopfler")],
                      pending=[{"mbid": "x", "folder": "THE SQUARE"}], skipped=["Дип Пёрпл"])
        self.assertEqual(r["THE SQUARE"]["state"], "pending")
        self.assertEqual(r["Дип Пёрпл"]["state"], "skipped")
        self.assertEqual(r["lidarr:7"]["state"], "no-folder")
        self.assertEqual(r["lidarr:7"]["folder"], "")

    def test_other_scripts_do_not_collide(self):
        # Cyrillic and Japanese names flatten to "": no "Lidarr tracks 下村陽子" for "Дип Пёрпл"
        r = self.rows([{"name": "Дип Пёрпл", "albums": 1}], {}, [lid(1, "下村陽子", "/music/Yoko Shimomura", files=20)])
        self.assertEqual(r["Дип Пёрпл"]["why"], "not in Lidarr")

    def test_path_match_is_exact(self):
        # the folder is the path's last part, as Lidarr has it; a namesake path elsewhere does not link it
        r = self.rows([{"name": "Queensrÿche", "albums": 9}], {"Queensrÿche": 9},
                      [lid(1, "Queensrÿche", "/music/Queensrÿche", files=100),
                       lid(2, "Queensrÿche", "/music/Queensrÿche (Geoff Tate’s temporary version)")])
        self.assertEqual(r["Queensrÿche"]["lidarr"]["id"], 1)
        self.assertEqual(r["lidarr:2"]["state"], "no-folder")


class Move(unittest.TestCase):
    def test_plan(self):
        moves, stay = artists.plan_move(["Opera", "Prequelle", "Infestissumam"], ["Opus Eponymous", "Prequelle"])
        self.assertEqual(moves, ["Opera", "Infestissumam"])
        self.assertEqual(stay, ["Prequelle"])

    def test_move_on_disk(self):
        import tempfile
        with tempfile.TemporaryDirectory() as t:
            music = Path(t) / "music"
            for f in ("Ghost B.C/Infestissumam", "Ghost/Opus Eponymous", "THE SQUARE/Lucky Summer Lady", "THE SQUARE/x.jpg.d"):
                (music / f).mkdir(parents=True)
            (music / "Ghost B.C/Infestissumam/1.01 - Infestissumam.flac").write_bytes(b"")

            class Lib:
                state = {"Ghost B.C/Infestissumam": {"state": "had", "mbid": "r1"}}
                saved = 0
                def save(self): Lib.saved += 1

            class Lid:
                asked = []
                def rescan_artists(self, f): Lid.asked.append(f); return "Lidarr: rescanned"
                def artists(self): return []

            a = artists.Artists(music, Path(t), Lid(), Lib(), lambda x: [], lambda: [])
            out = a.move("Ghost B.C", "Ghost")
            self.assertTrue((music / "Ghost/Infestissumam/1.01 - Infestissumam.flac").exists())
            self.assertFalse((music / "Ghost B.C").exists())              # empty: removed
            self.assertIn("Ghost/Infestissumam", Lib.state)
            self.assertNotIn("Ghost B.C/Infestissumam", Lib.state)
            self.assertEqual(Lid.asked, [["Ghost"]])
            self.assertIn("removed (empty)", out)
            with self.assertRaises(ValueError):
                a.move("Ghost", "Ghost")
            with self.assertRaises(ValueError):
                a.move("Nope", "Ghost")


class Replace(unittest.TestCase):
    def test_replace_trashes_the_one_there(self):
        import tempfile
        with tempfile.TemporaryDirectory() as t:
            music = Path(t) / "music"
            (music / "Ghost B.C/Infestissumam").mkdir(parents=True)
            (music / "Ghost B.C/Infestissumam/1.12 - I'm a Marionette.flac").write_bytes(b"")
            (music / "Ghost/Infestissumam").mkdir(parents=True)
            (music / "Ghost/Infestissumam/1.11 - La Mantra Mori [Bonus].flac").write_bytes(b"")

            class Lib:
                state = {"Ghost/Infestissumam": {"state": "had", "mbid": "r11"}, "Ghost B.C/Infestissumam": {"state": "had", "mbid": "r12"}}
                def save(self): pass
                def forget(self, f): Lib.state.pop(f, None)

            class Lid:
                def rescan_artists(self, f): return ""

            a = artists.Artists(music, Path(t), Lid(), Lib(), lambda x: [], lambda: [])
            with self.assertRaises(ValueError):
                a.move("Ghost B.C", "Ghost")                         # without replace: nothing to move
            out = a.move("Ghost B.C", "Ghost", replace=True)
            self.assertTrue((music / "Ghost/Infestissumam/1.12 - I'm a Marionette.flac").exists())
            self.assertFalse((music / "Ghost B.C").exists())
            trashed = list((music / ".library-trash").iterdir())
            self.assertEqual(len(trashed), 1)
            self.assertTrue((trashed[0] / "1.11 - La Mantra Mori [Bonus].flac").exists())
            self.assertEqual(Lib.state["Ghost/Infestissumam"]["mbid"], "r12")
            self.assertIn("replaced", out)


class Credits(unittest.TestCase):
    def test_most_credited_first_and_once_per_release(self):
        a = {"mbid": "a", "name": "T-SQUARE"}
        b = {"mbid": "b", "name": "THE SQUARE"}
        out = artists.count_credits([[b], [a, a], [a], [{"mbid": "", "name": "unknown"}]])
        self.assertEqual([(e["mbid"], e["releases"]) for e in out], [("a", 2), ("b", 1)])

    def test_mbid_of(self):
        self.assertEqual(artists.mbid_of("https://musicbrainz.org/artist/C3A5FE48-3F4C-4FAD-8AFE-0D2DBB0C6B5C"),
                         "c3a5fe48-3f4c-4fad-8afe-0d2dbb0c6b5c")
        self.assertEqual(artists.mbid_of("Mark Knopfler"), "")


if __name__ == "__main__":
    unittest.main()
