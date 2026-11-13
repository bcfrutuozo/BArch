"""service.py: the API token check (constant time, closed without a token) and the refusal to serve without one."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from barch_video.auth import require_token, token_ok  # noqa: E402


class Token(unittest.TestCase):
    def test_the_right_token(self):
        self.assertTrue(token_ok("s3cret", "s3cret"))

    def test_wrong_missing_or_partial(self):
        for got in ("", None, "s3cre", "s3cret ", "S3CRET", "s3cret\x00"):
            self.assertFalse(token_ok("s3cret", got), repr(got))

    def test_an_empty_token_opens_nothing(self):
        # before 2026-11-13 an empty token in secrets.json turned the check off
        for got in ("", None, "anything"):
            self.assertFalse(token_ok("", got), repr(got))

    def test_no_token_no_service(self):
        for cfg in ({}, {"token": ""}, {"token": None}):
            with self.assertRaises(SystemExit):
                require_token(cfg, "test")
        self.assertEqual(require_token({"token": "abc"}, "test"), "abc")


if __name__ == "__main__":
    unittest.main()
