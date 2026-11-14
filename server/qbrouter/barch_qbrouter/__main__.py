"""barch-qbrouter: one qBittorrent Web API in front of several qBittorrents, routed by tracker.

  python3 -m barch_qbrouter serve --config /config/config.json
  python3 -m barch_qbrouter which --config config.json <file.torrent | magnet>   (prints the backend; sends nothing)
"""

from __future__ import annotations

import argparse
import sys

from .proxy import Proxy, Route
from .server import load, serve
from .torrent import TorrentError, host_of, parse_magnet, parse_torrent


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="barch_qbrouter")
    ap.add_argument("command", choices=["serve", "which"])
    ap.add_argument("item", nargs="?")
    ap.add_argument("--config", default="/config/config.json")
    a = ap.parse_args(argv)
    config, secret = load(a.config)
    if a.command == "serve":
        serve(config, secret)
        return 0
    if not a.item:
        ap.error("which needs a .torrent file or a magnet")
    try:
        if a.item.lower().startswith("magnet:"):
            t = parse_magnet(a.item)
        else:
            with open(a.item, "rb") as f:
                t = parse_torrent(f.read())
    except (OSError, TorrentError) as e:
        print(f"which: {e}", file=sys.stderr)
        return 1
    p = Proxy({n: None for n in config["backends"]}, config["default"],  # type: ignore[arg-type]
              [Route(r["backend"], r["hosts"]) for r in config.get("routes", [])], fetch=lambda u: b"",
              private_backend=config.get("private_backend"))
    hosts = sorted({host_of(x) for x in t.trackers if host_of(x)})
    print(f"{t.name or t.hash}: {p.backend_for(t.trackers, t.private)} (trackers: {', '.join(hosts) or 'none'}"
          f"{', private flag' if t.private else ''})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
