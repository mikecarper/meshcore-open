import 'dart:typed_data';
import 'dart:ui' as ui;

/// Rasterizes the pixels used by encoding and the sender's cached preview.
/// Native FT2 takes the centered square; legacy FT32 stretches the whole frame.
/// The caller owns the returned image and must dispose it.
Future<ui.Image> renderImageCodecSquare(
  Uint8List imageBytes, {
  required int resolution,
  bool centerCrop = false,
}) async {
  final codec = await ui.instantiateImageCodec(imageBytes);
  ui.Image? source;
  try {
    source = (await codec.getNextFrame()).image;
    final width = source.width.toDouble();
    final height = source.height.toDouble();
    final side = width < height ? width : height;
    final src = centerCrop
        ? ui.Rect.fromLTWH((width - side) / 2, (height - side) / 2, side, side)
        : ui.Rect.fromLTWH(0, 0, width, height);
    final dst = resolution.toDouble();
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      source,
      src,
      ui.Rect.fromLTWH(0, 0, dst, dst),
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(resolution, resolution);
    } finally {
      picture.dispose();
    }
  } finally {
    source?.dispose();
    codec.dispose();
  }
}
