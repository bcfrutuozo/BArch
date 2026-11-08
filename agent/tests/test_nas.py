"""agent/nas.py: the snapshot made from Unraid's answer and what becomes an event.

    python3 -m unittest discover -s agent/tests
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import nas  # noqa: E402


def disk(name, status="DISK_OK", errors=0, temp=35, size=1000, used=250, **kw):
    return {"name": name, "device": "sd" + name[-1], "status": status, "temp": temp, "numErrors": errors,
            "fsSize": size, "fsUsed": used, **kw}


def container(name, state="RUNNING", status="Up 2 hours", auto=True, update=False):
    return {"names": ["/" + name], "state": state, "status": status, "autoStart": auto, "isUpdateAvailable": update}


def answer(**over):
    d = {
        "info": {"os": {"hostname": "NAS", "uptime": "2026-11-03T01:16:45.273Z"}, "versions": {"core": {"unraid": "7.3.4"}}},
        "array": {"state": "STARTED", "capacity": {"kilobytes": {"free": "750", "used": "250", "total": "1000"}},
                  "parityCheckStatus": {"status": "COMPLETED", "progress": 0, "errors": None, "running": None, "date": "2026-11-01T10:00:12.000Z"},
                  "parities": [disk("parity", size=None, used=None)],
                  "disks": [disk("disk1"), disk("disk2", temp=41), {"name": "disk3", "status": "DISK_NP"}],
                  "caches": [disk("cache", used=900, temp=None)]},
        "docker": {"containers": [container("swag"), container("plex", update=True)]},
        "notifications": {"overview": {"unread": {"warning": 0, "alert": 0}}, "warningsAndAlerts": []},
        "metrics": {"cpu": {"percentTotal": 12.7}, "memory": {"percentTotal": 46.9}},
    }
    d.update(over)
    return d


def alert(i, importance="ALERT", subject="Disk 1 SMART health", description="reallocated sectors"):
    return {"id": f"n{i}", "title": "Unraid", "subject": subject, "description": description, "importance": importance, "timestamp": ""}


class Summarize(unittest.TestCase):
    def test_healthy(self):
        s = nas.summarize(answer())
        self.assertEqual(s["problems"], [])
        self.assertEqual(s["array"], {"state": "STARTED", "pct": 25.0, "free_gb": 0.0, "total_gb": 0.0})
        self.assertEqual([d["name"] for d in s["disks"]], ["parity", "disk1", "disk2", "cache"])   # the empty slot is gone
        self.assertEqual(s["disk_temp"], 41)
        self.assertEqual(s["pool_pct"], 90.0)
        self.assertEqual(s["containers"], {"total": 2, "running": 2, "down": [], "updates": ["plex"]})

    def test_parity_stale_running(self):
        a = answer()
        a["array"]["parityCheckStatus"] = {"status": "RUNNING", "progress": 98, "errors": 0, "running": False, "date": "2026-11-07T23:06:22.000Z"}
        self.assertEqual(nas.summarize(a)["parity"]["status"], "ENDED")
        a["array"]["parityCheckStatus"]["running"] = True
        self.assertEqual(nas.summarize(a)["parity"]["status"], "RUNNING")

    def test_disk_and_array(self):
        a = answer()
        a["array"]["state"] = "STOPPED"
        a["array"]["disks"][0] = disk("disk1", status="DISK_DSBL")
        a["array"]["disks"][1] = disk("disk2", errors=12)
        s = nas.summarize(a)
        self.assertEqual(s["problems"], ["array STOPPED", "disk1: DSBL", "disk2: OK, 12 errors"])
        self.assertEqual([d["ok"] for d in s["disks"]], [True, False, False, True])

    def test_containers(self):
        cases = [
            (container("a", "EXITED", "Exited (1) 2 hours ago"), "crashed"),
            (container("b", "EXITED", "Exited (0) 2 hours ago"), "stopped"),
            (container("c", "EXITED", "Exited (143) 1 minute ago"), "stopped"),
            (container("d", "RUNNING", "Up 3 hours (unhealthy)"), "unhealthy"),
            (container("e", "EXITED", "Restarting (1) 5 seconds ago"), "restarting"),
            (container("f", "PAUSED", "Up 1 hour (Paused)"), "stopped"),
            # not started by Unraid (Nextcloud AIO's): a clean stop or a kill is its manager's doing
            (container("g", "EXITED", "Exited (0) 2 hours ago", auto=False), ""),
            (container("h", "EXITED", "Exited (137) 2 hours ago", auto=False), ""),
            (container("i", "EXITED", "Exited (78) 2 hours ago", auto=False), "crashed"),
            (container("j", "RUNNING", "Up 4 hours (healthy)", auto=False), ""),
        ]
        for c, want in cases:
            self.assertEqual(nas.container_problem(c), want, c["names"][0] + " " + c["status"])
        s = nas.summarize(answer(docker={"containers": [c for c, _ in cases]}), {"ignore_containers": ["^(a|d)$"]})
        self.assertEqual([c["name"] for c in s["containers"]["down"]], ["b", "c", "e", "f", "i"])
        self.assertEqual(s["containers"]["running"], 2)


class Changes(unittest.TestCase):
    def snap(self, **over):
        s = nas.summarize(answer(**over))
        s["reachable"] = True
        return s

    def test_nothing_on_a_healthy_nas(self):
        st = {}
        self.assertEqual(nas.changes(self.snap(), st, 1000), [])
        self.assertEqual(nas.changes(self.snap(), st, 2000), [])
        self.assertEqual(st["array"], "STARTED")

    def test_container_waits_for_the_grace_and_is_said_once(self):
        st = {}
        down = {"containers": [container("swag"), container("plex", "EXITED", "Exited (1) 1 minute ago")]}
        self.assertEqual(nas.changes(self.snap(docker=down), st, 1000, grace=900), [])
        self.assertEqual(nas.changes(self.snap(docker=down), st, 1600, grace=900), [])
        ev = nas.changes(self.snap(docker=down), st, 1900, grace=900)
        self.assertEqual(ev, [("nas.containers", {"names": "plex", "count": 1, "text": "plex: caiu (Exited (1) 1 minute ago)"})])
        self.assertEqual(nas.changes(self.snap(docker=down), st, 5000, grace=900), [])
        # back up, then down again: the clock starts over
        self.assertEqual(nas.changes(self.snap(), st, 6000, grace=900), [])
        self.assertEqual(st["bad"], {})
        self.assertEqual(nas.changes(self.snap(docker=down), st, 7000, grace=900), [])
        self.assertEqual(len(nas.changes(self.snap(docker=down), st, 7900, grace=900)), 1)

    def test_disk_once_per_state(self):
        st = {}
        a = answer()
        a["array"]["disks"][0] = disk("disk1", errors=3)
        ev = nas.changes(self.snap(array=a["array"]), st, 0)
        self.assertEqual(ev, [("nas.disk", {"names": "disk1", "count": 1, "text": "disk1 (sd1): OK, 3 erros"})])
        self.assertEqual(nas.changes(self.snap(array=a["array"]), st, 300), [])
        a["array"]["disks"][0] = disk("disk1", errors=9)
        self.assertEqual(len(nas.changes(self.snap(array=a["array"]), st, 600)), 1)

    def test_array_state(self):
        st = {}
        nas.changes(self.snap(), st, 0)
        a = answer()
        a["array"]["state"] = "STOPPED"
        self.assertEqual(nas.changes(self.snap(array=a["array"]), st, 300), [("nas.array", {"state": "STOPPED", "previous": "STARTED"})])
        self.assertEqual(nas.changes(self.snap(array=a["array"]), st, 600), [])
        self.assertEqual(nas.changes(self.snap(), st, 900), [("nas.array", {"state": "STARTED", "previous": "STOPPED"})])
        # the first look at a stopped array says so; at a started one, nothing
        self.assertEqual(nas.changes(self.snap(array=a["array"]), {}, 0)[0][1], {"state": "STOPPED", "previous": ""})

    def test_alerts_grouped_by_importance_and_said_once(self):
        st = {}
        n = {"overview": {}, "warningsAndAlerts": [alert(1), alert(2, subject="Disk 2 hot", description="52 C"),
                                                   alert(3, "WARNING", "Parity check", "finished with 2 errors")]}
        ev = nas.changes(self.snap(notifications=n), st, 0)
        self.assertEqual([(e, d["importance"], d["count"]) for e, d in ev], [("nas.alert", "ALERT", 2), ("nas.alert", "WARNING", 1)])
        self.assertEqual(ev[0][1]["text"], "Disk 1 SMART health: reallocated sectors · Disk 2 hot: 52 C")
        self.assertEqual(nas.changes(self.snap(notifications=n), st, 300), [])

    def test_certificates(self):
        st = {}

        def certs(*rows):
            s = self.snap()
            s["certs"] = [{"host": h, "days": d, "error": e} for h, d, e in rows]
            return s
        self.assertEqual(nas.changes(certs(("a:443", 60.0, ""), ("b:443", None, "unreachable")), st, 0), [])
        ev = nas.changes(certs(("a:443", 9.4, ""), ("b:443", None, "unreachable")), st, 1)
        self.assertEqual(ev, [("cert.expiring", {"hosts": "a:443", "count": 1, "days": 9, "text": "a: vence em 9 dias"})])
        self.assertEqual(nas.changes(certs(("a:443", 8.0, "")), st, 2), [])                 # said already
        self.assertEqual(len(nas.changes(certs(("a:443", 2.0, "")), st, 3)), 1)             # again under three days
        self.assertEqual(nas.changes(certs(("a:443", 89.0, "")), st, 4), [])                # renewed
        self.assertEqual(st["certs"], {})
        ev = nas.changes(certs(("a:443", None, "certificate has expired")), st, 5)
        self.assertEqual(ev[0][1]["text"], "a: recusado (certificate has expired)")
        # a sample without the certificate check leaves what was said alone
        self.assertEqual(nas.changes(self.snap(), st, 6), [])
        self.assertEqual(st["certs"], {"a:443": "refused"})

    def test_metrics(self):
        s = self.snap()
        s["certs"] = [{"host": "a:443", "days": 60.0, "error": ""}, {"host": "b:443", "days": 34.2, "error": ""},
                      {"host": "c:443", "days": None, "error": "unreachable"}]
        m = dict(nas.metrics(s))
        self.assertEqual(m, {"nas.cpu.pct": 12.7, "nas.ram.pct": 46.9, "nas.array.pct": 25.0, "nas.pool.pct": 90.0, "nas.disk.temp": 41.0,
                             "nas.disks.bad": 0.0, "nas.containers.down": 0.0, "nas.containers.updates": 1.0, "nas.alerts": 0.0,
                             "cert.days": 34.2})


if __name__ == "__main__":
    unittest.main()
