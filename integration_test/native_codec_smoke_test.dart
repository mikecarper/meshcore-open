import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:integration_test/integration_test.dart';
import 'package:meshcore_open/models/image_codec_support.dart';
import 'package:meshcore_open/services/image_codec_service.dart';
import 'package:meshcore_open/services/native_process_image_codec_backend.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/services/image_codec_file_store.dart';
import 'package:meshcore_open/services/image_codec_settings_store.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';

// The production main.dart adapter stores the same fields in AppSettings.
class _AppCodecSettings implements ImageCodecSettingsStore {
  final AppSettingsService settings;
  const _AppCodecSettings(this.settings);
  @override
  ImageCodecPreferences get preferences => settings.settings.imageCodec;
  @override
  Future<void> load() async {}
  @override
  Future<void> save(ImageCodecPreferences value) =>
      settings.setImageCodecPreferences(value);
}

// Benchmark threads are confined to this test; production remains at two.
class _SmokeCodecService extends ImageCodecService {
  // The same settings instance is passed to the production store adapter.
  // ignore: use_super_parameters
  _SmokeCodecService(AppSettingsService settings)
    : super(settings, settingsStore: _AppCodecSettings(settings));
  @override
  ImageCodecBundle? get installedBundle {
    final bundle = super.installedBundle;
    if (bundle == null || !bundle.isNativeFt2) return bundle;
    return ImageCodecBundle(
      decoderGraphPath: bundle.decoderGraphPath,
      ratePoint: bundle.ratePoint,
      nativeModelDirectory: bundle.nativeModelDirectory,
      nativeCodecIdentity: bundle.nativeCodecIdentity,
      nativeBestEffort: bundle.nativeBestEffort,
      nativeThreads: 4,
    );
  }
}

/// Real Android service -> worker isolate -> native process -> PNG.
/// No mocks, VM inference, or injected decoder latents are used here.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const modelRoot = String.fromEnvironment('NATIVE_MODEL_ROOT');
  testWidgets(
    'native Android128 and576 cycles save real PNGs',
    (tester) async {
      await tester.runAsync(() async {
        final directory = Directory(
          '${Directory.systemTemp.path}/native_codec_smoke',
        );
        await directory.create(recursive: true);
        final resultFile = File('${directory.path}/result.txt');
        final progressFile = File('${directory.path}/progress.txt');
        await resultFile.writeAsString('ANDROID_NATIVE_CODEC_SMOKE_STARTED\n');
        Future<void> step(String value) async {
          // Persist this before a long stage so adb can inspect progress.
          await progressFile.writeAsString('$value\n', flush: true);
          debugPrint('ANDROID_NATIVE_CODEC_SMOKE $value');
        }

        await PrefsManager.initialize();
        final settings = AppSettingsService();
        await settings.loadSettings();
        final service = _SmokeCodecService(settings);
        var percentage = -1;
        void progress() {
          final next = ((service.codecProgress ?? 0) * 100).floor();
          if (next >= percentage + 2) {
            percentage = next;
            debugPrint(
              'ANDROID_NATIVE_CODEC_PROGRESS stage=${service.codecStage} percent=$next',
            );
          }
        }

        service.addListener(progress);
        try {
          final installedRoot =
              '${await ImageCodecFileStore().modelDirectoryPath()}/$kNativeFt2ModelId';
          expect(
            await Directory(modelRoot).resolveSymbolicLinks(),
            await Directory(installedRoot).resolveSymbolicLinks(),
          );
          await step('step=verify_models');
          await service.validateNativeBundle();
          await service.setEnabled(true);
          await settings.setImageMessagesEnabled(true);
          expect(service.preferences.selectedModelId, kNativeFt2ModelId);
          expect(service.preferences.nativeResolution, 128);
          final expected = <int, (int, String)>{
            128: (
              137,
              '49dc462cb8fddccb3e775f288a75756eb408375eb1432521f9531a51aecde1c7',
            ),
            576: (
              1783,
              '35c15d496c87270f38a801562f0297e8b2d9c4a01ce94f809fdec58b5564d385',
            ),
          };
          for (final size in expected.keys) {
            final asset = await rootBundle.load(
              'assets/native_codec_smoke/input$size.ppm',
            );
            final ppm = asset.buffer.asUint8List(
              asset.offsetInBytes,
              asset.lengthInBytes,
            );
            final rgb = NativeProcessImageCodecBackend.parsePpmRgb(ppm, size);
            await File('${directory.path}/original$size.png').writeAsBytes(
              await ImageCodecService.rgbToPng(rgb, size),
              flush: true,
            );
            percentage = -1;
            await step('size=$size step=encode threads=4');
            final encodeResult = await service.encodeImage(
              rgbBytes: rgb,
              ratePoint: AeicRatePoint.ft2,
              resolution: size,
            );
            expect(
              encodeResult?.status,
              ImageCodecStatus.completed,
              reason: service.lastError,
            );
            final encoded = encodeResult!.bitstream!;
            expect(encoded.length, expected[size]!.$1);
            expect(sha256.convert(encoded).toString(), expected[size]!.$2);
            await File(
              '${directory.path}/encoded$size.aeic',
            ).writeAsBytes(encoded, flush: true);
            percentage = -1;
            await step(
              'size=$size step=decode bytes=${encoded.length} threads=4',
            );
            final decodeResult = await service.decodeBitstream(
              bitstream: encoded,
              ratePoint: AeicRatePoint.ft2,
              resolution: size,
            );
            expect(
              decodeResult?.status,
              ImageCodecStatus.completed,
              reason: service.lastError,
            );
            expect(decodeResult!.rgbBytes!.length, size * size * 3);
            expect(decodeResult.degraded, false);
            final png = decodeResult.pngBytes!;
            expect(png.take(8).toList(), [137, 80, 78, 71, 13, 10, 26, 10]);
            await File(
              '${directory.path}/decoded$size.png',
            ).writeAsBytes(png, flush: true);
            final message =
                'ANDROID_NATIVE_CODEC_SMOKE size=$size bytes=${encoded.length} '
                'sha256=${sha256.convert(encoded)} rgb=${decodeResult.rgbBytes!.length} '
                'degraded=${decodeResult.degraded} encode_ms=${encodeResult.durationMs} '
                'decode_ms=${decodeResult.durationMs} png_bytes=${png.length}';
            await resultFile.writeAsString(
              '$message\n',
              mode: FileMode.append,
              flush: true,
            );
            await step('size=$size step=complete');
            await service.releaseModel();
          }
          await step('step=all_complete');
        } catch (error) {
          await resultFile.writeAsString(
            'ANDROID_NATIVE_CODEC_SMOKE_FAILED $error\n',
            mode: FileMode.append,
            flush: true,
          );
          rethrow;
        } finally {
          service.removeListener(progress);
          await service.releaseModel();
          service.dispose();
          settings.dispose();
        }
      });
    },
    timeout: const Timeout(Duration(minutes: 120)),
    skip: modelRoot.isEmpty,
  );
}
