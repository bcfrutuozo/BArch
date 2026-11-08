"""Which Prowlarr results are dub candidates, and in which order."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from barch_video.pipeline import Pipeline  # noqa: E402


class FakePipeline(Pipeline):
    def __init__(self):   # no services: rank() only needs the config and the titles
        self.cfg = {"max_donor_gb": 40}


JOB = {"title": "Harry Potter and the Philosopher's Stone", "year": 2001,
       "titles": ["Harry Potter and the Philosopher's Stone", "Harry Potter e a Pedra Filosofal"]}


def r(title, seeders=10, gb=3):
    return {"title": title, "seeders": seeders, "size": gb * 2**30, "protocol": "torrent"}


class Rank(unittest.TestCase):
    p = FakePipeline()

    def score(self, title, **kw):
        return self.p.rank(dict(JOB), r(title, **kw))

    def test_dubbed_in_portuguese_title(self):
        s, why = self.score("Harry.Potter.e.a.Pedra.Filosofal.2001.BluRay.1080p.Dublado.5.1")
        self.assertGreater(s, 0, why)

    def test_dual_beats_dubbed_only(self):
        dual, _ = self.score("Harry Potter and the Philosopher's Stone 2001 1080p BluRay DUAL 5.1")
        dub, _ = self.score("Harry Potter e a Pedra Filosofal (2001) 1080p Dublado")
        self.assertGreater(dual, dub)

    def test_refused(self):
        for title, why in [("Harry Potter and the Philosopher's Stone 2001 2160p UHD BluRay x265", "not dubbed"),
                           ("Harry Potter e a Pedra Filosofal 2001 HDCAM Dublado", "cam"),
                           ("Harry Potter Coleção Completa 2001-2011 1080p Dublado", "pack"),
                           ("Harry Potter e a Camara Secreta (2002) 1080p Dublado", "another title"),
                           ("Harry Potter e a Pedra Filosofal 2015 1080p Dublado", "another year"),
                           ("Harry Potter and the Philosopher's Stone 2001 1080p BDRip [Dual Audio][Hindi Eng]", "dual audio with another"),
                           ("Harry Potter and the Philosopher's Stone 2001 German DL Dual 1080p", "dual audio with another")]:
            s, got = self.score(title)
            self.assertLess(s, 0, title)
            self.assertIn(why.split()[0], got, title)

    def test_no_seeders(self):
        s, why = self.score("Harry Potter e a Pedra Filosofal (2001) 1080p Dublado", seeders=0)
        self.assertLess(s, 0)


if __name__ == "__main__":
    unittest.main()
