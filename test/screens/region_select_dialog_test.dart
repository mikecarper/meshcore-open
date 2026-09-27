import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/screens/channel_chat_screen.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
  });

  Future<void> openPicker(WidgetTester tester) async {
    tester.view.physicalSize = const Size(480, 854);
    tester.view.devicePixelRatio = 1.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final connector = MeshCoreConnector();
    addTearDown(connector.dispose);
    final channel = Channel.fromHex(0, 'Public', Channel.publicChannelPsk);
    await tester.pumpWidget(
      ChangeNotifierProvider<MeshCoreConnector>.value(
        value: connector,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => RegionSelectDialog(channel: channel),
                ),
                child: const Text('Open regions'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open regions'));
    await tester.pumpAndSettle();
  }

  testWidgets('empty region picker explains itself and offers discovery', (
    tester,
  ) async {
    await openPicker(tester);
    expect(find.text('Select a region'), findsOneWidget);
    expect(find.text('No saved regions yet.'), findsOneWidget);
    expect(find.text('Fetch regions from repeaters'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stored regions are visible in compact picker', (tester) async {
    await PrefsManager.instance.setStringList('regions', ['North', 'South']);
    await openPicker(tester);
    expect(find.text('North'), findsOneWidget);
    expect(find.text('South'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
