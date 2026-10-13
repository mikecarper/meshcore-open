#!/usr/bin/env python3
"""Test genuine BPG still-image encoding, decoding, bounds, and metadata policy."""

from __future__ import annotations

import argparse
from pathlib import Path
import struct
import subprocess
import unittest

MAGIC = 0x31434D49
BPG_CODEC = 9
WORKER: Path


def request(operation: int, data: bytes, width: int = 0, height: int = 0,
            quality: int = 45, codec: int = BPG_CODEC):
    header = struct.pack("<7I", MAGIC, operation, codec, quality, width, height, len(data))
    process = subprocess.run([str(WORKER)], input=header + data, capture_output=True, timeout=120)
    if len(process.stdout) < 20:
        raise AssertionError(f"BPG worker failed: exit={process.returncode} stderr={process.stderr[:400]!r}")
    magic, status, decoded_width, decoded_height, length = struct.unpack("<5I", process.stdout[:20])
    if magic != MAGIC or len(process.stdout) != 20 + length:
        raise AssertionError("Invalid BPG worker response framing")
    return status, decoded_width, decoded_height, process.stdout[20:]


def pixels(width: int, height: int, alpha: bool = False) -> bytes:
    output = bytearray(width * height * 4)
    for y in range(height):
        for x in range(width):
            start = (y * width + x) * 4
            output[start:start + 4] = bytes((
                (x * 3 + y) % 256, (x + y * 2) % 256, (x * 2 + y * 3) % 256,
                (64 if x < width // 2 else 192) if alpha else 255,
            ))
    return bytes(output)


def ue7(value: int) -> bytes:
    result = [value & 127]
    value >>= 7
    while value:
        result.insert(0, (value & 127) | 128)
        value >>= 7
    return bytes(result)


class BpgWorkerTests(unittest.TestCase):
    def test_16_32_128_512_real_roundtrip(self):
        for size in [16, 32, 128, 512]:
            with self.subTest(size=size):
                status, _, _, encoded = request(0, pixels(size, size), size, size)
                self.assertEqual(status, 0, encoded)
                self.assertEqual(encoded[:4], b"BPG\xfb")
                status, width, height, decoded = request(1, encoded)
                self.assertEqual(status, 0, decoded)
                self.assertEqual((width, height, len(decoded)), (size, size, size * size * 4))
                self.assertEqual(decoded[3::4], bytes([255]) * (size * size))
                self.assertGreater(len(set(decoded[0::4])), 5)

    def test_non_square_blocks_preserve_dimensions(self):
        for width, height in [(32, 16), (128, 80), (480, 512)]:
            with self.subTest(width=width, height=height):
                status, _, _, encoded = request(0, pixels(width, height), width, height)
                self.assertEqual(status, 0, encoded)
                status, decoded_width, decoded_height, decoded = request(1, encoded)
                self.assertEqual(status, 0, decoded)
                self.assertEqual((decoded_width, decoded_height, len(decoded)), (width, height, width * height * 4))

    def test_no_extensions_animation_or_encoder_information(self):
        status, _, _, encoded = request(0, pixels(128, 80), 128, 80)
        self.assertEqual(status, 0, encoded)
        self.assertEqual(encoded[5] & 0x09, 0, "Extensions and animation must be absent")
        for metadata in [b"Exif", b"ICC_PROFILE", b"x265", b"http://ns.adobe.com/xap", b"Created by"]:
            self.assertNotIn(metadata, encoded)

    def test_under_1_and_2_kb_payload_including_mesh_envelope(self):
        for quality, target in [(25, 1024), (45, 2048)]:
            with self.subTest(target=target):
                status, _, _, encoded = request(0, pixels(128, 128), 128, 128, quality)
                self.assertEqual(status, 0, encoded)
                self.assertLessEqual(len(encoded) + 14, target)
                self.assertEqual(request(1, encoded)[0], 0)

    def test_alpha_plane_survives_encoding_and_decoding(self):
        original = pixels(32, 32, alpha=True)
        status, _, _, encoded = request(0, original, 32, 32, 65)
        self.assertEqual(status, 0, encoded)
        self.assertTrue(encoded[4] & 0x10)
        status, width, height, decoded = request(1, encoded)
        self.assertEqual(status, 0, decoded)
        self.assertEqual((width, height), (32, 32))
        self.assertLessEqual(max(abs(a - b) for a, b in zip(original[3::4], decoded[3::4])), 1)

    def test_rejects_huge_header_before_hevc_decode(self):
        status, _, _, encoded = request(0, pixels(16, 16), 16, 16)
        self.assertEqual(status, 0, encoded)
        oversized = encoded[:6] + ue7(513) + encoded[7:]
        status, _, _, reason = request(1, oversized)
        self.assertEqual(status, 1)
        self.assertIn(b"dimensions", reason)

    def test_rejects_animation_or_non_8_bit_headers(self):
        status, _, _, encoded = request(0, pixels(32, 32), 32, 32)
        self.assertEqual(status, 0, encoded)
        high_depth = bytearray(encoded)
        high_depth[4] |= 1
        self.assertEqual(request(1, high_depth)[0], 1)
        animated = bytearray(encoded)
        animated[5] |= 1
        self.assertEqual(request(1, animated)[0], 1)

    def test_rejects_malformed_and_truncated_bitstreams(self):
        for encoded in [b"not-an-image\x00\xff", b"BPG\xfb", b"BPG\xfb\x20\x00\x20\x20\x00\x01"]:
            with self.subTest(encoded=encoded):
                self.assertEqual(request(1, encoded)[0], 1)

    def test_checks_rgba_length_dimensions_and_minimum_axis(self):
        for width, height, data in [(513, 16, b"\x00" * 4), (32, 32, b"\x00" * 4), (8, 8, pixels(8, 8))]:
            with self.subTest(width=width, height=height):
                self.assertEqual(request(0, data, width, height)[0], 1)

    def test_rejects_other_worker_codecs_and_invalid_quality(self):
        self.assertEqual(request(0, pixels(16, 16), 16, 16, codec=1)[0], 1)
        self.assertEqual(request(0, pixels(16, 16), 16, 16, quality=101)[0], 1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worker", type=Path, required=True)
    args, remaining = parser.parse_known_args()
    WORKER = args.worker.resolve()
    unittest.main(argv=[__file__, *remaining])
