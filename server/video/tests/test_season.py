"""Season donors: which releases fit a season job, and which file is which episode."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from barch_video.pipeline import Pipeline, episode_of, release_scope  # noqa: E402


class FakePipeline(Pipeline):
    def __init__(self):   # no services: rank() only needs the config and the titles
        self.cfg = {"max_donor_gb": 40, "max_season_donor_gb": 120}


def job(season=6, done=()):
    eps = {str(e): {"state": "done" if e in done else "todo"} for e in range(1, 17)}
    return {"kind": "season", "season": season, "title": f"The Walking Dead S{season:02d}", "year": 2010,
            "titles": ["The Walking Dead"], "episodes": eps}


def r(title, seeders=10, gb=20, protocol="torrent"):
    return {"title": title, "seeders": seeders, "size": gb * 2**30, "protocol": protocol}


class Scope(unittest.TestCase):
    def test_titles(self):
        self.assertEqual(release_scope("The Walking Dead S06 1080p WEB DL DUAL"), ({6}, None))
        self.assertEqual(release_scope("The Walking Dead S11.E01-E20 (2021) 1080p WEB-DL [Dublado]"), ({11}, range(1, 21)))
        self.assertEqual(release_scope("The Walking Dead S11 E21 E22 (2021) 1080p Dublado"), ({11}, range(21, 23)))
        self.assertEqual(release_scope("The.Walking.Dead.S06E03.720p.Dublado"), ({6}, range(3, 4)))
        self.assertEqual(release_scope("The Walking Dead 6ª Temporada 1080p Dublado"), ({6}, None))
        self.assertEqual(release_scope("The Walking Dead S01-S11 Completa Dublado")[0], {1, 11})

    def test_files(self):
        self.assertEqual(episode_of("TWD/The.Walking.Dead.S06E03.1080p.mkv", 6), 3)
        self.assertEqual(episode_of("The Walking Dead 6x03 Dublado.mkv", 6), 3)
        self.assertIsNone(episode_of("The.Walking.Dead.S07E03.mkv", 6))
        self.assertIsNone(episode_of("sample.mkv", 6))


class RankSeason(unittest.TestCase):
    p = FakePipeline()

    def score(self, title, j=None, **kw):
        return self.p.rank(j or job(), r(title, **kw))

    def test_season_pack(self):
        s, why = self.score("The Walking Dead S06 1080p WEB DL DD5 1 H 264 DUAL")
        self.assertGreater(s, 0, why)

    def test_named_forms(self):
        for title in ["The.Walking.Dead.S06.1080p.Dublado", "[ACESSE COMANDOTORRENTS] The Walking Dead S06 Dublado",
                      "www.site.com - The Walking Dead 6ª Temporada Dublado", "The Walking Dead (2010) S06 Dublado"]:
            s, why = self.score(title)
            self.assertGreater(s, 0, f"{title}: {why}")

    def test_pack_beats_single_episode(self):
        pack, _ = self.score("The Walking Dead S06 1080p WEB-DL Dublado")
        one, _ = self.score("The Walking Dead S06E03 1080p WEB-DL Dublado", gb=2)
        self.assertGreater(pack, one)

    def test_refused(self):
        for title, why, kw in [("The Walking Dead S06 1080p WEB-DL", "not dubbed", {}),
                               ("The Walking Dead S07 1080p Dublado", "another season", {}),
                               ("Fear the Walking Dead S06 1080p Dublado", "another title", {}),
                               ("The Walking Dead Daryl Dixon S06 1080p Dublado", "another title", {}),
                               ("The Walking Dead World Beyond S06 1080p Dublado", "another title", {}),
                               ("The Walking Dead S01-S11 1080p Dublado", "several", {}),
                               ("The Walking Dead Serie Completa 1080p Dublado", "whole series", {}),
                               ("The Walking Dead S06 1080p Dublado", "not a torrent", {"protocol": "usenet"}),
                               ("The Walking Dead S06 1080p Dublado", "no seeders", {"seeders": 0})]:
            s, got = self.score(title, **kw)
            self.assertLess(s, 0, title)
            if why:
                self.assertIn(why.split()[0], got, title)

    def test_only_done_episodes(self):
        s, why = self.score("The Walking Dead S06E03 1080p Dublado", j=job(done=(3,)))
        self.assertLess(s, 0)
        self.assertIn("already", why)


if __name__ == "__main__":
    unittest.main()
