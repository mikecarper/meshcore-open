import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/compact_image_codec.dart';
import '../widgets/image_send_codec_binding.dart';
import 'compact_image_backend.dart';
import 'compact_image_envelope.dart';
import 'compact_image_preparation.dart';
import 'compact_image_worker.dart';
import 'image_chunk_transport.dart';

export '../models/compact_image_codec.dart';
export 'compact_image_preparation.dart' show CompactImageCrop;

class _Encoded {
  const _Encoded(this.bytes, this.quality);
  final Uint8List bytes;
  final int quality;
}

class _Candidate {
  const _Candidate(
    this.codec,
    this.raster,
    this.quality,
    this.bytes,
    this.decoded,
    this.score,
  );
  final CompactImageCodec codec;
  final PreparedCompactImage raster;
  final int quality;
  final Uint8List bytes;
  final CompactImageRaster decoded;
  final double score;
}

/// Local encode/decode comparison, with one wall-clock budget per algorithm.
/// Chooses the best measured reconstruction that fits INCLUDING its envelope.
class CompactImageCodecService extends ChangeNotifier
    implements ImageSendCodec {
  CompactImageCodecService({
    bool Function()? enabled,
    CompactImageBackend? backend,
    SharedPreferences? preferences,
    this.algorithmLimit = const Duration(minutes: 2),
  }) : _enabled = enabled ?? (() => true),
       _backend = backend ?? LocalCompactImageBackend(),
       _preferences = preferences {
    if (algorithmLimit <= Duration.zero ||
        algorithmLimit > const Duration(minutes: 2)) {
      throw ArgumentError(
        'The per-codec budget must be between zero and two minutes.',
      );
    }
    final savedTarget = preferences?.getInt('image_compression_target_bytes');
    if (savedTarget != null &&
        savedTarget > CompactImageEnvelope.headerBytes &&
        savedTarget <= CompactImageEnvelope.maxPayloadBytes) {
      _targetBytes = savedTarget;
    }
    _budgetIncludesParity =
        preferences?.getBool('image_compression_parity') ?? true;
    _packetBudget =
        imageDataChunkCount(_targetBytes) + (_budgetIncludesParity ? 1 : 0);
  }

  final bool Function() _enabled;
  final CompactImageBackend _backend;
  final SharedPreferences? _preferences;
  final Duration algorithmLimit;
  final CompactImageWorker _worker = CompactImageWorker();
  bool _disposed = false;
  bool _busy = false;
  bool _cancelled = false;
  bool _quarantined = false;
  Future<void>? _stopping;
  Completer<void> _cancelSignal = Completer<void>();
  int _targetBytes = 1024;
  int _packetBudget = 8;
  bool _budgetIncludesParity = true;
  CompactImageCrop? _crop;
  CompactImageCompressionResult? _result;
  List<CompactImageCodecAttempt> _attempts = [];
  String? _stage;
  double? _progress;

  bool get isBusy => _busy || _stopping != null;
  String? get stage => _stage;
  double? get progress => _progress;
  int get targetBytes => _targetBytes;
  int get packetBudget => _packetBudget;
  bool get budgetIncludesParity => _budgetIncludesParity;
  CompactImageCrop? get crop => _crop;
  CompactImageCompressionResult? get result => _result;
  List<CompactImageCodecAttempt> get attempts => List.unmodifiable(_attempts);

  @override
  ImageCodecAvailability get availability => _enabled()
      ? ImageCodecAvailability.ready
      : ImageCodecAvailability.disabled;
  @override
  String? get unavailableReason => null;

  void setTargetBytes(int bytes) {
    if (bytes <= CompactImageEnvelope.headerBytes ||
        bytes > CompactImageEnvelope.maxPayloadBytes) {
      throw ArgumentError(
        'The byte target must fit in at most 15 data packets.',
      );
    }
    if (isBusy) {
      throw StateError(
        'Wait for compression to stop before changing its target.',
      );
    }
    _targetBytes = bytes;
    _packetBudget =
        imageDataChunkCount(bytes) + (_budgetIncludesParity ? 1 : 0);
    _result = null;
    _savePreferences();
    _notify();
  }

  void setPacketBudget(int packets, {bool includeParity = true}) {
    final dataPackets = packets - (includeParity ? 1 : 0);
    if (dataPackets < 1 || dataPackets > kImageMaxDataChunks) {
      throw ArgumentError('Choose 1..15 data packets plus optional parity.');
    }
    if (isBusy) throw StateError('Wait for image compression to stop first.');
    _packetBudget = packets;
    _budgetIncludesParity = includeParity;
    _targetBytes =
        kImageChunkFirstCapacity + (dataPackets - 1) * kImageChunkCapacity;
    _result = null;
    _savePreferences();
    _notify();
  }

  void setCrop(CompactImageCrop? crop) {
    if (_busy) {
      throw StateError(
        'Wait for compression to stop before changing its crop.',
      );
    }
    _crop = crop;
    _result = null;
    _notify();
  }

  Future<List<CompactImageCodecCapability>> capabilities() =>
      _backend.capabilities();

  @override
  Future<Uint8List> encode(
    Uint8List imageBytes,
    ImageCodecRatePoint rate,
  ) async {
    if (availability != ImageCodecAvailability.ready) {
      throw StateError('Enable image messages in App Settings first.');
    }
    if (rate != ImageCodecRatePoint.compact) {
      throw ArgumentError(
        'Compact images require their own wire-format identifier.',
      );
    }
    return (await compress(imageBytes)).payload;
  }

  Future<CompactImageCompressionResult> compress(
    Uint8List imageBytes, {
    int? targetBytes,
    CompactImageCrop? crop,
    List<CompactImageCodec>? codecs,
  }) async {
    if (_disposed || _quarantined) {
      throw StateError(
        'Image compression is closed or a previous worker could not be stopped.',
      );
    }
    if (isBusy) {
      throw StateError('An image job is already running or stopping.');
    }
    final target = targetBytes ?? _targetBytes;
    if (target <= CompactImageEnvelope.headerBytes ||
        target > CompactImageEnvelope.maxPayloadBytes) {
      throw ArgumentError(
        'The selected image budget exceeds the radio format.',
      );
    }
    _busy = true;
    _cancelled = false;
    _cancelSignal = Completer<void>();
    _result = null;
    _attempts = [];
    _stage = 'Cropping and aligning 16/32-pixel blocks';
    _progress = 0;
    _notify();
    try {
      final prepared = await _worker.run<List<PreparedCompactImage>>({
        'op': 'prepare',
        'bytes': imageBytes,
        'crop': crop ?? _crop,
        'sizes': <int>[512, 384, 256, 192, 128],
      }, const Duration(seconds: 30));
      final variants = prepared
          .where((raster) => math.max(raster.width, raster.height) >= 128)
          .toList();
      _checkCancelled();
      if (variants.isEmpty) {
        throw const FormatException(
          'The image or crop is below 128 pixels. Choose a larger image or crop.',
        );
      }
      final reference = variants.first;
      final caps = await capabilities().timeout(const Duration(seconds: 5));
      final requested = codecs ?? CompactImageCodec.values;
      _Candidate? winner;
      for (var index = 0; index < requested.length; index++) {
        _checkCancelled();
        final codec = requested[index];
        final capability = caps.where((c) => c.codec == codec).firstOrNull;
        if (capability?.available != true) {
          _attempts.add(
            CompactImageCodecAttempt(
              codec: codec,
              status: CompactImageCodecAttemptStatus.unavailable,
              elapsedMs: 0,
              reason: capability?.reason ?? 'No local encoder and decoder.',
            ),
          );
          _notify();
          continue;
        }
        _stage = 'Comparing ${codec.label}';
        _progress = index / math.max(1, requested.length);
        _notify();
        final clock = Stopwatch()..start();
        _Candidate? codecWinner;
        var status = CompactImageCodecAttemptStatus.overBudget;
        String? reason;
        int? smallest;
        int? successfulResolution;
        try {
          for (final raster in variants) {
            if (successfulResolution != null &&
                raster.resolutionStep != successfulResolution) {
              break;
            }
            _checkCancelled();
            {
              _Encoded? fitted;
              try {
                fitted = await _fit(codec, raster, target, clock, (length) {
                  smallest = math.min(smallest ?? length, length);
                });
              } on PlatformException catch (error) {
                if (error.code != 'codec_failed') rethrow;
                // A high-resolution attempt can exhaust a codec's bounded
                // working memory. Reap it and try the next smaller raster.
                reason = error.message;
                await _cancelBackend();
                continue;
              }
              _remaining(clock);
              if (fitted == null) continue;
              final encoded = fitted.bytes;
              final quality = fitted.quality;
              final decodeBudget = _remaining(clock);
              final decoded = await _awaitBackend(
                _backend.decode(codec, encoded, decodeBudget),
                decodeBudget,
              );
              _validateRaster(decoded, raster.width, raster.height);
              final score = await _worker.run<double>({
                'op': 'score',
                'rgba': decoded.rgba,
                'width': decoded.width,
                'height': decoded.height,
                'reference': reference,
              }, _remaining(clock));
              _remaining(clock);
              final candidate = _Candidate(
                codec,
                raster,
                quality,
                encoded,
                decoded,
                score,
              );
              if (_better(candidate, codecWinner)) codecWinner = candidate;
              successfulResolution = raster.resolutionStep;
            }
          }
          status = codecWinner == null
              ? CompactImageCodecAttemptStatus.overBudget
              : CompactImageCodecAttemptStatus.completed;
          if (codecWinner == null) {
            reason =
                'No verified image fits this budget at the 128-pixel minimum. Choose more packets.';
          }
        } on TimeoutException {
          status = CompactImageCodecAttemptStatus.timedOut;
          reason = 'The algorithm reached its two-minute wall-clock limit.';
          await _cancelBackend();
        } on PlatformException catch (error) {
          status =
              error.code.toUpperCase().contains('TIMEOUT') ||
                  error.code.toUpperCase().contains('DEADLINE')
              ? CompactImageCodecAttemptStatus.timedOut
              : CompactImageCodecAttemptStatus.failed;
          reason = error.message ?? error.code;
          await _cancelBackend();
        } on CompactImageCancelled {
          rethrow;
        } catch (error) {
          status = CompactImageCodecAttemptStatus.failed;
          reason = error.toString();
          await _cancelBackend();
        } finally {
          clock.stop();
        }
        _checkCancelled();
        if (codecWinner != null && _better(codecWinner, winner)) {
          winner = codecWinner;
        }
        _attempts.add(
          CompactImageCodecAttempt(
            codec: codec,
            status: status,
            elapsedMs: clock.elapsedMilliseconds,
            encodedBytes: codecWinner == null
                ? (smallest == null
                      ? null
                      : smallest! + CompactImageEnvelope.headerBytes)
                : codecWinner.bytes.length + CompactImageEnvelope.headerBytes,
            width: codecWinner?.raster.width,
            height: codecWinner?.raster.height,
            blockSize: codecWinner?.raster.blockSize,
            reason: reason,
          ),
        );
        _notify();
      }
      _checkCancelled();
      if (winner == null) {
        throw StateError(
          'No available codec produced a verified image under $target bytes.',
        );
      }
      final png = await _worker.run<Uint8List>({
        'op': 'finish',
        'rgba': winner.decoded.rgba,
        'width': winner.decoded.width,
        'height': winner.decoded.height,
      }, const Duration(seconds: 10));
      _checkCancelled();
      final envelope = CompactImageEnvelope(
        codec: winner.codec,
        width: winner.raster.width,
        height: winner.raster.height,
        blockSize: winner.raster.blockSize,
        bitstream: winner.bytes,
      );
      _result = CompactImageCompressionResult(
        payload: envelope.encode(),
        previewPng: png,
        codec: winner.codec,
        width: winner.raster.width,
        height: winner.raster.height,
        blockSize: winner.raster.blockSize,
        quality: winner.quality,
        score: winner.score,
        attempts: List.unmodifiable(_attempts),
      );
      _stage = '${winner.codec.label}: ${_result!.payload.length} bytes';
      _progress = 1;
      return _result!;
    } finally {
      _busy = false;
      _notify();
    }
  }

  bool _better(_Candidate next, _Candidate? old) =>
      old == null ||
      next.score > old.score + 0.02 ||
      ((next.score - old.score).abs() <= 0.02 &&
          next.bytes.length < old.bytes.length);

  Future<_Encoded?> _fit(
    CompactImageCodec codec,
    PreparedCompactImage raster,
    int target,
    Stopwatch clock,
    void Function(int) onSize,
  ) async {
    Future<_Encoded> probe(int quality) async {
      _checkCancelled();
      final budget = _remaining(clock);
      final bytes = await _awaitBackend(
        _backend.encode(codec, raster, quality, budget),
        budget,
      );
      _remaining(clock);
      onSize(bytes.length);
      return _Encoded(bytes, quality);
    }

    bool fits(_Encoded encoded) =>
        encoded.bytes.length + CompactImageEnvelope.headerBytes <= target;
    final levels = codec == CompactImageCodec.png
        ? <int>[2, 4, 8, 16, 32, 64, 128]
        : <int>[8, 13, 18, 23, 28, 33, 38, 43, 48, 53, 58, 63, 68, 73, 78, 85];
    final highest = await probe(levels.last);
    if (fits(highest)) return highest;
    var best = await probe(levels.first);
    if (!fits(best)) return null;
    var lower = 0;
    var upper = levels.length - 1;
    while (upper - lower > 1) {
      final middle = (lower + upper) ~/ 2;
      final candidate = await probe(levels[middle]);
      if (fits(candidate)) {
        best = candidate;
        lower = middle;
      } else {
        upper = middle;
      }
    }
    return best;
  }

  Duration _remaining(Stopwatch clock) {
    final budget = algorithmLimit - clock.elapsed;
    if (budget <= Duration.zero) {
      throw TimeoutException('Image codec deadline.');
    }
    return budget;
  }

  void _validateRaster(CompactImageRaster raster, int width, int height) {
    if (raster.width != width ||
        raster.height != height ||
        raster.rgba.length != width * height * 4) {
      throw const FormatException(
        'The image decoder returned unexpected dimensions.',
      );
    }
  }

  Future<T> _awaitBackend<T>(Future<T> operation, Duration budget) =>
      Future.any<T>([
        operation.timeout(budget),
        _cancelSignal.future.then<T>(
          (_) => throw const CompactImageCancelled(),
        ),
      ]);

  Future<void> _cancelBackend() async {
    final existing = _stopping;
    if (existing != null) return existing;
    final stopping = _backend.cancel().timeout(const Duration(seconds: 3));
    _stopping = stopping;
    try {
      await stopping;
    } catch (_) {
      _quarantined = true;
      throw StateError(
        'The previous codec worker could not confirm it stopped.',
      );
    } finally {
      _stopping = null;
      _notify();
    }
  }

  /// Receivers use the same identified codec, then create a fresh PNG container.
  Future<Uint8List> decodeToPng(Uint8List payload) async {
    if (_disposed || isBusy || _quarantined) {
      throw StateError('The image codec is busy or closed.');
    }
    final envelope = CompactImageEnvelope.decode(payload);
    _busy = true;
    _cancelled = false;
    _cancelSignal = Completer<void>();
    _notify();
    try {
      final raster = await _awaitBackend(
        _backend.decode(
          envelope.codec,
          envelope.bitstream,
          const Duration(seconds: 30),
        ),
        const Duration(seconds: 30),
      );
      _checkCancelled();
      _validateRaster(raster, envelope.width, envelope.height);
      final png = await _worker.run<Uint8List>({
        'op': 'finish',
        'rgba': raster.rgba,
        'width': raster.width,
        'height': raster.height,
      }, const Duration(seconds: 10));
      _checkCancelled();
      return png;
    } on TimeoutException {
      await _cancelBackend();
      rethrow;
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<void> cancelEncode() async {
    _cancelled = true;
    if (!_cancelSignal.isCompleted) _cancelSignal.complete();
    _worker.cancel();
    await _cancelBackend();
  }

  void _checkCancelled() {
    if (_cancelled || _disposed) throw const CompactImageCancelled();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _savePreferences() {
    final preferences = _preferences;
    if (preferences == null) return;
    unawaited(
      preferences
          .setInt('image_compression_target_bytes', _targetBytes)
          .catchError((Object _) => false),
    );
    unawaited(
      preferences
          .setBool('image_compression_parity', _budgetIncludesParity)
          .catchError((Object _) => false),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelled = true;
    if (!_cancelSignal.isCompleted) _cancelSignal.complete();
    _worker.cancel();
    unawaited(
      _backend.cancel().catchError((Object _) {
        // The disposed service cannot start another job. The native bridge keeps
        // its own process lease until termination or its independent deadline.
      }),
    );
    super.dispose();
  }
}
