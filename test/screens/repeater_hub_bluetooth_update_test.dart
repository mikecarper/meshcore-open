import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/screens/repeater_hub_screen.dart';
import 'package:meshcore_open/screens/nrf_bluetooth_dfu_screen.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('legacy guest reply still exposes Bluetooth updater', (
    tester,
  ) async {
    final connector = MeshCoreConnector();
    final settings = AppSettingsService();
    addTearDown(connector.dispose);
    addTearDown(settings.dispose);
    final repeater = Contact(
      publicKey: Uint8List.fromList(List.generate(32, (i) => i + 1)),
      name: 'RAK3401',
      type: advTypeRepeater,
      pathLength: 0,
      path: Uint8List(0),
      lastSeen: DateTime(2026, 9, 29),
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<MeshCoreConnector>.value(value: connector),
          ChangeNotifierProvider<AppSettingsService>.value(value: settings),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: RepeaterHubScreen(
            repeater: repeater,
            password: 'test-password',
            isAdmin: false,
          ),
        ),
      ),
    );
    final update = find.text('nRF52 Bluetooth update');
    expect(update, findsOneWidget);
    await tester.ensureVisible(update);
    await tester.tap(update);
    await tester.pumpAndSettle();
    expect(find.byType(NrfBluetoothDfuScreen), findsOneWidget);
  });
}
