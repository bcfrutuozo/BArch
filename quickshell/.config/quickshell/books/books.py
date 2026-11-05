#!/usr/bin/env python3
"""The book stack (server/books) from this desktop, through Shelfmark's API only: Shelfmark searches
Hardcover with its own token and writes the reading status there, so the one credential here is
Shelfmark's admin key (SHELFMARK_API_KEY in its container, ~/.config/barch/books.json here).

Every command prints one JSON object (`ok` true or false); `barch books` formats it and the Books app
reads it as is.

    books.py status                         Shelfmark, the request counts, what is downloading
    books.py search <query> [--page N]      Hardcover books, each with whether it is on Want to Read
    books.py shelf                          Want to Read, each book with what Shelfmark did with it
    books.py want <book id> [--off]         put on (take off) Want to Read
    books.py sync                           Shelfmark's Hardcover Sync now (shelf -> requests -> downloads)
    books.py requests [status]              requests (pending by default; "all" for every one)
    books.py request <id>                   one request
    books.py releases <id> [--query Q] [--source S] [--type ebook|audiobook]
                                            releases for a request's book (saved for `fulfil --pick`)
    books.py fulfil <id> --pick N | --release FILE   download that release for the request (a rejected
                                            or cancelled one is reopened first)
    books.py accept <id> [--query Q] [--source S]   download the best release that carries the book's
                                            title (the automatic rule without the author's surname)
    books.py reject <id> [note] · reopen <id> · cancel <id>
    books.py downloads                      the queue and the history of the last ones
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import time
import unicodedata
from concurrent.futures import ThreadPoolExecutor
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

CONFIG = Path(os.environ.get("BARCH_BOOKS_CONFIG", Path.home() / ".config/barch/books.json"))
CACHE = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "barch/books"
WANT = "status:1"                   # Hardcover's "Want to Read" as a Shelfmark target


class Fail(Exception):
    pass


def config() -> dict:
    try:
        cfg = json.loads(CONFIG.read_text())
    except FileNotFoundError:
        raise Fail(f"{CONFIG} missing: {{\"shelfmark\": {{\"url\": ..., \"key\": ...}}}}") from None
    sm = cfg.get("shelfmark") or {}
    if not sm.get("url") or not sm.get("key"):
        raise Fail(f"{CONFIG}: shelfmark.url and shelfmark.key are needed")
    return sm


def api(method: str, path: str, params: dict | None = None, body=None, timeout: float = 30):
    sm = config()
    url = sm["url"].rstrip("/") + path
    if params:
        url += "?" + urllib.parse.urlencode({k: v for k, v in params.items() if v not in (None, "")})
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "X-Api-Key": sm["key"], "Accept": "application/json",
        **({"Content-Type": "application/json"} if data is not None else {})})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            msg = json.loads(raw).get("error") or raw.decode()[:200]
        except (ValueError, AttributeError):
            msg = raw.decode(errors="replace")[:200]
        if e.code == 401:
            msg = "Shelfmark refused the key (SHELFMARK_API_KEY in its container = shelfmark.key in books.json?)"
        raise Fail(f"{method} {path}: {e.code} {msg}") from None
    except (urllib.error.URLError, TimeoutError) as e:
        raise Fail(f"Shelfmark not reachable at {sm['url']}: {getattr(e, 'reason', e)}") from None
    return json.loads(raw) if raw else {}


# ---------------------------------------------------------------- shapes

def book_view(b: dict) -> dict:
    """The fields the app and the CLI show, from Shelfmark's BookMetadata (+ library ownership)."""
    lib = b.get("library") or {}
    owned = {k: v for k, v in lib.items() if v} if isinstance(lib, dict) else lib
    return {
        "id": str(b.get("provider_id") or b.get("id") or ""),
        "provider": b.get("provider") or "hardcover",
        "title": b.get("title") or "",
        "subtitle": b.get("subtitle") or "",
        "authors": b.get("authors") or ([b["author"]] if b.get("author") else []),
        "year": b.get("publish_year") or b.get("year"),
        "cover": absolute(b.get("cover_url") or b.get("preview") or ""),
        "series": b.get("series_name") or "",
        "series_position": b.get("series_position"),
        "url": b.get("source_url") or "",
        "description": (b.get("description") or "")[:600],
        "owned": owned if owned else None,
    }


def absolute(u: str) -> str:
    if u and u.startswith("/"):
        return config()["url"].rstrip("/") + u
    return u


def local_covers(items: list[dict]) -> None:
    """Shelfmark serves its cached covers only to a logged-in client, which an Image in QML is not:
    each item's `cover` is fetched once into the cache (the key in a header) and `cover_file` set."""
    dest = CACHE / "covers"
    dest.mkdir(parents=True, exist_ok=True)
    key = config()["key"]

    def one(it: dict) -> None:
        url = it.get("cover") or ""
        if not url:
            it["cover_file"] = ""
            return
        f = dest / (hashlib.sha1(url.encode()).hexdigest()[:20] + ".img")
        if not f.exists() or f.stat().st_size == 0:
            headers = {"X-Api-Key": key} if url.startswith(config()["url"]) else {}
            try:
                with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=20) as r:
                    data = r.read()
                tmp = f.with_suffix(".part")
                tmp.write_bytes(data)
                tmp.replace(f)
            except (urllib.error.URLError, TimeoutError, OSError):
                it["cover_file"] = ""
                return
        it["cover_file"] = "file://" + str(f)

    with ThreadPoolExecutor(8) as ex:
        list(ex.map(one, items))


def want_flags(ids: list[str]) -> dict[str, bool]:
    if not ids:
        return {}
    try:
        res = api("POST", "/api/metadata/book/hardcover/targets/batch", body={"book_ids": ids}).get("results") or {}
    except Fail:
        return {}
    return {bid: any(o.get("value") == WANT and o.get("checked") for o in opts or []) for bid, opts in res.items()}


def request_view(r: dict) -> dict:
    bd = r.get("book_data") or {}
    if isinstance(bd, str):
        try:
            bd = json.loads(bd)
        except ValueError:
            bd = {}
    rd = r.get("release_data") or {}
    if isinstance(rd, str):
        try:
            rd = json.loads(rd)
        except ValueError:
            rd = {}
    authors = bd.get("authors") or ([bd["author"]] if bd.get("author") else [])
    return {
        "id": r.get("id"), "status": r.get("status"), "delivery": r.get("delivery_state"),
        "type": r.get("content_type"), "level": r.get("request_level"),
        "title": bd.get("title") or "", "authors": authors if isinstance(authors, list) else [str(authors)],
        "year": bd.get("publish_year") or bd.get("year"),
        "provider": bd.get("provider") or "", "book_id": str(bd.get("provider_id") or bd.get("id") or ""),
        "cover": absolute(bd.get("cover_url") or bd.get("preview") or ""),
        "url": bd.get("source_url") or "",
        "user": r.get("username") or "", "note": r.get("note") or "", "admin_note": r.get("admin_note") or "",
        "reason": r.get("failure_reason") or r.get("last_failure_reason") or r.get("auto_download_reason") or "",
        "release": {k: rd.get(k) for k in ("source", "title", "format", "size")} if rd else None,
        "created": r.get("created_at"), "updated": r.get("delivery_updated_at") or r.get("reviewed_at"),
        "book_data": bd,
    }


def release_view(i: int, r: dict) -> dict:
    return {"n": i, "source": r.get("source"), "indexer": r.get("indexer") or "", "title": r.get("title") or "",
            "format": r.get("format") or "", "language": r.get("language") or "", "size": r.get("size") or "",
            "seeders": r.get("seeders"), "protocol": r.get("protocol") or "", "info_url": r.get("info_url") or "",
            "content_type": kind(r)}


# ---------------------------------------------------------------- commands

def cmd_status(_args) -> dict:
    st = api("GET", "/api/status")
    try:
        counts = api("GET", "/api/admin/requests/count")
    except Fail as e:
        counts = {"error": str(e)}
    items = queue_items(st)
    live = [i for i in items if i["bucket"] in ("downloading", "resolving", "locating", "queued", "processing")]
    return {"ok": True, "requests": counts, "active": len(live), "queue": len(items)}


def cmd_search(args) -> dict:
    if not args:
        raise Fail("search <query>")
    page = 1
    if "--page" in args:
        i = args.index("--page")
        page = int(args[i + 1])
        args = args[:i] + args[i + 2:]
    q = " ".join(args)
    res = api("GET", "/api/metadata/search", {"provider": "hardcover", "query": q, "limit": 30, "page": page},
              timeout=60)
    books = [book_view(b) for b in res.get("books") or []]
    flags = want_flags([b["id"] for b in books if b["id"]])
    for b in books:
        b["want"] = flags.get(b["id"], False)
    local_covers(books)
    return {"ok": True, "query": q, "page": res.get("page", page), "has_more": bool(res.get("has_more")),
            "total": res.get("total_found"), "books": books}


def book_meta(provider: str, bid: str) -> dict:
    """The provider's full record of a book (cover, page, ISBN, library), cached for a day: the
    request keeps only title, author and year."""
    f = CACHE / "meta" / f"{provider}-{bid}.json"
    try:
        if time.time() - f.stat().st_mtime < 86400:
            return json.loads(f.read_text())
    except (OSError, ValueError):
        pass
    try:
        d = api("GET", f"/api/metadata/book/{provider}/{urllib.parse.quote(bid)}", timeout=30)
    except Fail:
        return {}
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(json.dumps(d))
    return d


def all_requests(enrich: bool = False) -> list[dict]:
    rows = api("GET", "/api/admin/requests", {"limit": 500})
    out = [request_view(r) for r in rows] if isinstance(rows, list) else []
    if enrich:
        def one(r: dict) -> None:
            if not r["provider"] or not r["book_id"]:
                return
            m = book_meta(r["provider"], r["book_id"])
            if not m:
                return
            v = book_view(m)
            r["cover"] = r["cover"] or v["cover"]
            r["url"] = r["url"] or v["url"]
            r["authors_full"] = v["authors"]
            r["isbn"] = [x for x in (m.get("isbn_13"), m.get("isbn_10")) if x]
            r["language"] = m.get("language") or ""
            r["series"] = v["series"]
            r["owned"] = v["owned"]
        with ThreadPoolExecutor(8) as ex:
            list(ex.map(one, out))
    return out


def cmd_shelf(_args) -> dict:
    books, page = [], 1
    while page <= 10:
        res = api("GET", "/api/metadata/search", {"provider": "hardcover", "hardcover_list": WANT,
                                                  "limit": 50, "page": page}, timeout=60)
        books += [book_view(b) for b in res.get("books") or []]
        if not res.get("has_more"):
            break
        page += 1
    by_book: dict[str, list[dict]] = {}
    try:
        for r in all_requests():
            if r["provider"] == "hardcover" and r["book_id"]:
                by_book.setdefault(r["book_id"], []).append(
                    {k: r[k] for k in ("id", "status", "delivery", "type", "reason")})
    except Fail:
        pass
    for b in books:
        b["want"] = True
        b["requests"] = by_book.get(b["id"], [])
    local_covers(books)
    return {"ok": True, "books": books}


def cmd_want(args) -> dict:
    if not args:
        raise Fail("want <hardcover book id> [--off]")
    bid, on = args[0], "--off" not in args
    res = api("PUT", f"/api/metadata/book/hardcover/{urllib.parse.quote(bid)}/targets",
              body={"target": WANT, "selected": on})
    return {"ok": True, "id": bid, "want": on, "result": res}


def cmd_sync(_args) -> dict:
    res = api("POST", "/api/settings/hardcover_sync/action/sync_now", body={}, timeout=600)
    return {"ok": bool(res.get("success", True)), "message": res.get("message") or "", "result": res}


def cmd_requests(args) -> dict:
    status = args[0] if args else "pending"
    rows = all_requests(enrich=True)
    if status != "all":
        rows = [r for r in rows if r["status"] == status]
    local_covers(rows)
    return {"ok": True, "status": status, "requests": rows}


def find_request(rid: str) -> dict:
    for r in all_requests(enrich=True):
        if str(r["id"]) == str(rid):
            return r
    raise Fail(f"no request {rid}")


def cmd_request(args) -> dict:
    if not args:
        raise Fail("request <id>")
    return {"ok": True, "request": find_request(args[0])}


def opt(args: list[str], name: str) -> str:
    if name in args:
        i = args.index(name)
        if i + 1 < len(args):
            return args[i + 1]
    return ""


def cmd_releases(args) -> dict:
    if not args:
        raise Fail("releases <request id> [--query Q] [--source S] [--type ebook|audiobook]")
    r = find_request(args[0])
    if "--cached" in args:                       # the last search of this request, as saved
        try:
            raw = json.loads((CACHE / f"releases-{r['id']}.json").read_text())
        except FileNotFoundError:
            raw = []
        return {"ok": True, "request": {k: r[k] for k in ("id", "title", "authors", "type")}, "query": "",
                "searched": [], "errors": {}, "releases": ranked(raw, r)}
    ctype = opt(args, "--type") or r["type"] or "ebook"
    params = {"provider": r["provider"], "book_id": r["book_id"], "content_type": ctype,
              "manual_query": opt(args, "--query"), "source": opt(args, "--source")}
    if not r["provider"] or not r["book_id"]:
        params = {"query": opt(args, "--query") or " ".join([r["title"]] + r["authors"][:1]),
                  "content_type": ctype, "source": opt(args, "--source")}
    res = api("GET", "/api/releases", params, timeout=300)
    raw = res.get("releases") or []
    CACHE.mkdir(parents=True, exist_ok=True)
    (CACHE / f"releases-{r['id']}.json").write_text(json.dumps(raw))
    return {"ok": True, "request": {k: r[k] for k in ("id", "title", "authors", "type")},
            "query": opt(args, "--query"), "searched": res.get("sources_searched") or [],
            "errors": res.get("errors") or {}, "releases": ranked(raw, r)}


def ranked(raw: list[dict], req: dict) -> list[dict]:
    """The releases best first (Accept's order): the ones that fit the request (its title, its type,
    no summary or pack) before the rest, then format, downloads, seeders, size; `fits` and `best`
    say which. `n` stays the index fulfil --pick takes."""
    full = [acceptable(x, req) for x in raw]
    main = re.sub(r"\(.*?\)", " ", req["title"]).split(":")[0]
    if not any(full) and ":" in req["title"] and len([w for w in words(main) if w not in STOP]) >= 3:
        full = [acceptable(x, req, main_only=True) for x in raw]       # releases that leave the subtitle out
    out = []
    for i, x in enumerate(raw):
        v = release_view(i, x)
        v["fits"] = full[i]
        v["_key"] = (v["fits"], *rank(x, req["type"] or "ebook"))
        out.append(v)
    out.sort(key=lambda v: v["_key"], reverse=True)
    for k, v in enumerate(out):
        del v["_key"]
        v["best"] = k == 0 and v["fits"]
    return out


def cmd_fulfil(args) -> dict:
    if not args:
        raise Fail("fulfil <request id> --pick N | --release FILE")
    rid = args[0]
    if opt(args, "--release"):
        rel = json.loads(Path(opt(args, "--release")).read_text())
    elif opt(args, "--pick") != "":
        try:
            cached = json.loads((CACHE / f"releases-{rid}.json").read_text())
        except FileNotFoundError:
            raise Fail(f"no releases saved for {rid}: run releases {rid} first") from None
        n = int(opt(args, "--pick"))
        if not 0 <= n < len(cached):
            raise Fail(f"--pick {n}: there are {len(cached)} releases")
        rel = cached[n]
    else:
        raise Fail("fulfil needs --pick N or --release FILE")
    current = find_request(rid)
    if current["status"] == "fulfilled":                 # a second click, or Hardcover Sync got there first
        raise Fail(f"#{rid} is already being downloaded (or done): see Downloads")
    if current["status"] in ("rejected", "cancelled"):   # changed your mind: back to pending, then download
        api("POST", f"/api/admin/requests/{rid}/reopen", body={})
    res = api("POST", f"/api/admin/requests/{rid}/fulfil",
              body={"release_data": rel, "manual_approval": True, "admin_note": opt(args, "--note") or None})
    return {"ok": True, "request": request_view(res) if isinstance(res, dict) and res.get("id") else res,
            "release": release_view(0, rel)}


# ---------------------------------------------------------------- accept: the best release, by hand
# Shelfmark's automatic download wants the author's surname in the release, which is what usually
# fails (a misspelt author, a release naming only the title). Accept keeps the rest of its rule: the
# book's title in the release name, no summary/adaptation, no pack, the request's type; then the
# same order: format, the copy others chose (downloads, seeders), size. Scanned DjVu goes last.
EBOOK_RANK = {"epub": 6, "kepub": 5, "azw3": 5, "mobi": 4, "azw": 4, "fb2": 3, "pdf": 2, "djvu": 0}
AUDIO_RANK = {"m4b": 4, "m4a": 3, "mp3": 2}
STOP = {"the", "a", "an", "of", "and", "o", "a", "os", "as", "de", "do", "da", "dos", "das", "e", "um", "uma", "to", "in"}
DERIVATIVE = {"summary", "analysis", "workbook", "abridged", "dramatized", "dramatised", "adaptation",
              "resumo", "sinopse", "guide"}
PACK = re.compile(r"\b(complete|collection|box ?set|omnibus|trilogy|megapack|colecao|coletanea|books? \d+ ?(-|to|a) ?\d+)\b")


def words(t: str) -> list[str]:
    t = unicodedata.normalize("NFKD", t or "").encode("ascii", "ignore").decode().lower()
    return re.findall(r"[a-z0-9]+", t)


def carries_title(title: str, release: str, main_only: bool = False) -> bool:
    """85 % of the title's significant words in the release name (Shelfmark's rule). The whole title
    (subtitle included) by default; main_only drops a subtitle after ":" for releases that omit it."""
    t = re.sub(r"\(.*?\)", " ", title or "")
    if main_only:
        t = t.split(":")[0]
    want = [w for w in words(t) if w not in STOP] or words(t)
    have = set(words(release))
    return bool(want) and sum(w in have for w in want) >= max(1, round(len(want) * 0.85))


AUDIO_FORMATS = {"m4b", "m4a", "mp3", "flac", "ogg", "opus", "aac", "wma", "wav"}


def kind(r: dict) -> str:
    """ebook or audiobook. Releases carry a display label in content_type ("📗 book (unknown)"), so
    the format and the title decide, as Shelfmark's audiobook signal does."""
    ct = (r.get("content_type") or "").lower()
    fmt = (r.get("format") or "").lower()
    title = (r.get("title") or "").lower()
    if fmt in AUDIO_FORMATS or "audiobook" in ct or "audio book" in title or "audiobook" in title \
            or "unabridged" in title or r.get("source") == "audiobookbay":
        return "audiobook"
    return "ebook"


def acceptable(r: dict, req: dict, main_only: bool = False) -> bool:
    title = r.get("title") or ""
    lowered = set(words(title))
    if (lowered & DERIVATIVE) - set(words(req["title"])):
        return False
    if PACK.search(" ".join(words(title))) and not PACK.search(" ".join(words(req["title"]))):
        return False
    if req["type"] and kind(r) != req["type"]:
        return False
    return carries_title(req["title"], title, main_only)


def rank(r: dict, ctype: str) -> tuple:
    fmt = (r.get("format") or "").lower()
    fr = (AUDIO_RANK if ctype == "audiobook" else EBOOK_RANK).get(fmt, 1)
    extra = r.get("extra") if isinstance(r.get("extra"), dict) else {}
    downloads = int(extra.get("downloads") or 0) if str(extra.get("downloads") or "0").isdigit() else 0
    return (fr, downloads, r.get("seeders") or 0, r.get("size_bytes") or 0)


def cmd_accept(args) -> dict:
    if not args:
        raise Fail("accept <request id> [--query Q] [--source S]")
    rid = args[0]
    req = find_request(rid)
    cached = CACHE / f"releases-{req['id']}.json"
    if opt(args, "--query") or opt(args, "--source") or not cached.exists():
        cmd_releases(args)
    raw = json.loads(cached.read_text())
    order = ranked(raw, req)
    ok = [v for v in order if v["fits"]]
    if not ok:
        kinds = {kind(r) for r in raw}
        what = f"no {req['type']} among them" if req["type"] and req["type"] not in kinds else \
            f"none carries the title \"{req['title']}\""
        return {"ok": False, "error": f"Accept: {len(raw)} releases, {what}: fix the query or the source, "
                                      "or pick one by hand"}
    n = ok[0]["n"]
    out = cmd_fulfil([str(req["id"]), "--pick", str(n)])
    out["candidates"] = len(ok)
    return out


def cmd_reject(args) -> dict:
    if not args:
        raise Fail("reject <request id> [note]")
    res = api("POST", f"/api/admin/requests/{args[0]}/reject", body={"admin_note": " ".join(args[1:]) or None})
    return {"ok": True, "request": request_view(res)}


def cmd_reopen(args) -> dict:
    if not args:
        raise Fail("reopen <request id>")
    res = api("POST", f"/api/admin/requests/{args[0]}/reopen", body={})
    return {"ok": True, "request": request_view(res)}


def cmd_cancel(args) -> dict:
    if not args:
        raise Fail("cancel <request id>")
    res = api("DELETE", f"/api/requests/{args[0]}")
    return {"ok": True, "request": request_view(res)}


def queue_items(status: dict) -> list[dict]:
    """Shelfmark's queue status ({bucket: {task id: task}}) as one list, the live ones first."""
    order = ["downloading", "resolving", "locating", "queued", "processing", "error", "failed", "complete", "done"]
    items = []
    for bucket, tasks in (status or {}).items():
        if not isinstance(tasks, dict):
            continue
        for tid, t in tasks.items():
            if not isinstance(t, dict):
                continue
            items.append({"bucket": bucket, "id": tid, "title": t.get("title") or "", "author": t.get("author") or "",
                          "source": t.get("source") or "", "format": t.get("format") or "",
                          "content_type": t.get("content_type") or "", "progress": t.get("progress"),
                          "message": t.get("status_message") or "", "request_id": t.get("request_id"),
                          "size": t.get("size") or "", "speed": t.get("download_speed"), "eta": t.get("eta"),
                          "added": t.get("added_time") or t.get("created_at")})
    items.sort(key=lambda i: (order.index(i["bucket"]) if i["bucket"] in order else len(order), -(i["added"] or 0)
                              if isinstance(i["added"], (int, float)) else 0))
    return items


def cmd_downloads(_args) -> dict:
    """The live queue, then the last fulfilled requests with their delivery (Shelfmark empties the
    queue once a download is delivered)."""
    items = queue_items(api("GET", "/api/status"))
    seen = {i.get("request_id") for i in items}
    done = [r for r in all_requests() if r["status"] == "fulfilled" and r["id"] not in seen]
    done.sort(key=lambda r: str(r["updated"] or r["created"] or ""), reverse=True)
    for r in done[:30]:
        items.append({"bucket": r["delivery"] if r["delivery"] not in (None, "", "none") else "requested",
                      "id": f"r{r['id']}", "title": r["title"], "author": ", ".join(r["authors"]),
                      "source": (r["release"] or {}).get("source") or "", "format": (r["release"] or {}).get("format") or "",
                      "content_type": r["type"], "progress": None, "message": (r["release"] or {}).get("title") or "",
                      "request_id": r["id"], "added": r["updated"] or r["created"]})
    return {"ok": True, "items": items}


COMMANDS = {"status": cmd_status, "search": cmd_search, "shelf": cmd_shelf, "want": cmd_want, "sync": cmd_sync,
            "requests": cmd_requests, "request": cmd_request, "releases": cmd_releases, "fulfil": cmd_fulfil,
            "accept": cmd_accept, "reject": cmd_reject, "reopen": cmd_reopen, "cancel": cmd_cancel, "downloads": cmd_downloads}


def main(argv: list[str]) -> int:
    if not argv or argv[0] not in COMMANDS:
        print(__doc__)
        return 2
    try:
        out = COMMANDS[argv[0]](argv[1:])
    except Fail as e:
        out = {"ok": False, "error": str(e)}
    except (ValueError, KeyError) as e:
        out = {"ok": False, "error": f"{type(e).__name__}: {e}"}
    print(json.dumps(out, ensure_ascii=False))
    return 0 if out.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
