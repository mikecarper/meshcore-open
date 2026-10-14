import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/image_codec_support.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/services/image_codec_service.dart';
import 'package:meshcore_open/services/image_codec_settings_store.dart';

void main() {
  test(
    'native public setting flows to the next installed session bundle',
    () async {
      final model = ImageCodecModelRecord(
        id: kNativeFt2ModelId,
        name: 'FT2',
        sourceUrl: '',
        localPath: '/private/ft2/manifest.json',
        downloadedAt: DateTime(2026),
        fileSizeBytes: 2036938808,
        bundleVersion: 1,
        bundleKind: ImageCodecBundleKind.nativeFt2Ncnn,
      );
      final store = InMemoryImageCodecSettingsStore(
        ImageCodecPreferences(
          enabled: true,
          selectedModelId: model.id,
          downloadedModels: [model],
        ),
      );
      final service = ImageCodecService(
        AppSettingsService(),
        settingsStore: store,
      );
      addTearDown(service.dispose);
      expect(service.hasUsableGpuAcceleration, isFalse);
      expect(service.nativeDecoderMode, AeicDecoderMode.fast);
      expect(service.installedBundle!.nativeDecoderMode, isNull);
      await service.setNativeDecoderMode(AeicDecoderMode.accurate);
      expect(store.preferences.nativeDecoderMode, AeicDecoderMode.accurate);
      expect(service.nativeDecoderMode, AeicDecoderMode.accurate);
      expect(
        service.installedBundle!.nativeDecoderMode,
        AeicDecoderMode.accurate,
      );
    },
  );
}
