"""agent/pfsense.py: the snapshot made from the REST API's answers and what becomes an event.

    python3 -m unittest discover -s agent/tests
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import pfsense  # noqa: E402

LOG = ("Nov  7 17:00:19 omni filterlog[12345]: 5,,,1794077112,em5.20,match,block,in,4,0x0,,64,3312,0,DF,6,tcp,60,"
       "100.100.20.242,172.18.0.33,58870,32400,0,S,1234,,65535,,mss;sackOK;TS;nop;wscale")
PASS = ("Nov  7 17:00:20 omni filterlog[12345]: 4,,,1794077066,em5.20,match,pass,in,4,0x0,,64,1,0,DF,17,udp,60,"
        "100.100.20.242,100.100.20.1,5353,123,40")
ISO = ("<134>1 2026-11-07T17:01:24.106958-03:00 fw.example.net filterlog 74491 - - 5,,,1794077066,em5.20,match,block,in,4,0x0,,64,1,0,DF,6,tcp,60,"
       "100.100.20.242,127.0.0.1,45116,19000,0,S,1,,65535,,mss")
ISO2 = ("<134>1 2026-11-07T17:02:00.000001-03:00 fw.example.net filterlog 74491 - - 0,13,,1000000107,em5,state-insert,block,in,6,0x00,0xa3a76,255,ICMPv6,58,32,"
        "fe80::2e4d:54ff:fe4d:be8f,ff02::1,")
ISO3 = ("<134>1 2026-11-07T17:03:10.500000-03:00 fw.example.net filterlog 74491 - - 6,,,1000000103,em0,match,block,in,4,0x0,,107,17287,0,DF,6,tcp,48,"
        "198.51.100.7,203.0.113.53,53146,50300,0,S,2138324341,,8192,,mss")
V6 = ("Nov  7 17:03:06 omni filterlog[12345]: 7,,,1000000112,em5.20,match,block,in,6,0x00,0x00000,255,ICMPv6,58,8,"
      "fe80::6275:6cff:fe34:39bd,ff02::2")


def raw(**over):
    d = {
        "system": {"uptime": "3 Days 04 Hours 12 Minutes 07 Seconds", "cpu_usage": 7, "mem_usage": 21, "disk_usage": 9, "temp_c": 0},
        "version": {"version": "2.9.0-RELEASE"},
        "gateways": [{"name": "WAN_DHCP", "monitorip": "8.8.8.8", "delay": 4.2, "loss": 0, "status": "online"},
                     {"name": "IPsec", "monitorip": "none", "delay": 0, "loss": 0, "status": "none"}],
        "interfaces": [{"name": "wan", "descr": "WAN", "hwif": "em0", "enable": True, "status": "up", "ipaddr": "200.1.2.3"},
                       {"name": "lan", "descr": "LAN", "hwif": "em5", "enable": True, "status": "up", "ipaddr": "100.100.0.1", "subnet": "255.255.255.0"},
                       {"name": "opt2", "descr": "IOT", "hwif": "em5.20", "enable": True, "status": "up", "ipaddr": "100.100.20.1"},
                       {"name": "opt9", "descr": "spare", "hwif": "em3", "enable": False, "status": "up", "ipaddr": ""}],
        "ipsec": [{"name": "con1", "state": "INSTALLED", "bytes_in": 10, "bytes_out": 20, "local_ts": ["100.100.0.0/24"], "remote_ts": ["100.100.1.0/24"]},
                  {"name": "con1", "state": "REKEYED", "bytes_in": 1, "bytes_out": 1, "local_ts": ["100.100.0.0/24"], "remote_ts": ["100.100.1.0/24"]}],
        "leases": [{"ip": "100.100.0.10", "mac": "2C:4D:54:4D:BE:8F", "hostname": "NASfrutuozo", "if": "lan", "online_status": "active/online", "active_status": "static"},
                   {"ip": "100.100.20.242", "mac": "60:75:6c:34:39:bd", "hostname": "", "if": "opt2", "online_status": "active/online", "active_status": "active"},
                   {"ip": "100.100.0.199", "mac": "aa:aa:aa:aa:aa:aa", "hostname": "old", "if": "lan", "online_status": "idle/offline", "active_status": "expired"}],
        "log": [{"text": LOG}, {"text": PASS}],
        "errors": {},
    }
    d.update(over)
    return d


class Summarize(unittest.TestCase):
    def test_snapshot(self):
        s = pfsense.summarize(raw(), "omni")
        self.assertEqual(s["version"], "2.9.0-RELEASE")
        self.assertEqual(s["uptime_s"], 3 * 86400 + 4 * 3600 + 12 * 60 + 7)
        self.assertIsNone(s["temp"])                                   # 0 means no sensor
        self.assertEqual([g["ok"] for g in s["gateways"]], [True, True])
        self.assertEqual([i["descr"] for i in s["interfaces"]], ["WAN", "LAN", "IOT", "spare"])   # `enable` is ignored (always false on 2.9)
        self.assertEqual(s["ifnames"]["em5.20"], "IOT")
        self.assertEqual(s["ipsec"], [{"name": "con1", "up": True, "local": ["100.100.0.0/24"], "remote": ["100.100.1.0/24"], "bytes_in": 10, "bytes_out": 20}])
        self.assertEqual(s["clients_online"], 2)
        self.assertEqual(s["clients"][0]["mac"], "2c:4d:54:4d:be:8f")
        self.assertTrue(s["clients"][0]["static"])
        self.assertEqual(s["clients"][1]["ifdescr"], "IOT")
        self.assertEqual(s["blocked"], {"IOT": 1})
        r2 = raw(); r2["leases"][0]["if"] = ""                          # chaos leaves `if` empty: the subnet says LAN
        self.assertEqual(pfsense.summarize(r2, "chaos")["clients"][0]["ifdescr"], "LAN")
        self.assertEqual(s["problems"], [])
        self.assertEqual(len(s["clients"]), 3)
        self.assertFalse(s["clients"][2]["online"])

    def test_ipsec_nested_in_sas(self):
        r = raw(ipsec=[], sas=[{"con_id": "con1", "state": "ESTABLISHED", "child_sas": [
            {"state": "INSTALLED", "bytes_in": 5, "bytes_out": 6, "local_ts": ["100.100.0.0/24"], "remote_ts": ["100.100.1.0/24"]}]}])
        s = pfsense.summarize(r, "omni")
        self.assertEqual(s["ipsec"][0]["name"], "con1")
        self.assertTrue(s["ipsec"][0]["up"])

    def test_problems(self):
        r = raw()
        r["gateways"][0].update(status="down", loss=100)
        r["interfaces"][0].update(status="no carrier")
        r["ipsec"] = [{"name": "con1", "state": "CONNECTING", "local_ts": [], "remote_ts": []}]
        r["errors"] = {"log": "HTTP 500: broken", "sas": "no privilege (api-v2-status-ipsec-sas-get)"}
        s = pfsense.summarize(r, "chaos")
        self.assertEqual(s["problems"], ["gateway WAN_DHCP: down, 100% loss", "interface WAN: no carrier", "IPsec con1: down", "log: HTTP 500: broken"])
        self.assertFalse(s["ipsec"][0]["up"])


class Log(unittest.TestCase):
    def test_parse(self):
        r = pfsense.parse_log_line(LOG)
        self.assertEqual((r["stamp"], r["interface"], r["action"], r["proto"], r["src"], r["dst"], r["sport"], r["dport"]),
                         ("Nov  7 17:00:19", "em5.20", "block", "tcp", "100.100.20.242", "172.18.0.33", "58870", "32400"))
        self.assertEqual(pfsense.parse_log_line(ISO)["stamp"], "2026-11-07T17:01:24.106958-03:00")
        self.assertEqual(pfsense.parse_log_line(ISO)["dport"], "19000")
        self.assertEqual(pfsense.parse_log_line(ISO)["reason"], "match")
        self.assertEqual(pfsense.parse_log_line(ISO2)["reason"], "state-insert")
        v6 = pfsense.parse_log_line(V6)
        self.assertEqual((v6["proto"], v6["src"], v6["dst"], v6["dport"]), ("ICMPv6", "fe80::6275:6cff:fe34:39bd", "ff02::2", ""))
        self.assertIsNone(pfsense.parse_log_line("Nov  7 17:00:19 omni sshd[1]: something else"))

    def test_cursor_bsd(self):
        lines = [LOG, PASS]
        rows, cur = pfsense.blocked_since(lines, "")               # a fresh start learns the position only
        self.assertEqual(rows, [])
        self.assertEqual(cur, PASS)
        rows, cur = pfsense.blocked_since(lines, cur)              # nothing new
        self.assertEqual(rows, [])
        rows, cur = pfsense.blocked_since(lines + [V6, PASS, LOG], cur)
        self.assertEqual([r["dst"] for r in rows], ["ff02::2", "172.18.0.33"])
        self.assertEqual(cur, LOG)
        rows, _ = pfsense.blocked_since([V6, LOG], "gone")          # the cursor line rotated out: everything counts
        self.assertEqual([r["dport"] for r in rows], ["", "32400"])

    def test_cursor_iso(self):
        rows, cur = pfsense.blocked_since([ISO], "")
        self.assertEqual((rows, cur), ([], "2026-11-07T17:01:24.106958-03:00"))
        rows, cur = pfsense.blocked_since([ISO, ISO2, ISO3], cur)
        self.assertEqual([r["dst"] for r in rows], ["203.0.113.53"])   # state-insert noise is not a block by a rule
        self.assertEqual(cur, "2026-11-07T17:03:10.500000-03:00")
        rows, cur = pfsense.blocked_since([ISO3], cur)             # the log rotated, nothing newer
        self.assertEqual(rows, [])
        self.assertEqual(cur, "2026-11-07T17:03:10.500000-03:00")

    def test_uptime(self):
        self.assertEqual(pfsense.uptime_seconds("04 Hours 02 Minutes"), 4 * 3600 + 120)
        self.assertEqual(pfsense.uptime_seconds("1 Day"), 86400)
        self.assertIsNone(pfsense.uptime_seconds(""))


class Changes(unittest.TestCase):
    def snap(self, **over):
        s = pfsense.summarize(raw(**over), "omni")
        s["dnsbl"] = over.pop("dnsbl", True) if "dnsbl" in over else True
        return s

    def test_first_sample_is_quiet(self):
        st = {}
        ev, rows = pfsense.changes(self.snap(), st, 1000)
        self.assertEqual(ev, [])
        self.assertEqual(rows, [])                                   # the log cursor is only set
        self.assertEqual(st["seen"], ["2c:4d:54:4d:be:8f", "60:75:6c:34:39:bd", "aa:aa:aa:aa:aa:aa"])
        ev, rows = pfsense.changes(self.snap(), st, 1300)
        self.assertEqual(ev, [])
        self.assertEqual(rows, [("fw.omni.blocked", 0.0)])

    def test_new_client(self):
        st = {}
        pfsense.changes(self.snap(), st, 1000)
        r = raw()
        r["leases"].append({"ip": "100.100.20.212", "mac": "28:9c:6e:0a:bc:32", "hostname": "hf-lpt230", "if": "opt2", "online_status": "online", "active_status": "active"})
        r["leases"].append({"ip": "100.100.0.199", "mac": "02:11:22:33:44:55", "hostname": "iphone", "if": "lan", "online_status": "online", "active_status": "active"})
        s = pfsense.summarize(r, "omni")
        s["dnsbl"] = True
        ev, _ = pfsense.changes(s, st, 1300, ignore_macs=["^02:"])
        self.assertEqual(ev, [("fw.client", {"site": "omni", "mac": "28:9c:6e:0a:bc:32", "ip": "100.100.20.212", "hostname": "hf-lpt230", "if": "IOT", "online": "yes",
                                             "text": "Aparelho novo na rede IOT do omni: hf-lpt230 (100.100.20.212, 28:9c:6e:0a:bc:32)"})])
        ev, _ = pfsense.changes(s, st, 1600, ignore_macs=["^02:"])
        self.assertEqual(ev, [])                                     # said once

    def test_gateway_ipsec_dnsbl_boot(self):
        st = {}
        pfsense.changes(self.snap(), st, 1000)
        r = raw()
        r["gateways"][0].update(status="down", loss=100, delay=0)
        r["ipsec"] = [{"name": "con1", "state": "CONNECTING", "local_ts": [], "remote_ts": []}]
        r["system"]["uptime"] = "02 Minutes 10 Seconds"
        s = pfsense.summarize(r, "omni")
        s["dnsbl"] = False
        ev, _ = pfsense.changes(s, st, 1300)
        names = [e[0] for e in ev]
        self.assertEqual(names, ["fw.boot", "fw.gateway", "fw.ipsec", "fw.dnsbl"])
        self.assertEqual(ev[1][1]["text"], "Gateway WAN_DHCP do omni: down (100% de perda, 0 ms)")
        self.assertEqual(ev[2][1]["up"], "no")
        self.assertEqual(ev[3][1]["ok"], "no")
        ev, _ = pfsense.changes(s, st, 1600)
        self.assertEqual(ev, [])                                     # nothing repeats while it stays so
        ev, _ = pfsense.changes(self.snap(), st, 1900)                # and back
        self.assertEqual([e[0] for e in ev], ["fw.gateway", "fw.ipsec", "fw.dnsbl"])
        self.assertEqual(ev[0][1]["ok"], "yes")

    def test_blocked_metrics(self):
        st = {}
        pfsense.changes(self.snap(), st, 1000)
        r = raw(log=[{"text": LOG}, {"text": PASS}, {"text": ISO}, {"text": V6}])
        s = pfsense.summarize(r, "omni")
        s["dnsbl"] = True
        _, rows = pfsense.changes(s, st, 1300)
        self.assertEqual(rows, [("fw.omni.blocked", 2.0), ("fw.omni.blocked.iot", 2.0)])
        st = {}
        pfsense.changes(pfsense.summarize(raw(log=[{"text": ISO}]), "omni"), st, 1000)
        _, rows = pfsense.changes(pfsense.summarize(raw(log=[{"text": ISO}, {"text": ISO2}, {"text": ISO3}]), "omni"), st, 1300)
        self.assertEqual(rows, [("fw.omni.blocked", 1.0), ("fw.omni.blocked.wan", 1.0)])

    def test_metrics(self):
        rows = dict(pfsense.metrics(self.snap()))
        self.assertEqual(rows["fw.omni.gw.wan_dhcp.rtt"], 4.2)
        self.assertNotIn("fw.omni.gw.ipsec.rtt", rows)               # no monitor address
        self.assertEqual(rows["fw.omni.ipsec.up"], 1.0)
        self.assertEqual(rows["fw.omni.dnsbl"], 1.0)
        self.assertEqual(rows["fw.omni.clients"], 2.0)                 # the expired one is offline
        self.assertNotIn("fw.omni.temp", rows)


if __name__ == "__main__":
    unittest.main()
