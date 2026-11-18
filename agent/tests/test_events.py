"""agent/events.py: the pure helpers (failure incidents).

    python3 -m unittest discover -s agent/tests
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import events  # noqa: E402


def fail(ts, unit):
    return {"ts": ts, "event": "failure", "data": {"unit": unit, "path": f"/x/{unit}-{ts}.log"}}


class FailureIncidents(unittest.TestCase):
    def test_burst_of_one_unit_is_one_incident(self):
        # nvidia-cdi-refresh.path fired five times in five seconds (2026-11-13)
        inc = events.failure_incidents([fail(100 + i, "nvidia-cdi-refresh.service") for i in range(5)])
        self.assertEqual(inc, [{"unit": "nvidia-cdi-refresh.service", "start": 100, "end": 104, "count": 5}])

    def test_restart_loop_chains_within_the_gap(self):
        # a failure every 25 min keeps extending the same incident
        inc = events.failure_incidents([fail(t, "a.service") for t in (0, 1500, 3000, 4500)])
        self.assertEqual(len(inc), 1)
        self.assertEqual(inc[0]["count"], 4)

    def test_after_the_gap_is_a_new_incident(self):
        inc = events.failure_incidents([fail(0, "a.service"), fail(events.FAILURE_GAP_S + 1, "a.service")])
        self.assertEqual([i["count"] for i in inc], [1, 1])

    def test_units_are_separate_and_order_does_not_matter(self):
        inc = events.failure_incidents([fail(10, "b.service"), fail(0, "a.service"), fail(5, "a.service"),
                                        {"ts": 3, "event": "nas.alert", "data": {"text": "Power failure"}}])
        self.assertEqual([(i["unit"], i["count"]) for i in inc], [("a.service", 2), ("b.service", 1)])


class LanPaused(unittest.TestCase):
    """Anonymous Mode: the NAS and the pfSense are not asked (2026-11-18: fw.down right after anon.on)."""
    def daemon(self, anon):
        d = events.Daemon.__new__(events.Daemon)
        d.flags = {"anon": anon}
        d.anon_quiet_until = 0.0
        d.nas_fails, d.next_nas = 2, 999.0
        d.fw_fails, d.next_fw = {"omni": 2}, {"omni": 999.0}
        return d

    def test_anon_on_pauses_and_forgets_misses(self):
        d = self.daemon(True)
        self.assertTrue(d.lan_paused())
        self.assertEqual((d.nas_fails, d.next_nas, d.fw_fails), (0, 0.0, {}))
        self.assertEqual(d.next_fw, {"omni": 999.0})  # the fw.auth backoff is kept
        self.assertEqual(d.sample_nas(), [])
        self.assertEqual(d.sample_fw(), [])

    def test_grace_after_anon_off(self):
        d = self.daemon(False)
        self.assertFalse(d.lan_paused())
        d.anon_quiet_until = events.time.time() + 60
        self.assertTrue(d.lan_paused())


if __name__ == "__main__":
    unittest.main()
