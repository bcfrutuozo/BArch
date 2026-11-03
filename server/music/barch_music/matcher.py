"""Which MusicBrainz release is this download? Candidates come from what the download says
(folder name, CUE, old tags, a MusicBrainz id); each is scored on what cannot lie: the number of
tracks on every disc and the length of every track, then the titles and the names.

A match is accepted only when it is unambiguous; otherwise the album goes to review with the
candidates and the reason, never skipped in silence.
"""
from __future__ import annotations

import difflib
import re
from dataclasses import dataclass, field

from . import mb
from .audio import Track
from .style import norm

AUDIO_FORMATS = ("CD", "Digital Media", "Enhanced CD", "CD-R", "HDCD", "SHM-CD", "Blu-spec CD", "SACD",
                 "Hybrid SACD", "Vinyl", '12" Vinyl', '7" Vinyl', '10" Vinyl', "Cassette", "Copy Control CD",
                 "DualDisc", "HQCD", "Data CD", "Blu-ray", "DVD-Audio")


@dataclass
class Candidate:
    mbid: str
    title: str
    artist: str
    date: str
    country: str
    tracks: int
    score: float = 0.0
    why: list[str] = field(default_factory=list)
    ok: bool = False
    release: dict | None = None
    media: list[dict] = field(default_factory=list)     # the media used (DVD/video media dropped)
    reorder: dict | None = None                          # {(disc, index): MB track}: same songs, another order
    bad: list[str] = field(default_factory=list)         # "D.TT" of download tracks that do not fit (truncated?)

    def summary(self) -> dict:
        return {"mbid": self.mbid, "title": self.title, "artist": self.artist, "date": self.date,
                "country": self.country, "tracks": self.tracks, "score": round(self.score, 3),
                "ok": self.ok, "why": self.why, "url": f"https://musicbrainz.org/release/{self.mbid}",
                "reordered": bool(self.reorder), "bad_tracks": self.bad}


# ---------------------------------------------------------------- hints

# "Album CD 1", "Album (Disc 2)", "Album (CD1, VICP-70192)" (a catalogue number after the disc), "Album (1)"
_DISC_SUFFIX = re.compile(r"[\s,]*[\[(]?\s*(?:cd|disc|disk|vol\.?|volume)\s*\d{1,2}(?:\s*[,;:][^\])]*)?\s*[\])]?\s*$|\s*\(\d\)\s*$", re.I)


def hints_from(folder_name: str, tracks: list[Track]) -> dict:
    """artist, album, year guessed from the folder name and the CUE/old tags ("album" from the
    tags, "album_folder" from the folder name: both are searched)."""
    h = {"artist": "", "album": "", "year": "", "mbid": "", "album_folder": ""}
    for t in tracks:
        for k_src, k in (("artist", "artist"), ("albumartist", "artist"), ("album", "album")):
            if t.hints.get(k_src) and not h[k]:
                h[k] = t.hints[k_src]
        if t.hints.get("mb_albumid"):
            h["mbid"] = t.hints["mb_albumid"]
        if h["album"]:
            h["album"] = _DISC_SUFFIX.sub("", h["album"]).strip()      # "Pandora's Box CD 1", "The Wall (1)"
        if t.hints.get("date") and not h["year"]:
            m = re.search(r"\b(19|20)\d\d\b", t.hints["date"])
            h["year"] = m.group(0) if m else ""
    name = clean_folder_name(folder_name)
    y = re.search(r"\b(19[5-9]\d|20[0-4]\d)\b", folder_name)
    if y and not h["year"]:
        h["year"] = y.group(0)
    parts = [p.strip() for p in re.split(r"\s+[-–—]\s+|(?<=\w)[–—](?=\w)|(?<=\w)-(?=[A-Z])", name) if p.strip()]
    parts = [p for p in parts if not re.fullmatch(r"\(?(19|20)\d\d\)?", p)]
    if len(parts) >= 2:
        h["artist"] = h["artist"] or parts[0]
        h["album_folder"] = re.sub(r"\s*\((19|20)\d\d[^)]*\)\s*$", "", " ".join(parts[1:])).strip()
    elif parts:
        h["album_folder"] = re.sub(r"^(19|20)\d\d\s+", "", re.sub(r"\s*\((19|20)\d\d[^)]*\)", "", parts[0])).strip()
    h["album_folder"] = _DISC_SUFFIX.sub("", h["album_folder"]).strip()                              # ", disc 1" before the stray number
    h["album_folder"] = re.sub(r"\s*\((?:19|20)\d\d[^)]*\)|\s+\d{1,3}$", "", h["album_folder"]).strip()   # "(1979,2000)", a stray "88"
    h["album_folder"] = h["album_folder"].rstrip(" ,;:-")
    h["album"] = (h["album"] or h["album_folder"]).rstrip(" ,;:-")
    return h


_TAG_WORDS = r"flac|web|cd|cds|lossless|\d{2} ?-?bit|hi-?res|\d+(?:\.\d+)? ?khz|\d{2}-\d{2,3}|eac|rip|log|cue|remaster(?:ed)?|\d{4}"


def clean_folder_name(name: str) -> str:
    """"Deep Purple - The Best Of - [EAC]-[FLAC]" -> "Deep Purple - The Best Of": the release tags in
    brackets ((2003), [FLAC], (3 CD), [24Bit-48kHz], {US, CMC Int., 06076 86285-2}), the uploader
    tags ([rjk], [PMEDIA]), the bare words (FLAC, WEB, 24bit) and stray symbols go; what is in
    parentheses and is not a tag ("(20th Anniversary Remix)") stays, it may be part of the title."""
    n = re.sub(r"\{[^}]*\}", " ", name)                                  # {US, CMC Int., 06076 86285-2}
    n = re.sub(r"[\[(][^\])]*\b(?:" + _TAG_WORDS + r")\b[^\])]*[\])]", " ", n, flags=re.I)
    n = re.sub(r"[\[(][^\])\s]{1,14}[\])]", " ", n)                        # [EAC] [rjk] [TFM] [PMEDIA] (1)
    n = re.sub(r"\b(?:FLAC|WEB|CD|LOSSLESS|\d{2}-?bit|EAC|Hi-?Res)\b", " ", n, flags=re.I)
    n = re.sub(r"[^\w\s'’&,.!?:/()\[\]+–—-]", " ", n)                      # ⭐️ and the like
    n = re.sub(r"\s+(?=\S*\d)(?=\S*[a-z])\S+$", "", n)                      # a trailing uploader tag: vtwin88cube
    n = re.sub(r"\s+", " ", n).strip(" -–—_.")
    return n


# ---------------------------------------------------------------- scoring

def _sim(a: str, b: str) -> float:
    a, b = norm(a), norm(b)
    if not a or not b:
        return 0.0
    if a == b or a in b or b in a:
        return 1.0 if a == b else 0.9
    return difflib.SequenceMatcher(None, a, b).ratio()


def _credit(ac: list[dict]) -> str:
    return "".join(c.get("name", "") + c.get("joinphrase", "") for c in ac or [])


def audio_media(rel: dict) -> list[dict]:
    """The media that hold the album (a "CD + DVD" edition: only the CD)."""
    media = [m for m in rel.get("media", []) if (m.get("tracks") or m.get("track-count"))]
    keep = [m for m in media if (m.get("format") or "CD") not in ("DVD", "DVD-Video", "Blu-ray", "VHS", "UMD")]
    return keep or media


def score(cand: Candidate, tracks: list[Track], hints: dict) -> None:
    rel = cand.release or {}
    media = audio_media(rel)
    discs: dict[int, list[Track]] = {}
    for t in tracks:
        discs.setdefault(t.disc, []).append(t)
    ours = [len(v) for _, v in sorted(discs.items())]
    theirs = [len(m.get("tracks") or []) for m in media]
    # a download of only some discs of a box: match the discs we have, by track count
    if len(ours) < len(theirs) and ours == theirs[:len(ours)]:
        media = media[:len(ours)]
        theirs = theirs[:len(ours)]
        cand.why.append(f"only the first {len(ours)} of {len(audio_media(rel))} discs downloaded")
    cand.media = media
    if ours != theirs:
        cand.score = 0.0
        cand.why.append(f"track count per disc {ours} vs MusicBrainz {theirs}")
        return
    diffs, title_sims, keyed = [], [], []
    for n, ((dn, ts), m) in enumerate(zip(sorted(discs.items()), media), 1):
        for t, mt in zip(sorted(ts, key=lambda x: x.index), m["tracks"]):
            length = (mt.get("length") or (mt.get("recording") or {}).get("length") or 0) / 1000
            if length:
                diffs.append(abs(length - t.seconds))
                keyed.append((f"{n}.{t.index:02d}", abs(length - t.seconds)))
            if t.hints.get("title"):
                title_sims.append(_sim(t.hints["title"], mt.get("title", "")))
    # a damaged track in the download (cut short, another take) must not hide the album: up to 5%
    # of the tracks (at least one) may be off when the rest fits; they are named, never used blindly
    off = sorted((k for k, d in keyed if d > 7), key=lambda k: -dict(keyed)[k])
    if off and len(off) <= max(1, len(keyed) // 20) and len(keyed) > len(off):
        rest = [d for k, d in keyed if k not in off]
        if max(rest) <= 7 and sum(rest) / len(rest) <= 3:
            cand.bad = off
            diffs = rest
    worst = max(diffs) if diffs else 99
    mean = sum(diffs) / len(diffs) if diffs else 99
    known = (len(diffs) + len(cand.bad)) / max(1, sum(ours))
    album_sim = _sim(hints.get("album", ""), cand.title) if hints.get("album") else 0.5
    artist_sim = _sim(hints.get("artist", ""), cand.artist) if hints.get("artist") else 0.5
    tsim = sum(title_sims) / len(title_sims) if title_sims else None
    s = 0.0
    s += 0.45 * (1.0 if worst <= 3 else 0.8 if worst <= 7 else 0.4 if worst <= 15 else 0.0) * known
    s += 0.15 * (1.0 if mean <= 1.5 else 0.7 if mean <= 4 else 0.2)
    s += 0.15 * album_sim + 0.10 * artist_sim
    s += 0.15 * (tsim if tsim is not None else max(album_sim, 0.6))
    if hints.get("year") and cand.date[:4] == hints["year"]:
        s += 0.03
    s -= 0.005 * min(mean, 4)                       # tie-break: the edition whose lengths fit best
    cand.score = s
    cand.why.append(f"lengths: worst {worst:.1f}s, mean {mean:.1f}s over {len(diffs)} tracks"
                    + (f" (left out: {', '.join(cand.bad)}, which do not fit)" if cand.bad else ""))
    cand.why.append(f"album {album_sim:.2f}, artist {artist_sim:.2f}" + (f", titles {tsim:.2f}" if tsim is not None else ""))
    cand.ok = worst <= 7 and mean <= 3 and known >= 0.9 and (album_sim >= 0.6 or (tsim or 0) >= 0.75) and artist_sim >= 0.5
    if not cand.ok and album_sim >= 0.6 and artist_sim >= 0.5:
        cand.reorder = _by_title(discs, media)
        if cand.reorder:
            cand.why.append("the same songs in another order (an edition MusicBrainz does not have, e.g. an LP)")


def _by_title(discs: dict[int, list[Track]], media: list[dict]) -> dict | None:
    """Every track matched to a different track of the same disc by its title (>= 0.85) and its
    length (within 7 s): {(disc number, index): MB track}. None unless all of them match."""
    out = {}
    for (dn, ts), m in zip(sorted(discs.items()), media):
        free = list(m.get("tracks", []))
        for t in sorted(ts, key=lambda x: x.index):
            if not t.hints.get("title"):
                return None
            best = max(free, key=lambda mt: _sim(t.hints["title"], mt.get("title", "")), default=None)
            if best is None or _sim(t.hints["title"], best.get("title", "")) < 0.85:
                return None
            length = (best.get("length") or (best.get("recording") or {}).get("length") or 0) / 1000
            if length and abs(length - t.seconds) > 7:
                return None
            out[(dn, t.index)] = best
            free.remove(best)
    return out


def _candidate(rel: dict) -> Candidate:
    return Candidate(mbid=rel["id"], title=rel.get("title", ""), artist=_credit(rel.get("artist-credit")),
                     date=rel.get("date", ""), country=rel.get("country", ""),
                     tracks=sum(len(m.get("tracks") or []) or m.get("track-count", 0) for m in rel.get("media", [])),
                     release=rel)


def find(tracks: list[Track], hints: dict, force: str = "", acoustid_key: str = "", fingerprints=None,
         keep_order: bool = False) -> tuple[Candidate | None, list[Candidate], str]:
    """(the accepted release or None, every candidate scored, the reason when None)."""
    ids: list[str] = []
    if force:
        ids = [force]
    elif hints.get("mbid"):
        ids = [hints["mbid"]]
    else:
        total = len(tracks)
        seen = set()
        queries = [(hints.get("artist", ""), hints.get("album", ""), total),
                   (hints.get("artist", ""), hints.get("album", ""), 0)]
        if hints.get("album_folder") and norm(hints["album_folder"]) != norm(hints.get("album", "")):
            queries += [(hints.get("artist", ""), hints["album_folder"], total), (hints.get("artist", ""), hints["album_folder"], 0)]
        queries.append(("", hints.get("album", ""), total))
        for artist, album, n in queries:
            if not album:
                continue
            for r in mb.search_releases(artist, album, n):
                if r["id"] not in seen and r.get("score", 0) >= 50:
                    seen.add(r["id"])
                    ids.append(r["id"])
            if len(ids) >= 8:
                break
        if acoustid_key and fingerprints and len(ids) < 3:
            ids += [i for i in _acoustid_releases(acoustid_key, fingerprints) if i not in seen]
    cands = []

    def add(mbid: str, why: str = "") -> None:
        rel = mb.release(mbid)
        if not rel:
            return
        c = _candidate(rel)
        score(c, tracks, hints if not force else {**hints, "album": "", "artist": ""})
        if why:
            c.why.insert(0, why)
        cands.append(c)

    for mbid in ids[:10]:
        add(mbid)
    cands.sort(key=lambda c: -c.score)
    if not force and not keep_order and not (cands and cands[0].ok):
        # the folder lies about the album ("The Best Of" holding Stormbringer whole): the songs do not.
        # Releases of the groups that hold these titles, with this many tracks, scored like the rest
        seen = {c.mbid for c in cands}
        for mbid in _by_titles(hints.get("artist", ""), tracks, seen):
            add(mbid, f"found by the track titles, not by the name the download gives the album ({hints.get('album') or '?'})")
        cands.sort(key=lambda c: -c.score)
    if not cands:
        return None, [], "MusicBrainz has no release for " + (f"{hints.get('artist')} - {hints.get('album')}" if hints.get("album") else "this download")
    best = cands[0]
    if keep_order:
        same = next((c for c in cands if c.reorder), None)
        if same:
            return same, cands, ""
    if force:
        if best.score == 0.0:
            return None, cands, "the chosen release does not fit: " + "; ".join(best.why)
        if not best.ok and best.reorder:
            return None, cands, f"{best.artist} - {best.title}: the same songs in another order; approve the download's order with --keep-order"
        return best, cands, ""
    if not best.ok:
        same = next((c for c in cands if c.reorder), None)
        if same:
            return None, cands, (f"{same.artist} - {same.title} ({same.date}): the same {sum(len(m.get('tracks', [])) for m in same.media)} "
                                 "songs in another order, an edition MusicBrainz does not have (an LP?); keep the download's order with --keep-order")
        return None, cands, "no release fits well enough: " + "; ".join(best.why)
    rivals = [c for c in cands[1:] if c.ok and c.score >= best.score - 0.02]
    if rivals:
        same = all(_same_tracklist(best, r) for r in rivals)
        if not same:
            return None, cands, f"{len(rivals) + 1} releases fit equally well with different track titles"
        best.why.append(f"{len(rivals)} other editions with the same tracks also fit")
    return best, cands, ""


def _by_titles(artist: str, tracks: list[Track], seen: set[str]) -> list[str]:
    """Release ids to try when the album's name finds nothing that fits: four titles spread over the
    download (old tags or CUE) searched as recordings, the release groups they share, and the
    releases of those groups with the download's track count. A famous song is on fifty
    compilations; four songs together are on the album (and the big box sets, which the track
    count drops)."""
    titles = [t.hints.get("title", "").strip() for t in sorted(tracks, key=lambda x: (x.disc, x.index))]
    titles = [x for x in titles if x]
    if len(titles) < 3:
        return []
    picks = [titles[0], titles[len(titles) // 3], titles[2 * len(titles) // 3], titles[-1]]
    picks = list(dict.fromkeys(picks))
    votes: dict[str, int] = {}
    plain: dict[str, bool] = {}          # a studio album, not a compilation / box / live: tried first
    try:
        for title in picks:
            groups = set()
            for rec in mb.search_recordings(artist, title):
                if (rec.get("score") or 0) < 70:
                    continue
                for rel in rec.get("releases", []):
                    g = rel.get("release-group") or {}
                    if g.get("id"):
                        groups.add(g["id"])
                        plain[g["id"]] = g.get("primary-type") == "Album" and not g.get("secondary-types")
            for g in groups:
                votes[g] = votes.get(g, 0) + 1
        # four songs together: the album, the box sets and the big compilations tie; the album goes first
        top = [g for g, n in sorted(votes.items(), key=lambda kv: (-kv[1], 0 if plain.get(kv[0]) else 1))
               if n >= max(2, len(picks) - 1)][:12]
        out: list[str] = []
        total = len(tracks)
        for g in top:
            for rel in mb.releases_of_group(g):
                if rel["id"] in seen or sum(m.get("track-count", 0) for m in rel.get("media", [])) != total:
                    continue
                out.append(rel["id"])
                seen.add(rel["id"])
                if len(out) >= 6:
                    return out
    except mb.NetError:
        pass
    return out


def _same_tracklist(a: Candidate, b: Candidate) -> bool:
    """The same songs: the titles without their qualifiers, 90% identical and the rest spelling
    variants ("Sleepless Night" / "Sleepless Nights", "(live)" / "("Texxas Jam" live)"), never
    another song."""
    from .style import split_title     # qualifiers aside: "Movin' Out (alternate version)" = "Movin' Out"
    ta = [norm(split_title(t.get("title", ""))[0]) for m in a.media for t in m.get("tracks", [])]
    tb = [norm(split_title(t.get("title", ""))[0]) for m in b.media for t in m.get("tracks", [])]
    if len(ta) != len(tb):
        return False
    diff = [(x, y) for x, y in zip(ta, tb) if x != y]
    return len(diff) <= max(1, len(ta) // 10) and all(difflib.SequenceMatcher(None, x, y).ratio() >= 0.8 for x, y in diff)


def _acoustid_releases(key: str, fingerprints: list[tuple[str, int]]) -> list[str]:
    """releases that hold most of the fingerprinted recordings."""
    votes: dict[str, int] = {}
    for fp, dur in fingerprints[:4]:
        for rec in mb.acoustid_lookup(key, fp, dur)[:3]:
            for r in mb.recording_releases(rec):
                votes[r["id"]] = votes.get(r["id"], 0) + 1
    return [k for k, _ in sorted(votes.items(), key=lambda kv: -kv[1])][:6]
