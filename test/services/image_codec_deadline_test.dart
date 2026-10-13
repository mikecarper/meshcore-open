import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/image_codec_support.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/services/image_codec_backend.dart'
    show kImageCodecBitstreamPathAvailable;
import 'package:meshcore_open/services/image_codec_service.dart';
import 'package:meshcore_open/services/image_codec_session.dart';
import 'package:meshcore_open/services/image_codec_settings_store.dart';

const _bundle = ImageCodecBundle(
  decoderGraphPath: '/models/decoder.onnx',
  entropyGraphPath: '/models/entropy.onnx',
  entropyDecodeGraphPath: '/models/entropy_decode.onnx',
  tablesPath: '/models/tables.bin',
);

// Deliberately never acknowledges jobs, release, cancel, or shutdown.
void _stalledWorker(List<Object?> payload) {
  final reply = payload.first as SendPort;
  final commands = ReceivePort();
  reply.send(<String, Object?>{
    'type': 'ready',
    'port': commands.sendPort,
    'backend': 'stalled-test-worker',
    'bitstream': true,
    'entropy': true,
    'tables': true,
  });
  commands.listen((message) {
    if (message is Map && message['type'] == 'job') {
      reply.send(<String, Object?>{
        'type': 'progress',
        'id': message['id'],
        'value': 0.1,
      });
    }
  });
}

void _neverReadyWorker(List<Object?> payload) {
  ReceivePort().listen((_) {});
}

class _FakeSession implements ImageCodecSession {
  final Completer<Uint8List> pendingEncode = Completer<Uint8List>();
  final Completer<void> encodeEntered = Completer<void>();
  bool forced = false;
  int encodeCalls = 0;
  int releaseCalls = 0;

  @override
  Future<Uint8List> encode(
    Uint8List rgbBytes,
    AeicRatePoint ratePoint,
    int resolution, {
    void Function(double)? onProgress,
  }) {
    encodeCalls++;
    if (!encodeEntered.isCompleted) encodeEntered.complete();
    return pendingEncode.future;
  }

  @override
  Future<void> release({bool decoder = false, bool entropy = false}) {
    releaseCalls++;
    return Completer<void>().future;
  }

  @override
  void forceDispose([Object? reason]) {
    forced = true;
    if (encodeCalls > 0 && !pendingEncode.isCompleted) {
      pendingEncode.completeError(reason ?? StateError('force disposed'));
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ImageCodecService _service({
  required Future<ImageCodecSession> Function(ImageCodecBundle) sessionFactory,
  Duration limit = const Duration(milliseconds: 40),
}) {
  final model = ImageCodecModelRecord(
    id: 'deadline-test',
    name: 'decoder.onnx',
    sourceUrl: 'https://example.invalid/decoder.onnx',
    localPath: _bundle.decoderGraphPath,
    downloadedAt: DateTime(2026),
    fileSizeBytes: 1,
    assetFileNames: const ['entropy.onnx', 'entropy_decode.onnx', 'tables.bin'],
    assetRoles: const {
      'entropy.onnx': ImageCodecAssetRole.entropyGraph,
      'entropy_decode.onnx': ImageCodecAssetRole.entropyDecodeGraph,
      'tables.bin': ImageCodecAssetRole.cdfTables,
    },
    bundleVersion: kImageCodecBundleVersion,
  );
  return ImageCodecService(
    AppSettingsService(),
    settingsStore: InMemoryImageCodecSettingsStore(
      ImageCodecPreferences(
        enabled: true,
        downloadedModels: [model],
        selectedModelId: model.id,
      ),
    ),
    sessionFactory: sessionFactory,
    encodeTimeLimit: limit,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('AEIC encode budget cannot exceed 120 seconds', () {
    final service = _service(
      sessionFactory: (_) async => _FakeSession(),
      limit: const Duration(minutes: 10),
    );
    addTearDown(service.dispose);
    expect(service.encodeTimeLimit, const Duration(seconds: 120));
    expect(
      () => _service(
        sessionFactory: (_) async => _FakeSession(),
        limit: Duration.zero,
      ),
      throwsArgumentError,
    );
  });

  test('force disposal completes jobs and unacknowledged releases', () async {
    final session = await ImageCodecSession.debugSpawnWorker(
      _bundle,
      _stalledWorker,
    );
    addTearDown(session.forceDispose);
    final entered = Completer<void>();
    final pending = session.encode(
      Uint8List(3),
      AeicRatePoint.ft32,
      1,
      onProgress: (_) => entered.complete(),
    );
    final result = expectLater(pending, throwsA(isA<TimeoutException>()));
    await entered.future.timeout(const Duration(seconds: 2));
    final release = session.release(decoder: true);
    session.forceDispose(TimeoutException('test deadline'));
    await result;
    await release.timeout(const Duration(milliseconds: 100));
    session.forceDispose(); // Idempotent, including pending completers.
    await expectLater(
      session.encode(Uint8List(3), AeicRatePoint.ft32, 1),
      throwsStateError,
    );
  });

  test('worker handshake has a bounded startup deadline', () async {
    await expectLater(
      ImageCodecSession.debugSpawnWorker(
        _bundle,
        _neverReadyWorker,
        startupTimeout: const Duration(milliseconds: 40),
      ),
      throwsA(isA<TimeoutException>()),
    );
  });

  test(
    'force disposal interrupts the graceful shutdown grace period',
    () async {
      final session = await ImageCodecSession.debugSpawnWorker(
        _bundle,
        _stalledWorker,
      );
      final pending = session.encode(Uint8List(3), AeicRatePoint.ft32, 1);
      final result = expectLater(pending, throwsStateError);
      final graceful = session.dispose();
      session.forceDispose();
      await result;
      await graceful;
    },
  );

  group('AEIC service deadline', () {
    final rgb = Uint8List(512 * 512 * 3);

    test(
      'timeout stops the worker without awaiting a queued release',
      () async {
        final session = _FakeSession();
        var starts = 0;
        final service = _service(
          sessionFactory: (_) async {
            starts++;
            return session;
          },
        );
        addTearDown(service.dispose);
        final result = await service
            .encodeImage(rgbBytes: rgb, ratePoint: AeicRatePoint.ft32)
            .timeout(const Duration(seconds: 1));
        expect(result?.status, ImageCodecStatus.failed);
        expect(session.forced, isTrue);
        expect(session.releaseCalls, 0);
        expect(service.isBusy, isFalse);
        expect(service.codecStage, isNull);
        expect(service.isModelLoaded, isFalse);
        expect(service.canRunInference, isFalse);
        expect(service.unavailableReason, contains('Restart the app'));
        expect(
          await service.encodeImage(
            rgbBytes: rgb,
            ratePoint: AeicRatePoint.ft32,
          ),
          isNull,
        );
        expect(starts, 1);
      },
    );

    test('an already-queued encode cannot start after a timeout', () async {
      final session = _FakeSession();
      final service = _service(sessionFactory: (_) async => session);
      addTearDown(service.dispose);
      final first = service.encodeImage(
        rgbBytes: rgb,
        ratePoint: AeicRatePoint.ft32,
      );
      final second = service.encodeImage(
        rgbBytes: rgb,
        ratePoint: AeicRatePoint.ft32,
      );
      expect((await first)?.status, ImageCodecStatus.failed);
      expect(await second, isNull);
      expect(session.encodeCalls, 1);
    });

    test('late startup after timeout is discarded before encoding', () async {
      final starting = Completer<ImageCodecSession>();
      final service = _service(sessionFactory: (_) => starting.future);
      addTearDown(service.dispose);
      final result = await service.encodeImage(
        rgbBytes: rgb,
        ratePoint: AeicRatePoint.ft32,
      );
      expect(result?.status, ImageCodecStatus.failed);
      final lateSession = _FakeSession();
      starting.complete(lateSession);
      await Future<void>.delayed(Duration.zero);
      expect(lateSession.forced, isTrue);
      expect(lateSession.encodeCalls, 0);
      expect(service.isModelLoaded, isFalse);
    });

    test('successful encode preserves the existing result contract', () async {
      final session = _FakeSession();
      final encoded = Uint8List.fromList([1, 2, 3]);
      session.pendingEncode.complete(encoded);
      final service = _service(sessionFactory: (_) async => session);
      addTearDown(service.dispose);
      final result = await service.encodeImage(
        rgbBytes: rgb,
        ratePoint: AeicRatePoint.ft32,
      );
      expect(result?.status, ImageCodecStatus.completed);
      expect(result?.bitstream, encoded);
      expect(session.forced, isFalse);
      expect(service.canEncode, isTrue);
    });

    test('forced memory stop quarantines an active native job', () async {
      final session = _FakeSession();
      final service = _service(
        sessionFactory: (_) async => session,
        limit: const Duration(seconds: 1),
      );
      addTearDown(service.dispose);
      final pending = service.encodeImage(
        rgbBytes: rgb,
        ratePoint: AeicRatePoint.ft32,
      );
      await session.encodeEntered.future;
      await service.handleMemoryPressure().timeout(
        const Duration(milliseconds: 100),
      );
      expect((await pending)?.status, ImageCodecStatus.failed);
      expect(session.forced, isTrue);
      expect(session.releaseCalls, 0);
      expect(service.canRunInference, isFalse);
      expect(service.unavailableReason, contains('memory pressure'));
      expect(service.unavailableReason, contains('Restart the app'));
    });

    test('idle memory eviction does not quarantine a completed job', () async {
      final session = _FakeSession();
      session.pendingEncode.complete(Uint8List.fromList([1]));
      final service = _service(sessionFactory: (_) async => session);
      addTearDown(service.dispose);
      await service.encodeImage(rgbBytes: rgb, ratePoint: AeicRatePoint.ft32);
      await service.handleMemoryPressure();
      expect(session.forced, isTrue);
      expect(service.canRunInference, isTrue);
      expect(service.isModelLoaded, isFalse);
    });

    test('memory pressure abandons an in-flight worker startup', () async {
      final starting = Completer<ImageCodecSession>();
      final entered = Completer<void>();
      final service = _service(
        sessionFactory: (_) {
          entered.complete();
          return starting.future;
        },
        limit: const Duration(seconds: 1),
      );
      addTearDown(service.dispose);
      final pending = service.encodeImage(
        rgbBytes: rgb,
        ratePoint: AeicRatePoint.ft32,
      );
      await entered.future;
      await service.handleMemoryPressure();
      expect(service.canRunInference, isFalse);
      final lateSession = _FakeSession();
      starting.complete(lateSession);
      expect(await pending, isNull);
      expect(lateSession.forced, isTrue);
      expect(lateSession.encodeCalls, 0);
      expect(service.isModelLoaded, isFalse);
    });
  }, skip: !kImageCodecBitstreamPathAvailable);
}
