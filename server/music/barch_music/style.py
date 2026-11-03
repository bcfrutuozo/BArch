"""The library's naming rules, as measured over all 23,314 tracks of /music on 2026-11-02.

Nothing here talks to the network or the disk (except loading title_rules.json): every rule is a
pure function, so tests/test_style.py can check it against the real library.

    TITLE tag   = base title (official parentheses kept) + one trailing [ ] with Bruno's qualifiers,
                  parts joined by " - " in RANK order; several featured artists joined by "; "
    file name   = "D.TT - " + TITLE with / -> ,  ? -> !  : -> -  " -> '  * -> -
    album dir   = ALBUM with : ? / -> _  " -> -  and no trailing dot
"""
from __future__ import annotations

import json
import re
import unicodedata
from pathlib import Path

_RULES_FILE = Path(__file__).with_name("title_rules.json")
_RULES: list[tuple[str, str]] = list(json.loads(_RULES_FILE.read_text())["rules"].items())

# words kept lower case inside a title (measured: "is" 248 lower vs 3, "the" 3024 vs 5, ...)
SMALL = {"a", "an", "and", "as", "at", "but", "by", "for", "from", "in", "into", "is", "of", "on",
         "or", "over", "the", "to", "with", "vs.", "nor", "off", "onto", "out"}
# "out" is half and half in the library (33/33): it stays lower only as a preposition; the
# dictionary capitalizes it in phrasal verbs ("Act Out", "Zone Out"), which run after this


# ---------------------------------------------------------------- file system

def file_title(title: str) -> str:
    """TITLE tag -> the title part of the file name ("1.01 - <this>.flac")."""
    t = title.replace("/", ",").replace("?", "!").replace(":", "-").replace('"', "'").replace("*", "-")
    t = re.sub(r"[<>|\\]", "-", t)                  # never seen in the library; Windows/SMB refuse them
    return re.sub(r"\s+", " ", t).strip()           # a final dot stays ("F.I.N.E..flac"): ".flac" follows


def file_name(disc: int, track: int, title: str) -> str:
    return f"{int(disc)}.{int(track):02d} - {file_title(title)}.flac"


def folder_name(name: str) -> str:
    """ALBUM (or artist) -> folder name."""
    t = name.replace(":", "_").replace("?", "_").replace("/", "_").replace('"', "-").replace("*", "-")
    t = re.sub(r"[<>|\\]", "_", t)
    t = re.sub(r"\s+", " ", t).strip()
    return t.rstrip(". ") or "_"


# ---------------------------------------------------------------- title case

def _rule_rx(key: str) -> re.Pattern:
    """A dictionary key matches whole words, in any case: "key on" must not hit "Monkey On"."""
    rx = re.escape(key)
    if key[:1].isalnum():
        rx = r"(?<![\w'’])" + rx
    if key[-1:].isalnum():
        rx = rx + r"(?![\w'’])"
    return re.compile(rx, re.I)


_COMPILED = [(_rule_rx(a), b) for a, b in _RULES]

# where a part of a title starts and ends: the first and the last word of each part keep their
# capital ("'Freedom' / The Execution", "[Bonus - The Mamas...]", "Dream On [Live]")
_PART_START = r"(?:^|(?<=: )|(?<= / )|(?<= - )|(?<=\()|(?<=\[)|(?<=; )|(?<=\d\. )|(?<=\b[IVX]\. )|(?<=\b[IVX]{2}\. )|(?<=\b[IVX]{3}\. ))"
_PART_END = r"(?=$|\s*\(|\s*\[|\s*\)|\s*\]| / |: | - |; )"


def _part_edges(t: str) -> str:
    def up(m):
        w = m.group(0)
        return w[:1].upper() + w[1:] if w.lower() in SMALL else w
    t = re.sub(_PART_START + r"[a-z][\w.]*", up, t)
    t = re.sub(r"(?<![\w'’])[a-z][\w.]*" + _PART_END, up, t)
    return t


def title_case(title: str) -> str:
    """MusicBrainz title -> the library's casing: Bruno's dictionary, whole words, any case (small
    words lower, phrasal verbs capitalized, Mc*, Roman numerals, "feat."), then the first and the
    last word of every part capitalized. Words the dictionary does not know keep the spelling
    they came with, so stylized names (TV, JIRENMA, WeMoveForward) survive."""
    t = title
    for rx, b in _COMPILED:
        t = rx.sub(lambda m, b=b: b, t)
    t = _part_edges(t)
    t = t.replace("[Feat. ", "[feat. ")
    return t[:1].upper() + t[1:] if t[:1].islower() else t


# ---------------------------------------------------------------- the [ ] suffix

# order of the parts inside the one trailing [ ], measured: feat. - Bonus - Live (18),
# feat. - Edit (12), Bonus - X Cover (12), Acoustic - Live (8), Unreleased - Live (5), Live - Alternate
RANK = [
    ("feat", r"^(feat|part)\. "),
    ("bonus", r"^bonus\b"),
    ("unreleased", r"^unreleased\b"),
    ("kind", r"\b(acoustic|unplugged|instrumental|orchestral|orchestrated|demo|edit|remix|mix|version|single|"
             r"reprise|cover|karaoke|a cappella|piano|extended|re-recorded|remaster(ed)?|mono|stereo)\b"),
    ("live", r"^live\b"),
    ("variant", r"^(alternate|alternative|hidden|outtake|rehearsal|take \d+)\b"),
]


def rank(part: str) -> int:
    p = part.lower()
    for i, (_, rx) in enumerate(RANK):
        if re.search(rx, p):
            return i
    return len(RANK) - 1          # unknown qualifiers ("BBC Session '86") go with the variants


_QUAL_WORDS = {"live", "remix", "mix", "edit", "version", "acoustic", "demo", "instrumental", "bonus", "single",
               "reprise", "extended", "original", "alternate", "alternative", "take", "orchestral", "karaoke",
               "remastered", "remaster", "unplugged", "outtake", "rehearsal", "session", "radio", "cover",
               "unreleased", "hidden", "track", "medley", "intro", "outro", "piano", "studio"}


def qualifier_case(part: str) -> str:
    """"radio edit" -> "Radio Edit", "The South Beach mix" -> "The South Beach Mix". MusicBrainz
    writes qualifiers lower case; names and foreign words inside them are left as written
    ("From Opera 'La mia verita'"). "feat." and the Portuguese "part." stay lower."""
    head = part.split(" ", 1)
    if head[0].lower() in ("feat.", "ft.", "featuring", "part.") and len(head) > 1:
        return ("part. " if head[0].lower() == "part." else "feat. ") + head[1]
    if part.islower():                              # "(radio edit)", "(live at the forum)"
        return title_case(" ".join(w[:1].upper() + w[1:] for w in part.split(" ")))
    words = part.split(" ")
    words = [w[:1].upper() + w[1:] if (i == 0 or w.lower() in _QUAL_WORDS) and w[:1].islower() else w
             for i, w in enumerate(words)]
    return " ".join(words)


def build_suffix(feats: list[str], parts: list[str]) -> str:
    items = []
    if feats:
        items.append("feat. " + "; ".join(feats))
    seen = set()
    for p in parts:
        p = qualifier_case(p.strip())
        if p and p.lower() not in seen:
            seen.add(p.lower())
            items.append(p)
    items.sort(key=rank)                            # stable: equal ranks keep their order
    return f"[{' - '.join(items)}]" if items else ""


# what MusicBrainz writes in parentheses that is a qualifier, not part of the title
_QUAL_START = (r"live|demo|instrumental|acoustic|unplugged|bonus(?: track)?|single(?: version)?|orchestral|karaoke|"
               r"a cappella|remaster(?:ed)?|outtake|alternate|alternative|rehearsal|take \d+|reprise|radio edit|"
               r"edit|remix|mix|extended|original|early|monitor|rough|instrumental version|piano version|bbc")
_QUAL_END = r"mix|remix|edit|version|demo|take \d+|remaster(?:ed)?(?: \d{4})?|reprise|session|dub"
# what MusicBrainz writes in parentheses that is a qualifier, not part of the title: it starts with
# a qualifier word ("(live at Rock in Rio)") or ends with one ("(The South Beach mix)");
# "Live to Rock (Rock to Live)" and "(Is Hard on the Knees)" are titles
_QUAL_PAREN = re.compile(r"\s*\((?P<q>(?:(?:" + _QUAL_START + r")\b[^()]*|[^()]*\b(?:" + _QUAL_END + r")))\)\s*$", re.I)
_FEAT_PAREN = re.compile(r"\s*[(\[](?:feat\.|ft\.|featuring) (?P<who>[^)\]]+)[)\]]\s*$", re.I)


def split_title(mb_title: str) -> tuple[str, list[str], list[str]]:
    """"Memories (remix) (feat. X & Y)" -> ("Memories", ["X", "Y"], ["remix"]).
    Official parentheses ("Falling in Love (Is Hard on the Knees)") stay in the base."""
    base, feats, parts = mb_title.strip(), [], []
    while True:
        m = _FEAT_PAREN.search(base)
        if m:
            feats = split_names(m.group("who")) + feats
            base = base[:m.start()].rstrip()
            continue
        m = _QUAL_PAREN.search(base)
        if m:
            parts.insert(0, m.group("q"))
            base = base[:m.start()].rstrip()
            continue
        m = re.search(r"\s*\[(?P<q>[^\[\]]+)\]\s*$", base)     # someone already wrote [Live] etc.
        if m:
            inner = m.group("q")
            for p in inner.split(" - "):
                if p.lower().startswith(("feat. ", "ft. ")):
                    feats += split_names(p.split(" ", 1)[1])
                else:
                    parts.append(p)
            base = base[:m.start()].rstrip()
            continue
        break
    return base, feats, parts


def split_names(s: str) -> list[str]:
    """"A, B & C" / "A and B" / "A; B" -> ["A", "B", "C"] (the library joins them with "; ")."""
    return [x.strip() for x in re.split(r";\s*|,\s*|\s+&\s+|\s+and\s+|\s+x\s+", s) if x.strip()]


def plain_quotes(s: str) -> str:
    """MusicBrainz writes typographic quotes (Pandora’s Box, “Texxas Jam”); the library uses the
    plain ones (1807 file names with ' against 70 with ’): same folder, same file names."""
    return s.replace("’", "'").replace("‘", "'").replace("“", '"').replace("”", '"').replace("‐", "-")


def make_title(mb_title: str, feats: list[str] | None = None, parts: list[str] | None = None) -> str:
    """The TITLE tag for a track: MusicBrainz title + credited guests + qualifiers (bonus, live...)."""
    base, f, p = split_title(plain_quotes(mb_title))
    allf = []
    for n in f + list(feats or []):
        if n.lower() not in (x.lower() for x in allf):
            allf.append(n)
    base = title_case(base)
    suffix = build_suffix(allf, p + list(parts or []))
    return f"{base} {suffix}".strip() if suffix else base


def make_album(mb_title: str) -> str:
    return title_case(plain_quotes(mb_title.strip()))


def norm(s: str) -> str:
    """For comparisons: no accents, lower case, only letters and digits."""
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()
