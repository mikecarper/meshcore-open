import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;

import '../models/compact_image_codec.dart';
import 'image_chunk_transport.dart' show kImageMaxPayloadBytes;

/// Essential decoding information only, never camera metadata.
/// MCI1 | codec:u8 | block:u8 | width:u16le | height:u16le | CRC32:u32le.
class CompactImageEnvelope {
  const CompactImageEnvelope({
    required this.codec,
    required this.width,
    required this.height,
    required this.blockSize,
    required this.bitstream,
  });
  static const int headerBytes = 14;
  static const int maxPayloadBytes = kImageMaxPayloadBytes;
  static const int maxDimension = 512;
  static const List<int> _magic = [0x4d, 0x43, 0x49, 0x31];

  final CompactImageCodec codec;
  final int width;
  final int height;
  final int blockSize;
  final Uint8List bitstream;

  Uint8List encode() {
    _validate();
    final result = Uint8List(headerBytes + bitstream.length);
    result.setRange(0, 4, _magic);
    result[4] = codec.wireId;
    result[5] = blockSize;
    final data = ByteData.sublistView(result);
    data.setUint16(6, width, Endian.little);
    data.setUint16(8, height, Endian.little);
    data.setUint32(10, getCrc32(bitstream), Endian.little);
    result.setRange(headerBytes, result.length, bitstream);
    return result;
  }

  static bool hasMagic(Uint8List bytes) =>
      bytes.length >= 4 &&
      List.generate(4, (i) => bytes[i] == _magic[i]).every((v) => v);

  static CompactImageEnvelope decode(Uint8List bytes) {
    if (bytes.length <= headerBytes ||
        bytes.length > maxPayloadBytes ||
        !hasMagic(bytes)) {
      throw const FormatException('Invalid compact image envelope.');
    }
    final codec = CompactImageCodec.fromId(bytes[4]);
    if (codec == null) {
      throw const FormatException('Unsupported compact image codec.');
    }
    final data = ByteData.sublistView(bytes);
    final bitstream = Uint8List.sublistView(bytes, headerBytes);
    if (data.getUint32(10, Endian.little) != getCrc32(bitstream)) {
      throw const FormatException('Compact image checksum mismatch.');
    }
    final envelope = CompactImageEnvelope(
      codec: codec,
      width: data.getUint16(6, Endian.little),
      height: data.getUint16(8, Endian.little),
      blockSize: bytes[5],
      bitstream: bitstream,
    );
    envelope._validate();
    return envelope;
  }

  void _validate() {
    if (width < 1 ||
        height < 1 ||
        width > maxDimension ||
        height > maxDimension ||
        ![1, 16, 32].contains(blockSize) ||
        width % blockSize != 0 ||
        height % blockSize != 0 ||
        bitstream.isEmpty ||
        bitstream.length + headerBytes > maxPayloadBytes) {
      throw const FormatException('Invalid compact image dimensions or size.');
    }
  }
}
