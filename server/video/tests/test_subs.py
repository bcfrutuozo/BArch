"""Which subtitle and audio tracks a trim or a mux keeps (no media: mkvmerge -J shaped tracks)."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from barch_video import sync  # noqa: E402


def t(tid, lang, name="", forced=False, ietf="", sdh=False, kind="subtitles"):
    return {"id": tid, "type": kind, "properties": {"language": lang, "track_name": name, "forced_track": forced,
                                                   "language_ietf": ietf, "flag_hearing_impaired": sdh}}


# the Prada 2 release, as mkvmerge lists it
PRADA = [t(3, "por", "Portuguese (Brazil)", ietf="pt-BR"), t(4, "por", "Portuguese (Brazil) [SDH]", ietf="pt-BR"),
         t(5, "por", "Portuguese (Brazil) [Forced]", forced=True, ietf="pt-BR"), t(6, "eng", "English [SDH]"),
         t(7, "por", "Portuguese (Portugal)", ietf="pt-PT"), t(8, "spa", "Spanish")]


class Subs(unittest.TestCase):
    def ids(self, subs, have=frozenset()):
        return [x["id"] for x in sync.pick_subs(subs, {"por", "eng"}, have)]

    def test_prada(self):
        # PT-BR plain + PT-BR forced; no SDH (not even the only English), no Portugal, no Spanish
        self.assertEqual(self.ids(PRADA), [3, 5])

    def test_sdh_never(self):
        self.assertEqual(self.ids([t(1, "eng", "English [SDH]"), t(2, "eng", "English")]), [2])
        self.assertEqual(self.ids([t(1, "eng", "English [SDH]"), t(2, "por", sdh=True)]), [])

    def test_portugal_only_is_no_portuguese(self):
        self.assertEqual(self.ids([t(1, "por", "Português (Portugal)"), t(2, "eng")]), [2])

    def test_donor_adds_only_what_is_missing(self):
        have = {("por", False), ("eng", False)}
        self.assertEqual(self.ids(PRADA, have), [5])   # the reference lacked only the forced PT-BR


if __name__ == "__main__":
    unittest.main()
