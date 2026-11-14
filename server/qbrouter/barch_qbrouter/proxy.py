"""The routing itself, between one qBittorrent Web API caller (Shelfmark) and several qBittorrents.

No sockets here: backends are objects with `call(method, endpoint, query, fields, files) -> Reply`
(server.py has the HTTP one, the tests a fake), and `fetch(url) -> bytes | str` gets a .torrent URL
(str = the magnet it redirected to). Rules:

- torrents/add: each torrent goes to the backend of the first route whose hosts match one of its
  trackers; else, when `private_backend` is set, a .torrent with the BEP 27 private flag (any private
  tracker, no list to keep) or a magnet whose tracker was learned from one goes there; else the default.
  The hosts of private torrents are learned, never one that ever appeared in a public torrent (an uploader
  who left an open tracker in a private torrent must not pull public magnets off the VPN). A torrent whose trackers cannot be known (a URL that cannot be fetched
  or is not a torrent) is refused with qBittorrent's own "Fails.", never guessed: a private tracker that
  bans VPNs must never see the VPN client announce.
- Anything naming hashes goes to the backend holding them (learned at add time and from every listing,
  else asked); torrents/info without hashes is the union of all backends.
- Category and tag management goes to every backend, so a category exists wherever a torrent lands.
- The rest (app/*, transfer/*, sync/*...) is the default backend's.
- guard(): stops any torrent in the default backend that should not be there (a route's tracker, the
  private flag qBittorrent reports, a learned private host), whoever added it (a pipeline, by hand).
"""

from __future__ import annotations

import json
import os
import threading
import time
from dataclasses import dataclass, field
from typing import Callable, Protocol

from .torrent import Torrent, TorrentError, host_matches, host_of, parse_magnet, parse_torrent, safe_url

Pairs = list[tuple[str, str]]
Files = list[tuple[str, str, bytes]]  # (field, filename, bytes)

BROADCAST = {
    "torrents/createCategory",
    "torrents/editCategory",
    "torrents/removeCategories",
    "torrents/createTags",
    "torrents/deleteTags",
}
PAGING = ("sort", "reverse", "limit", "offset")


@dataclass
class Reply:
    status: int
    body: bytes = b""
    ctype: str = "text/plain; charset=UTF-8"

    @classmethod
    def text(cls, s: str, status: int = 200) -> "Reply":
        return cls(status, s.encode())

    @classmethod
    def json(cls, obj: object, status: int = 200) -> "Reply":
        return cls(status, json.dumps(obj).encode(), "application/json")

    def ok(self) -> bool:
        return self.status == 200 and self.body.strip().rstrip(b".").lower() not in (b"fail", b"fails")


class Backend(Protocol):
    name: str

    def call(self, method: str, endpoint: str, query: Pairs | None = None,
             fields: Pairs | None = None, files: Files | None = None) -> Reply: ...


@dataclass
class Route:
    backend: str
    hosts: list[str]


class HashMap:
    """hash -> backend name, kept on disk so a restart still knows where each torrent lives."""

    def __init__(self, path: str | None):
        self.path = path
        self.lock = threading.Lock()
        self.map: dict[str, str] = {}
        if path and os.path.exists(path):
            try:
                with open(path) as f:
                    self.map = {k.lower(): v for k, v in json.load(f).items()}
            except (OSError, ValueError):
                self.map = {}

    def get(self, h: str) -> str | None:
        with self.lock:
            return self.map.get(h.lower())

    def set(self, hashes: set[str] | list[str], backend: str) -> None:
        changed = False
        with self.lock:
            for h in hashes:
                if h and self.map.get(h.lower()) != backend:
                    self.map[h.lower()] = backend
                    changed = True
            if changed and self.path:
                tmp = self.path + ".tmp"
                with open(tmp, "w") as f:
                    json.dump(self.map, f)
                os.replace(tmp, self.path)


class HostBook:
    """Tracker hosts seen in private torrents (learned) and in public ones (which never count as private)."""

    def __init__(self, path: str | None):
        self.path = path
        self.lock = threading.Lock()
        self.private: set[str] = set()
        self.public: set[str] = set()
        if path and os.path.exists(path):
            try:
                with open(path) as f:
                    d = json.load(f)
                self.private, self.public = set(d.get("private", [])), set(d.get("public", []))
            except (OSError, ValueError):
                pass

    def _save(self) -> None:
        if self.path:
            tmp = self.path + ".tmp"
            with open(tmp, "w") as f:
                json.dump({"private": sorted(self.private), "public": sorted(self.public)}, f)
            os.replace(tmp, self.path)

    def learn_private(self, hosts: list[str]) -> list[str]:
        with self.lock:
            new = [h for h in hosts if h and h not in self.public and h not in self.private]
            self.private.update(new)
            if new:
                self._save()
            return new

    def see_public(self, hosts: list[str]) -> list[str]:
        with self.lock:
            new = [h for h in hosts if h and h not in self.public]
            dropped = [h for h in new if h in self.private]
            self.public.update(new)
            self.private.difference_update(dropped)
            if new:
                self._save()
            return dropped

    def is_private(self, host: str) -> bool:
        with self.lock:
            return host in self.private


def _hosts(trackers: list[str]) -> list[str]:
    return list(dict.fromkeys(h for h in (host_of(t) for t in trackers) if h))


def _log(msg: str) -> None:
    print(time.strftime("%Y-%m-%d %H:%M:%S"), "qbrouter:", msg, flush=True)


@dataclass
class Proxy:
    backends: dict[str, Backend]
    default: str
    routes: list[Route]
    fetch: Callable[[str], "bytes | str"]
    hashmap: HashMap = field(default_factory=lambda: HashMap(None))
    private_backend: str | None = None
    hostbook: HostBook = field(default_factory=lambda: HostBook(None))
    log: Callable[[str], None] = _log
    blocked: list[dict] = field(default_factory=list)
    guard_last: float = 0.0
    _probe_cache: dict[str, tuple[float, list[dict]]] = field(default_factory=dict)

    # ---- classification ----

    def backend_for(self, trackers: list[str], private: bool = False) -> str:
        hosts = _hosts(trackers)
        for r in self.routes:
            if any(host_matches(h, r.hosts) for h in hosts):
                return r.backend
        if self.private_backend and (private or any(self.hostbook.is_private(h) for h in hosts)):
            return self.private_backend
        return self.default

    def _route_host(self, trackers: list[str]) -> str:
        for h in _hosts(trackers):
            if any(host_matches(h, r.hosts) for r in self.routes if r.backend != self.default):
                return h
            if self.private_backend and self.hostbook.is_private(h):
                return h
        return ""

    def _note(self, t: Torrent, from_file: bool) -> None:
        """What a torrent teaches about its trackers: private hosts, or hosts that are public for sure."""
        if not self.private_backend:
            return
        if t.private:
            new = self.hostbook.learn_private(_hosts(t.trackers))
            if new:
                self.log(f"learned private tracker host(s): {', '.join(new)}")
        elif from_file:  # a magnet cannot say it is public
            dropped = self.hostbook.see_public(_hosts(t.trackers))
            if dropped:
                self.log(f"seen in a public torrent, no longer private: {', '.join(dropped)}")

    def _place(self, t: Torrent) -> str:
        return self.backend_for(t.trackers, t.private)

    def resolve(self, item: str | bytes) -> Torrent:
        """A torrent from an `urls` line or an uploaded file; raises TorrentError when unknowable."""
        if isinstance(item, bytes):
            return parse_torrent(item)
        item = item.strip()
        if item.lower().startswith("magnet:"):
            return parse_magnet(item)
        if item.lower().startswith(("http://", "https://")):
            try:
                got = self.fetch(item)
            except Exception as e:  # noqa: BLE001 - any failure means "cannot know"
                raise TorrentError(f"could not fetch {safe_url(item)}: {e}") from e
            return parse_magnet(got) if isinstance(got, str) else parse_torrent(got)
        if len(item) in (32, 40):  # a bare info hash, as qBittorrent accepts: no trackers to go by
            return parse_magnet("magnet:?xt=urn:btih:" + item)
        raise TorrentError("neither a magnet, a .torrent URL nor a hash")

    # ---- dispatch ----

    def dispatch(self, method: str, endpoint: str, query: Pairs, fields: Pairs, files: Files) -> Reply:
        if endpoint == "auth/login":
            return Reply.text("Ok.")
        if endpoint == "auth/logout":
            return Reply.text("")
        if endpoint == "torrents/add":
            return self.add(fields, files)
        params = query + fields
        if endpoint == "torrents/info":
            return self.info(params)
        if endpoint in BROADCAST:
            replies = {n: self._call(n, method, endpoint, query, fields, files) for n in self.backends}
            return replies[self.default]
        hashes = self._param(params, "hashes") or self._param(params, "hash")
        if hashes is None:
            return self._call(self.default, method, endpoint, query, fields, files)
        key = "hashes" if self._param(params, "hashes") is not None else "hash"
        if hashes.strip().lower() == "all":
            replies = [self._call(n, method, endpoint, query, fields, files) for n in self.backends]
            return self._combine(replies)
        groups: dict[str, list[str]] = {}
        for h in [h for h in hashes.split("|") if h]:
            groups.setdefault(self.where(h), []).append(h)
        if len(groups) <= 1:
            name = next(iter(groups), self.default)
            return self._call(name, method, endpoint, query, fields, files)
        replies = []
        for name, hs in groups.items():
            q = self._replace(query, key, "|".join(hs))
            f = self._replace(fields, key, "|".join(hs))
            replies.append(self._call(name, method, endpoint, q, f, files))
        return self._combine(replies)

    def add(self, fields: Pairs, files: Files) -> Reply:
        items: list[tuple[str, Torrent, str | None, tuple[str, str, bytes] | None]] = []
        urls = [u for v in (v for k, v in fields if k == "urls") for u in v.splitlines() if u.strip()]
        try:
            for u in (u.strip() for u in urls):
                if not u.lower().startswith(("http://", "https://")):
                    t = self.resolve(u)
                    items.append((self._place(t), t, u, None))
                    continue
                # fetched here, and sent on as what it turned out to be: the backend may not resolve the
                # URL (the VPN qBittorrent cannot resolve Docker names) and must never fetch it differently
                try:
                    got = self.fetch(u)
                except Exception as e:  # noqa: BLE001 - any failure means "cannot know"
                    raise TorrentError(f"could not fetch {safe_url(u)}: {e}") from e
                if isinstance(got, str):
                    t = parse_magnet(got)
                    items.append((self._place(t), t, got, None))
                else:
                    t = parse_torrent(got)
                    self._note(t, True)
                    items.append((self._place(t), t, None,
                                  ("torrents", (t.name or t.hash) + ".torrent", got)))
            for fl in files:
                t = self.resolve(fl[2])
                self._note(t, True)
                items.append((self._place(t), t, None, fl))
        except TorrentError as e:
            self.log(f"add refused: {e}")
            return Reply.text("Fails.")
        if not items:
            return Reply.text("Fails.")
        rest = [(k, v) for k, v in fields if k != "urls"]
        groups: dict[str, list] = {}
        for it in items:
            groups.setdefault(it[0], []).append(it)
        replies = []
        for name, its in groups.items():
            gf = list(rest)
            us = [u for _, _, u, _ in its if u]
            if us:
                gf.append(("urls", "\n".join(us)))
            fls = [fl for _, _, _, fl in its if fl]
            r = self._call(name, "POST", "torrents/add", [], gf, fls)
            replies.append(r)
            for _, t, _, _ in its:
                host = self._route_host(t.trackers) or (host_of(t.trackers[0]) if t.trackers else "no tracker")
                if t.private:
                    host += ", private"
                self.log(f"add {t.name or t.hash} -> {name} ({host}): {r.body[:40].decode('utf-8', 'replace')}")
                if r.ok():
                    self.hashmap.set(t.hashes | {t.hash}, name)
        if len(replies) == 1:
            return replies[0]
        return replies[0] if all(r.ok() for r in replies) else Reply.text("Fails.")

    def info(self, params: Pairs) -> Reply:
        hashes = self._param(params, "hashes")
        passthru = [(k, v) for k, v in params if k not in PAGING and k != "hashes"]
        if hashes and hashes.lower() != "all":
            groups: dict[str, list[str]] = {}
            for h in [h for h in hashes.split("|") if h]:
                groups.setdefault(self.where(h), []).append(h)
            targets = {n: passthru + [("hashes", "|".join(hs))] for n, hs in groups.items()}
        else:
            targets = {n: passthru for n in self.backends}
        merged: list[dict] = []
        seen: set[str] = set()
        for name, q in targets.items():
            r = self._call(name, "GET", "torrents/info", q, [], [])
            if r.status != 200:  # half a listing would read as torrents gone missing
                return r
            try:
                rows = json.loads(r.body or b"[]")
            except ValueError:
                return Reply.text(f"{name}: bad JSON", 502)
            for t in rows:
                if not isinstance(t, dict) or t.get("hash") in seen:
                    continue
                seen.add(t.get("hash"))
                merged.append(t)
                self.hashmap.set({t.get("hash", ""), t.get("infohash_v1", ""), t.get("infohash_v2", "")[:40]}, name)
        sort = self._param(params, "sort")
        if sort:
            rev = (self._param(params, "reverse") or "").lower() == "true"
            merged.sort(key=lambda t: (t.get(sort) is None, t.get(sort) if not isinstance(t.get(sort), dict) else 0),
                        reverse=rev)
        off = int(self._param(params, "offset") or 0)
        lim = int(self._param(params, "limit") or 0)
        if off < 0:
            off = max(0, len(merged) + off)
        merged = merged[off : off + lim] if lim > 0 else merged[off:]
        return Reply.json(merged)

    def where(self, h: str) -> str:
        """The backend holding a hash: remembered, else asked of the non-default ones, else the default."""
        known = self.hashmap.get(h)
        if known in self.backends:
            return known
        h = h.lower()
        for name in self.backends:
            if name == self.default:
                continue
            for t in self._listing(name):
                ids = {t.get("hash", ""), t.get("infohash_v1", ""), (t.get("infohash_v2") or "")[:40]}
                if h in {i.lower() for i in ids if i}:
                    self.hashmap.set(ids, name)
                    return name
        return self.default

    def _listing(self, name: str) -> list[dict]:
        at, rows = self._probe_cache.get(name, (0.0, []))
        if time.monotonic() - at < 5:
            return rows
        r = self._call(name, "GET", "torrents/info", [], [], [])
        try:
            rows = json.loads(r.body) if r.status == 200 else []
        except ValueError:
            rows = []
        self._probe_cache[name] = (time.monotonic(), rows)
        return rows

    # ---- guard ----

    def guard(self) -> list[dict]:
        """Stop every torrent in the default backend whose tracker belongs to another backend's route."""
        r = self._call(self.default, "GET", "torrents/info", [], [], [])
        self.guard_last = time.time()
        if r.status != 200:
            return []
        try:
            rows = json.loads(r.body)
        except ValueError:
            return []
        stopped = []
        for t in rows:
            trackers = [t.get("tracker") or ""]
            magnet = t.get("magnet_uri") or ""
            if magnet:
                try:
                    trackers += parse_magnet(magnet).trackers
                except TorrentError:
                    pass
            trackers = [x for x in trackers if x]
            private = bool(t.get("private"))
            if self.private_backend:
                if private:
                    new = self.hostbook.learn_private(_hosts(trackers))
                    if new:
                        self.log(f"learned private tracker host(s): {', '.join(new)}")
                elif t.get("private") is False:  # qBittorrent knows it is public (the field exists)
                    self.hostbook.see_public(_hosts(trackers))
            if self.backend_for(trackers, private) == self.default:
                continue
            if t.get("state") in ("stoppedUP", "stoppedDL", "pausedUP", "pausedDL"):
                continue
            host = self._route_host(trackers) or ("private flag" if private else "")
            s = self._call(self.default, "POST", "torrents/stop", [], [("hashes", t["hash"])], [])
            if s.status == 404:  # qBittorrent before 5.0
                s = self._call(self.default, "POST", "torrents/pause", [], [("hashes", t["hash"])], [])
            entry = {"at": int(time.time()), "hash": t["hash"], "name": t.get("name", ""), "host": host,
                     "category": t.get("category", ""), "stopped": s.status == 200}
            self.log(f"GUARD: {entry['name']} ({host}, category {entry['category'] or '-'}) was in "
                     f"{self.default}; {'stopped' if entry['stopped'] else 'COULD NOT STOP'} it")
            stopped.append(entry)
            self.blocked = (self.blocked + [entry])[-50:]
        return stopped

    # ---- helpers ----

    def _call(self, name: str, method: str, endpoint: str, query: Pairs, fields: Pairs, files: Files) -> Reply:
        try:
            return self.backends[name].call(method, endpoint, query, fields, files)
        except Exception as e:  # noqa: BLE001 - one backend down must answer, not crash the request
            self.log(f"{name} {endpoint}: {type(e).__name__}: {e}")
            return Reply.text(f"{name} unreachable", 502)

    @staticmethod
    def _param(pairs: Pairs, key: str) -> str | None:
        for k, v in pairs:
            if k == key:
                return v
        return None

    @staticmethod
    def _replace(pairs: Pairs, key: str, value: str) -> Pairs:
        return [(k, value if k == key else v) for k, v in pairs]

    @staticmethod
    def _combine(replies: list[Reply]) -> Reply:
        bad = [r for r in replies if r.status != 200]
        if bad:
            return bad[0]
        try:
            lists = [json.loads(r.body) for r in replies]
            if all(isinstance(x, list) for x in lists):
                return Reply.json([y for x in lists for y in x])
        except ValueError:
            pass
        return replies[0]
