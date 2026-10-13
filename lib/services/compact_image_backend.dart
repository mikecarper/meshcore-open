import 'package:flutter/services.dart';

import '../models/compact_image_codec.dart';
import 'compact_image_preparation.dart';
import 'compact_image_worker.dart';

abstract class CompactImageBackend {
  Future<List<CompactImageCodecCapability>> capabilities();
  Future<Uint8List> encode(
    CompactImageCodec codec,
    PreparedCompactImage raster,
    int quality,
    Duration budget,
  );
  Future<CompactImageRaster> decode(
    CompactImageCodec codec,
    Uint8List bytes,
    Duration budget,
  );
  Future<void> cancel();
}

/// Native codecs on Android, plus portable metadata-free JPEG/palette PNG.
class LocalCompactImageBackend implements CompactImageBackend {
  LocalCompactImageBackend({MethodChannel? channel})
    : _channel =
          channel ??
          const MethodChannel('com.meshcore.meshcore_open/image_codec');
  final MethodChannel _channel;
  final CompactImageWorker _worker = CompactImageWorker();
  Set<String> _native = {};
  List<CompactImageCodecCapability>? _capabilities;

  @override
  Future<List<CompactImageCodecCapability>> capabilities() async {
    if (_capabilities != null) return _capabilities!;
    List<Object?> details = [];
    try {
      _native = (await _channel.invokeListMethod<String>('capabilities') ?? [])
          .toSet();
      details =
          await _channel.invokeListMethod<Object?>('capabilityDetails') ?? [];
    } on MissingPluginException {
      // Portable fallback is real encoding/decoding, not a placeholder.
    } on PlatformException {
      // A failed optional library does not disable JPEG and palette PNG.
    }
    return _capabilities = [
      for (final codec in CompactImageCodec.values)
        CompactImageCodecCapability(
          codec: codec,
          available:
              _native.contains(codec.wireName) ||
              codec == CompactImageCodec.jpeg ||
              codec == CompactImageCodec.png,
          reason: codec == CompactImageCodec.aeic
              ? 'AEIC needs the optional model and a 64-bit inference runtime; its decoder exceeds the 32-bit phone memory limit.'
              : _reason(details, codec.wireName),
        ),
    ];
  }

  String? _reason(List<Object?> details, String name) {
    for (final detail in details) {
      if (detail is Map && detail['codec'] == name) {
        return detail['reason'] as String?;
      }
    }
    return _native.contains(name) || ['jpeg', 'png'].contains(name)
        ? null
        : 'An encoder and decoder for this codec are not included on this platform.';
  }

  @override
  Future<Uint8List> encode(
    CompactImageCodec codec,
    PreparedCompactImage raster,
    int quality,
    Duration budget,
  ) async {
    await capabilities();
    // Palette quantization is part of the PNG search, not Bitmap lossless PNG.
    if (_native.contains(codec.wireName) && codec != CompactImageCodec.png) {
      final result = await _channel.invokeMethod<Uint8List>('encode', {
        'codec': codec.wireName,
        'width': raster.width,
        'height': raster.height,
        'rgba': raster.rgba,
        'quality': quality,
        'deadlineMs': budget.inMilliseconds,
      });
      if (result == null || result.isEmpty) {
        throw StateError('The encoder returned no image.');
      }
      return result;
    }
    return _worker.run<Uint8List>({
      'op': 'encode',
      'codec': codec.wireName,
      'width': raster.width,
      'height': raster.height,
      'rgba': raster.rgba,
      'quality': quality,
    }, budget);
  }

  @override
  Future<CompactImageRaster> decode(
    CompactImageCodec codec,
    Uint8List bytes,
    Duration budget,
  ) async {
    await capabilities();
    if (_native.contains(codec.wireName)) {
      final result = await _channel.invokeMapMethod<String, Object?>('decode', {
        'codec': codec.wireName,
        'bytes': bytes,
        'deadlineMs': budget.inMilliseconds,
      });
      if (result == null) throw StateError('The decoder returned no image.');
      return CompactImageRaster(
        width: result['width']! as int,
        height: result['height']! as int,
        rgba: result['rgba']! as Uint8List,
      );
    }
    if (codec != CompactImageCodec.jpeg &&
        codec != CompactImageCodec.png &&
        codec != CompactImageCodec.webp) {
      throw UnsupportedError('No ${codec.label} decoder on this platform.');
    }
    return _worker.run<CompactImageRaster>({
      'op': 'decode',
      'codec': codec.wireName,
      'bytes': bytes,
    }, budget);
  }

  @override
  Future<void> cancel() async {
    _worker.cancel();
    try {
      await _channel.invokeMethod<void>('cancel');
    } on MissingPluginException {
      // No native work was started.
    }
  }
}
