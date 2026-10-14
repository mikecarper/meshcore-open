import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/image_chunk_transport.dart';
import 'package:meshcore_open/widgets/image_send_codec_binding.dart';

Uint8List nativeFile(int side, {int bytes = 137}) {
  final data = Uint8List.fromList(
    List<int>.generate(bytes, (i) => (i * 29 + 11) & 255),
  );
  ByteData.sublistView(data)
    ..setUint32(0, side, Endian.big)
    ..setUint32(4, side, Endian.big)
    ..setUint32(8, bytes - 12, Endian.big);
  return data;
}

ImageReassemblyResult? reassemble(List<Uint8List> blobs) {
  final receiver = ImageReassembler();
  ImageReassemblyResult? result;
  for (final blob in blobs) {
    result ??= receiver.addChunk(blob).result;
  }
  return result;
}

void main() {
  test('legacy metadata bytes and raw payloads remain unchanged', () {
    for (final rate in [
      ImageCodecRatePoint.standard,
      ImageCodecRatePoint.high,
    ]) {
      for (var code = 0; code < kImageResolutionCodes.length; code++) {
        for (var aspect = 0; aspect < 16; aspect++) {
          final metadata = ImageStreamMetadata(
            rate: rate,
            squareSize: kImageResolutionCodes[code],
            aspectCode: aspect,
          );
          expect(metadata.encode(), (aspect << 4) | (code << 2) | rate.index);
          expect(ImageStreamMetadata.decode(metadata.encode()), metadata);
          final payload = Uint8List.fromList([1, 2, 3, 4]);
          final chunks = buildImageChunks(
            payload: payload,
            metadata: metadata,
            senderPrefix: 0x1234,
            imgId: 1,
          );
          final received = reassemble(chunks.blobs);
          expect(received?.metadata, metadata);
          expect(received?.data, payload);
        }
      }
    }
  });

  test('all eight native sizes use wire2 and resolve from the full header', () {
    expect(kNativeImageCodecResolutions, [
      128,
      192,
      256,
      320,
      384,
      448,
      512,
      576,
    ]);
    for (final side in kNativeImageCodecResolutions) {
      for (var aspect = 0; aspect < 16; aspect++) {
        final payload = nativeFile(side);
        final metadata = ImageStreamMetadata(
          rate: ImageCodecRatePoint.nativeFt2,
          squareSize: side,
          aspectCode: aspect,
        );
        expect(metadata.encode(), (aspect << 4) | 2);
        final pending = ImageStreamMetadata.decode(metadata.encode())!;
        expect(pending.squareSize, 0);
        expect(pending.resolvePayload(payload), metadata);
        final chunks = buildImageChunks(
          payload: payload,
          metadata: metadata,
          senderPrefix: 0x4321,
          imgId: 2,
        );
        final received = reassemble(chunks.blobs);
        expect(received?.metadata, metadata);
        expect(received?.data, payload);
      }
    }
  });

  test(
    'native metadata survives out of order delivery and one parity repair',
    () {
      final payload = nativeFile(576, bytes: 1783);
      const metadata = ImageStreamMetadata(
        rate: ImageCodecRatePoint.nativeFt2,
        squareSize: 576,
      );
      final chunks = buildImageChunks(
        payload: payload,
        metadata: metadata,
        senderPrefix: 0x4321,
        imgId: 3,
      );
      final delivered = <Uint8List>[
        for (var i = chunks.blobs.length - 1; i >= 0; i--)
          if (i != 3) chunks.blobs[i],
      ];
      final received = reassemble(delivered);
      expect(received?.metadata, metadata);
      expect(received?.data, payload);
      expect(received?.recoveredWithParity, isTrue);
    },
  );

  test('native headers reject invalid sizes, mismatched axes and lengths', () {
    final pending = ImageStreamMetadata.decode(2)!;
    for (final size in [0, 64, 96, 127, 129, 192 + 1, 640, 1024, 0xffffffff]) {
      expect(pending.resolvePayload(nativeFile(size)), isNull, reason: '$size');
    }
    for (final field in [0, 4, 8]) {
      final payload = nativeFile(128);
      ByteData.sublistView(payload).setUint32(field, 0xffffffff, Endian.big);
      expect(pending.resolvePayload(payload), isNull, reason: 'field $field');
    }
    final rectangular = nativeFile(128);
    ByteData.sublistView(rectangular).setUint32(4, 192, Endian.big);
    expect(pending.resolvePayload(rectangular), isNull);
    final wrongLength = nativeFile(128);
    ByteData.sublistView(wrongLength).setUint32(8, 126, Endian.big);
    expect(pending.resolvePayload(wrongLength), isNull);
    for (final length in [0, 11, 12]) {
      expect(pending.resolvePayload(Uint8List(length)), isNull);
    }
  });

  test('native file capacity includes the twelve-byte header', () {
    expect(kImageMaxPayloadBytes, 2369);
    final pending = ImageStreamMetadata.decode(2)!;
    expect(pending.resolvePayload(nativeFile(128, bytes: 2369)), isNotNull);
    expect(pending.resolvePayload(nativeFile(128, bytes: 2370)), isNull);
    expect(
      () => buildImageChunks(
        payload: nativeFile(128, bytes: 2370),
        metadata: const ImageStreamMetadata(
          rate: ImageCodecRatePoint.nativeFt2,
          squareSize: 128,
        ),
        senderPrefix: 1,
        imgId: 1,
      ),
      throwsArgumentError,
    );
  });

  test('sender refuses a header that disagrees with the chosen resolution', () {
    expect(
      () => buildImageChunks(
        payload: nativeFile(192),
        metadata: const ImageStreamMetadata(
          rate: ImageCodecRatePoint.nativeFt2,
          squareSize: 128,
        ),
        senderPrefix: 1,
        imgId: 1,
      ),
      throwsArgumentError,
    );
  });

  test('unknown rate and nonzero native resolution bits are rejected', () {
    for (var aspect = 0; aspect < 16; aspect++) {
      for (final low in [3, 6, 10, 14]) {
        expect(ImageStreamMetadata.decode((aspect << 4) | low), isNull);
      }
    }
  });

  test(
    'bounded native length damage survives reassembly for explicit recovery',
    () {
      final payload = nativeFile(128);
      ByteData.sublistView(payload).setUint32(8, 0xffffffff, Endian.big);
      // Build as a legacy payload, then announce native2 to simulate a peer.
      final chunks = buildImageChunks(
        payload: payload,
        metadata: const ImageStreamMetadata(rate: ImageCodecRatePoint.standard),
        senderPrefix: 1,
        imgId: 9,
        parity: false,
      );
      final blob = Uint8List.fromList(chunks.blobs.single);
      blob[kImageChunkHeaderBytes] = 2;
      final outcome = ImageReassembler().addChunk(blob);
      expect(outcome.status, ImageChunkStatus.completed);
      expect(outcome.result?.metadata?.squareSize, 128);
      expect(outcome.result?.data, payload);
      expect(NativeImageBitstreamHeader.tryParse(outcome.result!.data), isNull);
    },
  );

  test(
    'completed chunks can retain a truncated file with valid dimensions',
    () {
      final full = nativeFile(128);
      final truncated = Uint8List.sublistView(full, 0, full.length - 7);
      final chunks = buildImageChunks(
        payload: truncated,
        metadata: const ImageStreamMetadata(rate: ImageCodecRatePoint.standard),
        senderPrefix: 1,
        imgId: 10,
        parity: false,
      );
      final blob = Uint8List.fromList(chunks.blobs.single);
      blob[kImageChunkHeaderBytes] = 2;
      final outcome = ImageReassembler().addChunk(blob);
      expect(outcome.status, ImageChunkStatus.completed);
      expect(outcome.result?.metadata?.squareSize, 128);
      expect(outcome.result?.data, truncated);
      expect(NativeImageBitstreamHeader.tryParse(truncated), isNull);
    },
  );
}
