import 'dart:typed_data';

/// Minimal, dependency-free abstraction over the neural image codec used by
/// [ImageSendPreviewSheet].
///
/// The real implementation lives in `lib/services/image_codec_service.dart`
/// (`ImageCodecService implements ImageSendCodec`) and
/// `lib/services/image_chunk_transport.dart`. This file deliberately does NOT
/// import them, so the preview sheet can be built, analyzed and previewed on
/// its own and so the service depends on the UI contract rather than the other
/// way round.
///
// Packet-count and airtime maths deliberately live in
// `lib/utils/lora_airtime.dart`, not here.

/// Static square size of the legacy ONNX model.
const int kImageCodecSquareSize = 512;

const List<int> kNativeImageCodecResolutions = <int>[
  128,
  192,
  256,
  320,
  384,
  448,
  512,
  576,
];

/// The native file carries three big-endian uint32 values, followed by its
/// entropy payload. Rate code 2 identifies this container on the mesh.
class NativeImageBitstreamHeader {
  final int resolution;
  final int payloadBytes;

  const NativeImageBitstreamHeader._(this.resolution, this.payloadBytes);

  static NativeImageBitstreamHeader? tryParse(
    Uint8List bytes, {
    int maxFileBytes = 2369,
    bool allowPayloadLengthMismatch = false,
  }) {
    if (bytes.length <= 12 || bytes.length > maxFileBytes) return null;
    final header = ByteData.sublistView(bytes, 0, 12);
    final height = header.getUint32(0, Endian.big);
    final width = header.getUint32(4, Endian.big);
    final length = header.getUint32(8, Endian.big);
    if (height != width ||
        !kNativeImageCodecResolutions.contains(height) ||
        (!allowPayloadLengthMismatch && length != bytes.length - 12)) {
      return null;
    }
    return NativeImageBitstreamHeader._(height, length);
  }
}

/// Availability of the image codec, as far as the UI is concerned.
enum ImageCodecAvailability {
  /// The feature is switched off in app settings.
  disabled,

  /// The codec model is being fetched; the feature is temporarily unusable.
  downloading,

  /// The codec is usable right now.
  ready,

  /// The codec cannot run on this device/platform at all.
  unavailable,
}

/// Rate points the wire format can express.
///
/// The shipping build encodes at [standard] (`ft32`) only — see
/// [kImageSendRatePoint]. The enum keeps more than one value because the rate
/// point is written into the chunk-0 metadata byte by
/// `image_chunk_transport.dart`, so the ordinals are part of the wire format and
/// must stay stable even for rate points the UI never offers. Removing [high]
/// would renumber nothing today but would make a future rate point silently
/// reuse ordinal 1 and be decoded as ft16 by older builds.
enum ImageCodecRatePoint {
  /// `ft32` — the only rate point this build sends. Measured 110-209 B
  /// (mean 156 B) over 26 images, i.e. 1-2 data chunks plus parity.
  standard,

  /// `ft16` — larger, higher fidelity. **Not offered in the UI**: the model
  /// registry ships ft32 weights only. Retained so the ordinal stays reserved
  /// and so bitstreams produced elsewhere can still be identified on the wire.
  high,

  /// Native ncnn FT2 bundle. Appended; its explicit mesh wire code is 2.
  nativeFt2,
}

/// The single rate point the compose UI encodes at.
///
/// The quality selector was removed once ft32 became the only shipping model;
/// every send goes out at this rate. Named rather than inlined so a future
/// second rate point has one place to come back to.
const ImageCodecRatePoint kImageSendRatePoint = ImageCodecRatePoint.standard;

/// Measured payload statistics for a rate point, in bytes.
///
/// These are real measurements over 26 images of rANS bitstreams produced by
/// the codec at 512x512, not estimates. They let the sheet show a plausible
/// range instantly, before an encode has finished.
class ImageCodecRateStats {
  final int meanBytes;
  final int minBytes;
  final int maxBytes;

  const ImageCodecRateStats({
    required this.meanBytes,
    required this.minBytes,
    required this.maxBytes,
  });

  static const ImageCodecRateStats standard = ImageCodecRateStats(
    meanBytes: 156,
    minBytes: 110,
    maxBytes: 209,
  );

  /// Retained for [ImageCodecRatePoint.high], which the UI no longer offers.
  static const ImageCodecRateStats high = ImageCodecRateStats(
    meanBytes: 288,
    minBytes: 176,
    maxBytes: 409,
  );

  /// Single-photo native benchmark sizes, used only by the deterministic fake.
  /// The real preview waits for the actual encode instead of predicting size.
  static const ImageCodecRateStats nativeFt2 = ImageCodecRateStats(
    meanBytes: 137,
    minBytes: 137,
    maxBytes: 1783,
  );

  static ImageCodecRateStats forRate(ImageCodecRatePoint rate) {
    switch (rate) {
      case ImageCodecRatePoint.standard:
        return standard;
      case ImageCodecRatePoint.high:
        return high;
      case ImageCodecRatePoint.nativeFt2:
        return nativeFt2;
    }
  }
}

/// The encode interface the preview sheet consumes.
abstract class ImageSendCodec {
  ImageCodecRatePoint get sendRatePoint;
  List<int> get supportedResolutions;

  /// Current availability. The sheet renders a non-interactive explanation for
  /// anything other than [ImageCodecAvailability.ready].
  ImageCodecAvailability get availability;

  /// Why [availability] is [ImageCodecAvailability.unavailable], as one
  /// user-facing sentence, or null when the codec is not permanently
  /// unavailable.
  ///
  /// This is the sentence the compose sheet shows in place of its generic
  /// "not available on this device" string: `unavailable` is a permanent
  /// property of the build (no native runtime, no entropy path, backend failed
  /// to load) and the only useful thing the UI can do is say WHICH one it hit.
  /// Implementations must not return an empty string; return null instead.
  String? get unavailableReason;

  /// Encode [imageBytes] (any common still format) at [rate], returning the
  /// compressed bitstream that will be chunked onto the air.
  ///
  /// Implementations are expected to centre-crop to
  /// [kImageCodecSquareSize] square first.
  Future<Uint8List> encode(
    Uint8List imageBytes,
    ImageCodecRatePoint rate, {
    int? resolution,
  });
}

/// A deterministic stand-in used for widget previews and tests.
///
/// It produces a buffer of the measured mean size for the requested rate point
/// so the sheet can be exercised end-to-end without the real codec.
class FakeImageSendCodec implements ImageSendCodec {
  @override
  final ImageCodecRatePoint sendRatePoint;

  @override
  List<int> get supportedResolutions =>
      sendRatePoint == ImageCodecRatePoint.nativeFt2
      ? kNativeImageCodecResolutions
      : const <int>[kImageCodecSquareSize];

  @override
  final ImageCodecAvailability availability;

  /// Mirrors `ImageCodecService.unavailableReason`; null unless a test wants to
  /// exercise the "why can't I send?" path.
  @override
  final String? unavailableReason;

  final Duration latency;

  const FakeImageSendCodec({
    this.sendRatePoint = ImageCodecRatePoint.standard,
    this.availability = ImageCodecAvailability.ready,
    this.unavailableReason,
    this.latency = const Duration(milliseconds: 250),
  });

  @override
  Future<Uint8List> encode(
    Uint8List imageBytes,
    ImageCodecRatePoint rate, {
    int? resolution,
  }) async {
    if (latency > Duration.zero) {
      await Future<void>.delayed(latency);
    }
    final side =
        resolution ??
        (rate == ImageCodecRatePoint.nativeFt2 ? 128 : kImageCodecSquareSize);
    final size = rate == ImageCodecRatePoint.nativeFt2
        ? const <int, int>{
            128: 137,
            192: 270,
            256: 407,
            320: 602,
            384: 804,
            448: 1122,
            512: 1363,
            576: 1783,
          }[side]
        : ImageCodecRateStats.forRate(rate).meanBytes;
    if (size == null) throw ArgumentError.value(side, 'resolution');
    final bytes = Uint8List.fromList(
      List<int>.generate(size, (i) => (i * 31 + rate.index) & 0xFF),
    );
    if (rate == ImageCodecRatePoint.nativeFt2) {
      ByteData.sublistView(bytes)
        ..setUint32(0, side, Endian.big)
        ..setUint32(4, side, Endian.big)
        ..setUint32(8, size - 12, Endian.big);
    }
    return bytes;
  }
}
