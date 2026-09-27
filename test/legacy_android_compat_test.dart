import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/app_settings.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/services/image_codec_backend.dart';
import 'package:meshcore_open/services/image_codec_session_io.dart';
import 'package:meshcore_open/services/translation_service.dart';
import 'package:meshcore_open/widgets/legacy_radio.dart' as legacy_radio;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const legacy = bool.fromEnvironment('LEGACY_ARM32');
  test('native image codec follows the selected build profile', () {
    expect(kImageCodecBitstreamPathAvailable, !legacy);
    final backend = createImageCodecBackend();
    expect(backend, legacy ? isNull : isA<OnnxImageCodecBackend>());
  });

  test('worker factory connects the real entropy coder', () async {
    imageCodecRansCoderBuilder = null;
    final backend = createWorkerImageCodecBackend();
    expect(imageCodecRansCoderBuilder, isNotNull);
    final coder = await imageCodecRansCoderBuilder!(
      'test/services/golden/aeic_cdf_ft32.bin',
    );
    expect(coder, isA<AeicRansCoders>());
    await backend?.dispose();
  });

  test('translation follows the selected profile even when enabled', () async {
    final service = TranslationService(_EnabledTranslationSettings());
    expect(
      service.canTranslateIncoming(
        text: 'hello',
        isCli: false,
        isOutgoing: false,
      ),
      !legacy,
    );
    expect(
      service.shouldTranslateOutgoing(text: 'hello', targetLanguageCode: 'fr'),
      !legacy,
    );
    if (legacy) {
      await expectLater(
        service.downloadModel(sourceUrl: 'https://example.invalid/model.gguf'),
        throwsUnsupportedError,
      );
    }
    service.dispose();
  });

  testWidgets('legacy radio adapter updates selection', (tester) async {
    bool selected = true;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => legacy_radio.RadioGroup<bool>(
            groupValue: selected,
            onChanged: (value) => setState(() => selected = value!),
            child: const Scaffold(
              body: Column(
                children: [
                  legacy_radio.RadioListTile<bool>(
                    value: true,
                    title: Text('Regular'),
                  ),
                  legacy_radio.RadioListTile<bool>(
                    value: false,
                    title: Text('Community'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Community'));
    await tester.pump();
    expect(selected, isFalse);
    final tiles = tester.widgetList<legacy_radio.RadioListTile<bool>>(
      find.byType(legacy_radio.RadioListTile<bool>),
    );
    expect(tiles.length, 2);
  });
}

class _EnabledTranslationSettings extends AppSettingsService {
  @override
  AppSettings get settings =>
      AppSettings(translationEnabled: true, composerTranslationEnabled: true);
}
