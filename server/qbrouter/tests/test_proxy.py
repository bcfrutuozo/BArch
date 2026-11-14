import json
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qsl, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from barch_qbrouter.proxy import HashMap, HostBook, Proxy, Reply, Route  # noqa: E402
from barch_qbrouter.server import HTTPBackend, decode_multipart, encode_multipart, make_fetcher  # noqa: E402
from barch_qbrouter.torrent import parse_torrent  # noqa: E402
from test_torrent import INFO, torrent  # noqa: E402

PRIV = torrent("https://sapibr.com/announce/PASSKEY")
PUB = torrent("udp://tracker.opentrackr.org:1337/announce", info=dict(INFO, name="public"))
PRIV_HASH = parse_torrent(PRIV).hash
PUB_HASH = parse_torrent(PUB).hash


class Fake:
    """A qBittorrent that records calls and keeps the torrents it was given."""

    def __init__(self, name):
        self.name = name
        self.calls = []
        self.torrents = {}
        self.stopped = []

    def call(self, method, endpoint, query=None, fields=None, files=None):
        query, fields, files = query or [], fields or [], files or []
        self.calls.append((endpoint, list(query), list(fields), [f[1] for f in files]))
        if endpoint == "torrents/add":
            for _, _, data in files:
                t = parse_torrent(data)
                self.torrents[t.hash] = {"hash": t.hash, "name": t.name, "category": dict(fields).get("category", ""),
                                         "tracker": t.trackers[0], "magnet_uri": "", "state": "downloading"}
            return Reply.text("Ok.")
        if endpoint == "torrents/info":
            p = dict(query)
            rows = list(self.torrents.values())
            if "hashes" in p:
                rows = [t for t in rows if t["hash"] in p["hashes"].split("|")]
            if "category" in p:
                rows = [t for t in rows if t["category"] == p["category"]]
            return Reply.json(rows)
        if endpoint == "torrents/stop":
            self.stopped.append(dict(fields)["hashes"])
            return Reply.text("")
        if endpoint == "torrents/files":
            return Reply.json([{"name": self.name}])
        return Reply.text("Ok.")


def make(fetch=None, state=None, private_backend=None, hosts=None):
    vpn, priv = Fake("vpn"), Fake("private")
    logs = []
    p = Proxy({"vpn": vpn, "private": priv}, "vpn", [Route("private", ["sapibr.com"])],
              fetch or (lambda u: (_ for _ in ()).throw(OSError("no network"))), HashMap(state),
              private_backend=private_backend, hostbook=HostBook(hosts), log=logs.append)
    return p, vpn, priv, logs


def adds(fake):
    return [c for c in fake.calls if c[0] == "torrents/add"]


class Add(unittest.TestCase):
    def test_private_file_goes_to_private_only(self):
        p, vpn, priv, _ = make()
        r = p.dispatch("POST", "torrents/add", [], [("category", "books")], [("torrents", "a.torrent", PRIV)])
        self.assertEqual(r.body, b"Ok.")
        self.assertEqual(len(adds(priv)), 1)
        self.assertEqual(adds(vpn), [])
        self.assertEqual(("category", "books"), adds(priv)[0][2][0])

    def test_public_file_goes_to_vpn(self):
        p, vpn, priv, _ = make()
        p.dispatch("POST", "torrents/add", [], [], [("torrents", "b.torrent", PUB)])
        self.assertEqual(len(adds(vpn)), 1)
        self.assertEqual(adds(priv), [])

    def test_magnet_routed_by_tr(self):
        p, vpn, priv, _ = make()
        m = f"magnet:?xt=urn:btih:{PRIV_HASH}&tr=https%3A%2F%2Ftracker.sapibr.com%2Fannounce%2FK"
        p.dispatch("POST", "torrents/add", [], [("urls", m)], [])
        self.assertEqual(adds(priv)[0][2], [("urls", m)])
        self.assertEqual(adds(vpn), [])

    def test_url_fetched_here_and_sent_as_file(self):
        p, vpn, priv, _ = make(fetch=lambda u: PRIV)
        p.dispatch("POST", "torrents/add", [], [("urls", "http://prowlarr:9696/5/download?apikey=K")], [])
        self.assertEqual(adds(vpn), [])
        endpoint, _, fields, files = adds(priv)[0]
        self.assertEqual(files, ["Livro - Autor [2026].torrent"])
        self.assertNotIn("urls", dict(fields))

    def test_url_redirecting_to_magnet(self):
        m = f"magnet:?xt=urn:btih:{PUB_HASH}&tr=udp%3A%2F%2Fopen.example%3A1"
        p, vpn, priv, _ = make(fetch=lambda u: m)
        p.dispatch("POST", "torrents/add", [], [("urls", "http://prowlarr:9696/1/download")], [])
        self.assertEqual(adds(vpn)[0][2], [("urls", m)])

    def test_unfetchable_url_is_refused_and_reaches_nobody(self):
        p, vpn, priv, logs = make()
        r = p.dispatch("POST", "torrents/add", [], [("urls", "http://prowlarr:9696/5/download?apikey=SECRET")], [])
        self.assertEqual(r.body, b"Fails.")
        self.assertEqual(adds(vpn) + adds(priv), [])
        self.assertTrue(logs and "SECRET" not in logs[0])

    def test_html_instead_of_torrent_is_refused(self):
        p, vpn, priv, _ = make(fetch=lambda u: b"<html>login</html>")
        r = p.dispatch("POST", "torrents/add", [], [("urls", "https://sapibr.com/torrent/download/1")], [])
        self.assertEqual(r.body, b"Fails.")
        self.assertEqual(adds(vpn) + adds(priv), [])

    def test_mixed_add_split(self):
        p, vpn, priv, _ = make()
        r = p.dispatch("POST", "torrents/add", [], [], [("torrents", "a", PRIV), ("torrents", "b", PUB)])
        self.assertEqual(r.body, b"Ok.")
        self.assertEqual((len(adds(vpn)), len(adds(priv))), (1, 1))


class ByHash(unittest.TestCase):
    def setUp(self):
        self.p, self.vpn, self.priv, _ = make()
        self.p.dispatch("POST", "torrents/add", [], [("category", "books")], [("torrents", "a", PRIV)])
        self.p.dispatch("POST", "torrents/add", [], [("category", "books")], [("torrents", "b", PUB)])

    def test_files_and_delete_follow_the_hash(self):
        r = self.p.dispatch("GET", "torrents/files", [("hash", PRIV_HASH)], [], [])
        self.assertEqual(json.loads(r.body), [{"name": "private"}])
        self.p.dispatch("POST", "torrents/delete", [], [("hashes", PRIV_HASH), ("deleteFiles", "false")], [])
        self.assertEqual(self.priv.calls[-1][0], "torrents/delete")
        self.assertNotIn("torrents/delete", [c[0] for c in self.vpn.calls])

    def test_info_merges_and_keeps_paging(self):
        rows = json.loads(self.p.dispatch("GET", "torrents/info", [("category", "books")], [], []).body)
        self.assertEqual({t["hash"] for t in rows}, {PRIV_HASH, PUB_HASH})
        one = json.loads(self.p.dispatch("GET", "torrents/info", [("sort", "name"), ("limit", "1")], [], []).body)
        self.assertEqual([t["name"] for t in one], ["Livro - Autor [2026]"])

    def test_info_by_hashes_split(self):
        rows = json.loads(self.p.dispatch("GET", "torrents/info", [("hashes", f"{PRIV_HASH}|{PUB_HASH}")], [], []).body)
        self.assertEqual(len(rows), 2)

    def test_unknown_hash_found_by_asking(self):
        p, vpn, priv, _ = make()
        priv.torrents["ab" * 20] = {"hash": "ab" * 20, "infohash_v1": "ab" * 20}
        self.assertEqual(p.where("ab" * 20), "private")
        self.assertEqual(p.where("cd" * 20), "vpn")

    def test_info_fails_whole_when_a_backend_is_down(self):
        self.priv.call = lambda *a, **k: (_ for _ in ()).throw(ConnectionError("down"))
        r = self.p.dispatch("GET", "torrents/info", [("category", "books")], [], [])
        self.assertEqual(r.status, 502)

    def test_categories_created_everywhere(self):
        self.p.dispatch("POST", "torrents/createCategory", [], [("category", "audiobooks")], [])
        for f in (self.vpn, self.priv):
            self.assertEqual(f.calls[-1][0], "torrents/createCategory")

    def test_map_survives_restart(self):
        with tempfile.TemporaryDirectory() as d:
            p, *_ = make(state=f"{d}/h.json")
            p.dispatch("POST", "torrents/add", [], [], [("torrents", "a", PRIV)])
            p2, vpn2, priv2, _ = make(state=f"{d}/h.json")
            p2.dispatch("GET", "torrents/properties", [("hash", PRIV_HASH)], [], [])
            self.assertEqual(priv2.calls[-1][0], "torrents/properties")
            self.assertEqual(vpn2.calls, [])


class Guard(unittest.TestCase):
    def test_private_tracker_torrent_in_vpn_is_stopped(self):
        p, vpn, priv, logs = make()
        vpn.torrents["x" * 40] = {"hash": "x" * 40, "name": "Curso", "tracker": "", "state": "uploading",
                                  "magnet_uri": "magnet:?xt=urn:btih:" + "a" * 40 + "&tr=https%3A%2F%2Fsapibr.com%2Fannounce%2FK"}
        vpn.torrents["y" * 40] = {"hash": "y" * 40, "name": "ok", "tracker": "udp://open.org:1/a",
                                  "state": "uploading", "magnet_uri": ""}
        stopped = p.guard()
        self.assertEqual(vpn.stopped, ["x" * 40])
        self.assertEqual(stopped[0]["host"], "sapibr.com")
        self.assertIn("GUARD", logs[-1])
        self.assertNotIn("/announce/K", logs[-1])
        vpn.torrents["x" * 40]["state"] = "stoppedUP"
        self.assertEqual(p.guard(), [])


# a private tracker nobody listed, and a public torrent that shares nothing with it
OTHER = torrent("https://tracker.newtracker.example/announce/KEY", info=dict(INFO, name="novo", private=1))
OTHER_PUB = torrent("udp://tracker.opentrackr.org:1337/announce", info=dict(INFO, name="aberto", private=0))


class PrivateFlag(unittest.TestCase):
    def test_off_by_default_unlisted_private_goes_to_vpn(self):
        p, vpn, priv, _ = make()
        p.dispatch("POST", "torrents/add", [], [], [("torrents", "a", OTHER)])
        self.assertEqual(len(adds(vpn)), 1)

    def test_any_private_torrent_goes_to_private(self):
        p, vpn, priv, logs = make(private_backend="private")
        p.dispatch("POST", "torrents/add", [], [], [("torrents", "a", OTHER)])
        p.dispatch("POST", "torrents/add", [], [], [("torrents", "b", OTHER_PUB)])
        self.assertEqual([a[3] for a in adds(priv)], [["a"]])
        self.assertEqual([a[3] for a in adds(vpn)], [["b"]])
        self.assertTrue(any("tracker.newtracker.example" in m for m in logs))

    def test_url_fetched_private_goes_to_private(self):
        p, vpn, priv, _ = make(fetch=lambda u: OTHER, private_backend="private")
        p.dispatch("POST", "torrents/add", [], [("urls", "http://prowlarr:9696/150/download?apikey=K")], [])
        self.assertEqual((len(adds(priv)), len(adds(vpn))), (1, 0))

    def test_magnet_of_a_learned_private_host_follows(self):
        with tempfile.TemporaryDirectory() as d:
            p, *_ = make(private_backend="private", hosts=f"{d}/hosts.json")
            p.dispatch("POST", "torrents/add", [], [], [("torrents", "a", OTHER)])
            p2, vpn, priv, _ = make(private_backend="private", hosts=f"{d}/hosts.json")  # after a restart
            m = "magnet:?xt=urn:btih:" + "b" * 40 + "&tr=https%3A%2F%2Ftracker.newtracker.example%2Fannounce%2FK"
            p2.dispatch("POST", "torrents/add", [], [("urls", m)], [])
            self.assertEqual((len(adds(priv)), len(adds(vpn))), (1, 0))

    def test_public_host_never_learned_as_private(self):
        p, vpn, priv, _ = make(private_backend="private")
        leaky = torrent("https://tracker.newtracker.example/a/K", [["https://tracker.newtracker.example/a/K"],
                        ["udp://tracker.opentrackr.org:1337/announce"]], info=dict(INFO, name="leaky", private=1))
        p.dispatch("POST", "torrents/add", [], [], [("torrents", "pub", OTHER_PUB)])   # opentrackr seen public
        p.dispatch("POST", "torrents/add", [], [], [("torrents", "leaky", leaky)])     # still private: flag
        m = "magnet:?xt=urn:btih:" + "c" * 40 + "&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce"
        p.dispatch("POST", "torrents/add", [], [("urls", m)], [])
        self.assertEqual(adds(vpn)[-1][2], [("urls", m)])
        self.assertEqual(adds(priv)[-1][3], ["leaky"])
        self.assertNotIn("tracker.opentrackr.org", p.hostbook.private)

    def test_later_public_sighting_unlearns(self):
        p, *_ = make(private_backend="private")
        p.hostbook.learn_private(["shared.example"])
        p.hostbook.see_public(["shared.example"])
        self.assertFalse(p.hostbook.is_private("shared.example"))
        self.assertEqual(p.hostbook.learn_private(["shared.example"]), [])

    def test_guard_stops_private_flag_in_vpn_and_leaves_public(self):
        p, vpn, priv, logs = make(private_backend="private")
        vpn.torrents["p" * 40] = {"hash": "p" * 40, "name": "filme", "tracker": "https://bj.example/announce/K",
                                  "magnet_uri": "", "state": "uploading", "private": True}
        vpn.torrents["q" * 40] = {"hash": "q" * 40, "name": "linux.iso", "tracker": "udp://open.example:1/a",
                                  "magnet_uri": "", "state": "uploading", "private": False}
        stopped = p.guard()
        self.assertEqual(vpn.stopped, ["p" * 40])
        self.assertEqual(stopped[0]["host"], "bj.example")
        self.assertIn("bj.example", p.hostbook.private)
        self.assertIn("open.example", p.hostbook.public)

    def test_guard_without_private_backend_ignores_flag(self):
        p, vpn, _, _ = make()
        vpn.torrents["p" * 40] = {"hash": "p" * 40, "name": "x", "tracker": "https://bj.example/a/K",
                                  "magnet_uri": "", "state": "uploading", "private": True}
        self.assertEqual(p.guard(), [])


class Http(unittest.TestCase):
    """The real HTTP backend and multipart against a tiny fake qBittorrent server."""

    def test_multipart_round_trip(self):
        body, ctype = encode_multipart([("category", "books"), ("rename", 'a "b"')], [("torrents", "x.torrent", PRIV)])
        fields, files = decode_multipart(ctype, body)
        self.assertEqual(fields, [("category", "books"), ("rename", 'a "b"')])
        self.assertEqual(files, [("torrents", "x.torrent", PRIV)])

    def test_fetcher_follows_to_magnet_or_bytes_and_keeps_the_key_home(self):
        heads = []

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                heads.append((self.path, self.headers.get("X-Api-Key")))
                if self.path == "/magnet":
                    self.send_response(301)
                    self.send_header("Location", "magnet:?xt=urn:btih:" + "a" * 40)
                    self.end_headers()
                elif self.path == "/hop":
                    self.send_response(302)
                    self.send_header("Location", "/file")
                    self.end_headers()
                elif self.path == "/file":
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(PRIV)
                else:
                    self.send_response(404)
                    self.end_headers()

        srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{srv.server_port}"
        try:
            self.assertTrue(make_fetcher("K", ["127.0.0.1"], 5)(base + "/magnet").startswith("magnet:?"))
            self.assertEqual(make_fetcher("K", ["prowlarr"], 5)(base + "/hop"), PRIV)
            self.assertEqual(heads[0][1], "K")
            self.assertEqual([h[1] for h in heads[1:]], [None, None])
            with self.assertRaises(ValueError):
                make_fetcher()(base + "/nope")
        finally:
            srv.shutdown()
            srv.server_close()

    def test_backend_logs_in_on_403(self):
        seen = []

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_POST(self):
                n = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(n)
                path = urlsplit(self.path).path
                seen.append((path, self.headers.get("Cookie")))
                if path.endswith("auth/login"):
                    ok = dict(parse_qsl(body.decode())) == {"username": "u", "password": "p"}
                    self.send_response(200)
                    if ok:
                        self.send_header("Set-Cookie", "SID=abc; HttpOnly; path=/")
                    self.end_headers()
                    self.wfile.write(b"Ok." if ok else b"Fails.")
                    return
                good = self.headers.get("Cookie") == "SID=abc"
                self.send_response(200 if good else 403)
                self.end_headers()
                self.wfile.write(b"Ok." if good else b"Forbidden")

        srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            b = HTTPBackend("private", f"http://127.0.0.1:{srv.server_port}", "u", "p", timeout=5)
            r = b.call("POST", "torrents/add", [], [("category", "books")], [("torrents", "a", PRIV)])
            self.assertEqual((r.status, r.body), (200, b"Ok."))
            self.assertEqual([s[0] for s in seen], ["/api/v2/torrents/add", "/api/v2/auth/login", "/api/v2/torrents/add"])
        finally:
            srv.shutdown()
            srv.server_close()


if __name__ == "__main__":
    unittest.main()
