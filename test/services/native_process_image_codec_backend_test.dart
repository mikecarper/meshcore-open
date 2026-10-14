import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/image_codec_support.dart';
import 'package:meshcore_open/services/image_codec_backend.dart';
import 'package:meshcore_open/services/native_process_image_codec_backend.dart';

// Channel-contract tests only. The real native engine has separate CTest and
// Android encode/decode evidence; the mock never claims neural inference.
Uint8List framed(int side) {
  final result = Uint8List(23);
  final header = ByteData.sublistView(result);
  header.setUint32(0, side, Endian.big);
  header.setUint32(4, side, Endian.big);
  header.setUint32(8, 11, Endian.big);
  result.setAll(12, [0x11, 4, 0, 0, 0, 128, 0, 0, 0, 128, 0]);
  return result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(NativeProcessImageCodecBackend.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late NativeProcessImageCodecBackend backend;
  late ImageCodecBundle bundle;
  var polls = 0;
  var cancelled = false;
  var starts = 0;
  var degraded = false;
  var completeMarker = true;
  var hold = false;
  var paused = false;
  var cancelPolls = 0;
  var delayCancel = false;
  String? workspace;
  Map<String, dynamic>? lastStart;
  var usableGpu = false;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('native-codec-contract-');
    final model = await Directory('${root.path}/codec128').create();
    for (final name in [
      'codec.tsv',
      'encoder.tsv',
      'renderer.tsv',
      'metadata.tsv',
    ]) {
      await File('${model.path}/$name').writeAsString('');
    }
    polls = 0;
    cancelled = false;
    starts = 0;
    degraded = false;
    completeMarker = true;
    hold = false;
    paused = false;
    cancelPolls = 0;
    delayCancel = false;
    workspace = null;
    lastStart = null;
    usableGpu = false;
    bundle = ImageCodecBundle(
      decoderGraphPath: '',
      ratePoint: AeicRatePoint.ft2,
      nativeModelDirectory: root.path,
      nativeCodecIdentity: NativeProcessImageCodecBackend.codecIdentity,
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'info':
          return {
            'available': true,
            'usableGpuAcceleration': usableGpu,
            'codecIdentity': NativeProcessImageCodecBackend.codecIdentity,
          };
        case 'createWorkspace':
          workspace = (await Directory('${root.path}/work').create()).path;
          return workspace;
        case 'start':
          starts++;
          final args = Map<String, dynamic>.from(call.arguments as Map);
          lastStart = args;
          expect(
            args['codecIdentity'],
            NativeProcessImageCodecBackend.codecIdentity,
          );
          expect(args['resolution'], 128);
          if (args['operation'] == 'encode') {
            final input = await File('$workspace/input.ppm').readAsBytes();
            expect(ascii.decode(input.sublist(0, 15)), 'P6\n128 128\n255\n');
            expect(input.length, 15 + 128 * 128 * 3);
            await File('$workspace/output.aeic').writeAsBytes(framed(128));
          } else {
            final pixels = Uint8List(128 * 128 * 3)
              ..fillRange(0, 128 * 128 * 3, 10);
            await File(
              '$workspace/output.ppm',
            ).writeAsBytes([...ascii.encode('P6\n128 128\n255\n'), ...pixels]);
          }
          return {'jobId': 'job'};
        case 'poll':
          polls++;
          final done = cancelled
              ? (!delayCancel || ++cancelPolls >= 3)
              : (!hold && polls > 1);
          if (!done) {
            expect(
              await Directory(workspace!).exists(),
              isTrue,
              reason: 'scratch must remain while the process is active',
            );
          }
          return {
            'finished': done,
            'progress': done ? 1.0 : 0.5,
            'exitCode': done ? 0 : null,
            'complete': done && !cancelled && completeMarker,
            'cancelled': cancelled,
            'pauseRequested': paused,
            'paused': paused,
            'degraded': degraded,
            'recoveryEvents': degraded ? 2 : 0,
            'warnings': degraded
                ? ['Recovered damaged entropy data.']
                : <String>[],
          };
        case 'pause':
          paused = true;
          return null;
        case 'resume':
          paused = false;
          return null;
        case 'activeJobs':
          return cancelled && cancelPolls >= 3 ? <String>[] : ['job'];
        case 'cancel':
          paused = false;
          cancelled = true;
          return null;
        case 'cancelAll':
          cancelled = true;
          return ['job'];
        case 'forget':
          return null;
      }
      throw MissingPluginException(call.method);
    });
    backend = NativeProcessImageCodecBackend(channel: channel);
    await backend.load(bundle);
  });
  tearDown(() async {
    await backend.dispose();
    messenger.setMockMethodCallHandler(channel, null);
    await root.delete(recursive: true);
  });

  test(
    'auto mode uses actual usable backend capability, not device hardware',
    () async {
      await backend.decode(
        bitstream: framed(128),
        ratePoint: AeicRatePoint.ft2,
        resolution: 128,
      );
      expect(lastStart!['decoderMode'], 'fast');
      usableGpu = true;
      await backend.load(bundle);
      await backend.decode(
        bitstream: framed(128),
        ratePoint: AeicRatePoint.ft2,
        resolution: 128,
      );
      expect(lastStart!['decoderMode'], 'accurate');
    },
  );

  test(
    'explicit Accurate survives backend load and never changes encoding',
    () async {
      await backend.load(
        ImageCodecBundle(
          decoderGraphPath: '',
          ratePoint: AeicRatePoint.ft2,
          nativeModelDirectory: root.path,
          nativeCodecIdentity: NativeProcessImageCodecBackend.codecIdentity,
          nativeDecoderMode: AeicDecoderMode.accurate,
        ),
      );
      await backend.decode(
        bitstream: framed(128),
        ratePoint: AeicRatePoint.ft2,
        resolution: 128,
      );
      expect(lastStart!['decoderMode'], 'accurate');
      await backend.encode(
        rgbBytes: Uint8List(128 * 128 * 3),
        ratePoint: AeicRatePoint.ft2,
        resolution: 128,
      );
      expect(lastStart!.containsKey('decoderMode'), isFalse);
    },
  );

  test('pause and resume preserve an active job before its result', () async {
    hold = true;
    final job = backend.decode(
      bitstream: framed(128),
      ratePoint: AeicRatePoint.ft2,
      resolution: 128,
    );
    while (starts == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
    await backend.pause();
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (!paused && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(paused, isTrue);
    expect(await Directory(workspace!).exists(), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 180));
    expect(cancelled, isFalse);
    await backend.resume();
    expect(paused, isFalse);
    hold = false;
    await job;
    expect(await Directory(workspace!).exists(), isFalse);
  });

  test(
    'cancel from pause waits for process completion before scratch cleanup',
    () async {
      hold = true;
      delayCancel = true;
      final job = backend.decode(
        bitstream: framed(128),
        ratePoint: AeicRatePoint.ft2,
        resolution: 128,
      );
      final rejected = expectLater(job, throwsA(isA<ImageCodecCancelled>()));
      while (starts == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
      await backend.pause();
      await backend.cancel();
      await rejected;
      expect(paused, isFalse);
      expect(cancelPolls, greaterThanOrEqualTo(3));
      expect(await Directory(workspace!).exists(), isFalse);
    },
  );

  test(
    'encode stages selected RGB geometry and cleans completed workspace',
    () async {
      final progress = <double>[];
      final result = await backend.encode(
        rgbBytes: Uint8List(128 * 128 * 3),
        ratePoint: AeicRatePoint.ft2,
        resolution: 128,
        onProgress: progress.add,
      );
      expect(result, framed(128));
      expect(progress, contains(0.5));
      expect(progress.last, 1.0);
      expect(await Directory(workspace!).exists(), false);
    },
  );
  test(
    'decode preserves first pixel whitespace and recovered diagnostics',
    () async {
      degraded = true;
      final rgb = await backend.decode(
        bitstream: framed(128),
        ratePoint: AeicRatePoint.ft2,
        resolution: 128,
      );
      expect(rgb.length, 128 * 128 * 3);
      expect(rgb.every((value) => value == 10), true);
      expect(backend.lastDegraded, true);
      expect(backend.lastRecoveryEvents, 2);
      expect(backend.lastWarnings, ['Recovered damaged entropy data.']);
    },
  );
  test(
    'cooperative cancellation waits for process finish before cleanup',
    () async {
      var stop = false;
      await expectLater(
        backend.encode(
          rgbBytes: Uint8List(128 * 128 * 3),
          ratePoint: AeicRatePoint.ft2,
          resolution: 128,
          onProgress: (_) => stop = true,
          shouldCancel: () => stop,
        ),
        throwsA(isA<ImageCodecCancelled>()),
      );
      expect(cancelled, true);
      expect(await Directory(workspace!).exists(), false);
    },
  );
  test('legacy FT32 is rejected before starting a native process', () async {
    await expectLater(
      backend.encode(
        rgbBytes: Uint8List(128 * 128 * 3),
        ratePoint: AeicRatePoint.ft32,
        resolution: 128,
      ),
      throwsA(isA<ImageCodecBundleIncomplete>()),
    );
    expect(starts, 0);
  });
  test(
    'strict input rejects truncated frame while best effort forwards it',
    () async {
      final truncated = Uint8List.sublistView(framed(128), 0, 20);
      await expectLater(
        backend.decode(
          bitstream: truncated,
          ratePoint: AeicRatePoint.ft2,
          resolution: 128,
        ),
        throwsFormatException,
      );
      expect(starts, 0);
      await backend.load(
        ImageCodecBundle(
          decoderGraphPath: '',
          ratePoint: AeicRatePoint.ft2,
          nativeModelDirectory: root.path,
          nativeCodecIdentity: NativeProcessImageCodecBackend.codecIdentity,
          nativeBestEffort: true,
        ),
      );
      final rgb = await backend.decode(
        bitstream: truncated,
        ratePoint: AeicRatePoint.ft2,
        resolution: 128,
      );
      expect(rgb.length, 128 * 128 * 3);
      expect(starts, 1);
    },
  );
  test('zero exit without native completion marker is not a result', () async {
    completeMarker = false;
    await expectLater(
      backend.encode(
        rgbBytes: Uint8List(128 * 128 * 3),
        ratePoint: AeicRatePoint.ft2,
        resolution: 128,
      ),
      throwsStateError,
    );
    expect(await Directory(workspace!).exists(), false);
  });
  test('wrong bundle identity cannot enable the native FT2 backend', () async {
    await expectLater(
      backend.load(
        ImageCodecBundle(
          decoderGraphPath: '',
          nativeModelDirectory: root.path,
          nativeCodecIdentity: 'FT32',
          ratePoint: AeicRatePoint.ft32,
        ),
      ),
      throwsA(isA<ImageCodecBundleIncomplete>()),
    );
    expect(starts, 0);
  });
  test('PPM comments and exactly one separator preserve whitespace pixels', () {
    for (final first in [10, 32]) {
      final pixels = Uint8List(128 * 128 * 3)
        ..fillRange(0, 128 * 128 * 3, first);
      final ppm = Uint8List.fromList([
        ...ascii.encode('P6\n# RGB output\n128 128\n255\n'),
        ...pixels,
      ]);
      expect(NativeProcessImageCodecBackend.parsePpmRgb(ppm, 128), pixels);
      expect(
        () => NativeProcessImageCodecBackend.parsePpmRgb(
          Uint8List.sublistView(ppm, 0, ppm.length - 1),
          128,
        ),
        throwsFormatException,
      );
      expect(
        () => NativeProcessImageCodecBackend.parsePpmRgb(
          Uint8List.fromList([...ppm, 0]),
          128,
        ),
        throwsFormatException,
      );
    }
  });
  test('native bitstream geometry and declared length are enforced', () {
    final dimensions = framed(128);
    ByteData.sublistView(dimensions).setUint32(4, 192, Endian.big);
    expect(
      () => NativeProcessImageCodecBackend.bitstreamResolution(dimensions),
      throwsFormatException,
    );
    final length = framed(128);
    ByteData.sublistView(length).setUint32(8, 12, Endian.big);
    expect(
      () => NativeProcessImageCodecBackend.bitstreamResolution(length),
      throwsFormatException,
    );
  });
}
