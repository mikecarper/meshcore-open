#!/usr/bin/env python3
"""Exercise actual native codec output, malformed input, and metadata stripping."""

from __future__ import annotations

import argparse
from pathlib import Path
import struct
import subprocess
import unittest

MAGIC = 0x31434D49
CODECS = {"webp": 1, "jpeg": 2, "png": 3, "avif": 4, "jxl": 5, "jp2": 6, "vvc": 7, "heic": 8}
WORKER: Path


def request(codec: int, operation: int, data: bytes, width: int = 0, height: int = 0, quality: int = 30):
    header = struct.pack("<7I", MAGIC, operation, codec, quality, width, height, len(data))
    process = subprocess.run([str(WORKER)], input=header + data, capture_output=True, timeout=120)
    if len(process.stdout) < 20:
        raise AssertionError(f"Native worker failed: exit={process.returncode} stderr={process.stderr[:400]!r}")
    magic, status, decoded_width, decoded_height, size = struct.unpack("<5I", process.stdout[:20])
    if magic != MAGIC or len(process.stdout) != 20 + size:
        raise AssertionError("Invalid native worker response framing")
    return status, decoded_width, decoded_height, process.stdout[20:]


def pixels(width: int, height: int) -> bytes:
    output = bytearray(width * height * 4)
    for y in range(height):
        for x in range(width):
            start = (y * width + x) * 4
            output[start:start + 4] = bytes(((x * 3 + y) % 256, (x + y * 2) % 256, (x * 2 + y * 3) % 256, 255))
    return bytes(output)


def metadata_free(name: str, data: bytes) -> None:
    if name == "png":
        assert data[:8] == b"\x89PNG\r\n\x1a\n"
        offset = 8
        while offset < len(data):
            size = struct.unpack(">I", data[offset:offset + 4])[0]
            assert data[offset + 4:offset + 8] in (b"IHDR", b"IDAT", b"IEND")
            offset += size + 12
        assert offset == len(data)
    elif name == "webp":
        assert data[:4] == b"RIFF" and data[8:12] == b"WEBP"
        offset = 12
        while offset < len(data):
            name_bytes = data[offset:offset + 4]
            assert name_bytes in (b"VP8 ", b"VP8L", b"VP8X", b"ALPH")
            size = struct.unpack("<I", data[offset + 4:offset + 8])[0]
            offset += 8 + size + (size & 1)
        assert offset == len(data)
    elif name == "jpeg":
        assert data[:2] == b"\xff\xd8"
        offset = 2
        while offset + 4 <= len(data):
            assert data[offset] == 255
            marker = data[offset + 1]
            assert not 0xE0 <= marker <= 0xEF and marker != 0xFE
            if marker == 0xDA:
                break
            size = struct.unpack(">H", data[offset + 2:offset + 4])[0]
            offset += 2 + size
    elif name == "jp2":
        assert data[:2] == b"\xff\x4f", "The radio representation is a raw J2K codestream"
        offset = 2
        while offset + 4 <= len(data) and data[offset:offset + 2] != b"\xff\x90":
            assert data[offset] == 255 and data[offset + 1] != 0x64
            size = struct.unpack(">H", data[offset + 2:offset + 4])[0]
            offset += 2 + size
    elif name == "jxl":
        assert data[:2] == b"\xff\x0a", "JXL must be a raw codestream, without metadata boxes"
    elif name in ("avif", "heic"):
        assert data[4:8] == b"ftyp"
        assert b"Exif" not in data and b"http://ns.adobe.com/xap" not in data
        assert b"prof" not in data and b"rICC" not in data
        assert b"Kvazaar" not in data and b"Created by" not in data


class NativeCodecTests(unittest.TestCase):
    def test_actual_roundtrip_and_metadata(self):
        for name, codec in CODECS.items():
            with self.subTest(codec=name):
                status, _, _, encoded = request(codec, 0, pixels(128, 80), 128, 80)
                self.assertEqual(status, 0, encoded)
                self.assertGreater(len(encoded), 0)
                metadata_free(name, encoded)
                status, width, height, decoded = request(codec, 1, encoded)
                self.assertEqual(status, 0, decoded)
                self.assertEqual((width, height, len(decoded)), (128, 80, 128 * 80 * 4))
                self.assertEqual(decoded[3::4], bytes([255]) * (128 * 80))

    def test_maximum_512_dimensions(self):
        for name in CODECS:
            with self.subTest(codec=name):
                status, _, _, encoded = request(CODECS[name], 0, pixels(512, 512), 512, 512, 15)
                self.assertEqual(status, 0, encoded)
                status, width, height, decoded = request(CODECS[name], 1, encoded)
                self.assertEqual(status, 0, decoded)
                self.assertEqual((width, height, len(decoded)), (512, 512, 512 * 512 * 4))

    def test_malformed_input_does_not_hang(self):
        for name, codec in CODECS.items():
            with self.subTest(codec=name):
                status, _, _, _ = request(codec, 1, b"not-an-image\x00\xff")
                self.assertEqual(status, 1)

    def test_dimensions_rejected_before_encoding(self):
        status, _, _, message = request(CODECS["webp"], 0, b"\x00" * 4, 513, 1)
        self.assertEqual(status, 1)
        self.assertIn(b"dimensions", message)

    def test_pixel_buffer_mismatch(self):
        status, _, _, message = request(CODECS["avif"], 0, b"\x00" * 4, 64, 64)
        self.assertEqual(status, 1)
        self.assertIn(b"RGBA", message)

    def test_unknown_codec_rejected(self):
        status, _, _, _ = request(900, 0, b"\x00" * 4, 1, 1)
        self.assertEqual(status, 1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worker", type=Path, required=True)
    args, remaining = parser.parse_known_args()
    WORKER = args.worker.resolve()
    unittest.main(argv=[__file__, *remaining])
