import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:meshcore_open/services/compact_image_preparation.dart';
import 'package:meshcore_open/services/compact_image_worker.dart';

Uint8List _pixelView(int prefix) {
  final buffer = Uint8List(prefix + 16 * 16 * 4 + 19)
    ..fillRange(0, prefix, 231);
  final pixels = Uint8List.sublistView(buffer, prefix, prefix + 16 * 16 * 4);
  for (var offset = 0; offset < pixels.length; offset += 4) {
    pixels.setRange(offset, offset + 4, [32, 64, 96, 128]);
  }
  return pixels;
}

void _expectExactPixels(Uint8List png) {
  final decoded = image.decodePng(png)!;
  expect([decoded.width, decoded.height], [16, 16]);
  for (final point in [(0, 0), (8, 8), (15, 15)]) {
    final pixel = decoded.getPixel(point.$1, point.$2);
    expect([pixel.r, pixel.g, pixel.b, pixel.a], [32, 64, 96, 128]);
  }
}

void main() {
  test(
    'a worker startup deadline is observed and leaves the next job usable',
    () async {
      final worker = CompactImageWorker();
      addTearDown(worker.cancel);
      final request = <String, Object?>{
        'op': 'finish',
        'width': 16,
        'height': 16,
        'rgba': _pixelView(13),
      };
      await expectLater(
        worker.run<Uint8List>(request, const Duration(microseconds: 1)),
        throwsA(isA<TimeoutException>()),
      ).timeout(const Duration(seconds: 5));
      _expectExactPixels(
        await worker.run<Uint8List>(request, const Duration(seconds: 5)),
      );
    },
  );

  for (final prefix in [13, 31]) {
    test(
      'finish displays the exact RGBA typed view at byte offset $prefix',
      () async {
        final pixels = _pixelView(prefix);
        expect(pixels.offsetInBytes, prefix);
        final worker = CompactImageWorker();
        addTearDown(worker.cancel);
        final png = await worker.run<Uint8List>({
          'op': 'finish',
          'width': 16,
          'height': 16,
          'rgba': pixels,
        }, const Duration(seconds: 5));
        _expectExactPixels(png);
      },
    );

    test(
      'score treats a typed RGBA view at offset $prefix as identical pixels',
      () async {
        final pixels = _pixelView(prefix);
        final reference = PreparedCompactImage(
          rgba: Uint8List.fromList(pixels),
          width: 16,
          height: 16,
          blockSize: 16,
          seamCount: 0,
        );
        final worker = CompactImageWorker();
        addTearDown(worker.cancel);
        final score = await worker.run<double>({
          'op': 'score',
          'width': 16,
          'height': 16,
          'rgba': pixels,
          'reference': reference,
        }, const Duration(seconds: 5));
        expect(score, 99.0);
      },
    );

    test(
      'palette encode retains color and alpha from typed view offset $prefix',
      () async {
        final worker = CompactImageWorker();
        addTearDown(worker.cancel);
        final png = await worker.run<Uint8List>({
          'op': 'encode',
          'codec': 'png',
          'quality': 2,
          'width': 16,
          'height': 16,
          'rgba': _pixelView(prefix),
        }, const Duration(seconds: 5));
        _expectExactPixels(png);
      },
    );
  }
}
