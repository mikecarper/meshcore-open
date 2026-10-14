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
  const verifyModels = bool.fromEnvironment(
    'SMOKE_VERIFY_MODELS',
    defaultValue: true,
  );
  const selectedSizes = String.fromEnvironment(
    'SMOKE_SIZES',
    defaultValue: '128,576',
  );
  const testControls = bool.fromEnvironment(
    'SMOKE_TEST_CONTROLS',
    defaultValue: true,
  );
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
          if (verifyModels) {
            await step('step=verify_models');
            await service.validateNativeBundle();
          } else {
            // Repeat-only shortcut: the first real app run already verified all
            // SHA256 assets/links. Require its persisted native selection/status.
            await step('step=reuse_previously_verified_models');
            expect(service.preferences.selectedModelId, kNativeFt2ModelId);
            expect(
              service.availableModels.any(
                (record) =>
                    record.id == kNativeFt2ModelId &&
                    record.bundleKind == ImageCodecBundleKind.nativeFt2Ncnn,
              ),
              isTrue,
            );
            await service.refreshDownloadedModels();
            expect(service.installedBundle?.isNativeFt2, isTrue);
          }
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
          final sizes = selectedSizes
              .split(',')
              .map((value) => int.parse(value.trim()))
              .toList();
          expect(sizes, isNotEmpty);
          expect(sizes.every(expected.containsKey), isTrue);

          Future<Map<String, dynamic>> liveJob() async {
            const channel = MethodChannel(
              NativeProcessImageCodecBackend.channelName,
            );
            final ids = await NativeProcessImageCodecBackend.activeJobs();
            expect(ids.length, 1);
            return (await channel.invokeMapMethod<String, dynamic>('poll', {
              'jobId': ids.single,
            }))!;
          }

          Future<void> waitForPauseCapability() async {
            final deadline = DateTime.now().add(const Duration(seconds: 60));
            while (!service.canPause || (service.codecProgress ?? 0) <= 0) {
              if (DateTime.now().isAfter(deadline)) {
                throw StateError('Native job did not reach its first stage.');
              }
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
          }

          Future<String?> workerState(int pid) async {
            final status = File('/proc/$pid/status');
            if (!await status.exists()) return null;
            final text = await status.readAsString();
            return RegExp(
              r'^State:\s+(\S+)',
              multiLine: true,
            ).firstMatch(text)?.group(1);
          }

          Future<String> waitForKernelState(
            int pid, {
            required bool stopped,
          }) async {
            final deadline = DateTime.now().add(const Duration(seconds: 10));
            while (true) {
              final state = await workerState(pid);
              if (state != null && (stopped ? state == 'T' : state != 'T')) {
                return state;
              }
              if (DateTime.now().isAfter(deadline)) {
                throw StateError(
                  'Worker $pid kernel state was $state; stopped=$stopped.',
                );
              }
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
          }

          Future<int> provePause(int size, String phase) async {
            await waitForPauseCapability();
            await service.pause();
            expect(service.isPaused, isTrue);
            final deadline = DateTime.now().add(const Duration(seconds: 10));
            Map<String, dynamic> job;
            do {
              job = await liveJob();
              if (job['paused'] == true &&
                  (job['processGroup'] as num? ?? 0) > 1) {
                break;
              }
              if (DateTime.now().isAfter(deadline)) {
                throw StateError('Native process group did not pause.');
              }
              await Future<void>.delayed(const Duration(milliseconds: 50));
            } while (true);
            final pid = (job['processId'] as num).toInt();
            final state = await waitForKernelState(pid, stopped: true);
            expect(state, 'T');
            await Future<void>.delayed(const Duration(milliseconds: 350));
            final before = (await liveJob())['progress'];
            await step(
              'size=$size step=$phase paused=true kernel_state=$state pid=$pid group=${job['processGroup']} progress=$before',
            );
            await Future<void>.delayed(const Duration(milliseconds: 750));
            final after = await liveJob();
            expect(after['paused'], isTrue);
            expect(
              after['progress'],
              before,
              reason:
                  'Native stage progress must remain stable while SIGSTOP applies.',
            );
            await File('${directory.path}/pause$size.txt').writeAsString(
              'paused=true kernel_state=$state pid=$pid stable_progress=$before group=${job['processGroup']}\n',
              flush: true,
            );
            expect(await workerState(pid), 'T');
            return pid;
          }

          if (testControls) {
            final asset = await rootBundle.load(
              'assets/native_codec_smoke/input128.ppm',
            );
            final rgb = NativeProcessImageCodecBackend.parsePpmRgb(
              asset.buffer.asUint8List(
                asset.offsetInBytes,
                asset.lengthInBytes,
              ),
              128,
            );
            await step('size=128 step=control_encode');
            final encoded = await service.encodeImage(
              rgbBytes: rgb,
              ratePoint: AeicRatePoint.ft2,
              resolution: 128,
            );
            expect(
              encoded?.status,
              ImageCodecStatus.completed,
              reason: service.lastError,
            );
            expect(
              sha256.convert(encoded!.bitstream!).toString(),
              expected[128]!.$2,
            );
            await step('size=128 step=control_decode');
            final cancelled = service.decodeBitstream(
              bitstream: encoded.bitstream!,
              ratePoint: AeicRatePoint.ft2,
              resolution: 128,
            );
            final cancelledWorker = await provePause(128, 'control_pause');
            await service.cancel();
            final result = await cancelled;
            expect(result?.status, ImageCodecStatus.failed);
            expect(result?.rgbBytes, isNull);
            expect(result?.pngBytes, isNull);
            expect(service.isPaused, isFalse);
            expect(service.isBusy, isFalse);
            expect(await NativeProcessImageCodecBackend.activeJobs(), isEmpty);
            expect(
              await File('/proc/$cancelledWorker/status').exists(),
              isFalse,
              reason: 'Cancelled worker must be reaped, not left as a zombie.',
            );
            await resultFile.writeAsString(
              'ANDROID_NATIVE_CODEC_CONTROL size=128 paused=true kernel_state=T cancelled=true worker_reaped=true active_jobs=0\n',
              mode: FileMode.append,
              flush: true,
            );
            await step('size=128 step=control_cancel_complete active_jobs=0');
            await service.releaseModel();
          }

          for (final size in sizes) {
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
            final decoding = service.decodeBitstream(
              bitstream: encoded,
              ratePoint: AeicRatePoint.ft2,
              resolution: size,
            );
            if (testControls && size == 576) {
              final resumedWorker = await provePause(size, 'full_decode_pause');
              await service.resume();
              expect(service.isPaused, isFalse);
              final resumedState = await waitForKernelState(
                resumedWorker,
                stopped: false,
              );
              expect(resumedState, isNot('T'));
              await File('${directory.path}/pause$size.txt').writeAsString(
                'resumed=true kernel_state=$resumedState pid=$resumedWorker\n',
                mode: FileMode.append,
                flush: true,
              );
              await step('size=$size step=full_decode_resumed');
            }
            final decodeResult = await decoding;
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
          expect(await NativeProcessImageCodecBackend.activeJobs(), isEmpty);
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
