import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:meshcore_open/models/app_settings.dart';
import 'package:meshcore_open/models/image_codec_support.dart';
import 'package:meshcore_open/services/app_settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
  });
  test('old and unknown preferences follow usable acceleration safely', () {
    for (final json in [
      <String, dynamic>{},
      {'image_codec_native_decoder_mode': 'future'},
    ]) {
      final mode = ImageCodecPreferences.fromJson(json).nativeDecoderMode;
      expect(mode, isNull);
      expect(
        resolveAeicDecoderMode(mode, usableGpuAcceleration: false),
        AeicDecoderMode.fast,
      );
      expect(
        resolveAeicDecoderMode(mode, usableGpuAcceleration: true),
        AeicDecoderMode.accurate,
      );
    }
  });
  test(
    'explicit Accurate persists through preferences and real AppSettings adapter',
    () async {
      final prefs = ImageCodecPreferences.fromJson(
        const ImageCodecPreferences(
          nativeDecoderMode: AeicDecoderMode.accurate,
        ).toJson(),
      );
      final service = AppSettingsService();
      await service.setImageCodecPreferences(prefs);
      final restored = AppSettings.fromJson(service.settings.toJson());
      expect(restored.imageCodec.nativeDecoderMode, AeicDecoderMode.accurate);
      expect(
        resolveAeicDecoderMode(
          restored.imageCodec.nativeDecoderMode,
          usableGpuAcceleration: false,
        ),
        AeicDecoderMode.accurate,
      );
      expect(
        restored.copyWith().imageCodec.nativeDecoderMode,
        AeicDecoderMode.accurate,
      );
      expect(
        restored
            .copyWith(imageCodecNativeDecoderMode: null)
            .imageCodec
            .nativeDecoderMode,
        isNull,
      );
      expect(prefs.copyWith(nativeDecoderMode: null).nativeDecoderMode, isNull);
    },
  );
  test('mode participates in native bundle session identity', () {
    const fast = ImageCodecBundle(
      decoderGraphPath: 'native',
      nativeDecoderMode: AeicDecoderMode.fast,
    );
    const accurate = ImageCodecBundle(
      decoderGraphPath: 'native',
      nativeDecoderMode: AeicDecoderMode.accurate,
    );
    expect(fast, isNot(accurate));
  });
}
