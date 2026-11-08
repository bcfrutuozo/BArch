"""agent/disk.py: the dump of barch-disk-health as a snapshot, metrics and events.

    python3 -m unittest discover -s agent/tests
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import disk  # noqa: E402

NOW = 1_794_160_000      # 2026-11-08


def nvme(passed=True, temp=47, spare=100, used=3, media=0, errlog=0, unsafe=12, warning=0, test_passed=True, test_h=5000):
    return {
        "model_name": "WD_BLACK SN770 1TB",
        "smart_status": {"passed": passed, "nvme": {"value": warning}},
        "nvme_smart_health_information_log": {
            "critical_warning": warning, "temperature": temp, "available_spare": spare, "percentage_used": used,
            "data_units_written": 70_000_000, "power_on_hours": 5200, "unsafe_shutdowns": unsafe,
            "media_errors": media, "num_err_log_entries": errlog,
        },
        "nvme_self_test_log": {"table": [{"self_test_code": {"value": 1, "string": "Short"},
                                          "self_test_result": {"value": 0 if test_passed else 7, "string": "Completed without error" if test_passed else "Failed segment"},
                                          "power_on_hours": test_h}]},
    }


SCRUB_OK = """UUID:             22b8de79-9b74-4c99-a64e-72d1a3ce1d61
Scrub started:    Sun Nov  2 14:39:48 2026
Status:           finished
Duration:         0:05:12
\tdata_extents_scrubbed: 2788432
\ttree_extents_scrubbed: 180021
\tdata_bytes_scrubbed: 350000000000
\ttree_bytes_scrubbed: 2949464064
\tread_errors: 0
\tcsum_errors: 0
\tverify_errors: 0
\tno_csum: 1200
\tcsum_discards: 0
\tsuper_errors: 0
\tmalloc_errors: 0
\tuncorrectable_errors: 0
\tunverified_errors: 0
\tcorrected_errors: 0
\tlast_physical: 400000000000
"""
SCRUB_BAD = SCRUB_OK.replace("csum_errors: 0", "csum_errors: 3").replace("uncorrectable_errors: 0", "uncorrectable_errors: 2") \
    .replace("Sun Nov  2 14:39:48 2026", "Mon Nov  9 03:00:00 2026")


def stats(**over):
    d = {"device": "/dev/mapper/cryptroot", "devid": 1, "write_io_errs": 0, "read_io_errs": 0, "flush_io_errs": 0,
         "corruption_errs": 0, "generation_errs": 0}
    d.update(over)
    return {"__header": {"version": "1"}, "device-stats": [d]}


def dump(at=NOW - 600, smart=None, btrfs=None):
    return {"at": at,
            "smart": {"/dev/nvme0": nvme()} if smart is None else smart,
            "btrfs": {"/": {"uuid": "22b8", "stats": stats(), "scrub": SCRUB_OK}} if btrfs is None else btrfs}


class Summarize(unittest.TestCase):
    def test_healthy(self):
        s = disk.summarize(dump(), now=NOW)
        self.assertEqual(s["problems"], [])
        d = s["disks"][0]
        self.assertEqual((d["name"], d["kind"], d["temp"], d["wear_pct"], d["spare_pct"], d["media_errors"]), ("nvme0", "nvme", 47, 3, 100, 0))
        self.assertAlmostEqual(d["written_tb"], 35.84, places=2)
        self.assertTrue(d["selftest"]["passed"])
        f = s["btrfs"][0]
        self.assertEqual((f["label"], f["errors"], f["scrub"]["status"], f["scrub"]["errors"]), ("root", 0, "finished", 0))
        self.assertEqual(f["scrub"]["duration_s"], 312)
        self.assertIn("scrub_age_d", f)

    def test_never_collected(self):
        s = disk.summarize(None, now=NOW)
        self.assertEqual(len(s["problems"]), 1)
        self.assertIn("never collected", s["problems"][0])
        self.assertEqual(disk.metrics(s), [])

    def test_stale(self):
        s = disk.summarize(dump(at=NOW - 5 * 3600), now=NOW)
        self.assertTrue(any("not collected for 5 h" in p for p in s["problems"]))

    def test_problems(self):
        raw = dump(smart={"/dev/nvme0": nvme(passed=False, temp=75, spare=20, used=95, media=4, warning=0x04, test_passed=False)},
                   btrfs={"/": {"uuid": "x", "stats": stats(corruption_errs=2), "scrub": SCRUB_BAD}})
        s = disk.summarize(raw, now=NOW)
        joined = "\n".join(s["problems"])
        for needle in ("failing", "critical warning 0x04", "4 media errors", "spare blocks at 20%", "95% of the rated",
                       "75 °C", "self-test failed", "2 I/O or corruption", "scrub found 5 errors, 2 uncorrectable"):
            self.assertIn(needle, joined)

    def test_scrub_overdue_and_never(self):
        old = SCRUB_OK.replace("Sun Nov  2 14:39:48 2026", "Sat Aug  1 10:00:00 2026")
        s = disk.summarize(dump(at=1_793_000_000, btrfs={"/": {"uuid": "x", "stats": stats(), "scrub": old}}), now=1_793_000_000)
        self.assertTrue(any("no scrub for" in p for p in s["problems"]))
        s = disk.summarize(dump(btrfs={"/": {"uuid": "x", "stats": stats(), "scrub": ""}}), now=NOW)
        self.assertTrue(any("never scrubbed" in p for p in s["problems"]))

    def test_ata_disk(self):
        ata = {"model_name": "Samsung 870", "smart_status": {"passed": True}, "temperature": {"current": 33},
               "ata_smart_attributes": {"table": [
                   {"name": "Reallocated_Sector_Ct", "value": 100, "raw": {"value": 0}},
                   {"name": "Current_Pending_Sector", "value": 100, "raw": {"value": 1}},
                   {"name": "Power_On_Hours", "value": 99, "raw": {"value": 8000}},
                   {"name": "Wear_Leveling_Count", "value": 97, "raw": {"value": 40}}]}}
        s = disk.summarize(dump(smart={"/dev/sda": ata}), now=NOW)
        d = s["disks"][0]
        self.assertEqual((d["kind"], d["temp"], d["media_errors"], d["wear_pct"], d["power_on_h"]), ("ata", 33, 1, 3, 8000))
        self.assertTrue(any("1 media errors" in p for p in s["problems"]))


class Metrics(unittest.TestCase):
    def test_rows(self):
        m = dict(disk.metrics(disk.summarize(dump(), now=NOW)))
        self.assertEqual(m["smart.nvme0.temp"], 47.0)
        self.assertEqual(m["smart.nvme0.wear.pct"], 3.0)
        self.assertEqual(m["smart.nvme0.media_errors"], 0.0)
        self.assertEqual(m["btrfs.root.errors"], 0.0)
        self.assertEqual(m["btrfs.root.scrub.errors"], 0.0)
        self.assertIn("btrfs.root.scrub.age_d", m)


class Changes(unittest.TestCase):
    def test_quiet_when_healthy(self):
        st = {}
        s = disk.summarize(dump(), now=NOW)
        self.assertEqual(disk.changes(s, st, NOW), [])
        self.assertEqual(disk.changes(s, st, NOW + 3600), [])

    def test_media_errors_grow_once(self):
        st = {}
        disk.changes(disk.summarize(dump(), now=NOW), st, NOW)
        worse = disk.summarize(dump(smart={"/dev/nvme0": nvme(media=3)}), now=NOW)
        ev = disk.changes(worse, st, NOW + 3600)
        self.assertEqual([e[0] for e in ev], ["disk.smart"])
        self.assertIn("0 → 3", ev[0][1]["text"])
        self.assertEqual(disk.changes(worse, st, NOW + 7200), [])

    def test_failing_and_selftest(self):
        st = {}
        s = disk.summarize(dump(smart={"/dev/nvme0": nvme(passed=False, test_passed=False)}), now=NOW)
        ev = disk.changes(s, st, NOW)
        self.assertEqual(sorted(e[0] for e in ev), ["disk.selftest", "disk.smart"])
        self.assertEqual(disk.changes(s, st, NOW + 60), [])
        # a newer failed test is said again
        s2 = disk.summarize(dump(smart={"/dev/nvme0": nvme(passed=False, test_passed=False, test_h=5100)}), now=NOW)
        self.assertEqual([e[0] for e in disk.changes(s2, st, NOW + 120)], ["disk.selftest"])

    def test_btrfs_counters_and_scrub(self):
        st = {}
        disk.changes(disk.summarize(dump(), now=NOW), st, NOW)
        bad = disk.summarize(dump(btrfs={"/": {"uuid": "x", "stats": stats(read_io_errs=1), "scrub": SCRUB_BAD}}), now=NOW)
        ev = disk.changes(bad, st, NOW + 60)
        self.assertEqual(sorted(e[0] for e in ev), ["btrfs.errors", "btrfs.scrub"])
        self.assertIn("5 erros", [e[1]["text"] for e in ev if e[0] == "btrfs.scrub"][0])
        self.assertEqual(disk.changes(bad, st, NOW + 120), [])

    def test_scrub_overdue_weekly(self):
        st = {}
        old = SCRUB_OK.replace("Sun Nov  2 14:39:48 2026", "Sat Aug  1 10:00:00 2026")
        now = 1_793_000_000
        s = disk.summarize(dump(at=now, btrfs={"/": {"uuid": "x", "stats": stats(), "scrub": old}}), now=now)
        self.assertEqual([e[0] for e in disk.changes(s, st, now)], ["btrfs.scrub"])
        self.assertEqual(disk.changes(s, st, now + 86400), [])
        self.assertEqual([e[0] for e in disk.changes(s, st, now + 8 * 86400)], ["btrfs.scrub"])


if __name__ == "__main__":
    unittest.main()
