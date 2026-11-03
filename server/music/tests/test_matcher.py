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
                 "Live to Rock (Rock to Live)": "Live to Rock (Rock to Live)", "Volume Two": "Volume Two"}
        for album, want in cases.items():
            h = matcher.hints_from("Deep Purple - Something", [track(album=album, artist="Deep Purple")])
            self.assertEqual(h["album"], want, album)

    def test_folder_name(self):
        h = matcher.hints_from("Deep Purple - The Now What! Live Tapes", [])
        self.assertEqual((h["artist"], h["album"], h["year"]), ("Deep Purple", "The Now What! Live Tapes", ""))
        h = matcher.hints_from("Pink Floyd - The Wall (1979,2000) [FLAC] 88", [])
        self.assertEqual((h["artist"], h["album"], h["year"]), ("Pink Floyd", "The Wall", "1979"))
