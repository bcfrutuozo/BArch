"""A MusicBrainz release -> the tags of every track, in the library's style (style.py), and the
checks that decide whether the album may enter /music."""
from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

from . import mb, style
from .audio import Track
from .matcher import Candidate, audio_media

# the only tags a track keeps (the library's set, plus the two MusicBrainz ids Bruno approved)
KEEP = ["ARTIST", "ALBUM", "TITLE", "TRACKNUMBER", "TRACKTOTAL", "DISCNUMBER", "DISCTOTAL", "DATE", "GENRE",
        "MUSICBRAINZ_ALBUMID", "MUSICBRAINZ_TRACKID"]
REQUIRED = ["ARTIST", "ALBUM", "TITLE", "TRACKNUMBER", "TRACKTOTAL", "DISCNUMBER", "DISCTOTAL", "DATE", "GENRE"]


@dataclass
class Album:
    artist_folder: str                      # the album artist ("Various Artists" for compilations)
    album: str                              # ALBUM tag
    date: str
    genre: str
    mbid: str
    group_mbid: str
    tracks: list[tuple[Track, dict]] = field(default_factory=list)   # (file, tags)
    lengths: dict[str, float] = field(default_factory=dict)          # "D.TT" -> seconds on MusicBrainz
    notes: list[str] = field(default_factory=list)
    problems: list[str] = field(default_factory=list)

    folder_override: str = ""                   # the library's own folder for this album (find_existing)

    @property
    def folder(self) -> str:
        return self.folder_override or f"{style.folder_name(self.artist_folder)}/{style.folder_name(self.album)}"

    @folder.setter
    def folder(self, value: str) -> None:
        self.folder_override = value

    def files(self) -> list[tuple[Track, dict, str]]:
        return [(t, tags, style.file_name(tags["DISCNUMBER"], tags["TRACKNUMBER"], tags["TITLE"])) for t, tags in self.tracks]


def split_credit(ac: list[dict]) -> tuple[list[str], list[str]]:
    """artist credit -> (main artists, featured artists). "A feat. B & C" -> ([A], [B, C]);
    "A & B" -> ([A, B]) (the library writes several artists of one track as "A; B")."""
    main, feats, in_feat = [], [], False
    for c in ac or []:
        name = c.get("name") or (c.get("artist") or {}).get("name", "")
        (feats if in_feat else main).append(name)
        jp = (c.get("joinphrase") or "").lower()
        if re.search(r"\b(feat\.?|ft\.?|featuring|with)\b", jp):
            in_feat = True
    return main, feats


def _full_date(*dates: str) -> str:
    for d in dates:
        if d and re.fullmatch(r"\d{4}-\d{2}-\d{2}", d):
            return d
    return ""


def original_date(group: dict, gfull: dict | None, rel: dict, year_only_ok: bool = False) -> tuple[str, str]:
    """(YYYY-MM-DD of the first release, where it came from). A date without the day is not
    accepted: MusicBrainz (the release group, then the earliest dated edition of that year), then
    Wikidata's publication date for the album. Only when every source has just the year, and the
    review said so (year_only_ok), it becomes YYYY-01-01."""
    first = group.get("first-release-date") or (gfull or {}).get("first-release-date") or ""
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", first):
        return first, "MusicBrainz release group"
    if group.get("id"):
        full = sorted(r["date"] for r in mb.releases_of_group(group["id"])
                      if re.fullmatch(r"\d{4}-\d{2}-\d{2}", r.get("date") or "") and r["date"].startswith(first))
        if full and first:
            return full[0], "earliest dated edition on MusicBrainz"
    qid = mb.wikidata_id(gfull)
    if qid:
        for d in mb.wikidata_dates(qid):
            if not first or d.startswith(first[:4]):
                return d, f"Wikidata {qid}"
        # the release field of the album's infobox, on every Wikipedia that has it: only dates of
        # the year of the first release (a later US release is not the original), the one most
        # Wikipedias agree on, the earliest on a tie
        wp = [(d, site) for d, site in mb.wikipedia_dates(qid) if not first or d.startswith(first[:4])]
        if wp:
            votes = Counter(d for d, _ in wp)
            best = sorted(votes, key=lambda d: (-votes[d], d))[0]
            return best, "Wikipedia (" + ", ".join(sorted({s for d, s in wp if d == best})) + ")"
    if first and re.fullmatch(r"\d{4}-\d{2}-\d{2}", rel.get("date") or "") and rel["date"].startswith(first):
        return rel["date"], "this edition on MusicBrainz"
    year = (first or rel.get("date") or "")[:4]
    if year_only_ok and re.fullmatch(r"\d{4}", year):
        return f"{year}-01-01", "only the year exists anywhere: accepted in the review as YYYY-01-01"
    return "", (f"only {first!r} on MusicBrainz" if first else "no date on MusicBrainz") + (
        ", none to the day of that year on Wikidata or Wikipedia" if qid else ", no Wikidata/Wikipedia entry")


def library_genre(music: Path, artist_folder: str) -> str:
    """The genre the library already uses for this artist (the most common one), if any."""
    d = music / style.folder_name(artist_folder)
    if not d.is_dir():
        return ""
    from mutagen.flac import FLAC          # only in the container (the beets image ships it)
    votes = Counter()
    for album in sorted(d.iterdir())[:12]:
        for f in sorted(album.glob("*.flac"))[:2]:
            try:
                g = (FLAC(f).get("GENRE") or [""])[0]
            except Exception:  # noqa: BLE001
                g = ""
            if g:
                votes[g] += 1
    return votes.most_common(1)[0][0] if votes else ""


def _genre_name(g: str) -> str:
    """"heavy metal music" / "hard rock" -> "Heavy Metal" / "Hard Rock" (the library's spelling)."""
    g = re.sub(r"\s+music$", "", g.strip(), flags=re.I)
    return style.title_case(" ".join(w.capitalize() if w.islower() else w for w in g.split()))


def find_genre(rel: dict, group: dict | None, artist_mbid: str) -> tuple[str, str]:
    """(genre, source) when the library has none for the artist: MusicBrainz (release group,
    release, artist), then Wikidata (album, artist). ("", why) when nobody has one."""
    for src, label in ((group or {}, "MusicBrainz release group"), (rel, "MusicBrainz release")):
        gs = sorted(src.get("genres") or [], key=lambda g: -g.get("count", 0))
        if gs:
            return _genre_name(gs[0]["name"]), label
    art = mb.artist(artist_mbid) if artist_mbid else None
    gs = sorted((art or {}).get("genres") or [], key=lambda g: -g.get("count", 0))
    if gs:
        return _genre_name(gs[0]["name"]), "MusicBrainz artist"
    for ent, label in ((group, "album"), (art, "artist")):
        qid = mb.wikidata_id(ent)
        if qid:
            names = mb.wikidata_genres(qid)
            if names:
                return _genre_name(names[0]), f"Wikidata {label} {qid}"
    return "", "no genre on MusicBrainz or Wikidata"


def original_titles(group_mbid: str, rel: dict) -> set[str] | None:
    """The track titles of the first official edition of this album, normalized: a track of a
    later, longer edition whose title is not among them is a bonus. Titles, not recording ids:
    editions often carry their own recording entries. None when it cannot be told."""
    rels = [r for r in mb.releases_of_group(group_mbid) if r.get("status", "Official") == "Official" and r.get("date")]
    if not rels:
        return None
    rels.sort(key=lambda r: (r.get("date") or "9999", sum(m.get("track-count", 0) for m in r.get("media", []))))
    first = rels[0]
    mine = sum(m.get("track-count", 0) or len(m.get("tracks") or []) for m in rel.get("media", []))
    if first["id"] == rel["id"] or sum(m.get("track-count", 0) for m in first.get("media", [])) >= mine:
        return None
    full = mb.release(first["id"]) or {}
    titles = set()
    for m in audio_media(full):
        for t in m.get("tracks", []):
            base = style.split_title(t.get("title", ""))[0]
            titles.add(style.norm(base))
            # an early edition may join two tracks ("Ginger Snaps (Intro) / Monkey Business")
            titles.update(style.norm(x) for x in base.split(" / "))
    return titles


def build(cand: Candidate, tracks: list[Track], music: Path, overrides: dict | None = None) -> Album:
    """Tags for every track of the download from the accepted release. overrides (from the review)
    replace any album field ("album", "artist_folder", "date", "genre") or track field
    ("tracks": {"1.03": {"TITLE": ...}})."""
    ov = overrides or {}
    rel = cand.release or {}
    group = rel.get("release-group") or {}
    gfull = mb.release_group(group["id"]) if group.get("id") else None
    album_artists, _ = split_credit(rel.get("artist-credit"))
    various = any(n.lower() == "various artists" for n in album_artists)
    artist_folder = "Various Artists" if various else "; ".join(album_artists)
    if not various and len(album_artists) > 1:
        artist_folder = album_artists[0]            # the library files collaborations under the first artist
    live_album = "Live" in (group.get("secondary-types") or [])
    date, date_src = original_date(group, gfull, rel, bool(ov.get("date_year_only")))
    a = Album(artist_folder=ov.get("artist_folder") or artist_folder,
              album=ov.get("album") or style.make_album(rel.get("title", "")),
              date=ov.get("date") or date, genre="", mbid=rel["id"], group_mbid=group.get("id", ""))
    if not ov.get("date"):
        a.notes.append(f"date {a.date or '?'} ({date_src})")
    lib_genre = "" if ov.get("genre") else library_genre(music, a.artist_folder)
    if ov.get("genre"):
        a.genre, genre_src = ov["genre"], "the review"
    elif lib_genre:
        a.genre, genre_src = lib_genre, "the library (this artist)"
    else:
        first_artist = ((rel.get("artist-credit") or [{}])[0].get("artist") or {}).get("id", "")
        a.genre, genre_src = find_genre(rel, gfull, first_artist)
    a.notes.append(f"genre {a.genre or '?'} ({genre_src})")
    original = original_titles(group["id"], rel) if group.get("id") else None
    if original:
        extra = [t for m in (cand.media or audio_media(rel)) for t in m.get("tracks", [])
                 if style.norm(style.split_title(t.get("title", ""))[0]) not in original]
        total = sum(len(m.get("tracks", [])) for m in (cand.media or audio_media(rel)))
        if not extra or len(extra) > total / 2:
            a.notes.append(f"bonus check skipped ({len(extra)} of {total} tracks would be bonus)")
            original = None
        else:
            a.notes.append(f"{len(extra)} tracks not on the first edition are marked Bonus")
    media = cand.media or audio_media(rel)
    discs: dict[int, list[Track]] = {}
    for t in tracks:
        discs.setdefault(t.disc, []).append(t)
    for dn, (disc, m) in enumerate(zip(sorted(discs), media), 1):
        ts = sorted(discs[disc], key=lambda x: x.index)
        mts = [cand.reorder[(disc, t.index)] for t in ts] if cand.reorder else m.get("tracks", [])
        if cand.reorder and dn == 1:
            a.notes.append("the download's track order is kept (same songs as the MusicBrainz release, another order)")
        for pos, (t, mt) in enumerate(zip(ts, mts), 1):
            rec = mt.get("recording") or {}
            main, feats = split_credit(mt.get("artist-credit") or rec.get("artist-credit") or rel.get("artist-credit"))
            parts = []
            if original is not None and style.norm(style.split_title(mt.get("title", ""))[0]) not in original:
                parts.append("bonus")
            dis = (rec.get("disambiguation") or "").lower()
            if not live_album and re.match(r"^live\b", dis) and "live" not in mt.get("title", "").lower():
                parts.append("live")
            tags = {
                "ARTIST": "; ".join(main),
                "ALBUM": a.album,
                "TITLE": style.make_title(mt.get("title") or rec.get("title", ""), feats, parts),
                "TRACKNUMBER": f"{pos if cand.reorder else int(mt.get('position') or mt.get('number') or 0):02d}",
                "TRACKTOTAL": f"{len(m.get('tracks', [])):02d}",
                "DISCNUMBER": str(dn),
                "DISCTOTAL": str(len(media)),
                "DATE": a.date,
                "GENRE": a.genre,
                "MUSICBRAINZ_ALBUMID": rel["id"],
                "MUSICBRAINZ_TRACKID": rec.get("id", ""),
            }
            key = f"{dn}.{tags['TRACKNUMBER']}"
            tags.update((ov.get("tracks") or {}).get(key, {}))
            a.lengths[key] = (mt.get("length") or rec.get("length") or 0) / 1000
            a.tracks.append((t, tags))
    check(a)
    return a


def check(a: Album) -> None:
    """Everything the library requires; any problem sends the album to review."""
    a.problems = []
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", a.date or ""):
        a.problems.append("no full original release date (YYYY-MM-DD): " + (next((n for n in a.notes if n.startswith("date ")), "") or "unknown"))
    if not a.genre:
        a.problems.append("no genre: " + (next((n for n in a.notes if n.startswith("genre ")), "") or "none found"))
    names = Counter()
    for t, tags in a.tracks:
        for k in REQUIRED:
            if k in ("DATE", "GENRE") and not getattr(a, k.lower()):
                continue                            # already reported once for the album
            if not str(tags.get(k, "")).strip():
                a.problems.append(f"{tags.get('DISCNUMBER')}.{tags.get('TRACKNUMBER')}: {k} is empty")
        names[style.file_name(tags["DISCNUMBER"], tags["TRACKNUMBER"], tags["TITLE"]).lower()] += 1
    for n, c in names.items():
        if c > 1:
            a.problems.append(f"two tracks would be named {n!r}")
    if not a.tracks:
        a.problems.append("no tracks")
