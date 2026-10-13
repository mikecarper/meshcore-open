import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:meshcore_open/models/image_codec_support.dart';
import 'package:meshcore_open/services/compact_image_backend.dart';
import 'package:meshcore_open/services/compact_image_codec_service.dart';
import 'package:meshcore_open/services/compact_image_envelope.dart';
import 'package:meshcore_open/services/image_chunk_transport.dart';
import 'package:meshcore_open/services/received_image_store.dart';
import 'package:meshcore_open/widgets/image_send_codec_binding.dart';

const _channel = MethodChannel('test/compact_image_receive');
final _now = DateTime.utc(2026, 10, 13);

Uint8List _source() {
  final raster = image.Image(width: 160, height: 112, numChannels: 4);
  for (final p in raster) {
    p.setRgba(
      p.x * 255 ~/ 159,
      p.y * 255 ~/ 111,
      ((p.x * 3 + p.y) * 255 ~/ 588).clamp(0, 255),
      255,
    );
  }
  raster.addTextData({'Comment': 'camera-GPS-private-not-transmitted'});
  return image.encodePng(raster);
}

CompactImageCodecService _service() => CompactImageCodecService(
  backend: LocalCompactImageBackend(channel: _channel),
);

/// This adapter holds a separately instantiated receiver codec. The neural
/// path is a small test seam so routing can be verified without model files.
class _ReceiverDecoder
    implements ReceivedImageDecoder, CompactReceivedImageDecoder {
  _ReceiverDecoder(this.service);

  final CompactImageCodecService service;
  int compactCalls = 0;
  int neuralCalls = 0;
  int cancels = 0;
  bool rejectCompact = false;
  Completer<void>? blocked;
  Completer<void>? compactStarted;

  @override
  ImageCodecAvailability get availability => service.availability;

  @override
  bool get isBusy => service.isBusy;

  @override
  Future<ImageCodecResult?> decodeCompactBitstream(Uint8List bitstream) async {
    compactCalls++;
    if (compactStarted != null && !compactStarted!.isCompleted) {
      compactStarted!.complete();
    }
    if (blocked != null) await blocked!.future;
    if (rejectCompact) {
      throw const FormatException('The local decoder rejected the image.');
    }
    final png = await service.decodeToPng(bitstream);
    return ImageCodecResult(
      pngBytes: png,
      ratePoint: AeicRatePoint.ft32,
      resolution: 512,
      durationMs: 1,
      status: ImageCodecStatus.completed,
    );
  }

  @override
  Future<ImageCodecResult?> decodeBitstream({
    required Uint8List bitstream,
    required AeicRatePoint ratePoint,
    required int resolution,
  }) async {
    neuralCalls++;
    final pixels = image.Image(width: 2, height: 2, numChannels: 3);
    pixels.clear(image.ColorRgb8(20, 40, 60));
    return ImageCodecResult(
      pngBytes: image.encodePng(pixels),
      ratePoint: ratePoint,
      resolution: resolution,
      durationMs: 1,
      status: ImageCodecStatus.completed,
    );
  }

  @override
  void cancelCodecJob() {
    cancels++;
    if (blocked != null && !blocked!.isCompleted) {
      blocked!.completeError(const CompactImageCancelled());
    }
    unawaited(service.cancelEncode());
  }
}

typedef _Receiver = ({
  ReceivedImageStore store,
  InMemoryReceivedImageBlobStore blobs,
  _ReceiverDecoder decoder,
  ImageReassembler reassembler,
});

_Receiver _receiver({
  InMemoryReceivedImageBlobStore? blobs,
  bool automatic = true,
}) {
  final decoder = _ReceiverDecoder(_service());
  final storage = blobs ?? InMemoryReceivedImageBlobStore();
  final store = ReceivedImageStore(
    blobs: storage,
    decoder: decoder,
    processAutomatically: automatic,
    clock: () => _now,
  );
  return (
    store: store,
    blobs: storage,
    decoder: decoder,
    reassembler: ImageReassembler(selfPrefix: 0xbeef, clock: () => _now),
  );
}

void _disposeReceiver(_Receiver receiver) {
  receiver.store.dispose();
  receiver.decoder.service.dispose();
}

Future<ReceivedImageEntry> _deliver(
  _Receiver receiver,
  Uint8List payload, {
  int imgId = 42,
  int? missing,
  ImageCodecRatePoint rate = ImageCodecRatePoint.compact,
}) async {
  final chunks = buildImageChunks(
    payload: payload,
    metadata: ImageStreamMetadata(rate: rate, aspectCode: 0),
    senderPrefix: 0x1a2b,
    imgId: imgId,
    parity: missing != null,
  );
  if (missing != null) expect(chunks.dataChunkCount, greaterThan(missing));
  final order = <int>[
    if (missing != null) chunks.dataChunkCount,
    for (var index = chunks.dataChunkCount - 1; index >= 0; index--)
      if (index != missing) index,
  ];
  for (final index in order) {
    final outcome = receiver.reassembler.addChunk(
      chunks.blobs[index],
      channelIndex: 3,
    );
    await receiver.store.handleOutcome(outcome, channelIndex: 3);
  }
  final entry = receiver.store.entries.singleWhere(
    (entry) => entry.imgId == imgId,
  );
  expect(await receiver.blobs.readBitstream(entry.streamId), payload);
  return entry;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
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
        .setMockMethodCallHandler(_channel, null);
  });

  test(
    'compact metadata uses code 2 and preserves every legal aspect/resolution combination',
    () {
      expect(imageRateWireCode(ImageCodecRatePoint.compact), 2);
      expect(imageRatePointFromWireCode(2), ImageCodecRatePoint.compact);
      expect(ImageStreamMetadata.decode(2)!.rate, ImageCodecRatePoint.compact);
      expect(imageRatePointFromWireCode(3), isNull);
      for (final size in kImageResolutionCodes) {
        for (var aspect = 0; aspect < kImageAspectCodes.length; aspect++) {
          final metadata = ImageStreamMetadata(
            rate: ImageCodecRatePoint.compact,
            squareSize: size,
            aspectCode: aspect,
          );
          expect(metadata.encode() & 3, 2);
          expect(ImageStreamMetadata.decode(metadata.encode()), metadata);
        }
      }
    },
  );

  for (final codec in [CompactImageCodec.jpeg, CompactImageCodec.png]) {
    for (final target in [1024, 2048]) {
      test(
        '${codec.label} $target-byte image reassembles out of order with one lost chunk and displays on another decoder',
        () async {
          final sender = _service();
          addTearDown(sender.dispose);
          final result = await sender.compress(
            _source(),
            targetBytes: target,
            codecs: [codec],
          );
          expect(result.payload.length, lessThanOrEqualTo(target));
          final receiver = _receiver();
          addTearDown(() => _disposeReceiver(receiver));
          expect(identical(sender, receiver.decoder.service), isFalse);
          final entry = await _deliver(
            receiver,
            result.payload,
            missing: target == 1024 ? 0 : 1,
          );
          await receiver.store.settle();
          final decoded = receiver.store.entryFor(entry.streamId)!;
          final display = await receiver.store.ensurePng(entry.streamId);
          final dimensions = image.decodePng(display!)!;

          expect(decoded.state, ReceivedImageState.decoded);
          expect(decoded.recoveredWithParity, isTrue);
          expect(decoded.metadataAssumed, isFalse);
          expect(decoded.formatRate, ImageCodecRatePoint.compact);
          expect(decoded.synthesized, isFalse);
          expect(decoded.displayAspectRatio, result.width / result.height);
          expect(
            [dimensions.width, dimensions.height],
            [result.width, result.height],
          );
          expect(display, result.previewPng);
          expect(
            latin1.decode(display, allowInvalid: true),
            isNot(contains('camera-GPS-private')),
          );
          expect(receiver.decoder.compactCalls, 1);
          expect(receiver.decoder.neuralCalls, 0);
        },
      );
    }
  }

  test(
    'compact format and decoded aspect survive persistence and lazy PNG reload',
    () async {
      final sender = _service();
      addTearDown(sender.dispose);
      final result = await sender.compress(
        _source(),
        codecs: [CompactImageCodec.jpeg],
      );
      final first = _receiver();
      final entry = await _deliver(first, result.payload);
      await first.store.settle();
      final stored =
          jsonDecode((await first.blobs.readSidecars())[entry.streamId]!)
              as Map<String, dynamic>;
      expect(stored['format_rate'], 'compact');
      expect(stored['compact_aspect_ratio'], result.width / result.height);
      expect(stored['synthesized'], isFalse);
      _disposeReceiver(first);

      final restored = _receiver(blobs: first.blobs, automatic: false);
      addTearDown(() => _disposeReceiver(restored));
      await restored.store.load();
      final decoded = restored.store.entryFor(entry.streamId)!;

      expect(decoded.state, ReceivedImageState.decoded);
      expect(decoded.formatRate, ImageCodecRatePoint.compact);
      expect(decoded.displayAspectRatio, result.width / result.height);
      expect(decoded.synthesized, isFalse);
      expect(decoded.pngBytes, isNull);
      expect(await restored.store.ensurePng(entry.streamId), result.previewPng);
      expect(restored.decoder.compactCalls, 0);
      expect(restored.decoder.neuralCalls, 0);
    },
  );

  test(
    'a pending compact image reloads and uses the compact decoder on explicit retry',
    () async {
      final sender = _service();
      addTearDown(sender.dispose);
      final result = await sender.compress(
        _source(),
        codecs: [CompactImageCodec.png],
      );
      final first = _receiver(automatic: false);
      final entry = await _deliver(first, result.payload);
      expect(entry.state, ReceivedImageState.reassembled);
      expect(entry.needsManualDecode, isTrue);
      expect(entry.displayAspectRatio, isNull);
      expect(first.decoder.compactCalls, 0);
      _disposeReceiver(first);

      final restored = _receiver(blobs: first.blobs, automatic: false);
      addTearDown(() => _disposeReceiver(restored));
      await restored.store.load();
      final pending = restored.store.entryFor(entry.streamId)!;
      expect(pending.formatRate, ImageCodecRatePoint.compact);
      expect(pending.needsManualDecode, isTrue);
      await restored.store.requestDecode(entry.streamId);

      final decoded = restored.store.entryFor(entry.streamId)!;
      expect(decoded.state, ReceivedImageState.decoded);
      expect(decoded.displayAspectRatio, result.width / result.height);
      expect(await restored.store.ensurePng(entry.streamId), result.previewPng);
      expect(restored.decoder.compactCalls, 1);
      expect(restored.decoder.neuralCalls, 0);
    },
  );

  test(
    'a rejected decoder writes no PNG and the intact bitstream can be retried',
    () async {
      final sender = _service();
      addTearDown(sender.dispose);
      final result = await sender.compress(
        _source(),
        codecs: [CompactImageCodec.jpeg],
      );
      final receiver = _receiver();
      addTearDown(() => _disposeReceiver(receiver));
      receiver.decoder.rejectCompact = true;
      final entry = await _deliver(receiver, result.payload);
      await receiver.store.settle();
      final failed = receiver.store.entryFor(entry.streamId)!;

      expect(failed.state, ReceivedImageState.failedCorrupt);
      expect(failed.canRetryDecode, isTrue);
      expect(failed.pngStored, isFalse);
      expect(receiver.blobs.hasPng(entry.streamId), isFalse);
      expect(await receiver.store.ensurePng(entry.streamId), isNull);
      expect(
        await receiver.blobs.readBitstream(entry.streamId),
        result.payload,
      );
      receiver.decoder.rejectCompact = false;
      await receiver.store.requestDecode(entry.streamId);
      expect(
        receiver.store.entryFor(entry.streamId)!.state,
        ReceivedImageState.decoded,
      );
      expect(await receiver.store.ensurePng(entry.streamId), result.previewPng);
      expect(receiver.decoder.neuralCalls, 0);
    },
  );

  test(
    'a corrupt envelope cannot overwrite an already decoded image or reach its codec',
    () async {
      final sender = _service();
      addTearDown(sender.dispose);
      final result = await sender.compress(
        _source(),
        codecs: [CompactImageCodec.jpeg],
      );
      final receiver = _receiver();
      addTearDown(() => _disposeReceiver(receiver));
      final good = await _deliver(receiver, result.payload, imgId: 40);
      await receiver.store.settle();
      final damaged = Uint8List.fromList(result.payload);
      damaged[damaged.length - 1] ^= 0x80;
      final bad = await _deliver(receiver, damaged, imgId: 41);
      await receiver.store.settle();

      expect(
        receiver.store.entryFor(good.streamId)!.state,
        ReceivedImageState.decoded,
      );
      expect(await receiver.store.ensurePng(good.streamId), result.previewPng);
      expect(
        receiver.store.entryFor(bad.streamId)!.state,
        ReceivedImageState.failedCorrupt,
      );
      expect(await receiver.store.ensurePng(bad.streamId), isNull);
      expect(receiver.blobs.hasPng(bad.streamId), isFalse);
      expect(receiver.decoder.compactCalls, 1);
      expect(receiver.decoder.neuralCalls, 0);
    },
  );

  test(
    'background cancellation parks the compact bitstream and resumes without corrupt pixels',
    () async {
      final sender = _service();
      addTearDown(sender.dispose);
      final result = await sender.compress(
        _source(),
        codecs: [CompactImageCodec.jpeg],
      );
      final receiver = _receiver();
      addTearDown(() => _disposeReceiver(receiver));
      receiver.decoder.blocked = Completer<void>();
      receiver.decoder.compactStarted = Completer<void>();
      final entry = await _deliver(receiver, result.payload);
      await receiver.decoder.compactStarted!.future;
      receiver.store.setForeground(false);
      await receiver.store.settle();

      expect(
        receiver.store.entryFor(entry.streamId)!.state,
        ReceivedImageState.reassembled,
      );
      expect(await receiver.store.ensurePng(entry.streamId), isNull);
      expect(receiver.blobs.hasPng(entry.streamId), isFalse);
      expect(receiver.decoder.cancels, 1);
      receiver.decoder.blocked = null;
      receiver.store.setForeground(true);
      await receiver.store.requestDecode(entry.streamId);

      expect(
        receiver.store.entryFor(entry.streamId)!.state,
        ReceivedImageState.decoded,
      );
      expect(await receiver.store.ensurePng(entry.streamId), result.previewPng);
    },
  );

  test(
    'incoming neural images retain the synthesized flag and original decoder route',
    () async {
      final receiver = _receiver();
      addTearDown(() => _disposeReceiver(receiver));
      final entry = await _deliver(
        receiver,
        Uint8List.fromList(List.generate(140, (index) => index)),
        rate: ImageCodecRatePoint.standard,
      );
      await receiver.store.settle();
      final decoded = receiver.store.entryFor(entry.streamId)!;

      expect(decoded.state, ReceivedImageState.decoded);
      expect(decoded.formatRate, ImageCodecRatePoint.standard);
      expect(decoded.synthesized, isTrue);
      expect(decoded.displayAspectRatio, isNull);
      expect(receiver.decoder.neuralCalls, 1);
      expect(receiver.decoder.compactCalls, 0);
    },
  );

  test(
    'aspect comes from the validated envelope instead of approximate chunk metadata',
    () async {
      final sender = _service();
      addTearDown(sender.dispose);
      final result = await sender.compress(
        _source(),
        codecs: [CompactImageCodec.jpeg],
      );
      final envelope = CompactImageEnvelope.decode(result.payload);
      final receiver = _receiver();
      addTearDown(() => _disposeReceiver(receiver));
      final entry = await _deliver(receiver, result.payload);
      await receiver.store.settle();
      final decoded = receiver.store.entryFor(entry.streamId)!;

      expect(decoded.aspectCode, 0);
      expect(envelope.width, isNot(envelope.height));
      expect(decoded.displayAspectRatio, envelope.width / envelope.height);
    },
  );
}
