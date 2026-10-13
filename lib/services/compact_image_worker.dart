import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import '../models/compact_image_codec.dart';
import 'compact_image_preparation.dart';

/// A killable worker, rather than Future.timeout around a live encoder.
class CompactImageWorker {
  Isolate? _isolate;
  Completer<Object?>? _active;

  Future<T> run<T>(Map<String, Object?> request, Duration budget) async {
    if (_active != null) throw StateError('An image worker is already active.');
    if (budget <= Duration.zero) {
      throw TimeoutException('Image codec deadline.');
    }
    final port = ReceivePort();
    final errors = ReceivePort();
    final done = Completer<Object?>();
    _active = done;
    final errorSub = errors.listen((error) {
      if (!done.isCompleted) done.completeError(StateError('$error'));
    });
    final outputSub = port.listen((message) {
      if (done.isCompleted) return;
      final reply = message as List<Object?>;
      if (reply[0] == true) {
        done.complete(reply[1]);
      } else {
        done.completeError(FormatException('${reply[1]}'));
      }
    });
    final timer = Timer(budget, () {
      _isolate?.kill(priority: Isolate.immediate);
      if (!done.isCompleted) {
        done.completeError(
          TimeoutException('Image codec exceeded its deadline.'),
        );
      }
    });
    try {
      // Await the result immediately, including while isolate startup is
      // pending. A timeout during spawn must not become an unhandled error,
      // and a late worker must not replace the next job's isolate handle.
      unawaited(
        Isolate.spawn(
          _entry,
          <Object?>[port.sendPort, request],
          onError: errors.sendPort,
          errorsAreFatal: true,
        ).then<void>(
          (isolate) {
            if (!identical(_active, done) || done.isCompleted) {
              isolate.kill(priority: Isolate.immediate);
            } else {
              _isolate = isolate;
            }
          },
          onError: (Object error, StackTrace stack) {
            if (identical(_active, done) && !done.isCompleted) {
              done.completeError(error, stack);
            }
          },
        ),
      );
      return (await done.future) as T;
    } finally {
      timer.cancel();
      _isolate?.kill(priority: Isolate.immediate);
      _isolate = null;
      _active = null;
      await outputSub.cancel();
      await errorSub.cancel();
      port.close();
      errors.close();
    }
  }

  void cancel() {
    _isolate?.kill(priority: Isolate.immediate);
    final active = _active;
    if (active != null && !active.isCompleted) {
      active.completeError(const CompactImageCancelled());
    }
  }

  static image.Image _raster(Map<String, Object?> request) =>
      image.Image.fromBytes(
        width: request['width']! as int,
        height: request['height']! as int,
        bytes: (request['rgba']! as Uint8List).buffer,
        bytesOffset: (request['rgba']! as Uint8List).offsetInBytes,
        numChannels: 4,
        order: image.ChannelOrder.rgba,
      );

  static void _entry(List<Object?> boot) {
    final reply = boot[0]! as SendPort;
    final request = boot[1]! as Map<String, Object?>;
    try {
      Object? result;
      switch (request['op']) {
        case 'prepare':
          result = CompactImagePreparation.prepareMany(
            request['bytes']! as Uint8List,
            maxDimensions: request['sizes']! as List<int>,
            crop: request['crop'] as CompactImageCrop?,
          );
        case 'encode':
          var raster = _raster(request);
          final codec = request['codec'];
          final quality = request['quality']! as int;
          if (codec == 'jpeg') {
            result = image.encodeJpg(raster, quality: quality);
          } else if (codec == 'png') {
            // Deterministic palette PNG is especially useful for diagrams.
            final source = raster;
            final hasAlpha = source.any((pixel) => pixel.a != 255);
            raster = image.quantize(
              raster,
              numberOfColors: quality.clamp(2, 256),
              method: image.QuantizeMethod.octree,
              dither: image.DitherKernel.none,
            );
            if (hasAlpha) {
              raster = raster.convert(numChannels: 4);
              for (final pixel in raster) {
                pixel.a = source.getPixel(pixel.x, pixel.y).a;
              }
            }
            result = image.encodePng(raster, level: 9);
          } else {
            throw UnsupportedError('No Dart encoder for $codec.');
          }
        case 'decode':
          final bytes = CompactImagePreparation.previewInput(
            request['bytes']! as Uint8List,
            maxDimension: 512,
            maxPixels: 512 * 512,
          );
          final decoder = image.findDecoderForData(bytes);
          final expected = switch (request['codec']) {
            'jpeg' => image.ImageFormat.jpg,
            'png' => image.ImageFormat.png,
            'webp' => image.ImageFormat.webp,
            _ => null,
          };
          if (expected == null || decoder?.format != expected) {
            throw const FormatException(
              'The bitstream does not match its codec identifier.',
            );
          }
          final info = decoder?.startDecode(bytes);
          if (info == null ||
              info.width < 1 ||
              info.height < 1 ||
              info.width > 512 ||
              info.height > 512) {
            throw const FormatException('Invalid image raster.');
          }
          final raster = decoder!.decodeFrame(0);
          if (raster == null) {
            throw const FormatException('Invalid image raster.');
          }
          result = CompactImageRaster(
            rgba: raster
                .convert(format: image.Format.uint8, numChannels: 4)
                .getBytes(order: image.ChannelOrder.rgba),
            width: raster.width,
            height: raster.height,
          );
        case 'finish':
          final raster = _raster(request);
          // Image.fromBytes creates a new image with no EXIF, XMP, ICC or text.
          result = image.encodePng(raster);
        case 'score':
          final raster = _raster(request);
          final reference = request['reference']! as PreparedCompactImage;
          final scaleX = reference.width <= 1
              ? 0.0
              : (raster.width - 1) / (reference.width - 1);
          final scaleY = reference.height <= 1
              ? 0.0
              : (raster.height - 1) / (reference.height - 1);
          double squared = 0;
          double gradientError = 0;
          int samples = 0;
          // Sample an 8K-pixel grid, preserving edge errors as well as color.
          final step = math.max(
            1,
            math.sqrt(reference.width * reference.height / 8192).ceil(),
          );
          for (var y = 0; y < reference.height; y += step) {
            for (var x = 0; x < reference.width; x += step) {
              final p = raster.getPixelInterpolate(x * scaleX, y * scaleY);
              final offset = (y * reference.width + x) * 4;
              for (var c = 0; c < 3; c++) {
                final value = c == 0
                    ? p.r
                    : c == 1
                    ? p.g
                    : p.b;
                final visible = (value * p.a + 255 * (255 - p.a)) / 255;
                final refAlpha = reference.rgba[offset + 3];
                final refVisible =
                    (reference.rgba[offset + c] * refAlpha +
                        255 * (255 - refAlpha)) /
                    255;
                final delta = visible - refVisible;
                squared += delta * delta;
              }
              final alphaDelta = p.a - reference.rgba[offset + 3];
              squared += alphaDelta * alphaDelta;
              if (x + step < reference.width) {
                final next = raster.getPixelInterpolate(
                  (x + step) * scaleX,
                  y * scaleY,
                );
                final refNext = offset + step * 4;
                final edge =
                    ((p.r - next.r) + (p.g - next.g) + (p.b - next.b)) / 3;
                final refEdge =
                    ((reference.rgba[offset] - reference.rgba[refNext]) +
                        (reference.rgba[offset + 1] -
                            reference.rgba[refNext + 1]) +
                        (reference.rgba[offset + 2] -
                            reference.rgba[refNext + 2])) /
                    3;
                gradientError += (edge - refEdge).abs();
              }
              samples++;
            }
          }
          final mse = squared / math.max(1, samples * 4);
          final psnr = mse == 0 ? 99.0 : 10 * math.log(65025 / mse) / math.ln10;
          result = psnr - gradientError / math.max(1, samples) * 0.025;
        default:
          throw UnsupportedError('Unknown image worker operation.');
      }
      reply.send(<Object?>[true, result]);
    } catch (error) {
      reply.send(<Object?>[false, error.toString()]);
    }
  }
}
