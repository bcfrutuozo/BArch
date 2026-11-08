#!/usr/bin/env python3
"""clip.py: the ffmpeg side of BArch Clip (quickshell/clip), the video editor in the spirit of the
iPhone's: open a video, cut the borders away, trim it, save it. The app and `barch clip` both run
this, so what the window shows is what the command line saves.

  clip.py probe <file>                            JSON: size as displayed, duration, fps, codec, HDR, audio
  clip.py frame <file> <seconds> [--height H]     a JPEG of that frame (HDR tone mapped), path on stdout
  clip.py strip <file> [--count N] [--height H]   a JPEG with N frames side by side (the trim bar)
  clip.py export <file> [edit...] [-o OUT] [--replace] [--json]
  clip.py preview <file> [edit...]                plays the edit in mpv (the export, piped, nothing written)
  clip.py filters [edit...]                       the ffmpeg -vf chain of an edit (debugging)

  edit: --crop W:H:X:Y (in the frame as displayed: after the file's own rotation, the --rotate and
        the --flip) · --rotate 0|90|180|270 (clockwise) · --flip h|v|hv · --from T · --to T
        (seconds, M:SS or H:MM:SS)

The video is re-encoded (a crop cannot be a stream copy) with the GPU when there is one:
h264_nvenc for H.264 sources, av1_nvenc for AV1, hevc_nvenc for everything else, 10-bit kept
10-bit, the color tags kept, HDR10 metadata passed through; libx264 / libx265 when NVENC is
missing. Audio and subtitles are copied, the container is the source's. Export reports progress
as JSON lines on stdout ({"progress": 0.42, ...}) and ends with {"ok": true, "file": ...}.
Frames and strips go to ~/.cache/barch/clip/<id>/ (id: path, size and mtime of the file).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from fractions import Fraction
from pathlib import Path

CACHE = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "barch" / "clip"
MIN_CROP = 16
VIDEO_EXT = {".mp4", ".mov", ".m4v", ".mkv", ".webm", ".avi", ".mts", ".m2ts", ".ts", ".3gp", ".wmv", ".flv", ".mpg", ".mpeg", ".ogv"}
# the HDR→SDR path of `barch replay share`: scale down first (tone mapping in float at 4K is slow) and
# declare the input (a file without color tags gives "no path between colorspaces")
TONEMAP = ("zscale=tin={trc}:pin={prim}:min={mat}:t=linear:npl=203,format=gbrpf32le,"
           "zscale=p=bt709,tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv")


# ------------------------------------------------------------------ pure helpers (tests/test_clip.py)

def secs(text) -> float:
    """'90', '1:30', '0:01:30.5' -> seconds; ValueError otherwise."""
    s = str(text).strip()
    if not re.fullmatch(r"(\d+:){0,2}\d+(\.\d+)?", s):
        raise ValueError(f"not a time: {text!r}")
    out = 0.0
    for part in s.split(":"):
        out = out * 60 + float(part)
    return out


def hms(t: float, frac: bool = True) -> str:
    """seconds -> 'M:SS.d' (or 'H:MM:SS.d'), what the app shows."""
    tenths = int(round(max(0.0, float(t)) * 10))
    whole, tenth = divmod(tenths, 10)
    h, rem = divmod(whole, 3600)
    m, s = divmod(rem, 60)
    base = f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"
    return f"{base}.{tenth}" if frac else base


def parse_crop(text: str) -> dict:
    m = re.fullmatch(r"(\d+)[:x](\d+)[:+](\d+)[:+](\d+)", text.strip())
    if not m:
        raise ValueError(f"crop must be W:H:X:Y, not {text!r}")
    w, h, x, y = (int(v) for v in m.groups())
    return {"w": w, "h": h, "x": x, "y": y}


def even(n: float) -> int:
    """The nearest even number (halves go up: 701 -> 702), never negative."""
    return max(0, int(n / 2 + 0.5) * 2)


def fit_crop(crop: dict | None, width: int, height: int) -> dict | None:
    """The crop in even numbers inside the frame; None when it is the whole frame (nothing to cut)."""
    if not crop:
        return None
    w, h = even(crop["w"]), even(crop["h"])
    x, y = even(crop["x"]), even(crop["y"])
    w = max(MIN_CROP, min(w, even(width)))
    h = max(MIN_CROP, min(h, even(height)))
    x = max(0, min(x, even(width) - w))
    y = max(0, min(y, even(height) - h))
    if x == 0 and y == 0 and w >= even(width) and h >= even(height):
        return None
    return {"w": w, "h": h, "x": x, "y": y}


def rotated_size(width: int, height: int, rotate: int) -> tuple[int, int]:
    return (height, width) if rotate % 180 else (width, height)


def displayed_size(info: dict) -> tuple[int, int]:
    """The frame as a player shows it: the file's own rotation tag applied (ffmpeg does that by itself)."""
    return rotated_size(info["coded_width"], info["coded_height"], info.get("rotation", 0))


def edit_filters(edit: dict, width: int, height: int) -> list[str]:
    """The -vf steps of an edit over a frame of width x height (as displayed): rotate, flip, crop."""
    steps = []
    rotate = int(edit.get("rotate") or 0) % 360
    if rotate == 90:
        steps.append("transpose=1")
    elif rotate == 180:
        steps += ["hflip", "vflip"]
    elif rotate == 270:
        steps.append("transpose=2")
    elif rotate:
        raise ValueError("rotate must be 0, 90, 180 or 270")
    flip = edit.get("flip") or ""
    if "h" in flip:
        steps.append("hflip")
    if "v" in flip:
        steps.append("vflip")
    rw, rh = rotated_size(width, height, rotate)
    crop = fit_crop(edit.get("crop"), rw, rh)
    if crop:
        steps.append(f"crop={crop['w']}:{crop['h']}:{crop['x']}:{crop['y']}")
    return steps


def output_size(edit: dict, width: int, height: int) -> tuple[int, int]:
    rw, rh = rotated_size(width, height, int(edit.get("rotate") or 0))
    crop = fit_crop(edit.get("crop"), rw, rh)
    return (crop["w"], crop["h"]) if crop else (even(rw), even(rh))


def trim_range(edit: dict, duration: float) -> tuple[float, float]:
    """(start, length) of the export; the whole file when nothing was trimmed."""
    start = max(0.0, float(edit.get("from") or 0))
    end = float(edit["to"]) if edit.get("to") is not None else duration
    end = min(end, duration) if duration > 0 else end
    length = end - start
    if length <= 0:
        raise ValueError(f"empty range: {hms(start)} to {hms(end)}")
    return start, length


def is_hdr(info: dict) -> bool:
    return info.get("transfer") in ("smpte2084", "arib-std-b67") or bool(info.get("mastering"))


def tonemap_filter(info: dict) -> str:
    return TONEMAP.format(trc=info.get("transfer") or "smpte2084",
                          prim=info.get("primaries") or "bt2020",
                          mat=info.get("matrix") or "bt2020nc")


def pick_encoder(info: dict, nvenc: bool) -> list[str]:
    """The -c:v part: codec family of the source, bit depth kept, color tags repeated."""
    codec = info.get("codec") or ""
    ten = info.get("bits", 8) > 8
    if nvenc:
        if codec == "h264" and not ten:
            args = ["-c:v", "h264_nvenc"]
        elif codec == "av1":
            args = ["-c:v", "av1_nvenc"]
        else:
            args = ["-c:v", "hevc_nvenc", "-tag:v", "hvc1"]
            if ten:
                args += ["-profile:v", "main10"]
        args += ["-preset", "p5", "-tune", "hq", "-rc", "vbr", "-cq", "20", "-b:v", "0",
                 "-pix_fmt", "p010le" if ten else "yuv420p"]
    else:
        if codec == "h264" and not ten:
            args = ["-c:v", "libx264", "-preset", "medium", "-crf", "18", "-pix_fmt", "yuv420p"]
        else:
            args = ["-c:v", "libx265", "-preset", "medium", "-crf", "20", "-tag:v", "hvc1",
                    "-pix_fmt", "yuv420p10le" if ten else "yuv420p"]
    for key, flag in (("primaries", "-color_primaries"), ("transfer", "-color_trc"),
                      ("matrix", "-colorspace"), ("range", "-color_range")):
        if info.get(key):
            args += [flag, info[key]]
    return args


def output_path(src: str | Path, explicit: str | None = None) -> Path:
    """<name>-clip.<ext> next to the source (-clip-2 when taken); the extension stays, so audio and
    subtitles can be copied as they are."""
    src = Path(src)
    if explicit:
        return Path(explicit).expanduser()
    ext = src.suffix if src.suffix.lower() in VIDEO_EXT else ".mp4"
    out = src.with_name(f"{src.stem}-clip{ext}")
    n = 2
    while out.exists():
        out = src.with_name(f"{src.stem}-clip-{n}{ext}")
        n += 1
    return out


def summarize_probe(raw: dict) -> dict:
    """ffprobe's JSON -> what the app needs (coded size, the rotation tag, fps, HDR, audio)."""
    streams = raw.get("streams") or []
    v = next((s for s in streams if s.get("codec_type") == "video" and s.get("disposition", {}).get("attached_pic", 0) != 1), None)
    if not v:
        raise ValueError("no video stream")
    a = next((s for s in streams if s.get("codec_type") == "audio"), None)
    fmt = raw.get("format") or {}
    rotation = 0
    for sd in v.get("side_data_list") or []:
        if "rotation" in sd:
            rotation = int(round(float(sd["rotation"]))) % 360
    if not rotation and (v.get("tags") or {}).get("rotate"):
        rotation = int(float(v["tags"]["rotate"])) % 360
    fps = 0.0
    for key in ("avg_frame_rate", "r_frame_rate"):
        try:
            f = Fraction(v.get(key) or "0")
            if f > 0:
                fps = float(f)
                break
        except (ValueError, ZeroDivisionError):
            continue
    duration = float(v.get("duration") or fmt.get("duration") or 0)
    bits = int(v.get("bits_per_raw_sample") or 0)
    if not bits:
        bits = 10 if "10" in (v.get("pix_fmt") or "") else 12 if "12" in (v.get("pix_fmt") or "") else 8
    mastering = any(sd.get("side_data_type", "").lower().startswith("mastering") for sd in (raw.get("frames") or [{}])[0].get("side_data_list") or [])
    info = {
        "file": fmt.get("filename") or "",
        "coded_width": int(v.get("width") or 0),
        "coded_height": int(v.get("height") or 0),
        "rotation": rotation,
        "duration": duration,
        "fps": round(fps, 3),
        "frames": int(v.get("nb_frames") or 0) or (int(duration * fps) if fps else 0),
        "codec": v.get("codec_name") or "",
        "pix_fmt": v.get("pix_fmt") or "",
        "bits": bits,
        "primaries": v.get("color_primaries") or "",
        "transfer": v.get("color_transfer") or "",
        "matrix": v.get("color_space") or "",
        "range": v.get("color_range") or "",
        "mastering": mastering,
        "size": int(fmt.get("size") or 0),
        "container": (fmt.get("format_name") or "").split(",")[0],
        "audio": {"codec": a.get("codec_name") or "", "channels": int(a.get("channels") or 0),
                  "rate": int(a.get("sample_rate") or 0)} if a else None,
    }
    info["width"], info["height"] = displayed_size(info)
    info["hdr"] = is_hdr(info)
    return info


def progress_of(line: str, start: float, length: float) -> dict | None:
    """One `-progress` line -> {"progress": 0..1, "time": s} for out_time_us, {"speed": "x"} for speed."""
    key, sep, val = line.strip().partition("=")
    if not sep:
        return None
    if key == "out_time_us" and val.lstrip("-").isdigit():
        t = max(0, int(val)) / 1e6
        return {"progress": max(0.0, min(1.0, t / length)) if length > 0 else 0.0, "time": round(start + t, 3)}
    if key == "speed":
        return {"speed": val.strip()}
    if key == "progress" and val == "end":
        return {"progress": 1.0}
    return None


def cache_dir(path: str | Path) -> Path:
    p = Path(path)
    try:
        st = p.stat()
        key = f"{p.resolve()}|{st.st_size}|{int(st.st_mtime)}"
    except OSError:
        key = str(p)
    return CACHE / hashlib.sha1(key.encode()).hexdigest()[:16]


# ------------------------------------------------------------------ ffmpeg

def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def ffprobe(path: str) -> dict:
    cp = run(["ffprobe", "-v", "error", "-show_entries",
              "stream=codec_type,codec_name,width,height,pix_fmt,bits_per_raw_sample,avg_frame_rate,r_frame_rate,"
              "duration,nb_frames,color_primaries,color_transfer,color_space,color_range,sample_rate,channels,disposition"
              ":stream_side_data=rotation:stream_tags=rotate:format=duration,size,format_name,filename",
              "-of", "json", path])
    if cp.returncode != 0:
        raise ValueError(cp.stderr.strip().splitlines()[-1] if cp.stderr.strip() else "ffprobe failed")
    raw = json.loads(cp.stdout)
    # HDR10 static metadata lives on the frames, not the stream: look at the first one
    fr = run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-read_intervals", "%+#1",
              "-show_entries", "frame_side_data_list", "-of", "json", path])
    if fr.returncode == 0:
        try:
            raw["frames"] = json.loads(fr.stdout).get("frames") or []
        except json.JSONDecodeError:
            pass
    return raw


def probe(path: str) -> dict:
    return summarize_probe(ffprobe(path))


def has_nvenc() -> bool:
    cp = run(["ffmpeg", "-hide_banner", "-encoders"])
    return "hevc_nvenc" in cp.stdout and Path("/dev/nvidiactl").exists()


def still(path: str, info: dict, t: float, height: int, out: Path, extra: list[str] | None = None) -> Path:
    vf = [f"scale=-2:'min({height},ih)':flags=bicubic"]
    if info["hdr"]:
        vf.append(tonemap_filter(info))
    vf += extra or []
    vf.append("format=yuv420p")
    out.parent.mkdir(parents=True, exist_ok=True)
    t = max(0.0, min(t, max(0.0, info["duration"] - 0.05)))
    cmd = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-ss", f"{t:.3f}", "-i", path,
           "-frames:v", "1", "-vf", ",".join(vf), "-q:v", "3", str(out)]
    cp = run(cmd)
    if cp.returncode != 0 or not out.exists():
        raise ValueError(cp.stderr.strip() or "no frame")
    return out


def frame(path: str, t: float, height: int = 1080) -> Path:
    """The frame at t, named by its time so a position scrubbed twice is instant; the newest 60 kept."""
    info = probe(path)
    folder = cache_dir(path)
    out = folder / f"frame-{int(round(t * 1000)):08d}-{height}.jpg"
    if out.exists():
        return out
    still(path, info, t, height, out)
    old = sorted(folder.glob("frame-*.jpg"), key=lambda f: f.stat().st_mtime)
    for f in old[:-60]:
        f.unlink(missing_ok=True)
    return out


def strip(path: str, count: int = 16, height: int = 72) -> Path:
    info = probe(path)
    out = cache_dir(path) / f"strip-{count}x{height}.jpg"
    if out.exists():
        return out
    out.parent.mkdir(parents=True, exist_ok=True)
    count = max(2, count)
    dur = max(info["duration"], 0.1)
    # one frame every dur/count seconds, the first at half a step (the middle of each cell)
    vf = [f"fps={count}/{dur:.4f}:start_time={dur / count / 2:.4f}", f"scale=-2:{height}:flags=bicubic"]
    if info["hdr"]:
        vf.append(tonemap_filter(info))
    vf += [f"tile={count}x1", "format=yuv420p"]
    cp = run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", path, "-frames:v", "1",
              "-vf", ",".join(vf), "-q:v", "4", str(out)])
    if cp.returncode != 0 or not out.exists():
        # a very short file can yield fewer frames than the tile wants: take what there is
        cp = run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", path, "-frames:v", "1",
                  "-vf", ",".join([f"scale=-2:{height}"] + ([tonemap_filter(info)] if info["hdr"] else []) + ["format=yuv420p"]),
                  "-q:v", "4", str(out)])
        if cp.returncode != 0 or not out.exists():
            raise ValueError(cp.stderr.strip() or "no strip")
    return out


def ffmpeg_args(path: str, info: dict, edit: dict, nvenc: bool, hwaccel: bool, quick: bool = False) -> tuple[list[str], float, float]:
    """The export command up to (not including) the output; (args, start, length)."""
    start, length = trim_range(edit, info["duration"])
    vf = edit_filters(edit, info["width"], info["height"])
    args = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y"]
    if hwaccel:
        args += ["-hwaccel", "cuda"]
    args += ["-ss", f"{start:.3f}", "-i", path, "-t", f"{length:.3f}",
             "-map", "0:v:0", "-map", "0:a?", "-map_chapters", "-1", "-map_metadata", "0"]
    if info["container"] in ("matroska", "webm"):
        args += ["-map", "0:s?", "-c:s", "copy"]
    if quick:
        # the preview: the same frames, encoded as fast as the GPU can, at most 1080p
        vf.append("scale=-2:'min(1080,ih)'")
        enc = pick_encoder(info, nvenc)
        enc = [a if a != "p5" else "p1" for a in enc]
        enc = [a if a != "20" else "26" for a in enc]
    else:
        enc = pick_encoder(info, nvenc)
    if vf:
        args += ["-vf", ",".join(vf)]
    args += enc + ["-c:a", "copy"]
    if info["container"] in ("mov", "mp4", "m4a", "3gp", "3g2", "mj2"):
        args += ["-movflags", "+faststart"]
    return args, start, length


def export(path: str, edit: dict, out: str | None, replace: bool, emit) -> dict:
    info = probe(path)
    target = Path(path) if replace else output_path(path, out)
    tmp = target.with_name(f".{target.stem}.part{target.suffix}")
    nvenc = has_nvenc()
    attempts = [(nvenc, nvenc), (nvenc, False), (False, False)] if nvenc else [(False, False)]
    tried = set()
    err = ""
    for use_nvenc, hwaccel in attempts:
        if (use_nvenc, hwaccel) in tried:
            continue
        tried.add((use_nvenc, hwaccel))
        args, start, length = ffmpeg_args(path, info, edit, use_nvenc, hwaccel)
        args += ["-progress", "pipe:1", "-nostats", str(tmp)]
        emit({"stage": "encoding", "encoder": args[args.index("-c:v") + 1], "hwaccel": hwaccel, "start": start, "length": length})
        proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        assert proc.stdout
        for line in proc.stdout:
            p = progress_of(line, start, length)
            if p:
                emit(p)
        proc.wait()
        err = (proc.stderr.read() if proc.stderr else "").strip()
        if proc.returncode == 0 and tmp.exists() and tmp.stat().st_size > 0:
            break
        tmp.unlink(missing_ok=True)
        emit({"stage": "retry", "error": err.splitlines()[-1] if err else f"ffmpeg exit {proc.returncode}"})
    else:
        raise ValueError(err.splitlines()[-1] if err else "ffmpeg failed")
    original = None
    if replace:
        # the original goes to the trash (gio), or stays next to the new file as <name>.orig.<ext>
        if shutil.which("gio") and run(["gio", "trash", str(target)]).returncode == 0:
            original = "trash"
        else:
            keep = target.with_name(f"{target.stem}.orig{target.suffix}")
            os.replace(target, keep)
            original = str(keep)
    os.replace(tmp, target)
    w, h = output_size(edit, info["width"], info["height"])
    return {"ok": True, "file": str(target), "source": path, "width": w, "height": h,
            "duration": round(length, 3), "size": target.stat().st_size, "hdr": info["hdr"], "original": original}


def preview(path: str, edit: dict) -> int:
    info = probe(path)
    nvenc = has_nvenc()
    args, start, length = ffmpeg_args(path, info, edit, nvenc, nvenc, quick=True)
    args += ["-f", "matroska", "-"]
    mpv = ["mpv", "--really-quiet", "--force-window=yes", "--keep-open=no", "--title=BArch Clip preview",
           "--osd-level=1", "--no-resume-playback", "--cache=yes", "-"]
    ff = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        return subprocess.run(mpv, stdin=ff.stdout).returncode
    finally:
        ff.terminate()


# ------------------------------------------------------------------ CLI

def edit_of(ns) -> dict:
    edit = {}
    if getattr(ns, "crop", None):
        edit["crop"] = parse_crop(ns.crop)
    if getattr(ns, "rotate", None):
        edit["rotate"] = int(ns.rotate)
    if getattr(ns, "flip", None):
        edit["flip"] = ns.flip
    if getattr(ns, "start", None) is not None:
        edit["from"] = secs(ns.start)
    if getattr(ns, "end", None) is not None:
        edit["to"] = secs(ns.end)
    return edit


def add_edit_args(p):
    p.add_argument("--crop", help="W:H:X:Y in the frame as displayed")
    p.add_argument("--rotate", choices=["0", "90", "180", "270"], help="clockwise")
    p.add_argument("--flip", choices=["h", "v", "hv"])
    p.add_argument("--from", dest="start", help="start (seconds, M:SS or H:MM:SS)")
    p.add_argument("--to", dest="end", help="end")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="clip.py", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("probe"); p.add_argument("file")
    p = sub.add_parser("frame"); p.add_argument("file"); p.add_argument("seconds"); p.add_argument("--height", type=int, default=1080)
    p = sub.add_parser("strip"); p.add_argument("file"); p.add_argument("--count", type=int, default=16); p.add_argument("--height", type=int, default=72)
    p = sub.add_parser("export"); p.add_argument("file"); add_edit_args(p)
    p.add_argument("-o", "--output"); p.add_argument("--replace", action="store_true", help="write over the original (it goes to the trash)")
    p.add_argument("--json", action="store_true", help="progress and result as JSON lines")
    p = sub.add_parser("preview"); p.add_argument("file"); add_edit_args(p)
    p = sub.add_parser("filters"); add_edit_args(p); p.add_argument("--size", default="1920x1080")
    ns = ap.parse_args(argv)
    try:
        if ns.cmd == "probe":
            print(json.dumps(probe(ns.file)))
        elif ns.cmd == "frame":
            print(frame(ns.file, secs(ns.seconds), ns.height))
        elif ns.cmd == "strip":
            print(strip(ns.file, ns.count, ns.height))
        elif ns.cmd == "filters":
            w, h = (int(v) for v in ns.size.lower().split("x"))
            print(",".join(edit_filters(edit_of(ns), w, h)) or "(none)")
        elif ns.cmd == "preview":
            return preview(ns.file, edit_of(ns))
        elif ns.cmd == "export":
            if not Path(ns.file).is_file():
                raise ValueError(f"cannot read {ns.file}")
            if ns.json:
                def emit(obj):
                    print(json.dumps(obj), flush=True)
            else:
                def emit(obj):
                    if "progress" in obj:
                        print(f"\r{obj['progress'] * 100:5.1f} %", end="", file=sys.stderr, flush=True)
            result = export(ns.file, edit_of(ns), ns.output, ns.replace, emit)
            if ns.json:
                print(json.dumps(result))
            else:
                print(file=sys.stderr)
                print(f"{result['file']}\n{result['width']}x{result['height']}, {hms(result['duration'])}, "
                      f"{result['size'] / 1048576:.1f} MB" + (", HDR" if result["hdr"] else ""))
    except (ValueError, OSError) as e:
        if getattr(ns, "json", False):
            print(json.dumps({"ok": False, "error": str(e)}))
        else:
            print(f"clip.py: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
