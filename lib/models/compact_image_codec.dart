import 'dart:typed_data';

/// Stable identifiers in the MCI1 envelope. Never reorder or reuse a value.
enum CompactImageCodec {
  webp(1, 'webp', 'WebP'),
  jpeg(2, 'jpeg', 'JPEG'),
  png(3, 'png', 'PNG palette'),
  avif(4, 'avif', 'AVIF'),
  bpg(5, 'bpg', 'BPG'),
  jxl(6, 'jxl', 'JPEG XL'),
  jp2(7, 'jp2', 'JPEG 2000'),
  heic(8, 'heic', 'HEIC'),
  vvc(9, 'vvc', 'VVC'),
  aeic(10, 'aeic', 'AEIC');

  const CompactImageCodec(this.wireId, this.wireName, this.label);
  final int wireId;
  final String wireName;
  final String label;

  static CompactImageCodec? fromId(int value) {
    for (final codec in values) {
      if (codec.wireId == value) return codec;
    }
    return null;
  }
}

class CompactImageCodecCapability {
  const CompactImageCodecCapability({
    required this.codec,
    required this.available,
    this.reason,
  });
  final CompactImageCodec codec;
  final bool available;
  final String? reason;
}

enum CompactImageCodecAttemptStatus {
  completed,
  unavailable,
  timedOut,
  failed,
  overBudget,
}

class CompactImageCodecAttempt {
  const CompactImageCodecAttempt({
    required this.codec,
    required this.status,
    required this.elapsedMs,
    this.encodedBytes,
    this.width,
    this.height,
    this.blockSize,
    this.reason,
  });
  final CompactImageCodec codec;
  final CompactImageCodecAttemptStatus status;
  final int elapsedMs;
  final int? encodedBytes;
  final int? width;
  final int? height;
  final int? blockSize;
  final String? reason;

  Map<String, Object?> toJson() => {
    'codec': codec.wireName,
    'status': status.name,
    'elapsed_ms': elapsedMs,
    if (encodedBytes != null) 'encoded_bytes': encodedBytes,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    if (blockSize != null) 'block_size': blockSize,
    if (reason != null) 'reason': reason,
  };
}

class CompactImageCompressionResult {
  const CompactImageCompressionResult({
    required this.payload,
    required this.previewPng,
    required this.codec,
    required this.width,
    required this.height,
    required this.blockSize,
    required this.quality,
    required this.score,
    required this.attempts,
  });
  final Uint8List payload;
  final Uint8List previewPng;
  final CompactImageCodec codec;
  final int width;
  final int height;
  final int blockSize;
  final int quality;
  final double score;
  final List<CompactImageCodecAttempt> attempts;

  Map<String, Object?> toJson() => {
    'codec': codec.wireName,
    'payload_bytes': payload.length,
    'display_png_bytes': previewPng.length,
    'width': width,
    'height': height,
    'block_size': blockSize,
    'quality': quality,
    'score': score,
    'attempts': attempts.map((a) => a.toJson()).toList(),
  };
}

class CompactImageRaster {
  const CompactImageRaster({
    required this.rgba,
    required this.width,
    required this.height,
  });
  final Uint8List rgba;
  final int width;
  final int height;
}

class CompactImageCancelled implements Exception {
  const CompactImageCancelled();
  @override
  String toString() => 'Image compression cancelled.';
}
