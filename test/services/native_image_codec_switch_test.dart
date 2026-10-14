import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/image_codec_support.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/services/image_codec_file_store.dart';
import 'package:meshcore_open/services/image_codec_service.dart';
import 'package:meshcore_open/services/image_codec_settings_store.dart';

class _NativeInstallStore extends ImageCodecFileStore {
  final ImageCodecModelRecord record;
  _NativeInstallStore(this.record);
  @override
  Future<ImageCodecModelRecord> importNativeBundle({
    required Stream<List<int>> chunks,
    void Function(int completed, int total)? onProgress,
  }) async => record;
}

void main() {
  for (final importing in [false, true]) {
    test(
      '${importing ? 'importing' : 'selecting'} FT2 clears a different bundle runtime failure',
      () async {
        final spec = imageCodecPresetModels.first;
        final legacy = ImageCodecModelRecord(
          id: spec.id,
          name: spec.fileName,
          sourceUrl: '',
          localPath: '/models/${spec.fileName}',
          downloadedAt: DateTime(2026),
          fileSizeBytes: 1,
          bundleVersion: kImageCodecBundleVersion,
          assetFileNames: [for (final asset in spec.assets) asset.fileName],
          assetRoles: {
            for (final asset in spec.assets) asset.fileName: asset.role,
          },
        );
        final native = ImageCodecModelRecord(
          id: kNativeFt2ModelId,
          name: 'FT2',
          sourceUrl: '',
          localPath: '/private/ft2/manifest.json',
          downloadedAt: DateTime(2026),
          fileSizeBytes: 2036938808,
          bundleVersion: 1,
          bundleKind: ImageCodecBundleKind.nativeFt2Ncnn,
        );
        final attempts = <ImageCodecBundle>[];
        final service = ImageCodecService(
          AppSettingsService(),
          fileStore: _NativeInstallStore(native),
          settingsStore: InMemoryImageCodecSettingsStore(
            ImageCodecPreferences(
              enabled: true,
              selectedModelId: legacy.id,
              downloadedModels: [legacy, native],
            ),
          ),
          sessionFactory: (bundle) async {
            attempts.add(bundle);
            if (!bundle.isNativeFt2) {
              throw const ImageCodecUnimplemented('legacy unavailable');
            }
            throw StateError('native factory reached');
          },
        );
        addTearDown(service.dispose);
        await service.encodeImage(
          rgbBytes: Uint8List(512 * 512 * 3),
          ratePoint: AeicRatePoint.ft32,
        );
        expect(service.unavailableReason, contains('legacy unavailable'));
        expect(service.canEncode, isFalse);
        if (importing) {
          await service.importNativeBundle(const Stream<List<int>>.empty());
        } else {
          await service.setSelectedModelId(native.id);
        }
        expect(service.unavailableReason, isNull);
        expect(service.canEncode, isTrue);
        expect(service.canDecode, isTrue);
        expect(service.needsModelUpgrade, isFalse);
        final result = await service.encodeImage(
          rgbBytes: Uint8List(128 * 128 * 3),
          ratePoint: AeicRatePoint.ft2,
        );
        expect(attempts.length, 2);
        expect(attempts.last.isNativeFt2, isTrue);
        expect(
          result?.status,
          ImageCodecStatus.failed,
          reason: 'The test only proves factory routing, never neural output.',
        );
      },
    );
  }
}
