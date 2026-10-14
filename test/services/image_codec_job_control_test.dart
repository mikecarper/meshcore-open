import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/image_codec_support.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/services/image_codec_service.dart';
import 'package:meshcore_open/services/image_codec_backend.dart'
    show ImageCodecCancelled;
import 'package:meshcore_open/services/image_codec_session.dart';
import 'package:meshcore_open/services/image_codec_settings_store.dart';
import 'package:meshcore_open/widgets/image_send_codec_binding.dart';

// Lifecycle/ownership test only; this session never returns reconstructed RGB.
class _ControlledSession implements ImageCodecSession {
  final result = Completer<Uint8List>();
  bool paused = false;
  int cancels = 0;
  int encodes = 0;
  @override
  bool get canPause => !result.isCompleted;
  @override
  bool get isPaused => paused;
  @override
  bool get supportsBitstreamCodec => true;
  @override
  bool get hasEntropyGraph => true;
  @override
  bool get hasTables => true;
  @override
  String get backendName => 'control-contract';
  @override
  Future<void> pause() async {
    paused = true;
  }

  @override
  Future<void> resume() async {
    paused = false;
  }

  @override
  Future<void> cancel() async {
    cancels++;
    paused = false;
    if (!result.isCompleted) result.completeError(const ImageCodecCancelled());
  }

  @override
  Future<Uint8List> decode(
    Uint8List data,
    AeicRatePoint rate,
    int size, {
    void Function(double)? onProgress,
  }) => result.future;
  @override
  Future<Uint8List> encode(
    Uint8List data,
    AeicRatePoint rate,
    int size, {
    void Function(double)? onProgress,
  }) {
    encodes++;
    return result.future;
  }

  @override
  Future<void> release({bool decoder = false, bool entropy = false}) async {}
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'send preparation cannot control or queue behind an active received decode',
    () async {
      final session = _ControlledSession();
      final native = ImageCodecModelRecord(
        id: kNativeFt2ModelId,
        name: 'FT2',
        sourceUrl: '',
        localPath: '/fixture/native/manifest.json',
        downloadedAt: DateTime(2026),
        fileSizeBytes: 1,
        bundleVersion: 1,
        bundleKind: ImageCodecBundleKind.nativeFt2Ncnn,
      );
      final service = ImageCodecService(
        AppSettingsService(),
        settingsStore: InMemoryImageCodecSettingsStore(
          ImageCodecPreferences(
            enabled: true,
            selectedModelId: native.id,
            downloadedModels: [native],
          ),
        ),
        sessionFactory: (_) async => session,
      );
      addTearDown(service.dispose);
      final stream = Uint8List(23);
      final header = ByteData.sublistView(stream);
      header.setUint32(0, 128);
      header.setUint32(4, 128);
      header.setUint32(8, 11);
      final decode = service.decodeBitstream(
        bitstream: stream,
        ratePoint: AeicRatePoint.ft2,
        resolution: 128,
      );
      while (!service.canPause) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await service.pause();
      expect(service.isPaused, isTrue);
      await expectLater(
        service.encode(
          Uint8List(0),
          ImageCodecRatePoint.nativeFt2,
          resolution: 128,
        ),
        throwsStateError,
      );
      expect(session.encodes, 0);
      expect(service.isPaused, isTrue);
      await service.resume();
      expect(service.isPaused, isFalse);
      await service.pause();
      await service.cancel();
      expect(session.cancels, 1);
      expect((await decode)?.status, ImageCodecStatus.failed);
      expect(service.isPaused, isFalse);
      expect(service.isBusy, isFalse);
    },
  );
}
