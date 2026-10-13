import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:meshcore_open/services/compact_image_backend.dart';
import 'package:meshcore_open/services/compact_image_codec_service.dart';
import 'package:meshcore_open/services/compact_image_envelope.dart';
import 'package:meshcore_open/services/compact_image_preparation.dart';
import 'package:meshcore_open/services/image_chunk_transport.dart';
import 'package:meshcore_open/widgets/image_send_codec_binding.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _BudgetBackend implements CompactImageBackend {
  _BudgetBackend(this.lengthFor);
  final int Function(PreparedCompactImage raster, int quality) lengthFor;
  final List<PreparedCompactImage> attempted = [];

  @override
  Future<List<CompactImageCodecCapability>> capabilities() async => const [
    CompactImageCodecCapability(codec: CompactImageCodec.jpeg, available: true),
  ];

  @override
  Future<Uint8List> encode(
    CompactImageCodec codec,
    PreparedCompactImage raster,
    int quality,
    Duration budget,
  ) async {
    attempted.add(raster);
    final bytes = Uint8List(lengthFor(raster, quality));
    final header = ByteData.sublistView(bytes);
    header.setUint16(0, raster.width, Endian.little);
    header.setUint16(2, raster.height, Endian.little);
    return bytes;
  }

  @override
  Future<CompactImageRaster> decode(
    CompactImageCodec codec,
    Uint8List bytes,
    Duration budget,
  ) async {
    final header = ByteData.sublistView(bytes);
    final width = header.getUint16(0, Endian.little);
    final height = header.getUint16(2, Endian.little);
    final rgba = Uint8List(width * height * 4);
    for (var offset = 0; offset < rgba.length; offset += 4) {
      rgba.setRange(offset, offset + 4, [18, 37, 73, 255]);
    }
    return CompactImageRaster(rgba: rgba, width: width, height: height);
  }

  @override
  Future<void> cancel() async {}
}

Uint8List _source({int size = 511}) {
  final raster = image.Image(width: size, height: size, numChannels: 4);
  raster.clear(image.ColorRgba8(18, 37, 73, 255));
  return image.encodePng(raster);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/compact_image_packet_budget');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
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

  test('defaults to 1 KB and eight total packets including parity', () {
    final service = CompactImageCodecService(
      backend: _BudgetBackend((raster, quality) => 100),
    );
    addTearDown(service.dispose);
    expect(service.targetBytes, 1024);
    expect(service.budgetIncludesParity, isTrue);
    expect(service.packetBudget, 8);
  });

  test(
    'every packet budget maps to the exact first and later chunk capacities',
    () {
      final service = CompactImageCodecService(
        backend: _BudgetBackend((raster, quality) => 100),
      );
      addTearDown(service.dispose);
      for (final parity in [true, false]) {
        for (var dataPackets = 1; dataPackets <= 15; dataPackets++) {
          final total = dataPackets + (parity ? 1 : 0);
          service.setPacketBudget(total, includeParity: parity);
          expect(service.packetBudget, total);
          expect(service.budgetIncludesParity, parity);
          expect(
            service.targetBytes,
            kImageChunkFirstCapacity + (dataPackets - 1) * kImageChunkCapacity,
          );
          expect(imageDataChunkCount(service.targetBytes), dataPackets);
        }
      }
      expect(service.targetBytes, CompactImageEnvelope.maxPayloadBytes);
      expect(service.targetBytes, 2369);
      for (final change in <void Function()>[
        () => service.setPacketBudget(1),
        () => service.setPacketBudget(17),
        () => service.setPacketBudget(0, includeParity: false),
        () => service.setPacketBudget(16, includeParity: false),
      ]) {
        expect(change, throwsArgumentError);
      }
    },
  );

  test(
    'preserves target and parity settings across service reconstruction',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final first = CompactImageCodecService(
        preferences: prefs,
        backend: _BudgetBackend((raster, quality) => 100),
      );
      first.setPacketBudget(5, includeParity: false);
      await Future<void>.delayed(Duration.zero);
      expect(
        prefs.getInt('image_compression_target_bytes'),
        kImageChunkFirstCapacity + 4 * kImageChunkCapacity,
      );
      expect(prefs.getBool('image_compression_parity'), isFalse);
      first.dispose();
      final restored = CompactImageCodecService(
        preferences: prefs,
        backend: _BudgetBackend((raster, quality) => 100),
      );
      addTearDown(restored.dispose);
      expect(restored.packetBudget, 5);
      expect(restored.budgetIncludesParity, isFalse);
      expect(restored.targetBytes, 789);
      restored.setTargetBytes(1024);
      await Future<void>.delayed(Duration.zero);
      expect(restored.packetBudget, 7);
      expect(prefs.getInt('image_compression_target_bytes'), 1024);
      expect(prefs.getBool('image_compression_parity'), isFalse);
    },
  );

  test('ignores a saved target outside the radio framing limits', () async {
    for (final target in [
      14,
      0,
      -1,
      CompactImageEnvelope.maxPayloadBytes + 1,
    ]) {
      SharedPreferences.setMockInitialValues({
        'image_compression_target_bytes': target,
      });
      final service = CompactImageCodecService(
        preferences: await SharedPreferences.getInstance(),
        backend: _BudgetBackend((raster, quality) => 100),
      );
      expect(service.targetBytes, 1024);
      expect(service.packetBudget, 8);
      service.dispose();
    }
  });

  test(
    'compares both block variants at the first fitting resolution then stops',
    () async {
      final backend = _BudgetBackend(
        (raster, quality) => raster.blockSize == 32 ? 100 : 300,
      );
      final service = CompactImageCodecService(backend: backend);
      addTearDown(service.dispose);
      final result = await service.compress(
        _source(),
        codecs: [CompactImageCodec.jpeg],
      );

      expect(backend.attempted.map((raster) => raster.resolutionStep).toSet(), {
        512,
      });
      expect(backend.attempted.map((raster) => raster.blockSize).toSet(), {
        16,
        32,
      });
      expect(result.blockSize, 32);
      expect(result.width, 480);
      expect(result.height, 480);
      expect(result.payload.length, 114);
    },
  );

  test(
    'uses the first fitting lower resolution without trying its remaining smaller levels',
    () async {
      final backend = _BudgetBackend(
        (raster, quality) => raster.resolutionStep >= 512 ? 1500 : 400,
      );
      final service = CompactImageCodecService(backend: backend);
      addTearDown(service.dispose);
      final result = await service.compress(
        _source(),
        codecs: [CompactImageCodec.jpeg],
      );

      expect(backend.attempted.map((raster) => raster.resolutionStep).toSet(), {
        512,
        384,
      });
      expect([result.width, result.height], [384, 384]);
    },
  );

  test(
    'never tries a 96/64 fallback and explains an over-budget 128 minimum',
    () async {
      final backend = _BudgetBackend((raster, quality) => 1500);
      final service = CompactImageCodecService(backend: backend);
      addTearDown(service.dispose);

      await expectLater(
        service.compress(_source(), codecs: [CompactImageCodec.jpeg]),
        throwsStateError,
      );
      expect(backend.attempted.map((raster) => raster.resolutionStep).toSet(), {
        512,
        384,
        256,
        192,
        128,
      });
      expect(
        backend.attempted.every(
          (raster) => raster.width >= 128 && raster.height >= 128,
        ),
        isTrue,
      );
      expect(
        service.attempts.single.status,
        CompactImageCodecAttemptStatus.overBudget,
      );
      expect(service.attempts.single.reason, contains('128-pixel minimum'));
      expect(service.attempts.single.reason, contains('more packets'));
    },
  );

  test(
    'rejects an input below the 128-pixel minimum before invoking a codec',
    () async {
      final backend = _BudgetBackend((raster, quality) => 100);
      final service = CompactImageCodecService(backend: backend);
      addTearDown(service.dispose);

      await expectLater(
        service.compress(_source(size: 64), codecs: [CompactImageCodec.jpeg]),
        throwsFormatException,
      );
      expect(backend.attempted, isEmpty);
      expect(service.isBusy, isFalse);
    },
  );

  test(
    'actual chunk sets respect total budgets with and without parity',
    () async {
      late CompactImageCodecService service;
      final backend = _BudgetBackend(
        (raster, quality) =>
            service.targetBytes - CompactImageEnvelope.headerBytes,
      );
      service = CompactImageCodecService(backend: backend);
      addTearDown(service.dispose);
      var imgId = 0;
      for (final parity in [true, false]) {
        for (final dataPackets in [1, 7, 15]) {
          final total = dataPackets + (parity ? 1 : 0);
          service.setPacketBudget(total, includeParity: parity);
          final result = await service.compress(
            _source(size: 128),
            codecs: [CompactImageCodec.jpeg],
          );
          final chunks = buildImageChunks(
            payload: result.payload,
            metadata: const ImageStreamMetadata(
              rate: ImageCodecRatePoint.compact,
            ),
            senderPrefix: 0x1a2b,
            imgId: imgId++,
            parity: parity,
          );
          expect(result.payload.length, service.targetBytes);
          expect(chunks.dataChunkCount, dataPackets);
          expect(chunks.blobs.length, total);
          expect(chunks.hasParity, parity);
          expect(
            result.payload.length,
            lessThanOrEqualTo(CompactImageEnvelope.maxPayloadBytes),
          );
        }
      }
    },
  );

  test(
    'real colored JPEG/PNG stay at least 128 pixels while honoring a 1 KB target',
    () async {
      final raster = image.Image(width: 160, height: 112, numChannels: 4);
      for (final p in raster) {
        p.setRgba(
          p.x * 255 ~/ 159,
          p.y * 255 ~/ 111,
          ((p.x * 3 + p.y) * 255 ~/ 588).clamp(0, 255),
          255,
        );
      }
      final source = image.encodePng(raster);
      for (final codec in [CompactImageCodec.jpeg, CompactImageCodec.png]) {
        final service = CompactImageCodecService(
          backend: LocalCompactImageBackend(channel: channel),
        );
        final result = await service.compress(source, codecs: [codec]);
        expect(result.payload.length, lessThanOrEqualTo(1024));
        expect(result.width >= 128 || result.height >= 128, isTrue);
        final decoded = image.decodePng(
          await service.decodeToPng(result.payload),
        )!;
        expect([decoded.width, decoded.height], [result.width, result.height]);
        service.dispose();
      }
    },
  );
}
