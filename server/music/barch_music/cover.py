"""The album cover: at least 500x500, 1000x1000 whenever a source has it, and the clean artwork
before a scan of the sleeve.

Every source is gathered, then ranked: the Cover Art Archive (the release, then its release
group), the images that came with the download (Front/Cover/Folder), the album's own cover.jpg
when it is already in the library, and the digital artwork of iTunes and Deezer. A photo or
scan of an old LP usually carries a frame: the scanner bed or the cardboard edge, a light band
that ends with a jump in brightness. A store's artwork is the master the label sent, without
one, but a store search can answer with another album: it counts only when artist and album
match and, if any other source has an image, when it looks like it (the same picture on a 24x24
grey thumbnail, correlation 0.75 or more: the same art measures 0.83-0.99, different albums at
most 0.60). Ranking: confirmed, without a frame, store artwork first, 1000 px or more, larger.
A framed image that still wins (nothing cleaner exists) gets its frame trimmed. The result is
a JPEG of 1000x1000 (or the source size if smaller), embedded in every track and cover.jpg.
"""
from __future__ import annotations

import json
import math
import re
import statistics
import subprocess
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

from . import mb
from .style import norm

MIN, TARGET = 500, 1000
N = 200                      # the analysis thumbnail, N x N
SAME_ART = 0.75              # fingerprint correlation from which two images are the same artwork
RANK = {"chosen": 0, "store": 1, "caa": 2, "library": 2, "download": 3, "other": 4}

# the images a download ships, by their names: the front is wanted; the back, the booklet, the
# disc and the inlay never are, whatever their size (a 2140 px "Contraportada.jpg" once beat
# the 2129 px "Portada.jpg" next to it on size alone)
_NOT_FRONT = re.compile(r"back|rear|contraportada|contracapa|trasera|verso|inlay|inside|interior|exterior|"
                        r"booklet|libreto|folleto|livret|tray|obi|matrix|label|sticker|\bcd\s*\d*\b|\bdis[ck]\s*\d*\b", re.I)
_FRONT = re.compile(r"front|cover|folder|portada|frente|\bcapa\b|album", re.I)


def image_role(name: str) -> str:
    """"Front.jpg", "Portada.jpg", "folder.jpg" -> "front"; "Back.jpg", "Booklet 2.jpg", "CD.png"
    -> "none" (never used as the cover); anything else ("Jolly Roger.png") -> "other", a candidate
    after the ones named as the front."""
    stem = Path(name).stem
    if _NOT_FRONT.search(stem):
        return "none"
    if _FRONT.search(stem):
        return "front"
    return "other"


@dataclass
class Cover:
    data: bytes                    # the final JPEG
    width: int
    height: int
    source: str                    # where it came from, for the report
    framed: bool = False           # the chosen image still had a scan frame (trimmed)
    better: str = ""               # the library's cover was kept, but this cleaner one exists


@dataclass
class Cand:
    label: str
    kind: str                      # chosen | store | caa | library | download
    path: Path
    w: int
    h: int
    borders: list = field(default_factory=lambda: [0, 0, 0, 0])   # lines of frame (top, bottom, left, right) of N
    fp: list = field(default_factory=list)
    trusted: bool = True
    same: float | None = None      # best similarity to a non-store image (stores only)

    @property
    def framed(self) -> bool:
        return sum(1 for b in self.borders if b) >= 2

    def describe(self) -> str:
        bits = [f"{self.w}x{self.h}", "scan frame" if self.framed else "clean"]
        if self.same is not None:
            bits.append(f"same art {self.same:.2f}" if self.same >= SAME_ART else f"other art {self.same:.2f}")
        if not self.trusted:
            bits.append("not used")
        return ", ".join(bits)


def _size(path: Path) -> tuple[int, int]:
    r = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
                        "-of", "json", str(path)], capture_output=True, text=True, timeout=60)
    try:
        s = json.loads(r.stdout)["streams"][0]
        return int(s["width"]), int(s["height"])
    except (KeyError, IndexError, ValueError, json.JSONDecodeError):
        return 0, 0


def _square(w: int, h: int) -> bool:
    return w and h and 0.9 <= w / h <= 1.1


# ---------------------------------------------------------------- looking at the picture

def _pixels(path: Path) -> list[list[bytes]] | None:
    r = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", str(path), "-vf", f"scale={N}:{N}:flags=area",
                        "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True, timeout=60)
    raw = r.stdout
    if r.returncode or len(raw) < N * N * 3:
        return None
    return [[raw[(y * N + x) * 3:(y * N + x) * 3 + 3] for x in range(N)] for y in range(N)]


def _line(img, side: int, k: int):
    if side == 0:
        return img[k]
    if side == 1:
        return img[N - 1 - k]
    if side == 2:
        return [r[k] for r in img]
    return [r[N - 1 - k] for r in img]


def _stats(line) -> tuple[float, float]:
    mean = sum(sum(p) for p in line) / len(line) / 3
    sd = sum(statistics.pstdev([p[c] for p in line]) for c in range(3)) / 3
    return mean, sd


def borders(img) -> list[int]:
    """Lines of frame per side (top, bottom, left, right) on the N x N thumbnail: the outer band of
    flat lines (no texture yet) that ends with a jump in brightness, within the outer 8 %."""
    out = []
    for side in range(4):
        st = [_stats(_line(img, side, k)) for k in range(N * 8 // 100 + 1)]
        w = 0
        for k in range(1, len(st)):
            if st[k - 1][1] > 18:          # a textured line: the artwork has begun
                break
            if abs(st[k][0] - st[k - 1][0]) > 25:
                w = k
        out.append(w)
    return out


def fingerprint(img, b: list[int], n: int = 24) -> list[float]:
    """The picture inside its frame as n x n grey levels, normalized (mean 0, deviation 1)."""
    t, bo, l, r = b
    h, w = N - t - bo, N - l - r
    g = []
    for j in range(n):
        for i in range(n):
            ys = range(t + j * h // n, t + (j + 1) * h // n)
            xs = range(l + i * w // n, l + (i + 1) * w // n)
            g.append(sum(sum(img[y][x]) for y in ys for x in xs) / (3 * len(ys) * len(xs)))
    m = sum(g) / len(g)
    sd = math.sqrt(sum((v - m) ** 2 for v in g) / len(g)) or 1.0
    return [(v - m) / sd for v in g]


def similarity(a: list[float], b: list[float]) -> float:
    return sum(x * y for x, y in zip(a, b)) / len(a) if a and b else 0.0


def look(path: Path) -> tuple[list[int], list[float]]:
    img = _pixels(path)
    if img is None:
        return [0, 0, 0, 0], []
    b = borders(img)
    return b, fingerprint(img, b)


# ---------------------------------------------------------------- the stores

def _base(s: str) -> str:
    """An album title without what stores add: (Remastered), [Deluxe Edition], - Single."""
    s = re.sub(r"\s*[\(\[][^\)\]]*[\)\]]", "", s)
    s = re.sub(r"\s+-\s+(single|ep|remaster.*|deluxe.*)$", "", s, flags=re.I)
    return norm(s)


def names_match(artist: str, album: str, got_artist: str, got_album: str) -> bool:
    def the(x: str) -> str:
        return re.sub(r"^the ", "", norm(x))
    a, b = the(artist), the(got_artist)
    if not a or not b or not (a == b or b.startswith(a + " ") or a.startswith(b + " ")):
        return False
    x, y = _base(album), _base(got_album)
    return bool(x) and (x == y or y.startswith(x + " ") or x.startswith(y + " "))


# ---------------------------------------------------------------- the choice

def _to_jpeg(c: Cand, trim: bool = True) -> tuple[bytes, int, int]:
    """Trim a scan frame (with a little margin), square it, scale to TARGET. trim=False for an
    image somebody chose as it is (a frame that belongs to the sleeve, an edit by Claude)."""
    w, h = c.w, c.h
    fx, fy = w / N, h / N
    crop = ""
    if trim and c.framed and c.kind != "library":           # the library's own cover is never altered
        t, b, l, r = (math.ceil((v + 1) * f) if v else 0 for v, f in zip(c.borders, (fy, fy, fx, fx)))
        cw, ch = w - l - r, h - t - b
        side = min(cw, ch)
        x, y = l + (cw - side) // 2, t + (ch - side) // 2
        crop, w, h = f"crop={side}:{side}:{x}:{y},", side, side
    side = min(TARGET, w, h) if _square(w, h) else 0
    out = c.path.with_suffix(".out.jpg")
    vf = crop + (f"scale={side}:{side}:flags=lanczos" if side else f"scale='min({TARGET},iw)':-2:flags=lanczos")
    subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", str(c.path), "-vf", vf, "-frames:v", "1",
                    "-q:v", "2", "-pix_fmt", "yuvj420p", str(out)], check=True, timeout=120)
    data = out.read_bytes()
    nw, nh = _size(out)
    out.unlink(missing_ok=True)
    return data, nw, nh


def rank_key(c: Cand):
    side = min(c.w, c.h)
    return (c.trusted, not c.framed, -RANK.get(c.kind, 9), side >= TARGET, side)


def choose(cands: list[Cand], keep_library: bool = False) -> Cand | None:
    """The chosen image, after the stores were checked against the other sources. keep_library:
    an album already in the library keeps its own cover.jpg (only an explicit choice replaces it)."""
    refs = [c for c in cands if c.kind != "store" and c.fp]
    for c in cands:
        if c.kind == "store" and refs:
            c.same = max(similarity(c.fp, r.fp) for r in refs)
            c.trusted = c.same >= SAME_ART
    chosen = [c for c in cands if c.kind == "chosen"]
    if chosen:
        return chosen[0]
    lib = [c for c in cands if c.kind == "library"]
    if keep_library and lib:
        return lib[0]
    usable = [c for c in cands if c.trusted]
    return max(usable, key=rank_key) if usable else None


def gather(release_mbid: str, group_mbid: str, artist: str, album: str, local: list[Path], explicit: str,
           tmp: Path, tried: list[str], library: Path | None = None) -> list[Cand]:
    cands: list[Cand] = []

    def add(get, label: str, kind: str):
        try:
            data = get()
        except mb.NetError as e:
            tried.append(f"{label}: {e}")
            return
        if not data or len(data) < 2000:
            tried.append(f"{label}: missing")
            return
        p = tmp / f"c{len(cands)}-{len(tried)}"
        p.write_bytes(data)
        w, h = _size(p)
        if not _square(w, h) or min(w, h) < MIN:
            tried.append(f"{label}: {w}x{h}, too small or not square")
            return
        b, fp = look(p)
        c = Cand(label, kind, p, w, h, b, fp)
        cands.append(c)

    if explicit:
        src = Path(explicit)
        add(lambda: src.read_bytes() if src.exists() else mb.download(explicit), f"chosen: {explicit}", "chosen")
    if library is not None and library.exists():
        add(library.read_bytes, "the library's cover.jpg", "library")
    for kind, mbid in (("release", release_mbid), ("release-group", group_mbid)):
        if not mbid:
            continue
        try:
            imgs = mb.caa_images(kind, mbid)[:2]
        except mb.NetError as e:
            tried.append(f"Cover Art Archive ({kind}): {e}")
            continue
        for img in imgs:
            if img.get("url"):
                add(lambda u=img["url"]: mb.download(u), f"Cover Art Archive ({kind})", "caa")
    for p in local[:6]:
        add(lambda p=p: p.read_bytes(), f"download: {p.name}", "download" if image_role(p.name) == "front" else "other")
    for name, fn in (("iTunes", mb.itunes_albums), ("Deezer", mb.deezer_albums)):
        try:
            hits = [h for h in fn(artist, album) if names_match(artist, album, h["artist"], h["album"])][:2]
        except mb.NetError as e:
            tried.append(f"{name}: {e}")
            continue
        if not hits:
            tried.append(f"{name}: no album with this artist and title")
        for h in hits:
            add(lambda u=h["url"]: mb.download(u), f"{name}: {h['album']}", "store")
    return cands


def find(release_mbid: str, group_mbid: str, artist: str, album: str, local: list[Path], explicit: str = "",
         library: Path | None = None, keep_library: bool = True) -> tuple[Cover | None, list[str]]:
    """(the cover or None, what was tried) - explicit is a URL or path chosen in the review;
    library is the album's cover.jpg when it is already in /music (kept unless keep_library=False)."""
    tried: list[str] = []
    with tempfile.TemporaryDirectory(prefix="barch-cover-") as td:
        cands = gather(release_mbid, group_mbid, artist, album, local, explicit, Path(td), tried, library)
        best = choose(cands, keep_library)
        alt = choose(cands) if best is not None and best.kind == "library" else None
        better = ""
        if alt is not None and alt is not best and best.framed and not alt.framed:
            better = f"{alt.label} ({alt.w}x{alt.h}, clean)"
        for c in cands:
            tried.append(f"{c.label}: {c.describe()}" + ("  <- chosen" if c is best else ""))
        if not best:
            return None, tried
        data, nw, nh = _to_jpeg(best)
        src = f"{best.label} ({best.w}x{best.h}" + (", scan frame trimmed" if best.framed else "") + ")"
        return Cover(data, nw, nh, src, best.framed, better), tried
