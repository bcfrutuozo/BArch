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


class OomKills(unittest.TestCase):
    def test_oomd_kill_of_an_app_scope(self):
        msg = ("Killed /user.slice/user-1000.slice/user@1000.service/app.slice/app-graphical.slice/"
               "app-Hyprland-foot-1a2b3c4d.scope due to memory pressure for /user.slice/user-1000.slice/"
               "user@1000.service/app.slice being 63.21% > 50.00% for > 20s with reclaim activity")
        ev = events.oom_kills([{"MESSAGE": msg, "_SYSTEMD_UNIT": "systemd-oomd.service", "_TRANSPORT": "journal"}])
        self.assertEqual(ev, [{"source": "oomd", "app": "foot", "unit": "app-Hyprland-foot-1a2b3c4d.scope",
                               "reason": "memory pressure for app.slice being 63.21% > 50.00% for > 20s with reclaim activity"}])

    def test_oomd_262_marks_for_killing(self):
        # the real line of the 2026-11-25 test (systemd 262 says "Marked ... for killing")
        msg = ("Marked /user.slice/user-1000.slice/user@1000.service/app.slice/app-graphical.slice/"
               "app-Hyprland-oomtest-d4cecd47.scope for killing due to memory pressure for /user.slice/"
               "user-1000.slice/user@1000.service/app.slice being 15.36% > 10.00% for > 20s with reclaim activity")
        ev = events.oom_kills([{"MESSAGE": msg, "_SYSTEMD_UNIT": "systemd-oomd.service", "_TRANSPORT": "journal"}])
        self.assertEqual([(e["source"], e["app"]) for e in ev], [("oomd", "oomtest")])
        self.assertTrue(ev[0]["reason"].startswith("memory pressure for app.slice being 15.36%"))

    def test_kernel_oom_killer(self):
        # blender, twice, with earlyoom running (2026-11): RAM and swap had to run out together
        msg = ("Out of memory: Killed process 187210 (blender) total-vm:108501340kB, anon-rss:52859184kB, "
               "file-rss:16kB, shmem-rss:0kB, UID:1000 pgtables:135336kB oom_score_adj:200")
        ev = events.oom_kills([{"MESSAGE": msg, "_TRANSPORT": "kernel"}])
        self.assertEqual(len(ev), 1)
        self.assertEqual((ev[0]["source"], ev[0]["app"], ev[0]["pid"]), ("kernel", "blender", "187210"))

    def test_other_lines_and_byte_messages(self):
        self.assertEqual(events.oom_kills([{"MESSAGE": "Killed by a signal", "_TRANSPORT": "kernel"},
                                           {"MESSAGE": [79, 117, 116], "_TRANSPORT": "kernel"}, {}]), [])

    def test_app_names(self):
        self.assertEqual(events.oom_app("/a/app.slice/app-org.chromium.Chromium-4345.scope"), "org.chromium.Chromium")
        self.assertEqual(events.oom_app("/a/app.slice/barch-voice.service"), "barch-voice")
        self.assertEqual(events.oom_app("/a/app-Nextcloud@autostart.service"), "Nextcloud")
        self.assertEqual(events.oom_app("/a/app-Hyprland-qs-f93891fe.scope"), "qs")
        self.assertEqual(events.oom_app("/a/app-flatpak\\x2dthing-12.scope"), "flatpak-thing")
