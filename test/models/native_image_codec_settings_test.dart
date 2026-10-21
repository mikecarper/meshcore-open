import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/app_settings.dart';

void main() {
  test(
    'the real app settings adapter retains native size and recovery policy',
    () {
      final settings = AppSettings().copyWith(
        imageCodecNativeResolution: 576,
        imageCodecNativeBestEffort: true,
      );
      final restored = AppSettings.fromJson(settings.toJson());
      expect(restored.imageCodec.nativeResolution, 576);
      expect(restored.imageCodec.nativeBestEffort, isTrue);
      expect(
        AppSettings.fromJson({
          'image_codec_native_resolution': 1024,
        }).imageCodec.nativeResolution,
        128,
      );
    },
  );
}
