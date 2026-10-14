import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final locale in AppLocalizations.supportedLocales) {
    test(
      'automatic reconstruction text avoids legacy memory/time promises in $locale',
      () async {
        final l10n = await AppLocalizations.delegate.load(locale);
        final text = l10n.imageMessages_autoReconstructSubtitle;
        expect(text, isNotEmpty);
        expect(text, isNot(contains('2 GB')));
        expect(text, isNot(contains('second each time')));
        // Untranslated locales must use the new key's accurate English fallback,
        // rather than their existing translated ONNX one-second description.
        if (locale.languageCode == 'en') {
          expect(text, contains('several minutes on older phones'));
          expect(text, contains('leave off'));
        }
      },
    );
  }
}
