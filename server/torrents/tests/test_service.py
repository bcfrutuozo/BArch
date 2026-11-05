import json
import sys
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from barch_torrents.service import DEFAULTS, make_handler  # noqa: E402
from barch_torrents.store import Store  # noqa: E402


class Http(unittest.TestCase):
    """The page is served to anyone (it asks for the token itself); the numbers only with the token."""

    def setUp(self):
        cfg = {**DEFAULTS, "db": ":memory:"}
        sampler = SimpleNamespace(store=Store(":memory:"), cfg=cfg, error="", last={}, version="", sources=[],
                                  prowlarr=SimpleNamespace(ok=False), wake=threading.Event())
        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(sampler, "secret"))
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.srv.server_address[1]}"

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()

    def get(self, path, token=""):
        req = urllib.request.Request(self.url + path, headers={"X-Barch-Token": token} if token else {})
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                return r.status, r.headers.get("Content-Type"), r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.headers.get("Content-Type"), e.read()

    def test_page_needs_no_token_and_carries_none(self):
        code, ctype, body = self.get("/")
        self.assertEqual(code, 200)
        self.assertTrue(ctype.startswith("text/html"))
        self.assertIn(b"<title>BArch Torrents</title>", body)
        self.assertNotIn(b"secret", body)

    def test_api_needs_the_token(self):
        self.assertEqual(self.get("/api/status")[0], 401)
        self.assertEqual(self.get("/api/status", "wrong")[0], 401)
        code, ctype, body = self.get("/api/status", "secret")
        self.assertEqual((code, ctype), (200, "application/json"))
        self.assertTrue(json.loads(body)["ok"])
        self.assertEqual(self.get("/api/status?token=secret")[0], 200)


if __name__ == "__main__":
    unittest.main()
