import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;

/// A crop in the displayed, EXIF-oriented image, with normalized edge positions.
class CompactImageCrop {
  const CompactImageCrop({
    this.left = 0,
    this.top = 0,
    this.right = 1,
    this.bottom = 1,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;

  void _validate() {
    if (!left.isFinite ||
        !top.isFinite ||
        !right.isFinite ||
        !bottom.isFinite ||
        left < 0 ||
        top < 0 ||
        right > 1 ||
        bottom > 1 ||
        right <= left ||
        bottom <= top) {
      throw ArgumentError(
        'Crop edges must describe a nonempty rectangle in 0..1.',
      );
    }
  }
}

/// Pixels only: no EXIF, GPS, comments, thumbnails, or other source metadata.
///
/// The fields can be copied between isolates. A block size of 1 identifies a
/// source with an axis smaller than 16 pixels, which is preserved without
/// upscaling. Otherwise both dimensions are divisible by [blockSize].
class PreparedCompactImage {
  const PreparedCompactImage({
    required this.rgba,
    required this.width,
    required this.height,
    required this.blockSize,
    required this.seamCount,
    this.resolutionStep = 0,
  });

  final Uint8List rgba;
  final int width;
  final int height;
  final int blockSize;
  final int seamCount;
  final int resolutionStep;
}

/// Bounded, deterministic image preparation for the low bandwidth image path.
///
/// Run [prepare] in a worker isolate. Crop and proportional downscaling happen
/// before seam carving. Grid alignment removes individual low energy seams;
/// it does not stretch an image to fit a codec's block dimensions.
class CompactImagePreparation {
  static const maxEncodedBytes = 20 * 1024 * 1024;
  static const maxDecodedPixels = 16 * 1024 * 1024;
  static const _maxDecodedAxis = 16384;

  /// Validate preview input without allocating decoded pixels. PNG ancillary
  /// chunks are discarded before the decoder can inflate private text or ICC
  /// data. Other formats retain their encoded EXIF orientation for the UI's
  /// preview decoder; [prepare] returns metadata-free pixels for transmission.
  static Uint8List previewInput(
    Uint8List input, {
    int maxDimension = _maxDecodedAxis,
    int maxPixels = maxDecodedPixels,
  }) {
    if (maxDimension < 1 ||
        maxDimension > _maxDecodedAxis ||
        maxPixels < 1 ||
        maxPixels > maxDecodedPixels) {
      throw ArgumentError('Preview bounds must fit the decoded image limits.');
    }
    if (input.isEmpty || input.length > maxEncodedBytes) {
      throw const FormatException('The image is empty or larger than 20 MiB.');
    }
    try {
      final decoderInput = _withoutPngAncillaryChunks(input);
      if (_isJpeg(decoderInput)) {
        final dimensions = _jpegDimensions(decoderInput);
        _checkDimensions(
          dimensions.width,
          dimensions.height,
          maxDimension: maxDimension,
          maxPixels: maxPixels,
        );
        return decoderInput;
      }
      final decoder = image.findDecoderForData(decoderInput);
      final info = decoder?.startDecode(decoderInput);
      if (info == null) {
        throw const FormatException('The image format could not be decoded.');
      }
      _checkDimensions(
        info.width,
        info.height,
        maxDimension: maxDimension,
        maxPixels: maxPixels,
      );
      return decoderInput;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('The image is damaged or unsupported.');
    }
  }

  static List<PreparedCompactImage> prepare(
    Uint8List input, {
    int maxDimension = 256,
    CompactImageCrop? crop,
  }) => prepareMany(input, maxDimensions: [maxDimension], crop: crop);

  /// Decode the original only once when comparing multiple output sizes.
  /// Smaller candidates come from the bounded working image, so a 16-megapixel
  /// camera original is not repeatedly decoded for every codec size trial.
  /// The caller's size order is preserved, with identical grids deduplicated.
  static List<PreparedCompactImage> prepareMany(
    Uint8List input, {
    required List<int> maxDimensions,
    CompactImageCrop? crop,
  }) {
    if (maxDimensions.isEmpty) {
      throw ArgumentError('At least one image dimension is required.');
    }
    var largestDimension = 0;
    for (final dimension in maxDimensions) {
      if (dimension < 16 || dimension > 512) {
        throw ArgumentError.value(dimension, 'maxDimension', 'Use 16..512.');
      }
      if (dimension > largestDimension) largestDimension = dimension;
    }
    crop?._validate();
    image.Image decoded;
    try {
      final decoderInput = previewInput(input);
      final decoder = image.findDecoderForData(decoderInput);
      if (decoder == null) {
        throw const FormatException('The image format could not be decoded.');
      }
      image.Image? firstFrame;
      if (decoder.format == image.ImageFormat.jpg) {
        // image 4.5.4's startDecode JPEG header parser allocates full DCT
        // arrays. Our marker preflight already checked dimensions, so decode
        // once instead of allocating those arrays again for header discovery.
        firstFrame = decoder.decode(decoderInput, frame: 0);
      } else {
        final info = decoder.startDecode(decoderInput);
        if (info == null) {
          throw const FormatException('The image format could not be decoded.');
        }
        _checkDimensions(info.width, info.height);
        firstFrame = decoder.decodeFrame(0);
      }
      if (firstFrame == null) {
        throw const FormatException('The image format could not be decoded.');
      }
      _checkDimensions(firstFrame.width, firstFrame.height);
      decoded = firstFrame;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('The image is damaged or unsupported.');
    }

    // JPEG decoding already bakes its EXIF orientation. This also covers
    // decoders that leave the orientation attached to the returned pixels.
    final orientation = decoded.exif.imageIfd.orientation;
    if (orientation != null && orientation != 1) {
      decoded = image.bakeOrientation(decoded);
    }
    if (crop != null) {
      final left = (crop.left * decoded.width).floor();
      final top = (crop.top * decoded.height).floor();
      final right = (crop.right * decoded.width).ceil();
      final bottom = (crop.bottom * decoded.height).ceil();
      if (left != 0 ||
          top != 0 ||
          right != decoded.width ||
          bottom != decoded.height) {
        decoded = image.copyCrop(
          decoded,
          x: left,
          y: top,
          width: right - left,
          height: bottom - top,
        );
      }
    }
    final longest = math.max(decoded.width, decoded.height);
    if (longest > largestDimension) {
      final scale = largestDimension / longest;
      decoded = image.copyResize(
        decoded,
        width: math.max(1, (decoded.width * scale).round()),
        height: math.max(1, (decoded.height * scale).round()),
        interpolation: image.Interpolation.average,
      );
    }
    // Converting only after downscaling bounds this allocation to 1 MiB.
    final rgbaImage = decoded.convert(
      format: image.Format.uint8,
      numChannels: 4,
      noAnimation: true,
    );
    final bounded = image.Image.fromBytes(
      width: rgbaImage.width,
      height: rgbaImage.height,
      bytes: rgbaImage.getBytes(order: image.ChannelOrder.rgba).buffer,
      numChannels: 4,
      order: image.ChannelOrder.rgba,
    );
    final variants = <PreparedCompactImage>[];
    final keys = <String>{};
    for (final dimension in maxDimensions) {
      var candidate = bounded;
      final longest = math.max(bounded.width, bounded.height);
      if (longest > dimension) {
        final scale = dimension / longest;
        candidate = image.copyResize(
          bounded,
          width: math.max(1, (bounded.width * scale).round()),
          height: math.max(1, (bounded.height * scale).round()),
          interpolation: image.Interpolation.average,
        );
      }
      final pixels = _Pixels(
        Uint8List.fromList(candidate.getBytes(order: image.ChannelOrder.rgba)),
        candidate.width,
        candidate.height,
      );
      for (final aligned in _preparePixels(pixels)) {
        if (keys.add(
          '${aligned.width}:${aligned.height}:${aligned.blockSize}',
        )) {
          variants.add(
            PreparedCompactImage(
              rgba: aligned.rgba,
              width: aligned.width,
              height: aligned.height,
              blockSize: aligned.blockSize,
              seamCount: aligned.seamCount,
              resolutionStep: dimension,
            ),
          );
        }
      }
    }
    return variants;
  }

  static List<PreparedCompactImage> _preparePixels(_Pixels pixels) {
    if (pixels.width < 16 || pixels.height < 16) {
      return [
        PreparedCompactImage(
          rgba: pixels.rgba,
          width: pixels.width,
          height: pixels.height,
          blockSize: 1,
          seamCount: 0,
        ),
      ];
    }

    final aligned16 = _align(pixels, 16);
    final variants = <PreparedCompactImage>[aligned16];
    if (pixels.width >= 32 && pixels.height >= 32) {
      final width32 = pixels.width - pixels.width % 32;
      final height32 = pixels.height - pixels.height % 32;
      if (width32 != aligned16.width || height32 != aligned16.height) {
        variants.add(_align(pixels, 32));
      }
    }
    return variants;
  }

  static void _checkDimensions(
    int width,
    int height, {
    int maxDimension = _maxDecodedAxis,
    int maxPixels = maxDecodedPixels,
  }) {
    if (width <= 0 ||
        height <= 0 ||
        width > maxDimension ||
        height > maxDimension ||
        width * height > maxPixels) {
      throw const FormatException('The image exceeds the decoded pixel limit.');
    }
  }

  static bool _isJpeg(Uint8List input) =>
      input.length >= 2 && input[0] == 0xff && input[1] == 0xd8;

  // Parse markers without JpegDecoder.startDecode, which prepares the full
  // component/DCT storage even when used only to ask for header dimensions.
  // Check every frame marker, including those following compressed scans.
  static ({int width, int height}) _jpegDimensions(Uint8List input) {
    final data = ByteData.sublistView(input);
    var offset = 2;
    var inScan = false;
    var sawScan = false;
    ({int width, int height})? dimensions;
    while (offset < input.length) {
      if (inScan) {
        while (offset < input.length && input[offset] != 0xff) {
          offset++;
        }
      } else if (input[offset] != 0xff) {
        throw const FormatException('The JPEG contains an invalid marker.');
      }
      while (offset < input.length && input[offset] == 0xff) {
        offset++;
      }
      if (offset >= input.length) break;
      final marker = input[offset++];
      if (marker == 0) {
        if (!inScan) {
          throw const FormatException('The JPEG contains an invalid marker.');
        }
        continue;
      }
      if (marker == 0xd9) {
        if (dimensions != null && sawScan) return dimensions;
        break;
      }
      if ((marker >= 0xd0 && marker <= 0xd7) || marker == 1) continue;
      inScan = false;
      if (marker == 0xd8 || offset + 2 > input.length) {
        throw const FormatException('The JPEG contains an invalid marker.');
      }
      final size = data.getUint16(offset);
      final end = offset + size;
      if (size < 2 || end > input.length) {
        throw const FormatException('The JPEG contains a truncated segment.');
      }
      if (marker == 0xc0 || marker == 0xc1 || marker == 0xc2) {
        if (size < 8 || dimensions != null) {
          throw const FormatException(
            'The JPEG frame is invalid or unsupported.',
          );
        }
        final components = input[offset + 7];
        if (input[offset + 2] != 8 ||
            ![1, 3, 4].contains(components) ||
            size != 8 + components * 3) {
          throw const FormatException(
            'The JPEG frame is invalid or unsupported.',
          );
        }
        final height = data.getUint16(offset + 3);
        final width = data.getUint16(offset + 5);
        _checkDimensions(width, height);
        var sampleBlocks = 0;
        for (var component = 0; component < components; component++) {
          final sampling = input[offset + 9 + component * 3];
          final horizontal = sampling >> 4;
          final vertical = sampling & 15;
          if (horizontal < 1 ||
              horizontal > 4 ||
              vertical < 1 ||
              vertical > 4) {
            throw const FormatException(
              'The JPEG sampling factors are invalid.',
            );
          }
          sampleBlocks += horizontal * vertical;
        }
        if (sampleBlocks > 10) {
          throw const FormatException('The JPEG sampling factors are invalid.');
        }
        dimensions = (width: width, height: height);
      } else if (marker == 0xda) {
        if (dimensions == null) {
          throw const FormatException('The JPEG scan has no frame header.');
        }
        sawScan = true;
        inScan = true;
      }
      offset = end;
    }
    throw const FormatException('The JPEG has no complete image frame.');
  }

  // PNG text and color-profile chunks can inflate independently of its pixel
  // dimensions. Ignore those chunks before invoking the decoder, rather than
  // decoding private metadata that will be discarded anyway. Keep tRNS,
  // which is pixel transparency, and the critical image chunks. The default
  // image in an animated PNG becomes the single static frame we transmit.
  static Uint8List _withoutPngAncillaryChunks(Uint8List input) {
    const signature = [137, 80, 78, 71, 13, 10, 26, 10];
    if (input.length < signature.length) return input;
    for (var i = 0; i < signature.length; i++) {
      if (input[i] != signature[i]) return input;
    }
    final output = BytesBuilder(copy: false)..add(input.sublist(0, 8));
    final data = ByteData.sublistView(input);
    var offset = 8;
    var headerSeen = false;
    while (offset + 12 <= input.length) {
      final size = data.getUint32(offset);
      final end = offset + size + 12;
      if (end > input.length) {
        throw const FormatException('The PNG contains a truncated chunk.');
      }
      final type = String.fromCharCodes(input.sublist(offset + 4, offset + 8));
      if (!headerSeen) {
        if (type != 'IHDR' || size != 13) {
          throw const FormatException('The PNG has no valid image header.');
        }
        _checkDimensions(
          data.getUint32(offset + 8),
          data.getUint32(offset + 12),
        );
        headerSeen = true;
      }
      final critical = (input[offset + 4] & 0x20) == 0;
      if (critical || type == 'tRNS') {
        output.add(Uint8List.sublistView(input, offset, end));
      }
      if (type == 'IEND') return output.takeBytes();
      offset = end;
    }
    throw const FormatException('The PNG has no end chunk.');
  }

  static PreparedCompactImage _align(_Pixels source, int blockSize) {
    final removeWidth = source.width % blockSize;
    final removeHeight = source.height % blockSize;
    var pixels = source;
    for (var i = 0; i < removeWidth; i++) {
      pixels = _removeVerticalSeam(pixels);
    }
    if (removeHeight != 0) {
      pixels = _transpose(pixels);
      for (var i = 0; i < removeHeight; i++) {
        pixels = _removeVerticalSeam(pixels);
      }
      pixels = _transpose(pixels);
    }
    return PreparedCompactImage(
      // Each candidate owns its buffer, even when the input was grid aligned.
      rgba: identical(pixels, source)
          ? Uint8List.fromList(pixels.rgba)
          : pixels.rgba,
      width: pixels.width,
      height: pixels.height,
      blockSize: blockSize,
      seamCount: removeWidth + removeHeight,
    );
  }

  static _Pixels _transpose(_Pixels source) {
    final output = Uint8List(source.rgba.length);
    for (var y = 0; y < source.height; y++) {
      for (var x = 0; x < source.width; x++) {
        final from = (y * source.width + x) * 4;
        final to = (x * source.height + y) * 4;
        output.setRange(to, to + 4, source.rgba, from);
      }
    }
    return _Pixels(output, source.height, source.width);
  }

  static _Pixels _removeVerticalSeam(_Pixels source) {
    final width = source.width;
    final height = source.height;
    final parents = Int8List(width * height);
    var previous = Int32List(width);
    var current = Int32List(width);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final energy = _energy(source, x, y);
        if (y == 0) {
          current[x] = energy;
          continue;
        }
        var best = previous[x];
        var direction = 0;
        if (x > 0 && previous[x - 1] < best) {
          best = previous[x - 1];
          direction = -1;
        }
        if (x + 1 < width && previous[x + 1] < best) {
          best = previous[x + 1];
          direction = 1;
        }
        current[x] = energy + best;
        parents[y * width + x] = direction;
      }
      final swap = previous;
      previous = current;
      current = swap;
    }
    var seamX = 0;
    for (var x = 1; x < width; x++) {
      if (previous[x] < previous[seamX]) seamX = x;
    }
    final seam = Int32List(height);
    for (var y = height - 1; y >= 0; y--) {
      seam[y] = seamX;
      seamX += parents[y * width + seamX];
    }
    final output = Uint8List((width - 1) * height * 4);
    for (var y = 0; y < height; y++) {
      final from = y * width * 4;
      final to = y * (width - 1) * 4;
      final cut = seam[y] * 4;
      output.setRange(to, to + cut, source.rgba, from);
      output.setRange(
        to + cut,
        to + (width - 1) * 4,
        source.rgba,
        from + cut + 4,
      );
    }
    return _Pixels(output, width - 1, height);
  }

  static int _energy(_Pixels source, int x, int y) {
    final width = source.width;
    final left = (y * width + (x == 0 ? 0 : x - 1)) * 4;
    final right = (y * width + (x == width - 1 ? x : x + 1)) * 4;
    final above = ((y == 0 ? 0 : y - 1) * width + x) * 4;
    final below = ((y == source.height - 1 ? y : y + 1) * width + x) * 4;
    var energy = 0;
    // Include alpha gradients so transparent object edges are preserved too.
    for (var channel = 0; channel < 4; channel++) {
      energy += (source.rgba[left + channel] - source.rgba[right + channel])
          .abs();
      energy += (source.rgba[above + channel] - source.rgba[below + channel])
          .abs();
    }
    return energy;
  }
}

class _Pixels {
  const _Pixels(this.rgba, this.width, this.height);

  final Uint8List rgba;
  final int width;
  final int height;
}
