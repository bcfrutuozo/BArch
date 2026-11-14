"""What routing needs from a torrent: its id in qBittorrent and the hosts of its trackers.

Pure functions over bytes and strings (no network), covered by tests/test_torrent.py.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
from dataclasses import dataclass, field
from urllib.parse import parse_qs, urlsplit


class TorrentError(ValueError):
    """The bytes are not a torrent, or the magnet has no usable info hash."""


@dataclass
class Torrent:
    hash: str  # the id qBittorrent gives it: the v1 info hash, or the truncated v2 one for v2-only torrents
    trackers: list[str] = field(default_factory=list)
    name: str = ""
    hashes: set[str] = field(default_factory=set)  # every id it may be asked by (v1, v2 truncated)
    private: bool = False  # BEP 27 flag in the .torrent (a magnet cannot tell)


# ---- bencode ----------------------------------------------------------------------------------------


def _decode(data: bytes, i: int) -> tuple[object, int]:
    c = data[i : i + 1]
    if c == b"i":
        j = data.index(b"e", i)
        return int(data[i + 1 : j]), j + 1
    if c == b"l":
        i += 1
        out: list[object] = []
        while data[i : i + 1] != b"e":
            if i >= len(data):
                raise TorrentError("unterminated list")
            v, i = _decode(data, i)
            out.append(v)
        return out, i + 1
    if c == b"d":
        i += 1
        d: dict[bytes, object] = {}
        while data[i : i + 1] != b"e":
            if i >= len(data):
                raise TorrentError("unterminated dict")
            k, i = _decode(data, i)
            if not isinstance(k, bytes):
                raise TorrentError("dict key is not a string")
            v, i = _decode(data, i)
            d[k] = v
        return d, i + 1
    if c.isdigit():
        j = data.index(b":", i)
        n = int(data[i:j])
        start = j + 1
        if n < 0 or start + n > len(data):
            raise TorrentError("string runs past the end")
        return data[start : start + n], start + n
    raise TorrentError(f"unexpected byte at {i}")


def bdecode(data: bytes) -> object:
    try:
        value, end = _decode(data, 0)
    except (IndexError, ValueError, RecursionError) as e:
        raise TorrentError(f"not bencoded: {e}") from e
    if end != len(data):
        raise TorrentError("trailing bytes after the torrent")
    return value


def _info_span(data: bytes) -> tuple[int, int]:
    """Where the raw `info` value sits in a torrent file: its hash is over those exact bytes."""
    if data[:1] != b"d":
        raise TorrentError("a torrent file is a dictionary")
    i = 1
    try:
        while data[i : i + 1] != b"e":
            k, i = _decode(data, i)
            start = i
            _, i = _decode(data, i)
            if k == b"info":
                return start, i
    except (IndexError, ValueError, RecursionError) as e:
        raise TorrentError(f"not bencoded: {e}") from e
    raise TorrentError("no info dictionary")


def _text(v: object) -> str:
    return v.decode("utf-8", "replace") if isinstance(v, bytes) else ""


def parse_torrent(data: bytes) -> Torrent:
    meta = bdecode(data)
    if not isinstance(meta, dict) or not isinstance(meta.get(b"info"), dict):
        raise TorrentError("no info dictionary")
    start, end = _info_span(data)
    raw = data[start:end]
    info = meta[b"info"]
    v1 = hashlib.sha1(raw).hexdigest()
    v2 = hashlib.sha256(raw).hexdigest()[:40]
    v2_only = b"pieces" not in info and info.get(b"meta version") == 2
    trackers: list[str] = []
    if isinstance(meta.get(b"announce"), bytes):
        trackers.append(_text(meta[b"announce"]))
    for tier in meta.get(b"announce-list") or []:
        for url in tier if isinstance(tier, list) else []:
            if isinstance(url, bytes) and _text(url) not in trackers:
                trackers.append(_text(url))
    hashes = {v2} if v2_only else {v1}
    if info.get(b"meta version") == 2:
        hashes.add(v2)
    return Torrent(hash=v2 if v2_only else v1, trackers=trackers, name=_text(info.get(b"name")), hashes=hashes,
                   private=info.get(b"private") == 1)


# ---- magnets ----------------------------------------------------------------------------------------


def _btih(value: str) -> str | None:
    if len(value) == 40:
        try:
            int(value, 16)
        except ValueError:
            return None
        return value.lower()
    if len(value) == 32:
        try:
            return base64.b32decode(value.upper()).hex()
        except (binascii.Error, ValueError):
            return None
    return None


def parse_magnet(uri: str) -> Torrent:
    if not uri.lower().startswith("magnet:?"):
        raise TorrentError("not a magnet link")
    q = parse_qs(uri[len("magnet:?") :])
    v1 = v2 = None
    for xt in q.get("xt", []):
        low = xt.lower()
        if low.startswith("urn:btih:"):
            v1 = _btih(xt[9:]) or v1
        elif low.startswith("urn:btmh:1220") and len(xt) >= 13 + 64:
            v2 = xt[13 : 13 + 64].lower()[:40]
    if not v1 and not v2:
        raise TorrentError("magnet without an info hash")
    hashes = {h for h in (v1, v2) if h}
    trackers = list(dict.fromkeys(q.get("tr", [])))
    return Torrent(hash=v1 or v2 or "", trackers=trackers, name=(q.get("dn") or [""])[0], hashes=hashes)


# ---- hosts ------------------------------------------------------------------------------------------


def host_of(url: str) -> str:
    try:
        return (urlsplit(url.strip()).hostname or "").lower().rstrip(".")
    except ValueError:
        return ""


def host_matches(host: str, domains: list[str]) -> bool:
    host = host.lower().rstrip(".")
    return any(host == d or host.endswith("." + d) for d in (d.lower().strip(".") for d in domains) if d)


def safe_url(url: str) -> str:
    """A URL fit for a log line: no query (Prowlarr's apikey), no path (a tracker's passkey)."""
    if url.lower().startswith("magnet:"):
        return "magnet:?…"
    try:
        p = urlsplit(url)
    except ValueError:
        return "<url>"
    return f"{p.scheme}://{p.hostname or ''}/…"
