import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/app_settings.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/services/translation_service.dart';

class _EnabledTranslationSettings extends AppSettingsService {
  @override
  AppSettings get settings => AppSettings().copyWith(
    translationEnabled: true,
    autoTranslateIncomingMessages: true,
    composerTranslationEnabled: true,
  );
}

void main() {
  test(
    'legacy build explicitly rejects translation despite enabled stored preferences',
    () async {
      final service = TranslationService(_EnabledTranslationSettings());
      expect(service.isSupported, isFalse);
      expect(
        service.canTranslateIncoming(
          text: 'Hello',
          isCli: false,
          isOutgoing: false,
        ),
        isFalse,
      );
      expect(
        service.shouldAutoTranslateIncoming(
          text: 'Hello',
          isCli: false,
          isOutgoing: false,
        ),
        isFalse,
      );
      expect(
        service.shouldTranslateOutgoing(
          text: 'Hello',
          targetLanguageCode: 'fr',
        ),
        isFalse,
      );
      expect(await service.detectLanguage('Hello'), isNull);
      await expectLater(
        service.downloadModel(sourceUrl: 'not a URL'),
        throwsUnsupportedError,
      );
      service.dispose();
    },
    skip: !const bool.fromEnvironment('LEGACY_ARM32'),
  );
}
