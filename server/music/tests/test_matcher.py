"""What the matcher reads from a download before asking MusicBrainz (no network)."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from barch_music import matcher  # noqa: E402
from barch_music.audio import Track  # noqa: E402


def track(**hints):
    return Track(Path("x.flac"), 1, 1, 44100, 44100, 16, hints)


class Hints(unittest.TestCase):
    def test_disc_suffix(self):
        cases = {"The Now What! Live Tapes (CD1, VICP-70192)": "The Now What! Live Tapes",
                 "Pandora's Box CD 1": "Pandora's Box", "The Wall (1)": "The Wall", "Made in Japan (Disc 2)": "Made in Japan",
                 "Live to Rock (Rock to Live)": "Live to Rock (Rock to Live)", "Volume Two": "Volume Two",
                 "The platinum collection, disc 2": "The platinum collection",
                 "Aerosmith (CD1- Box Of Fire)": "Aerosmith", "Toys In The Attic (CD3 - Box Of Fire)": "Toys In The Attic"}
        for album, want in cases.items():
            h = matcher.hints_from("Deep Purple - Something", [track(album=album, artist="Deep Purple")])
            self.assertEqual(h["album"], want, album)

    def test_folder_name(self):
        # real torrent names of 2026-11-02/03: the release and uploader tags go, the title stays
        cases = {
            "Deep Purple - The Now What! Live Tapes": ("Deep Purple", "The Now What! Live Tapes", ""),
            "Pink Floyd - The Wall (1979,2000) [FLAC] 88": ("Pink Floyd", "The Wall", "1979"),
            "Deep Purple - The Best Of - [EAC]-[FLAC]": ("Deep Purple", "The Best Of", ""),
            "Deep Purple - Greatest Hits (2022) (3 CD) [FLAC] [rjk]": ("Deep Purple", "Greatest Hits", "2022"),
            "Deep Purple - Original Album Classics - (2011)-[FLAC]-[TFM]": ("Deep Purple", "Original Album Classics", "2011"),
            "Deep Purple - Lazy Sod (2024) [24Bit-48kHz] FLAC [PMEDIA] ⭐️": ("Deep Purple", "Lazy Sod", "2024"),
            "Dokken - Live From The Sun - 2000 {US, CMC Int., 06076 86285-2}": ("Dokken", "Live From The Sun", "2000"),
            "Deep Purple - Fireball (1971) (UK PBTHAL LP 24-96) [FLAC] vtwin88cube": ("Deep Purple", "Fireball", "1971"),
            "Deep Purple - Rapture of the Deep (20th Anniversary Remix) (2001 Metal) [Flac 24-48]":
                ("Deep Purple", "Rapture of the Deep (20th Anniversary Remix)", "2001"),
            "Deep Purple–Soldier Of Fortune-The Greatest Hits": ("Deep Purple", "Soldier Of Fortune The Greatest Hits", ""),
            "Deep Purple - 2017 - Time For Bedlam": ("Deep Purple", "Time For Bedlam", "2017"),
            "1984 Tooth And Nail": ("", "Tooth And Nail", "1984"),
            "Deep Purple - The platinum collection, disc 1": ("Deep Purple", "The platinum collection", ""),
        }
        for name, want in cases.items():
            h = matcher.hints_from(name, [])
            self.assertEqual((h["artist"], h["album"], h["year"]), want, name)


class OneDiscForTwo(unittest.TestCase):
    """Purpendicular, "2LP" as one CUE of 13 tracks; MusicBrainz MOVLP 361 is 2x12" Vinyl, 6 + 7 (2026-11-04)."""
    MB = [[("Vavoom: Ted the Mechanic", 258), ("Loosen My Strings", 360), ("Soon Forgotten", 288),
           ("Sometimes I Feel Like Screaming", 452), ("Cascades: I'm Not Your Lover", 284), ("The Aviator", 321)],
          [("Rosa's Cantina", 312), ("A Castle Full of Rascals", 312), ("A Touch Away", 276), ("Hey Cisco", 354),
           ("Somebody Stole My Guitar", 249), ("The Purpendicular Waltz", 284), ("Don't Hold Your Breath", 280)]]
    OURS = [256, 357, 287, 449, 283, 320, 309, 308, 276, 354, 249, 283.4, 280.6]

    def release(self):
        return {"id": "r", "title": "Purpendicular", "artist-credit": [{"name": "Deep Purple", "joinphrase": ""}],
                "media": [{"format": '12" Vinyl', "tracks": [{"title": t, "length": l * 1000, "position": i}
                                                             for i, (t, l) in enumerate(d, 1)]} for d in self.MB]}

    def tracks(self, lengths):
        flat = [t for d in self.MB for t, _ in d]
        return [Track(Path(f"{i}.flac"), 1, i, int(s * 44100), 44100, 16, {"title": flat[i - 1]})
                for i, s in enumerate(lengths, 1)]

    def test_split_follows_musicbrainz(self):
        c = matcher._candidate(self.release())
        matcher.score(c, self.tracks(self.OURS), {"artist": "DEEP PURPLE", "album": "Purpendicular"})
        self.assertTrue(c.ok, c.why)
        discs, split = matcher.discs_for(self.tracks(self.OURS), c.media)
        self.assertTrue(split)
        self.assertEqual([len(v) for v in discs.values()], [6, 7])
        self.assertEqual(discs[2][0].hints["title"], "Rosa's Cantina")

    def test_split_still_needs_the_lengths(self):
        c = matcher._candidate(self.release())
        matcher.score(c, self.tracks(list(reversed(self.OURS))), {"artist": "DEEP PURPLE", "album": "Purpendicular"})
        self.assertFalse(c.ok)

    def test_other_total_is_not_split(self):
        _, split = matcher.discs_for(self.tracks(self.OURS[:12]), self.release()["media"])
        self.assertFalse(split)

    def test_compare_rows(self):
        job = [{"disc": 1, "index": i, "seconds": s, "title": t}
               for i, (s, t) in enumerate(zip(self.OURS, [t for d in self.MB for t, _ in d]), 1)]
        job[3]["seconds"] = 400                               # one track cut short
        c = matcher.compare(job[:12], self.release())          # and the last one missing: no split
        self.assertFalse(c["split"])
        self.assertEqual(len(c["rows"]), 13)
        self.assertEqual(c["rows"][3]["diff"], 52)
        self.assertIsNone(c["rows"][12]["seconds"])           # MusicBrainz 2.07 has nothing in front of it
        full = matcher.compare(job, self.release())
        self.assertTrue(full["split"])
        self.assertEqual((full["rows"][6]["disc"], full["rows"][6]["pos"], full["rows"][6]["file"]), (2, 1, "1.07"))
        self.assertEqual(full["rows"][6]["title_sim"], 1.0)
