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


def a(tid, lang, default=False, name=""):
    return {"id": tid, "type": "audio", "codec": "AC-3", "properties": {"language": lang, "track_name": name,
                                                                        "default_track": default}}


class Trim(unittest.TestCase):
    """trim_plan over mkvmerge -J shaped files (mkvmerge_ids patched): what goes, what is kept, the default."""

    def plan(self, tracks, original=("eng",), subs=("por", "eng")):
        real = sync.mkvmerge_ids
        sync.mkvmerge_ids = lambda path: {"tracks": [{"id": 0, "type": "video", "properties": {}}] + tracks}
        try:
            return sync.trim_plan("x.mkv", list(original), list(subs))
        finally:
            sync.mkvmerge_ids = real

    def test_german_dl_without_ptbr(self):
        # Family Guy S03E01 German.AC3.DL-FuN: German first and default, English second, German subtitles.
        # Trimmed before any dub exists: English alone, default, no subtitles left
        plan = self.plan([a(1, "ger", default=True), a(2, "eng"), t(3, "ger")])
        self.assertEqual(plan["keep_audio"], [2])
        self.assertEqual(plan["drop_audio"], ["deu AC-3"])
        self.assertEqual(plan["drop_subs"], ["deu"])
        self.assertTrue(plan["reorder"])
        self.assertFalse(plan["por"])

    def test_with_ptbr_keeps_both(self):
        plan = self.plan([a(1, "por", default=True), a(2, "eng"), a(3, "fre"), t(4, "por"), t(5, "fre")])
        self.assertEqual(plan["keep_audio"], [2, 1])
        self.assertEqual(plan["drop_audio"], ["fra AC-3"])
        self.assertEqual(plan["keep_subs"], [4])
        self.assertTrue(plan["por"])

    def test_nothing_to_do(self):
        self.assertIsNone(self.plan([a(1, "eng", default=True), t(2, "eng"), t(3, "por")]))
        self.assertIsNone(self.plan([a(1, "eng", default=True), a(2, "por"), t(3, "eng")]))

    def test_no_original_audio_is_not_trimmed(self):
        # a German-only file of an English series: another release fixes it, not a remux
        self.assertIsNone(self.plan([a(1, "ger", default=True), t(2, "ger")]))

    def test_not_matroska(self):
        self.assertIsNone(sync.trim_plan("x.mp4", ["eng"], ["por", "eng"]))


if __name__ == "__main__":
    unittest.main()
