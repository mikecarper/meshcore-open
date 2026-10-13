import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/compact_image_codec.dart';
import 'package:meshcore_open/services/compact_image_envelope.dart';

CompactImageEnvelope _envelope({
  CompactImageCodec codec = CompactImageCodec.webp,
  int width = 96,
  int height = 64,
  int blockSize = 32,
  Uint8List? bitstream,
}) => CompactImageEnvelope(
  codec: codec,
  width: width,
  height: height,
  blockSize: blockSize,
  bitstream: bitstream ?? Uint8List.fromList([17, 29, 31, 47]),
);

void main() {
  group('CompactImageEnvelope', () {
    test('encodes a stable little-endian header and payload-only CRC', () {
      final envelope = _envelope(width: 512, height: 128);
      final payload = envelope.encode();
      final data = ByteData.sublistView(payload);

      expect(payload.sublist(0, 10), [
        0x4d,
        0x43,
        0x49,
        0x31,
        1,
        32,
        0,
        2,
        128,
        0,
      ]);
      expect(data.getUint32(10, Endian.little), getCrc32(envelope.bitstream));
      expect(payload.sublist(14), envelope.bitstream);
      final decoded = CompactImageEnvelope.decode(payload);
      expect(decoded.codec, CompactImageCodec.webp);
      expect(
        [decoded.width, decoded.height, decoded.blockSize],
        [512, 128, 32],
      );
      expect(decoded.bitstream, envelope.bitstream);
    });

    test(
      'round trips every declared codec without reusing a wire identifier',
      () {
        final ids = <int>{};
        for (final codec in CompactImageCodec.values) {
          expect(ids.add(codec.wireId), isTrue);
          final decoded = CompactImageEnvelope.decode(
            _envelope(codec: codec).encode(),
          );
          expect(decoded.codec, codec);
        }
        expect(ids, {1, 2, 3, 4, 5, 6, 7, 8, 9, 10});
      },
    );

    test(
      'includes header bytes in the 15-data-packet radio transport limit',
      () {
        final largest = _envelope(
          bitstream: Uint8List(
            CompactImageEnvelope.maxPayloadBytes -
                CompactImageEnvelope.headerBytes,
          ),
        ).encode();
        expect(largest.length, CompactImageEnvelope.maxPayloadBytes);
        expect(
          CompactImageEnvelope.decode(largest).bitstream.length,
          CompactImageEnvelope.maxPayloadBytes -
              CompactImageEnvelope.headerBytes,
        );
        expect(
          () => _envelope(
            bitstream: Uint8List(
              CompactImageEnvelope.maxPayloadBytes -
                  CompactImageEnvelope.headerBytes +
                  1,
            ),
          ).encode(),
          throwsFormatException,
        );
        expect(
          () =>
              CompactImageEnvelope.decode(Uint8List.fromList([...largest, 0])),
          throwsFormatException,
        );
      },
    );

    test(
      'allows tiny unaligned images only through the explicit block size 1',
      () {
        final decoded = CompactImageEnvelope.decode(
          _envelope(width: 7, height: 5, blockSize: 1).encode(),
        );
        expect([decoded.width, decoded.height, decoded.blockSize], [7, 5, 1]);
        expect(
          () => _envelope(width: 7, height: 5, blockSize: 16).encode(),
          throwsFormatException,
        );
      },
    );

    test('rejects dimensions that exceed limits or violate grid alignment', () {
      for (final value in [
        _envelope(width: 0),
        _envelope(height: 0),
        _envelope(width: 544),
        _envelope(height: 544),
        _envelope(width: 48, blockSize: 32),
        _envelope(height: 48, blockSize: 32),
        _envelope(blockSize: 8),
        _envelope(blockSize: 0),
        _envelope(bitstream: Uint8List(0)),
      ]) {
        expect(value.encode, throwsFormatException);
      }
    });

    test('rejects a damaged bitstream before calling a decoder', () {
      final payload = _envelope().encode();
      payload[CompactImageEnvelope.headerBytes + 1] ^= 0x80;
      expect(
        () => CompactImageEnvelope.decode(payload),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('checksum mismatch'),
          ),
        ),
      );
    });

    test(
      'validates header fields even when the payload checksum is correct',
      () {
        for (final change in <void Function(Uint8List)>[
          (bytes) => bytes[4] = 0,
          (bytes) => bytes[4] = 255,
          (bytes) => bytes[5] = 8,
          (bytes) => ByteData.sublistView(bytes).setUint16(6, 0, Endian.little),
          (bytes) =>
              ByteData.sublistView(bytes).setUint16(8, 513, Endian.little),
          (bytes) =>
              ByteData.sublistView(bytes).setUint16(6, 49, Endian.little),
        ]) {
          final payload = _envelope().encode();
          change(payload);
          expect(
            () => CompactImageEnvelope.decode(payload),
            throwsFormatException,
          );
        }
      },
    );

    test('rejects short, empty, and unrecognized containers', () {
      for (final bytes in [
        Uint8List(0),
        Uint8List.fromList([0x4d, 0x43, 0x49]),
        Uint8List.fromList([0x4d, 0x43, 0x49, 0x31]),
        Uint8List(14),
        Uint8List.fromList([0x4d, 0x43, 0x49, 0x31, ...List.filled(10, 0)]),
        Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, ...List.filled(14, 0)]),
      ]) {
        expect(() => CompactImageEnvelope.decode(bytes), throwsFormatException);
      }
      expect(CompactImageEnvelope.hasMagic(Uint8List(3)), isFalse);
      expect(CompactImageEnvelope.hasMagic(_envelope().encode()), isTrue);
    });
  });
}
