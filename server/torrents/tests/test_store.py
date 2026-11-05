import os
import sys
import time
import unittest
from pathlib import Path

os.environ["TZ"] = "America/Sao_Paulo"
time.tzset()
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from barch_torrents.integrations import first_tracker, match_grabs, tracker_site  # noqa: E402
from barch_torrents.store import Store, bucket_kind, bucket_next, bucket_start, parse_range  # noqa: E402

T0 = 1793847600          # 2026-11-05 00:00 in São Paulo
GB = 10 ** 9


def tor(up=0, down=0, added=T0 - 86400, **kw):
    return {"name": "x", "category": "lidarr", "size": 5 * GB, "added_on": added, "completion_on": added + 60,
            "uploaded": up, "downloaded": down, "state": "stalledUP", "progress": 1.0, **kw}


def server(ul=0, dl=0):
    return {"alltime_ul": ul, "alltime_dl": dl, "up_info_speed": 0, "dl_info_speed": 0, "free_space_on_disk": 1}


class Record(unittest.TestCase):
    def setUp(self):
        self.s = Store(":memory:")

    def test_what_was_there_before_is_base_not_traffic(self):
        m = self.s.record(T0, server(), {"a": tor(up=3 * GB, down=4 * GB)})
        self.assertEqual((m["up"], m["down"], m["new"]), (0, 0, 1))
        t = self.s.torrent("a")
        self.assertEqual((t["base_up"], t["total_up"], t["total_down"]), (3 * GB, 3 * GB, 4 * GB))
        self.assertEqual(self.s.history(T0 + 10, 0)["up"], 0)

    def test_deltas_go_to_the_hour_they_were_seen(self):
        self.s.record(T0, server(), {"a": tor(up=GB, down=4 * GB)})
        self.s.record(T0 + 300, server(), {"a": tor(up=GB + 100, down=4 * GB)})
        self.s.record(T0 + 3900, server(), {"a": tor(up=GB + 350, down=4 * GB + 7)})
        h = self.s.history(T0 + 4000, 0, kind="hour")
        self.assertEqual([(b["t"], b["up"], b["down"]) for b in h["buckets"]], [(T0, 100, 0), (T0 + 3600, 250, 7)])
        self.assertEqual(h["buckets"][-1]["total_up"], GB + 350)
        self.assertEqual(self.s.torrent("a")["total_up"], GB + 350)

    def test_a_torrent_added_after_tracking_began_is_all_traffic(self):
        self.s.record(T0, server(), {})
        self.s.record(T0 + 600, server(), {"B": tor(up=10, down=500, added=T0 + 400)})
        t = self.s.torrent("b")                      # hashes are kept lower case
        self.assertEqual((t["base_up"], t["base_down"], t["total_down"]), (0, 0, 500))
        self.assertEqual(self.s.history(T0 + 700, 0)["down"], 500)

    def test_a_torrent_first_seen_late_but_older_than_tracking_is_base(self):
        self.s.record(T0, server(), {})
        self.s.record(T0 + 600, server(), {"a": tor(up=10, down=500, added=T0 - 5)})
        self.assertEqual(self.s.history(T0 + 700, 0)["down"], 0)
        self.assertEqual(self.s.torrent("a")["base_down"], 500)

    def test_removed_keeps_its_numbers_and_readded_starts_from_zero(self):
        self.s.record(T0, server(), {"a": tor(up=GB, down=GB)})
        self.s.record(T0 + 300, server(), {"a": tor(up=GB + 50, down=GB)})
        m = self.s.record(T0 + 600, server(), {})
        self.assertEqual(m["removed"], 1)
        self.assertEqual(self.s.torrent("a")["removed_at"], T0 + 600)
        self.assertEqual(self.s.groups(T0 + 700, 0, "category")[0]["total_up"], GB + 50)
        self.s.record(T0 + 900, server(), {"a": tor(up=20, down=0)})      # added again: counters at zero
        t = self.s.torrent("a")
        self.assertIsNone(t["removed_at"])
        self.assertEqual((t["total_up"], t["total_down"]), (GB + 70, GB))

    def test_groups_and_range(self):
        self.s.record(T0, server(), {"a": tor(up=0, down=10), "b": tor(up=0, down=10, category="radarr")})
        self.s.label("indexer", {"a": "RuTracker", "b": "1337x"})
        self.s.label("indexer", {"a": "Other"})                           # never overwritten
        self.s.record(T0 + 300, server(), {"a": tor(up=30, down=10), "b": tor(up=5, down=10, category="radarr")})
        self.s.record(T0 + 3 * 86400, server(), {"a": tor(up=31, down=10), "b": tor(up=5, down=10, category="radarr")})
        now = T0 + 3 * 86400 + 60
        g = {x["key"]: x for x in self.s.groups(now, 0, "indexer")}
        self.assertEqual((g["RuTracker"]["up"], g["RuTracker"]["total_up"], g["RuTracker"]["ratio"]), (31, 31, 3.1))
        self.assertEqual(g["1337x"]["ratio"], 0.5)
        g = {x["key"]: x for x in self.s.groups(now, 86400, "indexer")}
        self.assertEqual((g["RuTracker"]["up"], g["1337x"]["up"]), (1, 0))
        self.assertEqual(self.s.history(now, 0, "category", "radarr")["up"], 5)
        self.assertEqual([t["hash"] for t in self.s.torrents(now, 0, sort="up")], ["a", "b"])
        self.assertEqual([t["hash"] for t in self.s.torrents(now, 0, "indexer", "1337x")], ["b"])
        self.assertEqual(self.s.without("indexer"), [])

    def test_cumulative_ratio_per_day(self):
        self.s.record(T0, server(), {"a": tor(up=0, down=100)})
        self.s.record(T0 + 3600, server(), {"a": tor(up=50, down=100)})
        self.s.record(T0 + 86400 + 3600, server(), {"a": tor(up=150, down=100)})
        h = self.s.history(T0 + 2 * 86400 + 10, 0, kind="day")
        self.assertEqual([(b["up"], b["ratio"]) for b in h["buckets"]], [(50, 0.5), (100, 1.5), (0, 1.5)])

    def test_a_range_longer_than_the_tracking_covers_all_of_it(self):
        self.s.record(T0, server(ul=1, dl=10), {"a": tor(up=0, down=100)})
        self.s.record(T0 + 3600, server(ul=2, dl=10), {"a": tor(up=50, down=100)})
        now = T0 + 7200
        h = self.s.history(now, 7 * 86400)
        self.assertEqual((h["kind"], h["from"], len(h["buckets"])), ("day", now - 7 * 86400, 8))
        self.assertEqual([b["up"] for b in h["buckets"]], [0] * 7 + [50])
        self.assertEqual([b["ratio"] for b in h["buckets"]], [None] * 7 + [0.5])      # unknown before tracking began
        self.assertEqual(self.s.history(now, 0)["from"], T0)                          # "all" starts where the data does
        self.assertEqual([x["t"] for x in self.s.samples(now, 30 * 86400)], [T0, T0 + 3600])
        self.assertEqual(self.s.overview(now, 7 * 86400)["range"]["up"], 50)

    def test_compact_merges_old_hours_into_days_without_changing_totals(self):
        self.s.record(T0, server(), {"a": tor(up=0, down=0)})
        for i in range(1, 30):
            self.s.record(T0 + i * 3600, server(), {"a": tor(up=i * 10, down=i)})
        now = T0 + 100 * 86400
        before = self.s.history(now, 0, kind="day")
        self.assertGreater(self.s.compact(now, 60), 0)
        self.assertEqual(self.s.status()["traffic_rows"], 2)
        self.assertEqual(self.s.history(now, 0, kind="day"), before)
        self.assertEqual(self.s.compact(now, 60), 0)

    def test_overview_and_samples(self):
        self.s.record(T0, server(ul=100, dl=1000), {"a": tor(up=0, down=100)})
        self.s.record(T0 + 300, server(ul=400, dl=1000), {"a": tor(up=300, down=100)})
        o = self.s.overview(T0 + 400, 0, goal=3.0)
        self.assertEqual((o["now"]["ratio"], o["then"]["ratio"], o["then"]["up"]), (0.4, 0.1, 300))
        self.assertEqual((o["range"]["up"], o["live"]["at_goal"], o["live"]["below_1"]), (300, 1, 0))
        sm = self.s.samples(T0 + 400, 0)
        self.assertEqual((len(sm), sm[-1]["up_speed"], sm[-1]["ratio"]), (2, 1, 0.4))


class Helpers(unittest.TestCase):
    def test_ranges(self):
        self.assertEqual((parse_range("24h"), parse_range("7d"), parse_range("1y"), parse_range("all")),
                         (86400, 7 * 86400, 365 * 86400, 0))
        for bad in ("7", "d", "0d", "-1d", "7x"):
            self.assertRaises(ValueError, parse_range, bad)

    def test_buckets(self):
        self.assertEqual([bucket_kind(x * 86400) for x in (1, 7, 30, 90, 365, 800)],
                         ["hour", "day", "day", "week", "week", "month"])
        self.assertEqual(bucket_start("day", T0 + 5000), T0)
        self.assertEqual(bucket_start("week", T0), T0 - 3 * 86400)            # a Thursday: the week began on Monday
        self.assertEqual(bucket_next("day", T0), T0 + 86400)
        self.assertEqual(bucket_start("month", T0), T0 - 4 * 86400)
        self.assertEqual(bucket_next("month", T0 - 4 * 86400), T0 + 26 * 86400)

    def test_trackers(self):
        self.assertEqual(tracker_site("bt2.t-ru.org"), "t-ru.org")
        self.assertEqual(tracker_site("tracker.example.co.uk"), "example.co.uk")
        self.assertEqual(tracker_site("192.168.1.10"), "192.168.1.10")
        self.assertEqual(tracker_site("tracker.torrent.eu.org"), "torrent.eu.org")
        self.assertEqual(first_tracker([{"url": "** [DHT] **", "tier": -1},
                                        {"url": "udp://tracker.opentrackr.org:1337/announce", "tier": 1},
                                        {"url": "http://bt02.nnm-club.cc:2710/0123abc/announce", "tier": 0}]), "nnm-club.cc")
        self.assertEqual(first_tracker([{"url": "** [PeX] **", "tier": -1}]), "")


class Grabs(unittest.TestCase):
    G = [{"t": 1000, "title": "Bon.Jovi-Best.Ballads.1997.[FLAC]", "indexer": "NoNaMe Club"},
         {"t": 5000, "title": "Bon Jovi - Best Ballads 1997 FLAC", "indexer": "RuTracker"},
         {"t": 9000, "title": "David Arkenstone - Citizen of the World (1999) FLAC lossless image cue", "indexer": "Knaben"},
         {"t": 9040, "title": "Deep Purple - Colour Collection (2007) FLAC", "indexer": "1337x"}]

    def match(self, name, added):
        return match_grabs([{"hash": "h", "name": name, "added_on": added}], [dict(g) for g in self.G]).get("h")

    def test_same_title_nearest_in_time(self):
        self.assertEqual(self.match("Bon Jovi - Best Ballads 1997 [FLAC]", 5003), "RuTracker")
        self.assertEqual(self.match("bon_jovi best ballads 1997 flac", 900), "NoNaMe Club")
        self.assertEqual(self.match("Bon Jovi - Best Ballads 1997 [FLAC]", 10 ** 6), "RuTracker")    # days later: still it

    def test_other_name_goes_by_the_moment(self):
        self.assertEqual(self.match("David Arkenstone - 1999 - Citizen of the World", 9000), "Knaben")
        self.assertEqual(self.match("7d09775810b9b15cdea67742b0d0a6d2bbef0c44", 9041), "1337x")          # a magnet: no name yet
        self.assertEqual(self.match("David Arkenstone - 1999 - Citizen of the World", 9030), "Knaben")   # words decide in a burst
        self.assertEqual(self.match("Deep Purple Colour Collection", 9010), "1337x")

    def test_no_answer_when_nothing_ties_them(self):
        self.assertIsNone(self.match("Lord of the Rings Unabridged", 9020))       # near two grabs, words of neither
        self.assertIsNone(self.match("Lord of the Rings Unabridged", 20000))      # no grab around
        self.assertIsNone(self.match("7d09775810b9b15cdea67742b0d0a6d2bbef0c44", 9020))   # as far from one as from the other
        self.assertEqual(match_grabs([], self.G), {})


if __name__ == "__main__":
    unittest.main()
