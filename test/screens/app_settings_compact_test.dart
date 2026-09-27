import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/screens/app_settings_screen.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/services/translation_service.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('theme choices stay on one compact row at 320dp', (tester) async {
    tester.view.physicalSize = const Size(480, 854);
    tester.view.devicePixelRatio = 1.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final settings = AppSettingsService();
    final connector = MeshCoreConnector();
    final translation = TranslationService(settings);
    addTearDown(translation.dispose);
    addTearDown(connector.dispose);
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppSettingsService>.value(value: settings),
          ChangeNotifierProvider<MeshCoreConnector>.value(value: connector),
          ChangeNotifierProvider<TranslationService>.value(value: translation),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AppSettingsScreen(),
        ),
      ),
    );

    final themes = find.byType(SegmentedButton<String>);
    expect(
      find.descendant(of: themes, matching: find.text('System default')),
      findsOneWidget,
    );
    expect(find.text('Light'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
    expect(tester.getSize(themes).height, lessThan(60));
    expect(tester.takeException(), isNull);
  });
}
