"""wifi.summarize(): iwd's object tree → what the Wi-Fi widget shows."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import wifi  # noqa: E402

DEV = "/net/connman/iwd/0/4"
HOME = DEV + "/486f6d65_psk"
CAFE = DEV + "/43616665_open"
HOME2 = DEV + "/486f6d65_8021x"
TREE = {
    "/net/connman/iwd": {},
    "/net/connman/iwd/0": {"net.connman.iwd.Adapter": {"Powered": True, "Name": "phy0"}},
    DEV: {"net.connman.iwd.Device": {"Name": "wlp4s0", "Powered": True, "Mode": "station"},
          "net.connman.iwd.Station": {"State": "connected", "ConnectedNetwork": HOME}},
    HOME: {"net.connman.iwd.Network": {"Name": "Home", "Connected": True, "Device": DEV, "Type": "psk",
                                       "KnownNetwork": "/net/connman/iwd/486f6d65_psk"}},
    CAFE: {"net.connman.iwd.Network": {"Name": "Cafe", "Connected": False, "Device": DEV, "Type": "open"}},
    HOME2: {"net.connman.iwd.Network": {"Name": "Home", "Connected": False, "Device": DEV, "Type": "8021x"}},
    "/net/connman/iwd/486f6d65_psk": {"net.connman.iwd.KnownNetwork": {"Name": "Home", "Type": "psk"}},
    "/net/connman/iwd/4f6c64_psk": {"net.connman.iwd.KnownNetwork": {"Name": "Old", "Type": "psk"}},
}


class Summarize(unittest.TestCase):
    def test_networks(self):
        s = wifi.summarize(TREE, [(CAFE, -4500), (HOME2, -5000), (HOME, -6000)])
        self.assertEqual(s["device"], "wlp4s0")
        self.assertEqual(s["station"], DEV)
        self.assertTrue(s["radio"])
        self.assertEqual(s["saved"], ["Home", "Old"])
        self.assertEqual([n["ssid"] for n in s["networks"]], ["Home", "Cafe"])   # connected first, one per SSID
        home, cafe = s["networks"]
        self.assertTrue(home["active"] and home["secure"] and home["known"])
        self.assertEqual(home["signal"], 80)
        self.assertEqual(cafe["signal"], 100)
        self.assertFalse(cafe["secure"] or cafe["known"])

    def test_radio_off(self):
        tree = {k: v for k, v in TREE.items() if not k.startswith(DEV + "/")}
        tree[DEV] = {"net.connman.iwd.Device": {"Name": "wlp4s0", "Powered": False, "Mode": "station"}}
        s = wifi.summarize(tree, [])
        self.assertEqual((s["device"], s["station"], s["radio"], s["networks"]), ("wlp4s0", "", False, []))

    def test_no_device(self):
        self.assertEqual(wifi.summarize({}, [])["device"], "")

    def test_percent(self):
        self.assertEqual([wifi.percent(m) for m in (-3000, -5000, -7500, -9900, -12000)], [100, 100, 50, 2, 0])


if __name__ == "__main__":
    unittest.main()
