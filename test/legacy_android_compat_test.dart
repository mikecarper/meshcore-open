import 'package:flutter/material.dart' hide RadioListTile;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/services/image_codec_backend_legacy.dart';
import 'package:meshcore_open/services/translation_service.dart';
import 'package:meshcore_open/widgets/legacy_radio.dart';

void main() {
  test('API 22 build has no native image codec', () {
    expect(kImageCodecBitstreamPathAvailable, isFalse);
    expect(createImageCodecBackend(), isNull);
  });

  test('translation cannot be offered or downloaded on legacy ARM32', () async {
    expect(const bool.fromEnvironment('LEGACY_ARM32'), isTrue);
    final service = TranslationService(AppSettingsService());
    expect(
      service.canTranslateIncoming(
        text: 'hello',
        isCli: false,
        isOutgoing: false,
      ),
      isFalse,
    );
    expect(
      service.shouldTranslateOutgoing(text: 'hello', targetLanguageCode: 'fr'),
      isFalse,
    );
    await expectLater(
      service.downloadModel(sourceUrl: 'https://example.invalid/model.gguf'),
      throwsUnsupportedError,
    );
    service.dispose();
  });

  testWidgets('legacy radio adapter updates selection', (tester) async {
    bool selected = true;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => RadioGroup<bool>(
            groupValue: selected,
            onChanged: (value) => setState(() => selected = value!),
            child: const Scaffold(
              body: Column(
                children: [
                  RadioListTile<bool>(value: true, title: Text('Regular')),
                  RadioListTile<bool>(value: false, title: Text('Community')),
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
    final tiles = tester.widgetList<RadioListTile<bool>>(
      find.byType(RadioListTile<bool>),
    );
    expect(tiles.length, 2);
  });
}
