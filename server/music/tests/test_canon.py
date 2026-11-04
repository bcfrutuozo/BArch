"""Which release groups count as official (canon.judge, no network): cases from Deep Purple and T-SQUARE."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from barch_music import canon  # noqa: E402

WD = [{"type": "wikidata", "url": {"resource": "https://www.wikidata.org/wiki/Q1"}}]


def g(gid, title, primary="Album", secondary=(), date="1970", wd=False):
    return {"id": gid, "title": title, "primary-type": primary, "secondary-types": list(secondary),
            "first-release-date": date, "relations": WD if wd else []}


class Judge(unittest.TestCase):
    def test_rules(self):
        groups = [
            g("burn", "Burn", date="1974-02-15", wd=True),
            g("burn-ep", "Burn", "EP", date="1974-01-01"),                         # same title, the album is on Wikidata
            g("mij", "Made in Japan", secondary=["Live"], wd=True),
            g("aachen", "Live in Aachen 1970", secondary=["Live"], date="2001"),     # italics on Wikipedia
            g("stereo", "Stereo Pop Special‐12", secondary=["Compilation"]),          # nowhere
            g("dp-comp1", "Deep Purple", secondary=["Compilation"], date="1977"),
            g("dp-comp2", "Deep Purple", secondary=["Compilation"], date="1987"),
            g("studio", "Abandon"),                                                   # studio: always
            g("pair", "Machine Head / Who Do We Think We Are", secondary=["Compilation"]),
            g("fw", "Live Farewell & Welcome", secondary=["Live"]),                   # home wiki running text
            g("ys", "Best Live", secondary=["Live"]),                                  # too short for the text
        ]
        quoted = {canon.norm(t) for t in ("Burn", "Live in Aachen 1970", "Deep Purple")}
        text = " " + canon.norm("1991年 Live Farewell & Welcome を発売 Best Live machine head who do we think we are") + " "
        v = canon.judge(groups, quoted, text)
        self.assertEqual(v["burn"], "studio")
        self.assertEqual(v["burn-ep"], "")
        self.assertEqual(v["mij"], "wikidata")
        self.assertEqual(v["aachen"], "wikipedia")
        self.assertEqual(v["stereo"], "")
        self.assertEqual((v["dp-comp1"], v["dp-comp2"]), ("wikipedia", ""))     # one of the same title only
        self.assertEqual(v["studio"], "studio")
        self.assertEqual(v["fw"], "wikipedia text")
        self.assertEqual(v["ys"], "")
        self.assertEqual(v["pair"], "")              # a pair "A / B" never by the running text

    def test_norm(self):
        self.assertEqual(canon.norm("Live in Denmark ’72"), canon.norm("Live in Denmark '72"))
        self.assertEqual(canon.norm("New Live &amp; Rare"), "new live and rare")
        self.assertEqual(canon.norm("ＷＩＳＨ"), "wish")


if __name__ == "__main__":
    unittest.main()
