#!/usr/bin/env python3
"""Audit of the movie library against the BArch rule, on the files themselves (read only).

For every movie Radarr has a file for: HEVC, 2160p, HDR (PQ/HLG or Dolby Vision), a video bitrate
of at least MIN_MBPS (below it is a starved re-encode), an audio track in the movie's original
language and one in Portuguese, a Portuguese subtitle. Verdict per movie:
  ok       everything there
  fix      only what can be fixed in place: no PT-BR subtitle (Bazarr), extra audio tracks or the
           wrong default track (mkvmerge, no re-encode)
  replace  what only another release fixes: no PT-BR or no original audio, not HEVC, not 2160p,
           SDR, starved bitrate. The file goes, Radarr searches again with the BArch 4K profile.
Radarr comes from ~/.config/barch/video.json; its /movies is /mnt/nasfrutuozo/media/movies here.

  audit.py            the foreign-audio table (Radarr and Sonarr, from what they know of each file), then
                      the probe of every movie
  audit.py --json     one object per movie (the probe only)
  audit.py --foreign  only the files whose audio goes beyond the original language and PT-BR (a German DL
                      release of an English series, a MULTi), movies and episodes, from Radarr's and
                      Sonarr's media info, no probing; --json for one object per file
"""
import json, re, subprocess, sys, urllib.parse, urllib.request
from pathlib import Path

MIN_MBPS = 10.0
REMOTE, LOCAL = "/movies/", "/mnt/nasfrutuozo/media/movies/"
sys.path.insert(0, str(Path(__file__).resolve().parent))
from barch_video.langs import ISO  # noqa: E402


def arr(app, path, **params):
    cfg = json.load(open(Path.home() / ".config/barch/video.json"))[app]
    url = cfg["url"] + "/api/v3/" + path + ("?" + urllib.parse.urlencode(params) if params else "")
    req = urllib.request.Request(url, headers={"X-Api-Key": cfg["key"]})
    return json.load(urllib.request.urlopen(req, timeout=60))


def radarr(path):
    return arr("radarr", path)


CODE_ALIASES = {"ger": "deu", "fre": "fra", "dut": "nld", "cze": "ces", "rum": "ron", "gre": "ell", "chi": "zho",
                "pob": "por", "ptb": "por", "pt": "por", "en": "eng", "und": ""}


def codes_of(media, names):
    """The audio language codes of a Radarr/Sonarr file: its media info (ffprobe, "ger/eng") first, else the
    languages the app parsed from the release name."""
    raw = [x.strip().lower() for x in ((media or {}).get("audioLanguages") or "").split("/") if x.strip()]
    if not raw:
        raw = [sorted(ISO.get(n, {n.lower()[:3]}))[0] for n in names]
    return {CODE_ALIASES.get(c, c) for c in raw if CODE_ALIASES.get(c, c)}


def ep_tag(path, season):
    m = re.search(r"(?i)(?<![a-z0-9])S(\d{1,2})E(\d{1,3})(?:-?E?(\d{1,3}))?", Path(path).name)
    if not m:
        return f"S{season:02d}" if season is not None else Path(path).stem[:40]
    return f"S{int(m.group(1)):02d}E{int(m.group(2)):02d}" + (f"-E{int(m.group(3)):02d}" if m.group(3) else "")


def foreign():
    """Movies and episodes whose audio goes beyond the original language and PT-BR."""
    out = []
    for m in arr("radarr", "movie"):
        mf = m.get("movieFile")
        if not m.get("hasFile") or not mf:
            continue
        orig = (m.get("originalLanguage") or {}).get("name", "English")
        keep = {CODE_ALIASES.get(c, c) for c in ISO.get(orig, set())} | {"por"}
        have = codes_of(mf.get("mediaInfo"), [l["name"] for l in mf.get("languages") or []])
        extra = sorted(have - keep)
        if extra:
            out.append({"kind": "movie", "id": m["id"], "title": f"{m['title']} ({m['year']})", "original": orig,
                        "audio": sorted(have), "extra": extra, "file": mf.get("relativePath", ""),
                        "group": mf.get("releaseGroup", ""), "score": mf.get("customFormatScore")})
    for s in arr("sonarr", "series"):
        if not (s.get("statistics") or {}).get("episodeFileCount"):
            continue
        orig = (s.get("originalLanguage") or {}).get("name", "English")
        keep = {CODE_ALIASES.get(c, c) for c in ISO.get(orig, set())} | {"por"}
        for f in arr("sonarr", "episodefile", seriesId=s["id"]):
            have = codes_of(f.get("mediaInfo"), [l["name"] for l in f.get("languages") or []])
            extra = sorted(have - keep)
            if extra:
                out.append({"kind": "episode", "id": f["id"], "series_id": s["id"], "season": f.get("seasonNumber"),
                            "title": f"{s['title']} {ep_tag(f.get('relativePath', ''), f.get('seasonNumber'))}", "original": orig,
                            "audio": sorted(have), "extra": extra, "file": f.get("relativePath", ""),
                            "group": f.get("releaseGroup", ""), "score": f.get("customFormatScore")})
    return out


def print_foreign(rows):
    if not rows:
        print("== foreign audio: none (every file has only the original language and PT-BR)")
        return
    print(f"== foreign audio ({len(rows)}: audio beyond the original and PT-BR; the pipeline trims it, Radarr/Sonarr score it -10000)")
    for r in rows:
        print(f"  {r['title']}  audio {','.join(r['audio'])} (original {r['original']})  extra {','.join(r['extra'])}"
              f"  [{r['group'] or '?'}" + (f", score {r['score']}" if r.get("score") is not None else "") + "]")


def probe(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_format", "-show_streams", "-of", "json", path],
                         capture_output=True, text=True, timeout=120)
    return json.loads(out.stdout or "{}")


def mbps(stream, fmt):
    tags = stream.get("tags", {})
    for k in ("BPS", "BPS-eng"):
        if tags.get(k, "").isdigit():
            return int(tags[k]) / 1e6
    if str(stream.get("bit_rate", "")).isdigit():
        return int(stream["bit_rate"]) / 1e6
    # whole file over its length, minus nothing: an upper bound, good enough to catch a starved one
    try:
        return float(fmt["size"]) * 8 / float(fmt["duration"]) / 1e6
    except (KeyError, ValueError, ZeroDivisionError):
        return 0.0


def audit(movie):
    mf = movie["movieFile"]
    path = mf["path"].replace(REMOTE, LOCAL, 1)
    info = probe(path)
    streams, fmt = info.get("streams", []), info.get("format", {})
    video = next((s for s in streams if s["codec_type"] == "video" and not s.get("disposition", {}).get("attached_pic")), {})
    audio = [s for s in streams if s["codec_type"] == "audio"]
    subs = [s for s in streams if s["codec_type"] == "subtitle"]
    lang = lambda s: s.get("tags", {}).get("language", "und")
    orig = movie.get("originalLanguage", {}).get("name", "English")
    want = ISO.get(orig, set())
    dv = any("DOVI" in (d.get("side_data_type", "").upper()) or "Dolby" in d.get("side_data_type", "")
             for d in video.get("side_data_list", []))
    hdr = video.get("color_transfer") in ("smpte2084", "arib-std-b67")
    rate = mbps(video, fmt)
    alangs = [lang(s) for s in audio]
    replace, fix = [], []
    if video.get("codec_name") != "hevc":
        replace.append(f"codec {video.get('codec_name')}")
    if (video.get("width") or 0) < 3800 and (video.get("height") or 0) < 2000:
        replace.append(f"{video.get('width')}x{video.get('height')}")
    if not hdr:
        replace.append("SDR" + (" (DV without HDR10 fallback?)" if dv else ""))
    if rate and rate < MIN_MBPS:
        replace.append(f"video {rate:.1f} Mb/s")
    if "por" not in alangs:
        replace.append("no PT-BR audio")
    if want and not want & set(alangs):
        replace.append(f"no {orig} audio")
    if not want:
        fix.append(f"original language {orig} unknown to the audit")
    keep = want | {"por"}
    extra = [a for a in alangs if a not in keep]
    if extra:
        fix.append("extra audio " + ",".join(sorted(set(extra))))
    default = next((lang(s) for s in audio if s.get("disposition", {}).get("default")), alangs[0] if alangs else None)
    if alangs and default not in want:
        fix.append(f"default audio {default}")
    if "por" not in {lang(s) for s in subs}:
        fix.append("no PT-BR subtitle")
    return {
        "id": movie["id"], "title": movie["title"], "year": movie["year"], "original": orig,
        "file": mf["relativePath"], "size_gb": round(mf["size"] / 2**30, 1),
        "video": f"{video.get('codec_name')} {video.get('width')}x{video.get('height')}"
                 f" {'DV ' if dv else ''}{'HDR' if hdr else 'SDR'} {rate:.1f}Mb/s",
        "audio": alangs, "subs": sorted({lang(s) for s in subs}),
        "verdict": "replace" if replace else "fix" if fix else "ok",
        "replace": replace, "fix": fix,
        "score": mf.get("customFormatScore"),
    }


def main():
    if "--foreign" in sys.argv:
        rows = foreign()
        if "--json" in sys.argv:
            json.dump(rows, sys.stdout, indent=1, ensure_ascii=False)
        else:
            print_foreign(rows)
        return
    if "--json" not in sys.argv:
        print_foreign(foreign())
    movies = [m for m in radarr("movie") if m.get("hasFile")]
    rows = [audit(m) for m in sorted(movies, key=lambda m: (m["title"].lower(), m["year"]))]
    if "--json" in sys.argv:
        json.dump(rows, sys.stdout, indent=1, ensure_ascii=False)
        return
    for verdict in ("replace", "fix", "ok"):
        group = [r for r in rows if r["verdict"] == verdict]
        if not group:
            continue
        print(f"\n== {verdict} ({len(group)})")
        for r in group:
            why = "; ".join(r["replace"] + r["fix"])
            print(f"  {r['title']} ({r['year']}) [{r['size_gb']} GB, {r['video']}, audio {','.join(r['audio'])}]"
                  + (f"\n      {why}" if why else ""))
    missing = [m for m in radarr("movie") if not m.get("hasFile")]
    if missing:
        print(f"\n== no file ({len(missing)})")
        for m in missing:
            print(f"  {m['title']} ({m['year']})")


if __name__ == "__main__":
    main()
