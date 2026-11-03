"""The collect step on a synthetic rip: a CUE image split once, however many CUEs describe it."""
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from barch_music import audio  # noqa: E402

CUE = '''PERFORMER "Test"
TITLE "An Album (CD1, VICP-70192)"
FILE "{file}" WAVE
  TRACK 01 AUDIO
    TITLE "One"
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    TITLE "Two"
    INDEX 01 00:02:00
'''


@unittest.skipUnless(all(shutil.which(t) for t in ("flac", "metaflac", "ffmpeg", "ffprobe")), "audio tools missing")
class CueImages(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.src, self.work = self.tmp / "download", self.tmp / "work"
        self.src.mkdir()
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=4", "-ar", "44100", "-ac", "2",
                        "-sample_fmt", "s16", str(self.src / "image.flac")], check=True)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def test_two_cues_one_image(self):
        # EAC rips ship "X.flac.cue" and "X.wav.cue" for the same image: 2 tracks, not 4
        (self.src / "image.flac.cue").write_text(CUE.format(file="image.flac"))
        (self.src / "image.wav.cue").write_text(CUE.format(file="image.wav"))
        tracks, notes = audio.collect(self.src, self.work)
        self.assertEqual([(t.disc, t.index) for t in tracks], [(1, 1), (1, 2)])
        self.assertTrue(any("same image" in n for n in notes), notes)
        self.assertEqual(sum(t.samples for t in tracks), 4 * 44100)
        self.assertEqual(tracks[0].hints["album"], "An Album (CD1, VICP-70192)")

    def test_find_images_leaves_the_back_out(self):
        for name in ("Portada.jpg", "Contraportada.jpg", "Folleto.jpg", "scan.jpg"):
            subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=c=red:s=64x64", "-frames:v", "1", str(self.src / name)], check=True)
        names = [p.name for p in audio.find_images(self.src, self.work)]
        self.assertEqual(names[0], "Portada.jpg")
        self.assertNotIn("Contraportada.jpg", names)
        self.assertNotIn("Folleto.jpg", names)
        self.assertIn("scan.jpg", names)
