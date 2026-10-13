import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:meshcore_open/services/compact_image_backend.dart';
import 'package:meshcore_open/services/compact_image_codec_service.dart';
import 'package:meshcore_open/services/compact_image_envelope.dart';
import 'package:meshcore_open/services/compact_image_preparation.dart';
import 'package:meshcore_open/widgets/image_send_codec_binding.dart';

typedef _Encode =
    Future<Uint8List> Function(
      CompactImageCodec codec,
      PreparedCompactImage raster,
      int quality,
      Duration budget,
    );
typedef _Decode =
    Future<CompactImageRaster> Function(
      CompactImageCodec codec,
      Uint8List bytes,
      Duration budget,
    );

class _ControlledBackend implements CompactImageBackend {
  _ControlledBackend({
    this.encodeFn,
    this.decodeFn,
    this.cancelFn,
    this.available = const {CompactImageCodec.jpeg},
  });

  _Encode? encodeFn;
  _Decode? decodeFn;
  Future<void> Function()? cancelFn;
  final Set<CompactImageCodec> available;
  final List<PreparedCompactImage> rasters = [];
  int encodes = 0;
  int decodes = 0;
  int cancels = 0;

  @override
  Future<List<CompactImageCodecCapability>> capabilities() async => [
    for (final codec in CompactImageCodec.values)
      CompactImageCodecCapability(
        codec: codec,
        available: available.contains(codec),
        reason: available.contains(codec)
            ? null
            : 'Unavailable on this test device.',
      ),
  ];

  @override
  Future<Uint8List> encode(
    CompactImageCodec codec,
    PreparedCompactImage raster,
    int quality,
    Duration budget,
  ) async {
    encodes++;
    rasters.add(raster);
    if (encodeFn != null) return encodeFn!(codec, raster, quality, budget);
    return _fakeBitstream(raster, 100);
  }

  @override
  Future<CompactImageRaster> decode(
    CompactImageCodec codec,
    Uint8List bytes,
    Duration budget,
  ) async {
    decodes++;
    if (decodeFn != null) return decodeFn!(codec, bytes, budget);
    final data = ByteData.sublistView(bytes);
    final width = data.getUint16(0, Endian.little);
    final height = data.getUint16(2, Endian.little);
    final pixels = Uint8List(width * height * 4);
    for (var offset = 0; offset < pixels.length; offset += 4) {
      pixels.setRange(offset, offset + 4, [20, 40, 60, 255]);
    }
    return CompactImageRaster(rgba: pixels, width: width, height: height);
  }

  @override
  Future<void> cancel() async {
    cancels++;
    await cancelFn?.call();
  }
}

Uint8List _fakeBitstream(PreparedCompactImage raster, int length) {
  final bytes = Uint8List(length);
  final data = ByteData.sublistView(bytes);
  data.setUint16(0, raster.width, Endian.little);
  data.setUint16(2, raster.height, Endian.little);
  return bytes;
}

Uint8List _solid({int width = 145, int height = 161}) {
  final raster = image.Image(width: width, height: height, numChannels: 4);
  raster.clear(image.ColorRgba8(20, 40, 60, 255));
  return image.encodePng(raster);
}

Uint8List _gradient() {
  final raster = image.Image(width: 160, height: 112, numChannels: 4);
  for (final pixel in raster) {
    pixel.setRgba(
      pixel.x * 255 ~/ 159,
      pixel.y * 255 ~/ 111,
      (pixel.x + pixel.y) * 255 ~/ 270,
      255,
    );
  }
  raster.addTextData({'Comment': 'private-camera-GPS-12345'});
  return image.encodePng(raster);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/compact_image_codec');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'capabilities' ||
              call.method == 'capabilityDetails') {
            return <Object?>[];
          }
          if (call.method == 'cancel') return null;
          throw PlatformException(
            code: 'UNEXPECTED_CALL',
            message: call.method,
          );
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('CompactImageCodecService real portable codecs', () {
    for (final codec in [CompactImageCodec.jpeg, CompactImageCodec.png]) {
      for (final target in [1024, 2048]) {
        test(
          '${codec.label} fits $target bytes and decodes to a fresh PNG',
          () async {
            final service = CompactImageCodecService(
              backend: LocalCompactImageBackend(channel: channel),
            );
            addTearDown(service.dispose);
            final result = await service.compress(
              _gradient(),
              targetBytes: target,
              codecs: [codec],
            );

            expect(result.codec, codec);
            expect(result.payload.length, lessThanOrEqualTo(target));
            expect(
              result.payload.length,
              greaterThan(CompactImageEnvelope.headerBytes),
            );
            expect(result.score.isFinite, isTrue);
            expect(
              result.attempts.single.status,
              CompactImageCodecAttemptStatus.completed,
            );
            expect(
              [
                result.width % result.blockSize,
                result.height % result.blockSize,
              ],
              [0, 0],
            );
            final envelope = CompactImageEnvelope.decode(result.payload);
            expect(envelope.codec, codec);
            final decodedPng = await service.decodeToPng(result.payload);
            final displayed = image.decodePng(decodedPng)!;
            expect(
              [displayed.width, displayed.height],
              [result.width, result.height],
            );
            expect(decodedPng, result.previewPng);
            expect(
              latin1.decode(decodedPng, allowInvalid: true),
              isNot(contains('private-camera-GPS')),
            );
            expect(displayed.textData, anyOf(isNull, isEmpty));
            expect(displayed.exif.imageIfd.imageDescription, isNull);
            expect(service.isBusy, isFalse);
          },
        );
      }
    }

    test(
      'rejects an envelope whose codec identifier disagrees with its actual bitstream',
      () async {
        final raster = image.Image(width: 32, height: 32, numChannels: 3);
        raster.clear(image.ColorRgb8(12, 24, 48));
        final payload = CompactImageEnvelope(
          codec: CompactImageCodec.png,
          width: 32,
          height: 32,
          blockSize: 16,
          bitstream: image.encodeJpg(raster),
        ).encode();
        final service = CompactImageCodecService(
          backend: LocalCompactImageBackend(channel: channel),
        );
        addTearDown(service.dispose);

        await expectLater(service.decodeToPng(payload), throwsFormatException);
        expect(service.isBusy, isFalse);
      },
    );
  });

  group('CompactImageCodecService transparency', () {
    test(
      'portable PNG retains the image alpha channel after palette quantization',
      () async {
        final source = image.Image(width: 128, height: 128, numChannels: 4);
        for (final p in source) {
          p.setRgba(20, 40, 60, p.x < 64 ? 64 : 192);
        }
        final service = CompactImageCodecService(
          backend: LocalCompactImageBackend(channel: channel),
        );
        addTearDown(service.dispose);
        final result = await service.compress(
          image.encodePng(source),
          targetBytes: 1024,
          codecs: [CompactImageCodec.png],
        );
        final decoded = image.decodePng(
          await service.decodeToPng(result.payload),
        )!;

        expect(result.payload.length, lessThanOrEqualTo(1024));
        expect(decoded.getPixel(decoded.width ~/ 4, decoded.height ~/ 2).a, 64);
        expect(
          decoded.getPixel(decoded.width * 3 ~/ 4, decoded.height ~/ 2).a,
          192,
        );
      },
    );

    test(
      'scores alpha fidelity so a smaller opaque image cannot beat a transparent reconstruction',
      () async {
        final source = image.Image(width: 145, height: 161, numChannels: 4);
        source.clear(image.ColorRgba8(20, 40, 60, 64));
        final backend = _ControlledBackend(
          available: const {CompactImageCodec.jpeg, CompactImageCodec.png},
          encodeFn: (codec, raster, quality, budget) async => _fakeBitstream(
            raster,
            codec == CompactImageCodec.jpeg ? 20 : 400,
          ),
          decodeFn: (codec, bytes, budget) async {
            final data = ByteData.sublistView(bytes);
            final width = data.getUint16(0, Endian.little);
            final height = data.getUint16(2, Endian.little);
            final rgba = Uint8List(width * height * 4);
            for (var offset = 0; offset < rgba.length; offset += 4) {
              rgba.setRange(offset, offset + 4, [
                20,
                40,
                60,
                codec == CompactImageCodec.jpeg ? 255 : 64,
              ]);
            }
            return CompactImageRaster(rgba: rgba, width: width, height: height);
          },
        );
        final service = CompactImageCodecService(backend: backend);
        addTearDown(service.dispose);
        final result = await service.compress(
          image.encodePng(source),
          codecs: [CompactImageCodec.jpeg, CompactImageCodec.png],
        );

        expect(result.codec, CompactImageCodec.png);
        expect(result.score, greaterThan(90));
        expect(image.decodePng(result.previewPng)!.getPixel(0, 0).a, 64);
      },
    );
  });

  group('CompactImageCodecService portfolio and lifecycle', () {
    test(
      'measures both 16 and 32 variants and chooses the smaller verified result',
      () async {
        final backend = _ControlledBackend(
          encodeFn: (codec, raster, quality, budget) async =>
              _fakeBitstream(raster, raster.blockSize == 32 ? 20 : 400),
        );
        final service = CompactImageCodecService(backend: backend);
        addTearDown(service.dispose);
        final result = await service.compress(
          _solid(),
          codecs: [CompactImageCodec.jpeg],
        );

        expect(
          backend.rasters.map((raster) => raster.blockSize),
          containsAll([16, 32]),
        );
        expect(result.blockSize, 32);
        expect(result.payload.length, 20 + CompactImageEnvelope.headerBytes);
        expect(result.attempts.single.blockSize, 32);
      },
    );

    test(
      'can prefer 16-pixel blocks when that verified result is smaller',
      () async {
        final backend = _ControlledBackend(
          encodeFn: (codec, raster, quality, budget) async =>
              _fakeBitstream(raster, raster.blockSize == 16 ? 20 : 400),
        );
        final service = CompactImageCodecService(backend: backend);
        addTearDown(service.dispose);
        final result = await service.compress(
          _solid(),
          codecs: [CompactImageCodec.jpeg],
        );

        expect(
          backend.rasters.map((raster) => raster.blockSize),
          containsAll([16, 32]),
        );
        expect(result.blockSize, 16);
        expect(result.payload.length, 34);
      },
    );

    test(
      'reports unavailable codecs and continues with an available codec',
      () async {
        final backend = _ControlledBackend(
          available: const {CompactImageCodec.jpeg},
        );
        final service = CompactImageCodecService(backend: backend);
        addTearDown(service.dispose);
        final result = await service.compress(
          _solid(),
          codecs: [CompactImageCodec.avif, CompactImageCodec.jpeg],
        );

        expect(result.attempts.map((attempt) => attempt.status), [
          CompactImageCodecAttemptStatus.unavailable,
          CompactImageCodecAttemptStatus.completed,
        ]);
        expect(result.attempts.first.reason, contains('Unavailable'));
        expect(result.codec, CompactImageCodec.jpeg);
        expect(backend.encodes, greaterThan(0));
      },
    );

    test(
      'does not select bytes that fit only when the envelope is excluded',
      () async {
        final backend = _ControlledBackend(
          encodeFn: (codec, raster, quality, budget) async =>
              _fakeBitstream(raster, 1011),
        );
        final service = CompactImageCodecService(backend: backend);
        addTearDown(service.dispose);

        await expectLater(
          service.compress(
            _solid(),
            targetBytes: 1024,
            codecs: [CompactImageCodec.jpeg],
          ),
          throwsStateError,
        );
        expect(
          service.attempts.single.status,
          CompactImageCodecAttemptStatus.overBudget,
        );
        expect(service.attempts.single.encodedBytes, 1025);
        expect(backend.decodes, 0);
        expect(service.result, isNull);
        expect(service.isBusy, isFalse);
      },
    );

    test(
      'rejects a decoder with dimensions that differ from the prepared raster',
      () async {
        final backend = _ControlledBackend(
          decodeFn: (codec, bytes, budget) async => CompactImageRaster(
            rgba: Uint8List(16 * 16 * 4),
            width: 16,
            height: 16,
          ),
        );
        final service = CompactImageCodecService(backend: backend);
        addTearDown(service.dispose);

        await expectLater(
          service.compress(_solid(), codecs: [CompactImageCodec.jpeg]),
          throwsStateError,
        );
        expect(
          service.attempts.single.status,
          CompactImageCodecAttemptStatus.failed,
        );
        expect(
          service.attempts.single.reason,
          contains('unexpected dimensions'),
        );
        expect(backend.cancels, 1);
        expect(service.isBusy, isFalse);
      },
    );

    test(
      'enforces a backend deadline even when its Future never completes',
      () async {
        final blocked = Completer<Uint8List>();
        final backend = _ControlledBackend(
          encodeFn: (codec, raster, quality, budget) => blocked.future,
        );
        final service = CompactImageCodecService(
          backend: backend,
          algorithmLimit: const Duration(milliseconds: 250),
        );
        addTearDown(service.dispose);

        await expectLater(
          service
              .compress(_solid(), codecs: [CompactImageCodec.jpeg])
              .timeout(const Duration(seconds: 5)),
          throwsStateError,
        );
        expect(
          service.attempts.single.status,
          CompactImageCodecAttemptStatus.timedOut,
        );
        expect(backend.cancels, 1);
        expect(service.isBusy, isFalse);
        backend.encodeFn = null;
        final result = await service.compress(
          _solid(),
          codecs: [CompactImageCodec.jpeg],
        );
        expect(result.payload.length, lessThanOrEqualTo(2048));
      },
    );

    test(
      'cancellation releases a blocked backend and ignores its late completion',
      () async {
        final entered = Completer<void>();
        final blocked = Completer<Uint8List>();
        PreparedCompactImage? raster;
        final backend = _ControlledBackend(
          encodeFn: (codec, current, quality, budget) {
            raster = current;
            if (!entered.isCompleted) entered.complete();
            return blocked.future;
          },
        );
        final service = CompactImageCodecService(backend: backend);
        addTearDown(service.dispose);
        final job = service.compress(
          _solid(),
          codecs: [CompactImageCodec.jpeg],
        );
        final assertion = expectLater(
          job.timeout(const Duration(seconds: 5)),
          throwsA(isA<CompactImageCancelled>()),
        );
        await entered.future;
        await service.cancelEncode();
        await assertion;
        expect(backend.cancels, greaterThanOrEqualTo(1));
        expect(service.isBusy, isFalse);
        expect(service.result, isNull);
        blocked.complete(_fakeBitstream(raster!, 100));
        await Future<void>.delayed(Duration.zero);
        expect(service.result, isNull);
      },
    );

    test('validates receive dimensions and CRC before showing a PNG', () async {
      final backend = _ControlledBackend(
        decodeFn: (codec, bytes, budget) async => CompactImageRaster(
          rgba: Uint8List(32 * 16 * 4),
          width: 32,
          height: 16,
        ),
      );
      final service = CompactImageCodecService(backend: backend);
      addTearDown(service.dispose);
      final payload = CompactImageEnvelope(
        codec: CompactImageCodec.jpeg,
        width: 32,
        height: 32,
        blockSize: 16,
        bitstream: Uint8List.fromList([1, 2, 3]),
      ).encode();

      await expectLater(service.decodeToPng(payload), throwsFormatException);
      expect(service.isBusy, isFalse);
      expect(backend.decodes, 1);
      payload[payload.length - 1] ^= 1;
      await expectLater(service.decodeToPng(payload), throwsFormatException);
      expect(backend.decodes, 1);
    });

    test(
      'waits for the previous backend stop acknowledgment before allowing another job',
      () async {
        final encodeEntered = Completer<void>();
        final cancelEntered = Completer<void>();
        final stopAcknowledged = Completer<void>();
        final blocked = Completer<Uint8List>();
        final backend = _ControlledBackend(
          encodeFn: (codec, raster, quality, budget) {
            if (!encodeEntered.isCompleted) encodeEntered.complete();
            return blocked.future;
          },
          cancelFn: () {
            if (!cancelEntered.isCompleted) cancelEntered.complete();
            return stopAcknowledged.future;
          },
        );
        final service = CompactImageCodecService(backend: backend);
        addTearDown(() {
          if (!stopAcknowledged.isCompleted) stopAcknowledged.complete();
          service.dispose();
        });
        final job = service.compress(
          _solid(),
          codecs: [CompactImageCodec.jpeg],
        );
        final assertion = expectLater(
          job,
          throwsA(isA<CompactImageCancelled>()),
        );
        await encodeEntered.future;
        final cancellation = service.cancelEncode();
        await cancelEntered.future;
        await assertion;

        expect(service.isBusy, isTrue);
        await expectLater(
          service.compress(_solid(), codecs: [CompactImageCodec.jpeg]),
          throwsStateError,
        );
        stopAcknowledged.complete();
        await cancellation;
        expect(service.isBusy, isFalse);
        backend.encodeFn = null;
        backend.cancelFn = null;
        final next = await service.compress(
          _solid(),
          codecs: [CompactImageCodec.jpeg],
        );
        expect(next.payload.length, lessThanOrEqualTo(2048));
      },
    );

    test(
      'keeps the distinct compact wire identifier and disabled-state contract',
      () async {
        final backend = _ControlledBackend();
        final service = CompactImageCodecService(
          enabled: () => false,
          backend: backend,
        );
        addTearDown(service.dispose);

        expect(service.availability, ImageCodecAvailability.disabled);
        await expectLater(
          service.encode(_solid(), ImageCodecRatePoint.compact),
          throwsStateError,
        );
        expect(backend.encodes, 0);
        final enabled = CompactImageCodecService(backend: backend);
        addTearDown(enabled.dispose);
        await expectLater(
          enabled.encode(_solid(), ImageCodecRatePoint.standard),
          throwsArgumentError,
        );
      },
    );
  });
}
