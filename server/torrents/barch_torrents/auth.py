"""The API token: checked in constant time, and no token means no API (never an open one).
Kept apart from service.py so the tests run without the pipeline's dependencies."""
from __future__ import annotations

import hmac
import sys


def token_ok(expected: str, got: str | None) -> bool:
    """The API token check: constant time, and an empty token never matches (serve() refuses to
    start without one, so a lost secrets.json closes the API instead of opening it)."""
    return bool(expected) and hmac.compare_digest(expected.encode(), (got or "").encode())


def require_token(cfg: dict, name: str) -> str:
    token = str(cfg.get("token") or "")
    if not token:
        sys.exit(f"{name}: no token in the config (secrets.json): refusing to serve the API without one")
    return token
