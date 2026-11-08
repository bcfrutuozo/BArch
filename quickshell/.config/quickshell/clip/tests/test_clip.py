"""The pure side of clip.py: times, crops, filter chains, encoder choice, probe summary, progress lines."""
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import clip  # noqa: E402


def probe_json(**over):
    v = {"codec_type": "video", "codec_name": "hevc", "width": 3840, "height": 2160, "pix_fmt": "yuv420p10le",
         "avg_frame_rate": "60000/1001", "r_frame_rate": "60000/1001", "duration": "83.5", "nb_frames": "5000",
         "color_primaries": "bt2020", "color_transfer": "smpte2084", "color_space": "bt2020nc", "color_range": "tv",
         "disposition": {"attached_pic": 0}}
    v.update(over)
    a = {"codec_type": "audio", "codec_name": "aac", "channels": 2, "sample_rate": "48000"}
    return {"streams": [v, a], "format": {"duration": "83.5", "size": "1000", "format_name": "mov,mp4,m4a,3gp,3g2,mj2", "filename": "x.mp4"},
            "frames": [{"side_data_list": [{"side_data_type": "Mastering display metadata"}]}]}


class Times(unittest.TestCase):
    def test_secs(self):
        self.assertEqual(clip.secs("90"), 90)
        self.assertEqual(clip.secs("1:30"), 90)
        self.assertEqual(clip.secs("0:01:30.5"), 90.5)
        with self.assertRaises(ValueError):
            clip.secs("1m30")

    def test_hms(self):
        self.assertEqual(clip.hms(0), "0:00.0")
        self.assertEqual(clip.hms(83.46), "1:23.5")
        self.assertEqual(clip.hms(3600 + 5), "1:00:05.0")
        self.assertEqual(clip.hms(59.99), "1:00.0")
        self.assertEqual(clip.hms(-3), "0:00.0")

    def test_trim_range(self):
        self.assertEqual(clip.trim_range({}, 10), (0, 10))
        self.assertEqual(clip.trim_range({"from": 2, "to": 5.5}, 10), (2, 3.5))
        self.assertEqual(clip.trim_range({"from": 2, "to": 50}, 10), (2, 8))
        with self.assertRaises(ValueError):
            clip.trim_range({"from": 5, "to": 5}, 10)


class Crops(unittest.TestCase):
    def test_parse(self):
        self.assertEqual(clip.parse_crop("1000:700:200:100"), {"w": 1000, "h": 700, "x": 200, "y": 100})
        self.assertEqual(clip.parse_crop("1000x700+200+100"), {"w": 1000, "h": 700, "x": 200, "y": 100})
        with self.assertRaises(ValueError):
            clip.parse_crop("1000:700")

    def test_fit_even_and_inside(self):
        self.assertEqual(clip.fit_crop({"w": 501, "h": 301, "x": 11, "y": 7}, 1920, 1080), {"w": 502, "h": 302, "x": 12, "y": 8})
        # pushed back inside the frame
        self.assertEqual(clip.fit_crop({"w": 1000, "h": 500, "x": 1500, "y": 900}, 1920, 1080), {"w": 1000, "h": 500, "x": 920, "y": 580})
        # too big: the frame itself, which is no crop at all
        self.assertIsNone(clip.fit_crop({"w": 5000, "h": 5000, "x": 0, "y": 0}, 1920, 1080))
        self.assertIsNone(clip.fit_crop(None, 1920, 1080))
        # never smaller than MIN_CROP
        self.assertEqual(clip.fit_crop({"w": 2, "h": 2, "x": 0, "y": 0}, 1920, 1080)["w"], clip.MIN_CROP)

    def test_filters(self):
        self.assertEqual(clip.edit_filters({}, 1920, 1080), [])
        self.assertEqual(clip.edit_filters({"rotate": 90}, 1920, 1080), ["transpose=1"])
        self.assertEqual(clip.edit_filters({"rotate": 180}, 1920, 1080), ["hflip", "vflip"])
        self.assertEqual(clip.edit_filters({"rotate": 270, "flip": "hv"}, 1920, 1080), ["transpose=2", "hflip", "vflip"])
        # the crop is measured on the rotated frame: 1000 wide fits a 1080-wide portrait, 1500 does not
        self.assertEqual(clip.edit_filters({"rotate": 90, "crop": {"w": 1000, "h": 700, "x": 40, "y": 40}}, 1920, 1080),
                         ["transpose=1", "crop=1000:700:40:40"])
        self.assertEqual(clip.edit_filters({"rotate": 90, "crop": {"w": 1500, "h": 700, "x": 0, "y": 0}}, 1920, 1080),
                         ["transpose=1", "crop=1080:700:0:0"])
        with self.assertRaises(ValueError):
            clip.edit_filters({"rotate": 45}, 1920, 1080)

    def test_output_size(self):
        self.assertEqual(clip.output_size({}, 1920, 1080), (1920, 1080))
        self.assertEqual(clip.output_size({"rotate": 90}, 1920, 1080), (1080, 1920))
        self.assertEqual(clip.output_size({"crop": {"w": 999, "h": 701, "x": 0, "y": 0}}, 1920, 1080), (1000, 702))


class Encoders(unittest.TestCase):
    def test_nvenc_by_source(self):
        self.assertIn("h264_nvenc", clip.pick_encoder({"codec": "h264", "bits": 8}, True))
        self.assertIn("av1_nvenc", clip.pick_encoder({"codec": "av1", "bits": 10}, True))
        hevc = clip.pick_encoder({"codec": "hevc", "bits": 10, "transfer": "smpte2084"}, True)
        self.assertIn("hevc_nvenc", hevc)
        self.assertIn("main10", hevc)
        self.assertIn("p010le", hevc)
        self.assertEqual(hevc[hevc.index("-color_trc") + 1], "smpte2084")
        # 10-bit H.264 has no NVENC: HEVC then
        self.assertIn("hevc_nvenc", clip.pick_encoder({"codec": "h264", "bits": 10}, True))
        # an exotic source (prores) becomes HEVC
        self.assertIn("hevc_nvenc", clip.pick_encoder({"codec": "prores", "bits": 10}, True))

    def test_software(self):
        self.assertIn("libx264", clip.pick_encoder({"codec": "h264", "bits": 8}, False))
        x265 = clip.pick_encoder({"codec": "hevc", "bits": 10}, False)
        self.assertIn("libx265", x265)
        self.assertIn("yuv420p10le", x265)


class Probe(unittest.TestCase):
    def test_summary(self):
        info = clip.summarize_probe(probe_json())
        self.assertEqual((info["width"], info["height"]), (3840, 2160))
        self.assertAlmostEqual(info["fps"], 59.94, places=2)
        self.assertEqual(info["bits"], 10)
        self.assertTrue(info["hdr"])
        self.assertTrue(info["mastering"])
        self.assertEqual(info["container"], "mov")
        self.assertEqual(info["audio"]["codec"], "aac")

    def test_rotation_swaps_the_displayed_size(self):
        raw = probe_json(width=1920, height=1080, side_data_list=[{"rotation": -90}])
        info = clip.summarize_probe(raw)
        self.assertEqual(info["rotation"], 270)
        self.assertEqual((info["width"], info["height"]), (1080, 1920))
        raw = probe_json(width=1920, height=1080, tags={"rotate": "180"})
        self.assertEqual(clip.summarize_probe(raw)["rotation"], 180)
        self.assertEqual((clip.summarize_probe(raw)["width"]), 1920)

    def test_sdr_without_tags(self):
        raw = probe_json(codec_name="h264", pix_fmt="yuv420p", color_transfer=None, color_primaries=None, color_space=None)
        raw["frames"] = []
        info = clip.summarize_probe(raw)
        self.assertFalse(info["hdr"])
        self.assertEqual(info["bits"], 8)
        # the tone map chain still names an input when asked (a file that lies about being SDR)
        self.assertIn("tin=smpte2084", clip.tonemap_filter(info))

    def test_hlg_is_hdr(self):
        self.assertTrue(clip.is_hdr({"transfer": "arib-std-b67"}))
        self.assertFalse(clip.is_hdr({"transfer": "bt709", "mastering": False}))

    def test_no_video(self):
        with self.assertRaises(ValueError):
            clip.summarize_probe({"streams": [{"codec_type": "audio"}], "format": {}})


class Progress(unittest.TestCase):
    def test_lines(self):
        self.assertEqual(clip.progress_of("out_time_us=1500000", 2, 3), {"progress": 0.5, "time": 3.5})
        self.assertEqual(clip.progress_of("out_time_us=9000000", 0, 3)["progress"], 1.0)
        self.assertEqual(clip.progress_of("speed=12.5x", 0, 3), {"speed": "12.5x"})
        self.assertEqual(clip.progress_of("progress=end", 0, 3), {"progress": 1.0})
        self.assertIsNone(clip.progress_of("frame=90", 0, 3))
        self.assertIsNone(clip.progress_of("garbage", 0, 3))
        self.assertEqual(clip.progress_of("out_time_us=N/A", 0, 3), None)


class Output(unittest.TestCase):
    def test_next_to_the_source(self):
        with tempfile.TemporaryDirectory() as d:
            src = Path(d) / "IMG_0012.MOV"
            src.write_bytes(b"x")
            self.assertEqual(clip.output_path(src), Path(d) / "IMG_0012-clip.MOV")
            (Path(d) / "IMG_0012-clip.MOV").write_bytes(b"x")
            self.assertEqual(clip.output_path(src), Path(d) / "IMG_0012-clip-2.MOV")
            self.assertEqual(clip.output_path(src, "/tmp/o.mp4"), Path("/tmp/o.mp4"))
            # an unknown extension becomes mp4
            self.assertEqual(clip.output_path(Path(d) / "weird.bin").suffix, ".mp4")

    def test_cache_dir_follows_the_file(self):
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "a.mp4"
            f.write_bytes(b"abc")
            one = clip.cache_dir(f)
            f.write_bytes(b"abcd")
            os.utime(f, (1, 1))
            self.assertNotEqual(one, clip.cache_dir(f))
            self.assertTrue(str(one).startswith(str(clip.CACHE)))


class Args(unittest.TestCase):
    def test_ffmpeg_args(self):
        info = clip.summarize_probe(probe_json())
        args, start, length = clip.ffmpeg_args("in.mp4", info, {"from": 2, "to": 5, "crop": {"w": 1000, "h": 700, "x": 0, "y": 0}}, True, True)
        self.assertEqual((start, length), (2, 3))
        self.assertEqual(args[args.index("-ss") + 1], "2.000")
        self.assertEqual(args[args.index("-t") + 1], "3.000")
        self.assertIn("-hwaccel", args)
        self.assertEqual(args[args.index("-vf") + 1], "crop=1000:700:0:0")
        self.assertIn("+faststart", args)
        self.assertNotIn("-c:s", args)
        # a matroska keeps its subtitles; no faststart there
        mkv = clip.summarize_probe(probe_json())
        mkv["container"] = "matroska"
        args, _, _ = clip.ffmpeg_args("in.mkv", mkv, {}, False, False)
        self.assertIn("-c:s", args)
        self.assertNotIn("-movflags", args)
        self.assertNotIn("-vf", args)
        # the preview is the same chain, scaled down, at the fastest preset
        args, _, _ = clip.ffmpeg_args("in.mp4", info, {"rotate": 90}, True, True, quick=True)
        self.assertEqual(args[args.index("-vf") + 1], "transpose=1,scale=-2:'min(1080,ih)'")
        self.assertEqual(args[args.index("-preset") + 1], "p1")


if __name__ == "__main__":
    unittest.main()
