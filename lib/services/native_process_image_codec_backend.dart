import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../models/image_codec_support.dart';
import '../utils/app_logger.dart';
import 'image_codec_backend.dart';

/// Runs a packaged native executable in an Android-owned, cancellable process.
/// The learned FT2 models are installed separately from the executable.
class NativeProcessImageCodecBackend
    implements ImageCodecBackend, ImageCodecDiagnostics {
  static const codecIdentity = 'AEIC_SE_FT2_NCNN';
  static const channelName = 'com.meshcore.meshcore_open/native_image_codec';
  static const resolutions = <int>[128, 192, 256, 320, 384, 448, 512, 576];
  final MethodChannel _channel;
  ImageCodecBundle? _bundle;
  String? _activeJob;
  bool _busy = false;
  bool _disposed = false;
  bool _pauseRequested = false;

  NativeProcessImageCodecBackend({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  @override
  String get name => 'native-ncnn-ft2';
  @override
  bool get supportsBitstreamCodec => _bundle != null && !_disposed;
  @override
  bool lastDegraded = false;
  @override
  List<String> lastWarnings = const [];
  @override
  int lastRecoveryEvents = 0;

  /// A process survives a killed worker isolate. The owning session must call
  /// this before hard isolate teardown, including on memory pressure.
  static Future<void> pauseAll() =>
      const MethodChannel(channelName).invokeMethod<void>('pauseAll');
  static Future<void> resumeAll() =>
      const MethodChannel(channelName).invokeMethod<void>('resumeAll');
  static Future<List<String>> activeJobs() async =>
      await const MethodChannel(
        channelName,
      ).invokeListMethod<String>('activeJobs') ??
      const [];

  static Future<void> _waitForStopped(MethodChannel channel, String id) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (true) {
      try {
        final status = await channel.invokeMapMethod<String, dynamic>('poll', {
          'jobId': id,
        });
        if (status?['finished'] == true) return;
      } on PlatformException catch (error) {
        // The worker may have forgotten an already-finished job while the root
        // waits. The plugin rejects forget until all process handles are closed.
        if (error.code == 'native_codec' &&
            error.message == 'Unknown codec job') {
          return;
        }
        rethrow;
      }
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('Image conversion has not stopped.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  static Future<void> cancelAll() async {
    try {
      const channel = MethodChannel(channelName);
      final ids =
          await channel.invokeListMethod<String>('cancelAll') ?? const [];
      for (final id in ids) {
        await _waitForStopped(channel, id);
      }
    } on MissingPluginException {
      // No native job can exist when the process plugin is unavailable.
    }
  }

  Future<void> _setPaused(bool value) async {
    if (!_busy) return;
    _pauseRequested = value;
    final id = _activeJob;
    if (id == null) return; // Apply the request once this job has started.
    try {
      await _channel.invokeMethod<void>(value ? 'pause' : 'resume', {
        'jobId': id,
      });
    } on PlatformException catch (error) {
      if (error.code == 'native_codec' &&
          error.message == 'Codec job already finished') {
        return;
      }
      rethrow;
    }
  }

  Future<void> pause() => _setPaused(true);
  Future<void> resume() => _setPaused(false);
  Future<void> cancel() async {
    final id = _activeJob;
    if (id != null) {
      await _channel.invokeMethod<void>('cancel', {'jobId': id});
      await _waitForStopped(_channel, id);
    }
  }

  @override
  Future<void> load(Object bundle) async {
    if (bundle is! ImageCodecBundle ||
        bundle.nativeModelDirectory == null ||
        bundle.nativeCodecIdentity != codecIdentity ||
        bundle.ratePoint != AeicRatePoint.ft2) {
      throw const ImageCodecBundleIncomplete(
        'Install the native FT2 image model bundle.',
      );
    }
    if (bundle.nativeThreads < 1 || bundle.nativeThreads > 4) {
      throw ArgumentError.value(bundle.nativeThreads, 'nativeThreads');
    }
    final root = Directory(bundle.nativeModelDirectory!);
    if (!await root.exists()) {
      throw const ImageCodecBundleIncomplete(
        'The native image model folder is missing.',
      );
    }
    Map<String, dynamic>? info;
    try {
      info = await _channel.invokeMapMethod<String, dynamic>('info');
    } on MissingPluginException {
      throw const ImageCodecUnimplemented(
        'Native image conversion requires the Android codec build.',
      );
    }
    if (info?['available'] != true || info?['codecIdentity'] != codecIdentity) {
      throw const ImageCodecUnimplemented(
        'Native image conversion is unavailable in this Android build.',
      );
    }
    _disposed = false;
    _bundle = bundle;
  }

  ImageCodecBundle _requireBundle(AeicRatePoint ratePoint, int resolution) {
    final bundle = _bundle;
    if (_disposed || bundle == null) {
      throw StateError('The native image codec is not loaded.');
    }
    if (ratePoint != AeicRatePoint.ft2 ||
        bundle.nativeCodecIdentity != codecIdentity) {
      throw const ImageCodecBundleIncomplete(
        'This image requires the native FT2 codec.',
      );
    }
    if (!resolutions.contains(resolution)) {
      throw ArgumentError.value(
        resolution,
        'resolution',
        'Use 128..576 in steps of 64.',
      );
    }
    return bundle;
  }

  @override
  Future<Uint8List> encode({
    required Uint8List rgbBytes,
    required AeicRatePoint ratePoint,
    required int resolution,
    void Function(double progress)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    _requireBundle(ratePoint, resolution);
    if (rgbBytes.length != resolution * resolution * 3) {
      throw ArgumentError('Image pixels do not match the selected dimensions.');
    }
    return _job(
      operation: 'encode',
      resolution: resolution,
      prepare: (directory) async {
        final sink = File('${directory.path}/input.ppm').openWrite();
        sink.add(ascii.encode('P6\n$resolution $resolution\n255\n'));
        sink.add(rgbBytes);
        await sink.close();
      },
      read: (directory) async {
        final bytes = await File('${directory.path}/output.aeic').readAsBytes();
        final dimensions = bitstreamResolution(bytes);
        if (dimensions != resolution) {
          throw StateError('Encoded image dimensions changed.');
        }
        return bytes;
      },
      onProgress: onProgress,
      shouldCancel: shouldCancel,
    );
  }

  @override
  Future<Uint8List> decode({
    required Uint8List bitstream,
    required AeicRatePoint ratePoint,
    required int resolution,
    void Function(double progress)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    final bundle = _requireBundle(ratePoint, resolution);
    if (!bundle.nativeBestEffort &&
        bitstreamResolution(bitstream) != resolution) {
      throw ArgumentError(
        'Encoded image dimensions do not match the transfer.',
      );
    }
    if (bitstream.length > 64 * 1024 * 1024) {
      throw ArgumentError('Encoded image exceeds the native input limit.');
    }
    return _job(
      operation: 'decode',
      resolution: resolution,
      prepare: (directory) => File(
        '${directory.path}/input.aeic',
      ).writeAsBytes(bitstream).then((_) {}),
      read: (directory) async => parsePpmRgb(
        await File('${directory.path}/output.ppm').readAsBytes(),
        resolution,
      ),
      onProgress: onProgress,
      shouldCancel: shouldCancel,
    );
  }

  Future<Uint8List> _job({
    required String operation,
    required int resolution,
    required Future<void> Function(Directory) prepare,
    required Future<Uint8List> Function(Directory) read,
    void Function(double)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    if (_busy) throw StateError('Image conversion is already running.');
    if (shouldCancel?.call() == true) throw const ImageCodecCancelled();
    final bundle = _bundle!;
    _busy = true;
    lastDegraded = false;
    lastWarnings = const [];
    lastRecoveryEvents = 0;
    Directory? workspace;
    String? jobId;
    var finished = false;
    var cancelSent = false;
    try {
      final model = Directory(
        '${bundle.nativeModelDirectory}/codec$resolution',
      );
      for (final name in [
        'codec.tsv',
        'encoder.tsv',
        'renderer.tsv',
        'metadata.tsv',
      ]) {
        if (!await File('${model.path}/$name').exists()) {
          throw const ImageCodecBundleIncomplete(
            'Install the image models for the selected size.',
          );
        }
      }
      final path = await _channel.invokeMethod<String>('createWorkspace');
      if (path == null) {
        throw StateError('Cannot create image conversion workspace.');
      }
      workspace = Directory(path);
      await prepare(workspace);
      if (shouldCancel?.call() == true || _disposed) {
        throw const ImageCodecCancelled();
      }
      final start = await _channel.invokeMapMethod<String, dynamic>('start', {
        'operation': operation,
        'workspace': workspace.path,
        'modelDirectory': model.path,
        'codecIdentity': codecIdentity,
        'resolution': resolution,
        'threads': bundle.nativeThreads,
        'bestEffort': bundle.nativeBestEffort,
      });
      jobId = start?['jobId'] as String?;
      if (jobId == null || jobId.isEmpty) {
        throw StateError('Image conversion did not start.');
      }
      _activeJob = jobId;
      if (_pauseRequested) {
        await _channel.invokeMethod<void>('pause', {'jobId': jobId});
      }
      final started = DateTime.now();
      var pausedDuration = Duration.zero;
      DateTime? pauseStarted;
      while (true) {
        if ((_disposed ||
                shouldCancel?.call() == true ||
                (DateTime.now().difference(started) -
                        pausedDuration -
                        (pauseStarted == null
                            ? Duration.zero
                            : DateTime.now().difference(pauseStarted))) >
                    const Duration(hours: 2)) &&
            !cancelSent) {
          cancelSent = true;
          await _channel.invokeMethod<void>('cancel', {'jobId': jobId});
        }
        final status = await _channel.invokeMapMethod<String, dynamic>('poll', {
          'jobId': jobId,
        });
        if (status == null) {
          throw StateError('Image conversion status is unavailable.');
        }
        final now = DateTime.now();
        if (status['pauseRequested'] == true) {
          pauseStarted ??= now;
        } else if (pauseStarted != null) {
          pausedDuration += now.difference(pauseStarted);
          pauseStarted = null;
        }
        onProgress?.call(
          ((status['progress'] as num?)?.toDouble() ?? 0.0)
              .clamp(0.0, 1.0)
              .toDouble(),
        );
        if (status['finished'] == true) {
          finished = true;
          lastDegraded = status['degraded'] == true;
          lastRecoveryEvents = (status['recoveryEvents'] as num?)?.toInt() ?? 0;
          lastWarnings = List<String>.unmodifiable(
            (status['warnings'] as List? ?? []).whereType<String>(),
          );
          if (cancelSent || status['cancelled'] == true) {
            throw const ImageCodecCancelled();
          }
          if (status['exitCode'] != 0 ||
              status['complete'] != true ||
              status['error'] != null) {
            appLogger.error(
              '${status['error']}\n${status['logTail']}',
              tag: 'ImageCodec',
            );
            throw StateError(
              'Image conversion failed. Check the installed model files.',
            );
          }
          final bytes = await read(workspace);
          onProgress?.call(1.0);
          return bytes;
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    } finally {
      if (jobId != null) {
        if (!finished) {
          try {
            await _channel.invokeMethod<void>('cancel', {'jobId': jobId});
            await _waitForStopped(_channel, jobId);
            finished = true;
          } catch (_) {
            // Keep scratch if termination cannot be confirmed.
          }
        }
        if (finished) {
          try {
            await _channel.invokeMethod<void>('forget', {'jobId': jobId});
          } catch (_) {}
        }
      }
      _activeJob = null;
      _pauseRequested = false;
      _busy = false;
      // Do not delete a workspace while a native process may still own it.
      if (workspace != null && (jobId == null || finished)) {
        try {
          await workspace.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  @override
  Future<Uint8List> decodeLatentToRgb({
    required Float32List yHat,
    void Function(double progress)? onProgress,
    bool Function()? shouldCancel,
  }) => Future<Uint8List>.error(
    const ImageCodecUnimplemented(
      'Receive a complete encoded image to use the native codec.',
    ),
  );
  @override
  Future<void> releaseDecoderSession() async {}
  @override
  Future<void> releaseEntropySession() async {}
  @override
  Future<void> dispose() async {
    _disposed = true;
    _bundle = null;
    if (_activeJob != null) await cancelAll();
  }

  static int bitstreamResolution(Uint8List bytes) {
    if (bytes.length < 13) {
      throw const FormatException('Encoded image header is incomplete.');
    }
    final header = ByteData.sublistView(bytes);
    final height = header.getUint32(0, Endian.big),
        width = header.getUint32(4, Endian.big);
    if (height != width || !resolutions.contains(height)) {
      throw const FormatException('Encoded image dimensions are unsupported.');
    }
    if (header.getUint32(8, Endian.big) != bytes.length - 12) {
      throw const FormatException('Encoded image data is incomplete.');
    }
    return height;
  }

  static Uint8List parsePpmRgb(Uint8List bytes, int resolution) {
    var cursor = 0;
    bool space(int value) =>
        value == 9 || value == 10 || value == 13 || value == 32;
    String token() {
      while (cursor < bytes.length) {
        if (space(bytes[cursor])) {
          cursor++;
          continue;
        }
        if (bytes[cursor] == 35) {
          while (cursor < bytes.length && bytes[cursor] != 10) {
            cursor++;
          }
          continue;
        }
        break;
      }
      final start = cursor;
      while (cursor < bytes.length &&
          !space(bytes[cursor]) &&
          bytes[cursor] != 35) {
        cursor++;
      }
      if (start == cursor || cursor - start > 32) {
        throw const FormatException('Invalid image output header.');
      }
      return ascii.decode(bytes.sublist(start, cursor));
    }

    if (token() != 'P6' ||
        int.tryParse(token()) != resolution ||
        int.tryParse(token()) != resolution ||
        token() != '255' ||
        cursor >= bytes.length ||
        !space(bytes[cursor])) {
      throw const FormatException('Image output dimensions are invalid.');
    }
    if (bytes[cursor] == 13 &&
        cursor + 1 < bytes.length &&
        bytes[cursor + 1] == 10) {
      cursor += 2;
    } else {
      cursor++;
    }
    if (bytes.length - cursor != resolution * resolution * 3) {
      throw const FormatException('Image output pixels are incomplete.');
    }
    return Uint8List.sublistView(bytes, cursor);
  }
}
