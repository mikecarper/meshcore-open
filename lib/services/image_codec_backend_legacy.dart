import 'dart:typed_data';

import '../models/image_codec_support.dart';

/// The ONNX image codec cannot run on the Android 5.1 legacy build.
const bool kImageCodecBitstreamPathAvailable = false;

abstract class ImageCodecBackend {
  String get name;
  bool get supportsBitstreamCodec;

  Future<void> load(Object bundle);
  Future<Uint8List> decodeLatentToRgb({
    required Float32List yHat,
    void Function(double progress)? onProgress,
    bool Function()? shouldCancel,
  });
  Future<Uint8List> encode({
    required Uint8List rgbBytes,
    required AeicRatePoint ratePoint,
    required int resolution,
    void Function(double progress)? onProgress,
    bool Function()? shouldCancel,
  });
  Future<Uint8List> decode({
    required Uint8List bitstream,
    required AeicRatePoint ratePoint,
    required int resolution,
    void Function(double progress)? onProgress,
    bool Function()? shouldCancel,
  });
  Future<void> releaseDecoderSession();
  Future<void> releaseEntropySession();
  Future<void> dispose();
}

ImageCodecBackend? createImageCodecBackend() => null;
