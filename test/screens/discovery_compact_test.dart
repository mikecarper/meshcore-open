import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/screens/discovery_screen.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';

class _DiscoveryConnector extends MeshCoreConnector {
  _DiscoveryConnector(this.contact);
  final Contact contact;

  @override
  List<Contact> get discoveredContacts => [contact];
  @override
  List<Contact> get allContacts => [contact];
  @override
  Set<String> get knownContactKeys => {};
  @override
  double get selfLatitude => 45;
  @override
  double get selfLongitude => -122;
}

void main() {
  testWidgets('discovered contact keeps name and route readable at 320dp', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    tester.view.physicalSize = const Size(480, 854);
    tester.view.devicePixelRatio = 1.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final contact = Contact(
      publicKey: Uint8List.fromList(List<int>.generate(pubKeySize, (i) => i)),
      name: 'North Mercer Repeater',
      type: advTypeRepeater,
      pathLength: 2,
      path: Uint8List.fromList([1, 2]),
      latitude: 45,
      longitude: -121,
      lastSeen: DateTime.now(),
    );
    final connector = _DiscoveryConnector(contact);
    final settings = AppSettingsService();
    addTearDown(connector.dispose);
    addTearDown(settings.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<MeshCoreConnector>.value(value: connector),
          ChangeNotifierProvider<AppSettingsService>.value(value: settings),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DiscoveryScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final name = tester.renderObject<RenderParagraph>(
      find.text('North Mercer Repeater'),
    );
    expect(name.didExceedMaxLines, isFalse);
    expect(find.text('2 hops'), findsOneWidget);
    expect(find.text('79 km E'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
