"""Which albums of an artist are canonical: the ones the artist (or the label) actually put out, as
opposed to the hundreds of regional EPs, budget compilations and grey-market live records MusicBrainz
lists as "Official" too (Deep Purple: 616 release groups, "Stereo Pop Special-12", "Battle of Deep Purple
& Jimi Hendrix", each one release marked Official). Lidarr's release status filter cannot tell them apart.

The rule, measured on Deep Purple, Iron Maiden and T-SQUARE (2026-11-04):
- a studio album (primary type Album, no secondary type) is always canonical;
- an EP, a live album or a compilation is canonical when its MusicBrainz release group links to
  Wikidata or Wikipedia, or when its title is in the artist's Wikipedia: the artist's article and
  its discography article (Wikidata P358), in English and in the language of the artist's country.
  In English only a title in italics counts (the running text names songs and pairs of albums);
  in the home language, where discographies are tables without italics (ja), a distinctive title
  (three words or more, or non-Latin; not a pair "A / B", whose two names sit next to each other in
  any discography) found anywhere in the text counts too;
- several release groups with the same title (the 1974 "Burn" EPs next to the album): Wikipedia's
  mention goes to one only, none when one of them is on Wikidata, otherwise the earliest album;
- an artist without any Wikipedia article is not judged (everything canonical): nothing to go by.

Verdicts are cached per artist (`canon.json` in the jobs folder) for a week."""
from __future__ import annotations

import html
import json
import re
import threading
import time
import unicodedata
from pathlib import Path

from . import mb

TTL = 7 * 86400
HOME_LANG = {"JP": "ja", "BR": "pt", "PT": "pt", "DE": "de", "AT": "de", "CH": "de", "FR": "fr", "BE": "fr",
             "FI": "fi", "SE": "sv", "NO": "no", "DK": "da", "ES": "es", "MX": "es", "AR": "es", "CL": "es",
             "CO": "es", "IT": "it", "KR": "ko", "NL": "nl", "PL": "pl", "RU": "ru", "CZ": "cs", "HU": "hu",
             "GR": "el", "TR": "tr", "IS": "is", "CN": "zh", "TW": "zh", "HK": "zh"}


def norm(s: str) -> str:
    s = unicodedata.normalize("NFKC", html.unescape(s or "")).casefold().replace("&", " and ")
    return " ".join(re.findall(r"\w+", s))


def distinctive(n: str) -> bool:
    return len(n.split()) >= 3 or (len(n) >= 6 and bool(re.search(r"[^\x00-\x7f]", n)))


def studio(group: dict) -> bool:
    return group.get("primary-type") == "Album" and not group.get("secondary-types")


def _groups(artist_mbid: str) -> list[dict]:
    out, off = [], 0
    while True:
        d = mb.get(f"{mb.MB}/release-group", {"artist": artist_mbid, "inc": "url-rels", "limit": 100,
                                               "offset": off, "fmt": "json"}, mb=True) or {}
        out += d.get("release-groups", [])
        off += 100
        if off >= d.get("release-group-count", 0):
            return out


def _wiki_pages(artist: dict) -> list[tuple[str, str]]:
    """(lang, title) of the artist's article and of its discography article, in English and at home."""
    qid = mb.wikidata_id(artist)
    if not qid:
        return []
    langs = ["en"] + ([HOME_LANG[artist["country"]]] if HOME_LANG.get(artist.get("country") or "") else [])
    ents = [mb.wikidata(qid)]
    for c in (ents[0].get("claims") or {}).get("P358", []):
        did = (((c.get("mainsnak") or {}).get("datavalue") or {}).get("value") or {}).get("id")
        if did:
            ents.append(mb.wikidata(did))
    return [(lang, e["sitelinks"][f"{lang}wiki"]["title"]) for e in ents for lang in langs
            if f"{lang}wiki" in (e.get("sitelinks") or {})]


def _wiki_titles(pages: list[tuple[str, str]]) -> tuple[set[str], str]:
    """The titles set apart on these pages (italics, 『』, 「」) and the running text of the home ones."""
    quoted, text = set(), []
    for lang, title in pages:
        d = mb.get(f"https://{lang}.wikipedia.org/w/api.php", {"action": "parse", "page": title, "prop": "text",
                                                               "format": "json", "formatversion": 2, "redirects": 1}) or {}
        doc = (d.get("parse") or {}).get("text", "")
        for m in re.finditer(r"<i>(.*?)</i>|『(.*?)』|「(.*?)」", doc, re.S):
            quoted.add(norm(re.sub(r"<[^>]+>", "", next((x for x in m.groups() if x), ""))))
        if lang != "en":
            text.append(norm(re.sub(r"<[^>]+>", " ", doc)))
    quoted.discard("")
    return quoted, " " + " ".join(text) + " "


def judge(groups: list[dict], quoted: set[str], text: str) -> dict[str, str]:
    """{group mbid: why it is canonical ("studio", "wikidata", "wikipedia", "wikipedia text") or ""}."""
    has_wd = {g["id"]: any(r.get("type") in ("wikidata", "wikipedia") for r in g.get("relations", [])) for g in groups}
    by_title: dict[str, list[dict]] = {}
    for g in groups:
        by_title.setdefault(norm(g.get("title", "")), []).append(g)
    out = {}
    for g in groups:
        n = norm(g.get("title", ""))
        if studio(g):
            out[g["id"]] = "studio"
        elif has_wd[g["id"]]:
            out[g["id"]] = "wikidata"
        elif n in quoted or (distinctive(n) and "/" not in g.get("title", "") and f" {n} " in text):
            same = by_title[n]
            first = sorted(same, key=lambda x: (x.get("primary-type") != "Album", bool(x.get("secondary-types")),
                                                x.get("first-release-date") or "9999"))[0]
            ok = len(same) == 1 or (not any(has_wd[x["id"]] for x in same) and first is g)
            out[g["id"]] = ("wikipedia" if n in quoted else "wikipedia text") if ok else ""
        else:
            out[g["id"]] = ""
    return out


class Canon:
    def __init__(self, root: Path):
        self.file = root / "canon.json"
        try:
            self.cache = json.loads(self.file.read_text())
        except (OSError, ValueError):
            self.cache = {}
        self.lock = threading.Lock()          # the hourly check and the API judge artists from two threads

    def save(self) -> None:
        tmp = self.file.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.cache))
        tmp.replace(self.file)

    def fresh(self, artist_mbid: str) -> bool:
        return time.time() - (self.cache.get(artist_mbid) or {}).get("t", 0) < TTL

    def refresh(self, artist_mbid: str) -> dict:
        """Fetch the artist's release groups and Wikipedia pages and judge every group (cached)."""
        with self.lock:
            return self._refresh(artist_mbid)

    def _refresh(self, artist_mbid: str) -> dict:
        artist = mb.artist(artist_mbid) or {}
        groups = _groups(artist_mbid)
        pages = _wiki_pages(artist)
        if pages:
            quoted, text = _wiki_titles(pages)
            verdicts = judge(groups, quoted, text)
        else:
            verdicts = {g["id"]: "no wikipedia" for g in groups}
        entry = {"t": time.time(), "name": artist.get("name", ""), "pages": [f"{l}:{t}" for l, t in pages],
                 "groups": verdicts}
        self.cache[artist_mbid] = entry
        self.save()
        return entry

    def verdict(self, artist_mbid: str, group_mbid: str) -> str | None:
        """Why this album is canonical, "" when it is not, None when not judged yet (or not listed)."""
        groups = (self.cache.get(artist_mbid) or {}).get("groups")
        if groups is None or group_mbid not in groups:
            return None
        return groups[group_mbid]
