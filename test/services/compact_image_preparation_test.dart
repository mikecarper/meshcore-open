import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:meshcore_open/services/compact_image_preparation.dart';

Uint8List _png(image.Image source) => image.encodePng(source);

image.Image _fromPrepared(PreparedCompactImage prepared) =>
    image.Image.fromBytes(
      width: prepared.width,
      height: prepared.height,
      bytes: prepared.rgba.buffer,
      numChannels: 4,
      order: image.ChannelOrder.rgba,
    );

image.Image _solid(int width, int height) {
  final source = image.Image(width: width, height: height, numChannels: 4);
  source.clear(image.ColorRgba8(24, 48, 72, 123));
  return source;
}

void main() {
  group('CompactImagePreparation', () {
    test('removes only remainder seams and offers distinct 16/32 grids', () {
      final prepared = CompactImagePreparation.prepare(_png(_solid(49, 65)));

      expect(prepared, hasLength(2));
      expect(
        prepared.map((p) => [p.width, p.height, p.blockSize, p.seamCount]),
        [
          [48, 64, 16, 2],
          [32, 64, 32, 18],
        ],
      );
      for (final candidate in prepared) {
        expect(candidate.width % candidate.blockSize, 0);
        expect(candidate.height % candidate.blockSize, 0);
        expect(
          candidate.rgba,
          hasLength(candidate.width * candidate.height * 4),
        );
        for (var pixel = 0; pixel < candidate.rgba.length; pixel += 4) {
          expect(candidate.rgba.sublist(pixel, pixel + 4), [24, 48, 72, 123]);
        }
      }
    });

    test('keeps a high contrast subject intact instead of stretching it', () {
      final source = image.Image(width: 65, height: 65, numChannels: 4);
      source.clear(image.ColorRgba8(0, 0, 0, 255));
      for (var y = 24; y < 40; y++) {
        for (var x = 24; x < 40; x++) {
          source.setPixelRgba(x, y, 255, 255, 255, 255);
        }
      }

      final candidate = CompactImagePreparation.prepare(_png(source)).single;
      final result = _fromPrepared(candidate);
      final subject = result
          .where((p) => p.r == 255)
          .map((p) => (x: p.x, y: p.y))
          .toList();

      expect(
        [candidate.width, candidate.height, candidate.seamCount],
        [64, 64, 2],
      );
      expect(subject, hasLength(16 * 16));
      expect(subject.map((p) => p.x).toSet(), hasLength(16));
      expect(subject.map((p) => p.y).toSet(), hasLength(16));
      expect(result.every((p) => p.r == 0 || p.r == 255), isTrue);
    });

    test('preserves translucent edges and RGBA channel order', () {
      final source = _solid(33, 32);
      for (var y = 0; y < source.height; y++) {
        source.setPixelRgba(16, y, 249, 103, 5, 201);
      }

      final candidate = CompactImagePreparation.prepare(_png(source)).single;
      final subject = _fromPrepared(
        candidate,
      ).where((p) => p.r == 249).map((p) => (g: p.g, b: p.b, a: p.a)).toList();

      expect(subject, hasLength(32));
      expect(
        subject.every((p) => p.g == 103 && p.b == 5 && p.a == 201),
        isTrue,
      );
    });

    test('returns pixels with no source metadata in a fresh PNG', () {
      const secret = 'GPS-private-12345-not-for-transmission';
      final source = _solid(32, 32)
        ..addTextData({'Comment': secret})
        ..exif.imageIfd.imageDescription = secret;
      final encoded = _png(source);
      expect(latin1.decode(encoded, allowInvalid: true), contains(secret));

      final candidate = CompactImagePreparation.prepare(encoded).single;
      final rebuilt = _png(_fromPrepared(candidate));
      final decoded = image.decodePng(rebuilt)!;

      expect(
        latin1.decode(rebuilt, allowInvalid: true),
        isNot(contains(secret)),
      );
      expect(decoded.textData, anyOf(isNull, isEmpty));
      expect(decoded.exif.imageIfd.imageDescription, isNull);
      expect(decoded.iccProfile, isNull);
      final previewInput = CompactImagePreparation.previewInput(encoded);
      expect(
        latin1.decode(previewInput, allowInvalid: true),
        isNot(contains(secret)),
      );
      final preview = image.decodePng(previewInput)!;
      expect([preview.width, preview.height], [32, 32]);
      expect(preview.getPixel(0, 0).a, 123);
    });

    test(
      'ignores compressed PNG metadata before allocating its decoded data',
      () {
        final encoded = _png(_solid(32, 32));
        // A malformed zTXt stream must never be inflated merely to discard it.
        final payload = Uint8List.fromList([
          ...ascii.encode('Comment'),
          0,
          0,
          0xff,
          0xff,
          0xff,
        ]);
        final typeAndPayload = [...ascii.encode('zTXt'), ...payload];
        final chunk = Uint8List(payload.length + 12);
        final chunkData = ByteData.sublistView(chunk);
        chunkData.setUint32(0, payload.length);
        chunk.setRange(4, 4 + typeAndPayload.length, typeAndPayload);
        chunkData.setUint32(chunk.length - 4, getCrc32(typeAndPayload));
        final input = Uint8List.fromList([
          ...encoded.sublist(0, 33),
          ...chunk,
          ...encoded.sublist(33),
        ]);

        final candidate = CompactImagePreparation.prepare(input).single;
        final preview = CompactImagePreparation.previewInput(input);

        expect([candidate.width, candidate.height], [32, 32]);
        expect(candidate.rgba.sublist(0, 4), [24, 48, 72, 123]);
        expect(image.decodePng(preview)!.getPixel(0, 0).a, 123);
      },
    );

    test('bakes actual JPEG EXIF orientation before applying the crop', () {
      final source = image.Image(width: 80, height: 64, numChannels: 3);
      for (final p in source) {
        if (p.x < 40) {
          p.setRgb(255, 0, 0);
        } else {
          p.setRgb(0, 0, 255);
        }
      }
      source.exif.imageIfd.orientation = 6;
      final encoded = image.encodeJpg(source, quality: 100);
      // This is an encoded EXIF tag, not a mocked rotation on an image object.
      expect(latin1.decode(encoded, allowInvalid: true), contains('Exif'));
      expect(CompactImagePreparation.previewInput(encoded), encoded);

      final full = CompactImagePreparation.prepare(encoded);
      expect([full.first.width, full.first.height], [64, 80]);
      final cropped = CompactImagePreparation.prepare(
        encoded,
        crop: const CompactImageCrop(top: 0.5),
      );
      final center = _fromPrepared(cropped.first).getPixel(32, 16);

      expect([cropped.first.width, cropped.first.height], [64, 32]);
      expect(center.b, greaterThan(220));
      expect(center.r, lessThan(30));
    });

    test(
      'uses the selected normalized crop rather than an implicit center crop',
      () {
        final source = image.Image(width: 64, height: 32, numChannels: 4);
        for (final p in source) {
          p.setRgba(p.x < 32 ? 255 : 0, p.x < 32 ? 0 : 255, 0, 255);
        }

        final candidate = CompactImagePreparation.prepare(
          _png(source),
          crop: const CompactImageCrop(left: 0.5),
        ).single;

        expect(
          [candidate.width, candidate.height, candidate.seamCount],
          [32, 32, 0],
        );
        expect(
          _fromPrepared(candidate).every((p) => p.r == 0 && p.g == 255),
          isTrue,
        );
      },
    );

    test('bounds proportional downscaling before grid alignment', () {
      final source = _solid(320, 240);
      final candidate = CompactImagePreparation.prepare(
        _png(source),
        maxDimension: 128,
      ).single;

      expect(
        [candidate.width, candidate.height, candidate.seamCount],
        [128, 96, 0],
      );
    });

    test('supports bounded 512-pixel comparisons with both block grids', () {
      final source = _solid(503, 487);
      final prepared = CompactImagePreparation.prepare(
        _png(source),
        maxDimension: 512,
      );

      expect(
        prepared.map(
          (candidate) => [
            candidate.width,
            candidate.height,
            candidate.blockSize,
            candidate.seamCount,
          ],
        ),
        [
          [496, 480, 16, 14],
          [480, 480, 32, 30],
        ],
      );
      for (final candidate in prepared) {
        expect(candidate.rgba.length, lessThanOrEqualTo(512 * 512 * 4));
        expect(candidate.rgba.sublist(0, 4), [24, 48, 72, 123]);
        expect(candidate.rgba.sublist(candidate.rgba.length - 4), [
          24,
          48,
          72,
          123,
        ]);
      }
    });

    test(
      'keeps the default 256 bound while allowing proportional 512 preparation',
      () {
        final source = _solid(768, 1024);
        final encoded = _png(source);
        final defaultResult = CompactImagePreparation.prepare(encoded).single;
        final expanded = CompactImagePreparation.prepare(
          encoded,
          maxDimension: 512,
        ).single;

        expect([defaultResult.width, defaultResult.height], [192, 256]);
        expect([expanded.width, expanded.height], [384, 512]);
        expect(expanded.seamCount, 0);
      },
    );

    test(
      'prepares multiple bounded sizes from one metadata-free working image',
      () {
        final source = _solid(1000, 750)
          ..addTextData({'Comment': 'private-large-camera-image'});
        final prepared = CompactImagePreparation.prepareMany(
          _png(source),
          maxDimensions: [512, 384, 256, 192, 128, 96, 64, 48, 32],
        );

        expect([prepared.first.width, prepared.first.height], [512, 384]);
        final keys = <String>{};
        for (final candidate in prepared) {
          expect(
            keys.add(
              '${candidate.width}:${candidate.height}:${candidate.blockSize}',
            ),
            isTrue,
          );
          expect(candidate.width, lessThanOrEqualTo(512));
          expect(candidate.height, lessThanOrEqualTo(512));
          expect(candidate.width % candidate.blockSize, 0);
          expect(candidate.height % candidate.blockSize, 0);
          expect(candidate.seamCount, lessThanOrEqualTo(62));
          expect(candidate.rgba.length, candidate.width * candidate.height * 4);
          expect(candidate.rgba.sublist(0, 4), [24, 48, 72, 123]);
          expect(
            latin1.decode(_png(_fromPrepared(candidate)), allowInvalid: true),
            isNot(contains('private-large-camera-image')),
          );
        }
      },
    );

    test(
      'multi-size preparation keeps EXIF-oriented crop and the single-size caller contract',
      () {
        final source = image.Image(width: 80, height: 64, numChannels: 3);
        for (final p in source) {
          p.setRgb(p.x < 40 ? 255 : 0, 0, p.x < 40 ? 0 : 255);
        }
        source.exif.imageIfd.orientation = 6;
        final encoded = image.encodeJpg(source, quality: 100);
        const crop = CompactImageCrop(top: 0.5);
        final single = CompactImagePreparation.prepare(
          encoded,
          maxDimension: 128,
          crop: crop,
        ).single;
        final prepared = CompactImagePreparation.prepareMany(
          encoded,
          maxDimensions: [128, 64, 32, 16],
          crop: crop,
        );

        expect(
          prepared.map(
            (candidate) => [
              candidate.width,
              candidate.height,
              candidate.blockSize,
            ],
          ),
          [
            [64, 32, 16],
            [32, 16, 16],
            [16, 10, 1],
          ],
        );
        expect(prepared.first.rgba, single.rgba);
        for (final candidate in prepared) {
          final center = _fromPrepared(
            candidate,
          ).getPixel(candidate.width ~/ 2, candidate.height ~/ 2);
          expect(center.b, greaterThan(220));
          expect(center.r, lessThan(30));
        }
      },
    );

    test(
      'deduplicates tiny multi-size results and validates every requested bound',
      () {
        final encoded = _png(_solid(5, 7));
        final prepared = CompactImagePreparation.prepareMany(
          encoded,
          maxDimensions: [256, 128, 32, 32],
        );

        expect(prepared, hasLength(1));
        expect(
          [
            prepared.single.width,
            prepared.single.height,
            prepared.single.blockSize,
          ],
          [5, 7, 1],
        );
        for (final dimensions in <List<int>>[
          [],
          [512, 513],
          [32, 15],
        ]) {
          expect(
            () => CompactImagePreparation.prepareMany(
              encoded,
              maxDimensions: dimensions,
            ),
            throwsArgumentError,
          );
        }
      },
    );

    test(
      'does not add a duplicate 32 variant when the pixels are already aligned',
      () {
        final prepared = CompactImagePreparation.prepare(_png(_solid(64, 32)));
        expect(prepared, hasLength(1));
        expect(prepared.single.blockSize, 16);
        expect(prepared.single.seamCount, 0);
      },
    );

    test('never upscales or invents pixels in tiny images', () {
      final source = image.Image(width: 5, height: 7, numChannels: 4);
      for (final p in source) {
        p.setRgba(p.x * 13, p.y * 17, (p.x + p.y) * 7, 19 + p.x);
      }
      final candidate = CompactImagePreparation.prepare(_png(source)).single;

      expect(
        [candidate.width, candidate.height, candidate.blockSize],
        [5, 7, 1],
      );
      expect(candidate.seamCount, 0);
      expect(candidate.rgba, source.getBytes(order: image.ChannelOrder.rgba));
    });

    test('handles one-pixel crops without division by zero or enlargement', () {
      final candidate = CompactImagePreparation.prepare(
        _png(_solid(32, 32)),
        crop: const CompactImageCrop(
          left: 0.5,
          right: 0.51,
          top: 0.5,
          bottom: 0.51,
        ),
      ).single;

      expect(
        [candidate.width, candidate.height, candidate.blockSize],
        [1, 1, 1],
      );
      expect(candidate.rgba, [24, 48, 72, 123]);
    });

    test('is deterministic for changing energies across multiple seams', () {
      final source = image.Image(width: 63, height: 61, numChannels: 4);
      for (final p in source) {
        p.setRgba((p.x * 7) % 256, (p.y * 11) % 256, (p.x * p.y) % 256, 255);
      }
      final encoded = _png(source);
      final first = CompactImagePreparation.prepare(encoded);
      final second = CompactImagePreparation.prepare(encoded);

      expect(first, hasLength(2));
      for (var index = 0; index < first.length; index++) {
        expect(first[index].rgba, second[index].rgba);
        expect(first[index].seamCount, second[index].seamCount);
      }
    });

    test('rejects invalid crop edges and unbounded preparation dimensions', () {
      final encoded = _png(_solid(32, 32));
      for (final crop in [
        const CompactImageCrop(left: -0.1),
        const CompactImageCrop(bottom: 1.1),
        const CompactImageCrop(left: 0.5, right: 0.5),
        const CompactImageCrop(top: 0.9, bottom: 0.1),
        const CompactImageCrop(left: double.nan),
        const CompactImageCrop(bottom: double.infinity),
      ]) {
        expect(
          () => CompactImagePreparation.prepare(encoded, crop: crop),
          throwsArgumentError,
        );
      }
      for (final dimension in [0, 15, 513, 1000000]) {
        expect(
          () =>
              CompactImagePreparation.prepare(encoded, maxDimension: dimension),
          throwsArgumentError,
        );
      }
    });

    test('rejects empty, malformed, and oversized encoded files', () {
      for (final input in [
        Uint8List(0),
        Uint8List.fromList([0xff, 0xd8, 0x00]),
        Uint8List(CompactImagePreparation.maxEncodedBytes + 1),
      ]) {
        expect(
          () => CompactImagePreparation.prepare(input),
          throwsFormatException,
        );
        expect(
          () => CompactImagePreparation.previewInput(input),
          throwsFormatException,
        );
      }
    });

    test('rejects huge header dimensions before decoding a pixel buffer', () {
      final encoded = _png(_solid(1, 1));
      final header = ByteData.sublistView(encoded);
      header.setUint32(16, 4097);
      header.setUint32(20, 4097);
      header.setUint32(29, getCrc32(encoded.sublist(12, 29)));

      expect(
        () => CompactImagePreparation.prepare(encoded),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('decoded pixel limit'),
          ),
        ),
      );
      expect(
        () => CompactImagePreparation.previewInput(encoded),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('decoded pixel limit'),
          ),
        ),
      );
    });

    test(
      'preflights JPEG dimensions before its decoder can allocate DCT blocks',
      () {
        final encoded = image.encodeJpg(_solid(32, 32));
        var frame = -1;
        for (var offset = 0; offset + 1 < encoded.length; offset++) {
          if (encoded[offset] == 0xff && encoded[offset + 1] == 0xc0) {
            frame = offset;
            break;
          }
        }
        expect(frame, greaterThanOrEqualTo(0));
        final data = ByteData.sublistView(encoded);
        data.setUint16(frame + 5, 4097);
        data.setUint16(frame + 7, 4097);

        for (final preflight in <void Function()>[
          () => CompactImagePreparation.previewInput(encoded),
          () => CompactImagePreparation.prepare(encoded),
        ]) {
          expect(
            preflight,
            throwsA(
              isA<FormatException>().having(
                (error) => error.message,
                'message',
                contains('decoded pixel limit'),
              ),
            ),
          );
        }
      },
    );

    test(
      'checks JPEG receiver-specific bounds and malformed component sampling',
      () {
        final source = image.encodeJpg(_solid(64, 64));
        expect(
          () => CompactImagePreparation.previewInput(source, maxDimension: 32),
          throwsFormatException,
        );
        expect(
          () =>
              CompactImagePreparation.previewInput(source, maxPixels: 64 * 63),
          throwsFormatException,
        );
        final malformed = Uint8List.fromList(source);
        for (var offset = 0; offset + 11 < malformed.length; offset++) {
          if (malformed[offset] == 0xff && malformed[offset + 1] == 0xc0) {
            malformed[offset + 11] = 0xff;
            break;
          }
        }
        expect(
          () => CompactImagePreparation.previewInput(malformed),
          throwsFormatException,
        );
        expect(
          () => CompactImagePreparation.previewInput(source, maxPixels: 0),
          throwsArgumentError,
        );
      },
    );
  });
}
