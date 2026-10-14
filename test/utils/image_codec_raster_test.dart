import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/utils/image_codec_raster.dart';

Future<Uint8List> _stripedPhoto({required bool portrait}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  const colors = [
    ui.Color(0xffff0000),
    ui.Color(0xff00ff00),
    ui.Color(0xff0000ff),
  ];
  for (var band = 0; band < 3; band++) {
    canvas.drawRect(
      portrait
          ? ui.Rect.fromLTWH(0, band * 20.0, 20, 20)
          : ui.Rect.fromLTWH(band * 20.0, 0, 20, 20),
      ui.Paint()..color = colors[band],
    );
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(portrait ? 20 : 60, portrait ? 60 : 20);
  try {
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    return png!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

List<int> _rgb(Uint8List pixels, int side, int x, int y) {
  final offset = (y * side + x) * 4;
  return pixels.sublist(offset, offset + 3);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final portrait in [false, true]) {
    final orientation = portrait ? 'portrait' : 'landscape';
    test(
      'native $orientation photo uses only its center square at 128',
      () async {
        final source = await _stripedPhoto(portrait: portrait);
        final image = await renderImageCodecSquare(
          source,
          resolution: 128,
          centerCrop: true,
        );
        try {
          expect(image.width, 128);
          expect(image.height, 128);
          final rgba = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!.buffer.asUint8List();
          for (final coordinate in [16, 64, 112]) {
            expect(
              _rgb(
                rgba,
                128,
                portrait ? 64 : coordinate,
                portrait ? coordinate : 64,
              ),
              [0, 255, 0],
            );
          }
        } finally {
          image.dispose();
        }
      },
    );
    test(
      'legacy $orientation photo retains all bands stretched to 512',
      () async {
        final source = await _stripedPhoto(portrait: portrait);
        final image = await renderImageCodecSquare(source, resolution: 512);
        try {
          expect(image.width, 512);
          expect(image.height, 512);
          final rgba = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!.buffer.asUint8List();
          const coordinates = [64, 256, 448];
          const colors = [
            [255, 0, 0],
            [0, 255, 0],
            [0, 0, 255],
          ];
          for (var band = 0; band < 3; band++) {
            expect(
              _rgb(
                rgba,
                512,
                portrait ? 256 : coordinates[band],
                portrait ? coordinates[band] : 256,
              ),
              colors[band],
            );
          }
        } finally {
          image.dispose();
        }
      },
    );
  }
}
