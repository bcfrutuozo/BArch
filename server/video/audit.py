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

  audit.py            table
  audit.py --json     one object per movie
"""
import json, subprocess, sys, urllib.request
from pathlib import Path

MIN_MBPS = 10.0
REMOTE, LOCAL = "/movies/", "/mnt/nasfrutuozo/media/movies/"
sys.path.insert(0, str(Path(__file__).resolve().parent))
from barch_video.langs import ISO  # noqa: E402


def radarr(path):
    cfg = json.load(open(Path.home() / ".config/barch/video.json"))["radarr"]
    req = urllib.request.Request(cfg["url"] + "/api/v3/" + path, headers={"X-Api-Key": cfg["key"]})
    return json.load(urllib.request.urlopen(req, timeout=60))


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
