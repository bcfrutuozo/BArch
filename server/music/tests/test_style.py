"""The naming rules (barch_music/style.py) against the library's own examples.

    python3 -m unittest discover -s server/music/tests
    LIBRARY_JSON=/path/library.json python3 -m unittest ...   # also every track of the library
"""
import json
import os
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from barch_music import style  # noqa: E402


class FileNames(unittest.TestCase):
    def test_characters(self):
        cases = {
            "Three Mile Smile / Reefer Head Woman": "Three Mile Smile , Reefer Head Woman",
            "What Could Have Been Love?": "What Could Have Been Love!",
            "Lasting Child: I. The Parting Words": "Lasting Child- I. The Parting Words",
            'The Council of Elrond [feat. "Aníron"]': "The Council of Elrond [feat. 'Aníron']",
            "F*cking Robots": "F-cking Robots",
            "F.I.N.E.": "F.I.N.E.",
            "Why Didn’t Rosemary?": "Why Didn’t Rosemary!",
        }
        for tag, name in cases.items():
            self.assertEqual(style.file_title(tag), name)
        self.assertEqual(style.file_name(2, 1, "Unholy Wars"), "2.01 - Unholy Wars.flac")

    def test_folders(self):
        self.assertEqual(style.folder_name("Devil's Got a New Disguise: The Very Best of Aerosmith"),
                         "Devil's Got a New Disguise_ The Very Best of Aerosmith")
        self.assertEqual(style.folder_name("Are You Dead Yet?"), "Are You Dead Yet_")
        self.assertEqual(style.folder_name("G."), "G")
        self.assertEqual(style.folder_name('Club Circuit "Human"'), "Club Circuit -Human-")
        self.assertEqual(style.folder_name("World Tour 2005/2006"), "World Tour 2005_2006")


class Titles(unittest.TestCase):
    def test_title_case(self):
        cases = {
            "Whiskey In The Jar": "Whiskey in the Jar",
            "Dream On": "Dream On",                         # last word of a part keeps its capital
            "Monkey On My Back": "Monkey on My Back",        # whole words only: not "MonKey"
            "Whiskey In the Jar": "Whiskey in the Jar",      # not "WhisKey"
            "'Freedom' / The Execution": "'Freedom' / The Execution",
            "Lasting Child: I. The Parting Words": "Lasting Child: I. The Parting Words",
            "ReTurn To Avantasia": "Return to Avantasia",
            "TV Crimes": "TV Crimes",
            "JIRENMA (Movie Size)": "JIRENMA (Movie Size)",
            "Wake up the Mountain": "Wake Up the Mountain",
        }
        for a, b in cases.items():
            self.assertEqual(style.title_case(a), b, a)

    def test_musicbrainz_to_library(self):
        cases = {
            "Memories (remix) (feat. Nipsey Hussle & YG)": "Memories [feat. Nipsey Hussle; YG - Remix]",
            "Walk This Way (live)": "Walk This Way [Live]",
            "Pink (The South Beach mix)": "Pink [The South Beach Mix]",
            "Falling in Love (Is Hard on the Knees)": "Falling in Love (Is Hard on the Knees)",
            "Fear of the Dark (live at Rock in Rio)": "Fear of the Dark [Live at Rock in Rio]",
            "Breaking the Law (radio edit)": "Breaking the Law [Radio Edit]",
            "Song (feat. A, B & C) (acoustic)": "Song [feat. A; B; C - Acoustic]",
            "Born to Raise Hell (feat. Doro Pesch and Whitfield Crane)": "Born to Raise Hell [feat. Doro Pesch; Whitfield Crane]",
            "Tons [part. Mangueira do Amanhã]": "Tons [part. Mangueira do Amanhã]",
            "Overture [From Opera 'La mia verita']": "Overture [From Opera 'La mia verita']",
        }
        for a, b in cases.items():
            self.assertEqual(style.make_title(a), b, a)

    def test_order_inside_brackets(self):
        self.assertEqual(style.make_title("Walk [Live - Bonus]"), "Walk [Bonus - Live]")
        self.assertEqual(style.make_title("Reach a Little Longer", parts=["acoustic", "bonus"]),
                         "Reach a Little Longer [Bonus - Acoustic]")
        self.assertEqual(style.make_title("Sacred Worlds", feats=["Hansi Kürsch"], parts=["live", "bonus"]),
                         "Sacred Worlds [feat. Hansi Kürsch - Bonus - Live]")
        self.assertEqual(style.make_title("Movin' Out", parts=["alternate", "unreleased"]),
                         "Movin' Out [Unreleased - Alternate]")


@unittest.skipUnless(os.environ.get("LIBRARY_JSON"), "LIBRARY_JSON not set")
class Library(unittest.TestCase):
    """The real library (a scan of /music: artist_dir, album_dir, file, tags)."""

    @classmethod
    def setUpClass(cls):
        cls.rows = json.load(open(os.environ["LIBRARY_JSON"]))

    def test_every_file_name(self):
        bad = []
        for r in self.rows:
            m = re.match(r"^\d{1,2}\.\d{2} - (.*)\.flac$", r["file"])
            t = (r["tags"].get("TITLE") or [""])[0]
            if m and t and style.file_title(t) != m.group(1):
                bad.append((r["file"], t))
        self.assertLess(len(bad), 5, bad[:5])        # one known: a double space in a Portuguese title


class WikipediaDates(unittest.TestCase):
    """The release field of an album's infobox, in the formats the Wikipedias use."""

    def test_formats(self):
        from barch_music import mb
        cases = {"{{Start date|1984|9|14}}": ["1984-09-14"], "September 14, 1984": ["1984-09-14"],
                 "14 September 1984 (US)": ["1984-09-14"], "1 de setembro de 1991": ["1991-09-01"],
                 "1º settembre 1991": ["1991-09-01"], "1. September 1991": ["1991-09-01"],
                 "1991年9月12日": ["1991-09-12"], "{{Start date|df=yes|1983|09|01}}": ["1983-09-01"],
                 "1981 (Europe)<br />May 1982 (UK)": []}            # no day: not a date
        for text, want in cases.items():
            self.assertEqual(mb._dates_in(text), want, text)
