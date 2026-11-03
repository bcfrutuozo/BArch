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
