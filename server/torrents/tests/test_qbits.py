import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from barch_torrents.integrations import QBits  # noqa: E402
from barch_torrents.service import DEFAULTS  # noqa: E402


class FakeQBit:
    def __init__(self, server, torrents, version="v5", fail=False):
        self.server, self.torrents, self.v, self.fail = server, torrents, version, fail
        self.asked = []

    def maindata(self):
        if self.fail:
            raise ConnectionError("refused")
        return dict(self.server), dict(self.torrents)

    def trackers(self, h):
        self.asked.append(h)
        return [{"url": "https://x/announce/K", "tier": 0}]

    def version(self):
        return self.v


VPN = FakeQBit({"alltime_ul": 100, "alltime_dl": 50, "up_info_speed": 10, "dl_info_speed": 1,
                "total_peer_connections": 7, "free_space_on_disk": 900}, {"a" * 40: {"name": "pub"}}, "v5.2.4")
PRIV = FakeQBit({"alltime_ul": 5, "alltime_dl": 2, "up_info_speed": 3, "dl_info_speed": 0,
                 "total_peer_connections": 2, "free_space_on_disk": 899}, {"b" * 40: {"name": "priv"}}, "v5.3.0")


class Merge(unittest.TestCase):
    def test_sums_counters_keeps_one_disk_and_unites_torrents(self):
        q = QBits([("qbittorrent", VPN), ("qbittorrent_private", PRIV)])
        server, torrents = q.maindata()
        self.assertEqual((server["alltime_ul"], server["alltime_dl"]), (105, 52))
        self.assertEqual((server["up_info_speed"], server["total_peer_connections"]), (13, 9))
        self.assertEqual(server["free_space_on_disk"], 900)
        self.assertEqual(set(torrents), {"a" * 40, "b" * 40})

    def test_trackers_asked_of_the_client_holding_the_hash(self):
        vpn = FakeQBit({}, {"a" * 40: {}})
        priv = FakeQBit({}, {"b" * 40: {}})
        q = QBits([("qbittorrent", vpn), ("qbittorrent_private", priv)])
        q.maindata()
        q.trackers("b" * 40)
        self.assertEqual((vpn.asked, priv.asked), ([], ["b" * 40]))

    def test_one_client_down_fails_the_whole_sample(self):
        q = QBits([("qbittorrent", VPN), ("qbittorrent_private", FakeQBit({}, {}, fail=True))])
        with self.assertRaises(RuntimeError) as e:
            q.maindata()
        self.assertIn("qbittorrent_private", str(e.exception))

    def test_version_names_the_private_one(self):
        self.assertEqual(QBits([("qbittorrent", VPN), ("qbittorrent_private", PRIV)]).version(),
                         "v5.2.4 + v5.3.0 (private)")

    def test_config_without_private_reads_one(self):
        self.assertEqual(len(QBits.from_cfg(DEFAULTS).clients), 1)
        cfg = {**DEFAULTS, "qbittorrent_private": {"url": "http://qbittorrent-private:8080"}}
        self.assertEqual(len(QBits.from_cfg(cfg).clients), 2)


if __name__ == "__main__":
    unittest.main()
