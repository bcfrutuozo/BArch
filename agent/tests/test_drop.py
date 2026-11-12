"""agent/drop.py: the multipart parser, the request body reader and the file names.

    python3 -m unittest discover -s agent/tests
"""
import io
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import drop  # noqa: E402

B = b"----WebKitFormBoundaryX7"


def form(*parts):
    out = b""
    for headers, content in parts:
        out += b"--" + B + b"\r\n" + headers + b"\r\n\r\n" + content + b"\r\n"
    return out + b"--" + B + b"--\r\n"


class Reader:
    """A body that hands out a few bytes at a time, so delimiters straddle reads."""

    def __init__(self, data, step):
        self.data, self.step = data, step

    def read(self, n=0):
        out, self.data = self.data[:self.step], self.data[self.step:]
        return out


def parse(body, step):
    tmp = tempfile.mkdtemp()
    saved, texts = [], []
    drop.multipart(Reader(body, step), B,
                   lambda name, ct: drop.FileSink(tmp, name, ct, saved),
                   lambda field, value: texts.append((field, value)))
    files = {os.path.basename(f["path"]): Path(f["path"]).read_bytes() for f in saved}
    return tmp, files, texts


class Multipart(unittest.TestCase):
    payload = bytes(range(256)) * 300 + b"\r\n--" + B[:-1] + b"\r\n"   # near-delimiter inside

    def body(self):
        return form(
            (b'Content-Disposition: form-data; name="file"; filename="IMG_0001.HEIC"\r\nContent-Type: image/heic',
             self.payload),
            (b'Content-Disposition: form-data; name="file"; filename="IMG_0001.HEIC"', b"second"),
            (b'Content-Disposition: form-data; name="text"', "olá https://x.y".encode()),
            (b'Content-Disposition: form-data; name="file"; filename*=UTF-8\'\'Relat%C3%B3rio.pdf', b"%PDF"),
        )

    def test_every_chunk_size(self):
        for step in (1, 7, 64, 4096, 1 << 20):
            tmp, files, texts = parse(self.body(), step)
            self.assertEqual(files["IMG_0001.HEIC"], self.payload, step)
            self.assertEqual(files["IMG_0001-2.HEIC"], b"second", step)
            self.assertEqual(files["Relatório.pdf"], b"%PDF", step)
            self.assertEqual(texts, [("text", "olá https://x.y")], step)
            self.assertFalse([n for n in os.listdir(tmp) if n.endswith(".part")])

    def test_preamble_and_empty_file(self):
        body = b"preamble\r\n" + form((b'Content-Disposition: form-data; name="file"; filename="a.txt"', b""))
        _, files, _ = parse(body, 3)
        self.assertEqual(files, {"a.txt": b""})

    def test_truncated_body_leaves_nothing(self):
        body = self.body()[:5000]
        tmp = tempfile.mkdtemp()
        saved = []
        with self.assertRaises(ValueError):
            drop.multipart(Reader(body, 512), B, lambda n, ct: drop.FileSink(tmp, n, ct, saved), lambda f, v: None)
        self.assertEqual(os.listdir(tmp), [])


class Body(unittest.TestCase):
    def test_chunked(self):
        raw = b"5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\n\r\n"
        r = drop.BodyReader(io.BytesIO(raw), {"Transfer-Encoding": "chunked"})
        out = b""
        while chunk := r.read(3):
            out += chunk
        self.assertEqual(out, b"hello world")

    def test_length(self):
        r = drop.BodyReader(io.BytesIO(b"abcdefXX"), {"Content-Length": "6"})
        self.assertEqual(r.read() + r.read(), b"abcdef")


class Names(unittest.TestCase):
    def test_safe(self):
        self.assertEqual(drop.safe_name("../../.bashrc"), "bashrc")
        self.assertEqual(drop.safe_name("C:\\x\\foto.jpg"), "foto.jpg")
        self.assertEqual(drop.safe_name("a\x00b/c.mov"), "c.mov")
        self.assertTrue(drop.safe_name("", "image/jpeg").endswith(".jpg"))
        self.assertTrue(drop.safe_name("...", "").endswith(".bin"))

    def test_disposition(self):
        p = drop.parse_disposition('form-data; name="file"; filename="a \\"b\\".jpg"')
        self.assertEqual(p["filename"], 'a "b".jpg')


if __name__ == "__main__":
    unittest.main()
