"""MusicBrainz, Cover Art Archive, AcoustID and two cover fallbacks (iTunes, Deezer), with the
standard library only. MusicBrainz allows one request per second per client: every call waits."""
from __future__ import annotations

import json
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

UA = "barch-music-pipeline/1.0 ( https://github.com/bcfrutuozo/BArch )"
MB = "https://musicbrainz.org/ws/2"
_lock = threading.Lock()
_last = [0.0]


class NetError(Exception):
    pass


def get(url: str, params: dict | None = None, timeout: int = 30, raw: bool = False, mb: bool = False):
    if params:
        url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
    for attempt in range(4):
        if mb:
            with _lock:
                wait = _last[0] + 1.1 - time.time()
                if wait > 0:
                    time.sleep(wait)
                _last[0] = time.time()
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                data = r.read()
                return data if raw else json.loads(data.decode())
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            if e.code in (429, 500, 502, 503) and attempt < 3:
                time.sleep(2 + attempt * 3)
                continue
            raise NetError(f"{url.split('?')[0]}: HTTP {e.code}")
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            if attempt < 3:
                time.sleep(2 + attempt * 3)
                continue
            raise NetError(f"{url.split('?')[0]}: {e}")
    raise NetError(url)


def _q(s: str) -> str:
    return '"' + s.replace("\\", " ").replace('"', " ").strip() + '"'


def search_releases(artist: str = "", album: str = "", tracks: int = 0, limit: int = 12) -> list[dict]:
    parts = []
    if album:
        parts.append(f"release:{_q(album)}")
    if artist:
        parts.append(f"artist:{_q(artist)}")
    if tracks:
        parts.append(f"tracks:{tracks}")
    if not parts:
        return []
    d = get(f"{MB}/release", {"query": " AND ".join(parts), "limit": limit, "fmt": "json"}, mb=True) or {}
    return d.get("releases", [])


INC = "recordings+artist-credits+release-groups+media+labels+genres+isrcs"


def release(mbid: str) -> dict | None:
    return get(f"{MB}/release/{mbid}", {"inc": INC, "fmt": "json"}, mb=True)


def release_group(mbid: str) -> dict | None:
    return get(f"{MB}/release-group/{mbid}", {"inc": "releases+genres+artist-credits+url-rels", "fmt": "json"}, mb=True)


def releases_of_group(mbid: str) -> list[dict]:
    d = get(f"{MB}/release", {"release-group": mbid, "inc": "media", "limit": 100, "fmt": "json"}, mb=True) or {}
    return d.get("releases", [])


def artist_genres(mbid: str) -> list[dict]:
    d = get(f"{MB}/artist/{mbid}", {"inc": "genres", "fmt": "json"}, mb=True) or {}
    return d.get("genres", [])


def recording_releases(rec_id: str) -> list[dict]:
    d = get(f"{MB}/recording/{rec_id}", {"inc": "releases+release-groups", "fmt": "json"}, mb=True) or {}
    return d.get("releases", [])


# ---------------------------------------------------------------- covers

def caa_images(kind: str, mbid: str) -> list[dict]:
    """kind release|release-group -> the front images: {url, thumbs{500,1200}}."""
    d = get(f"https://coverartarchive.org/{kind}/{mbid}") or {}
    out = []
    for img in d.get("images", []):
        if img.get("front") or "Front" in (img.get("types") or []):
            th = img.get("thumbnails") or {}
            out.append({"url": img.get("image"), "1200": th.get("1200") or th.get("large"), "500": th.get("500")})
    return out


def itunes_covers(artist: str, album: str) -> list[str]:
    d = get("https://itunes.apple.com/search", {"term": f"{artist} {album}", "entity": "album", "limit": 5}) or {}
    return [r["artworkUrl100"].replace("100x100bb", "1400x1400bb") for r in d.get("results", []) if r.get("artworkUrl100")]


def deezer_covers(artist: str, album: str) -> list[str]:
    d = get("https://api.deezer.com/search/album", {"q": f'artist:"{artist}" album:"{album}"', "limit": 5}) or {}
    return [r["cover_xl"] for r in d.get("data", []) if r.get("cover_xl")]


def download(url: str, timeout: int = 60) -> bytes | None:
    try:
        return get(url, raw=True, timeout=timeout)
    except NetError:
        return None


# ---------------------------------------------------------------- AcoustID (optional)

def acoustid_lookup(key: str, fingerprint: str, duration: int) -> list[str]:
    """recording MBIDs for one fingerprint (fpcalc), best first."""
    d = get("https://api.acoustid.org/v2/lookup", {"client": key, "meta": "recordingids", "duration": duration,
                                                    "fingerprint": fingerprint}) or {}
    ids = []
    for res in sorted(d.get("results", []), key=lambda r: -r.get("score", 0)):
        if res.get("score", 0) < 0.8:
            continue
        ids += [rec["id"] for rec in res.get("recordings", []) if rec.get("id")]
    return ids


# ---------------------------------------------------------------- Wikidata (dates and genres)

def artist(mbid: str) -> dict | None:
    return get(f"{MB}/artist/{mbid}", {"inc": "genres+url-rels", "fmt": "json"}, mb=True)


def wikidata_id(entity: dict | None) -> str:
    """The Wikidata item MusicBrainz links to (release group or artist url-rels): "Q12345"."""
    for rel in (entity or {}).get("relations", []):
        if rel.get("type") == "wikidata":
            url = (rel.get("url") or {}).get("resource", "")
            if "/wiki/Q" in url:
                return url.rsplit("/", 1)[-1]
    return ""


def wikidata(qid: str) -> dict:
    d = get(f"https://www.wikidata.org/wiki/Special:EntityData/{qid}.json") or {}
    return (d.get("entities") or {}).get(qid, {})


def wikidata_dates(qid: str) -> list[str]:
    """Publication dates (P577) known to the day, as YYYY-MM-DD, earliest first."""
    out = []
    for c in (wikidata(qid).get("claims") or {}).get("P577", []):
        v = ((c.get("mainsnak") or {}).get("datavalue") or {}).get("value") or {}
        t, prec = v.get("time", ""), v.get("precision", 0)
        if prec >= 11 and len(t) >= 11:
            out.append(t.lstrip("+")[:10])
    return sorted(out)


def wikidata_genres(qid: str) -> list[str]:
    """Genre (P136) labels in English, as Wikidata orders them."""
    ids = [((c.get("mainsnak") or {}).get("datavalue") or {}).get("value", {}).get("id")
           for c in (wikidata(qid).get("claims") or {}).get("P136", [])]
    ids = [i for i in ids if i][:5]
    if not ids:
        return []
    d = get("https://www.wikidata.org/w/api.php", {"action": "wbgetentities", "ids": "|".join(ids), "props": "labels",
                                                    "languages": "en", "format": "json"}) or {}
    ents = d.get("entities") or {}
    return [ents[i]["labels"]["en"]["value"] for i in ids if (ents.get(i) or {}).get("labels", {}).get("en")]


# ---------------------------------------------------------------- Wikipedia (the infobox release date)

_RELEASED = {"en": r"released", "pt": r"lançado|lançamento|data_lançamento|data", "es": r"publicación|lanzamiento|lanzado",
             "it": r"pubblicazione", "fr": r"sortie|date", "de": r"veröffentlichung|veröffentlicht", "nl": r"uitgebracht",
             "sv": r"utgiven|släppt", "ja": r"リリース|発売日", "fi": r"julkaistu", "pl": r"wydany|data wydania"}
_MONTHS = {}
for _names in ("january february march april may june july august september october november december",
               "janeiro fevereiro março abril maio junho julho agosto setembro outubro novembro dezembro",
               "enero febrero marzo abril mayo junio julio agosto septiembre octubre noviembre diciembre",
               "gennaio febbraio marzo aprile maggio giugno luglio agosto settembre ottobre novembre dicembre",
               "janvier février mars avril mai juin juillet août septembre octobre novembre décembre",
               "januar februar märz april mai juni juli august september oktober november dezember",
               "januari februari maart april mei juni juli augustus september oktober november december",
               "januari februari mars april maj juni juli augusti september oktober november december",
               "tammikuuta helmikuuta maaliskuuta huhtikuuta toukokuuta kesäkuuta heinäkuuta elokuuta syyskuuta lokakuuta marraskuuta joulukuuta",
               "stycznia lutego marca kwietnia maja czerwca lipca sierpnia września października listopada grudnia"):
    for _i, _m in enumerate(_names.split(), 1):
        _MONTHS.setdefault(_m, _i)
        _MONTHS.setdefault(_m[:3], _i)


def _dates_in(text: str) -> list[str]:
    """Every date known to the day in one infobox value, as YYYY-MM-DD."""
    out = []
    for m in re.finditer(r"\{\{\s*(?:start date|release date|dts|data|fecha|datum)[^|}]*\|\s*(?:df=\w+\|\s*)?(\d{4})\s*\|\s*(\d{1,2})\s*\|\s*(\d{1,2})", text, re.I):
        out.append(f"{m.group(1)}-{int(m.group(2)):02d}-{int(m.group(3)):02d}")
    for m in re.finditer(r"\b(\d{4})-(\d{2})-(\d{2})\b", text):
        out.append(m.group(0))
    for m in re.finditer(r"(\d{4})年\s*(\d{1,2})月\s*(\d{1,2})日", text):
        out.append(f"{m.group(1)}-{int(m.group(2)):02d}-{int(m.group(3)):02d}")
    words = r"([A-Za-zÀ-ÿäöå]+)"
    for m in re.finditer(r"\b(\d{1,2})(?:º|er|\.)?\s+(?:de\s+)?" + words + r"\.?\s+(?:de\s+)?(\d{4})\b", text):
        mo = _MONTHS.get(m.group(2).lower())
        if mo:
            out.append(f"{m.group(3)}-{mo:02d}-{int(m.group(1)):02d}")
    for m in re.finditer(r"\b" + words + r"\.?\s+(\d{1,2}),?\s+(\d{4})\b", text):
        mo = _MONTHS.get(m.group(1).lower())
        if mo:
            out.append(f"{m.group(3)}-{mo:02d}-{int(m.group(2)):02d}")
    return [d for d in out if 1 <= int(d[5:7]) <= 12 and 1 <= int(d[8:10]) <= 31]


def wikipedia_dates(qid: str) -> list[tuple[str, str]]:
    """(YYYY-MM-DD, "enwiki") from the release field of the album's infobox on every Wikipedia that
    has the item, references and comments removed (an access date of a citation is not a release)."""
    links = wikidata(qid).get("sitelinks") or {}
    found = []
    for lang in _RELEASED:
        site = f"{lang}wiki"
        if site not in links:
            continue
        d = get(f"https://{lang}.wikipedia.org/w/api.php", {"action": "parse", "page": links[site]["title"], "prop": "wikitext",
                                                           "format": "json", "formatversion": 2}) or {}
        wt = (d.get("parse") or {}).get("wikitext", "")
        wt = re.sub(r"<ref[^>]*/>|<ref[^>]*>.*?</ref>|<!--.*?-->", " ", wt, flags=re.S | re.I)
        for m in re.finditer(r"^\s*\|\s*(?:" + _RELEASED[lang] + r")\s*=\s*(.*)$", wt, re.M | re.I):
            found += [(x, site) for x in _dates_in(m.group(1))]
    return found
