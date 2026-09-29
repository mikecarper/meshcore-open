import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/screens/companion_cli_screen.dart';
import 'package:meshcore_open/screens/settings_screen.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

void main() {
  Future<void> pumpCli(WidgetTester tester, _FakeCompanion connector) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<MeshCoreConnector>.value(
        value: connector,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: CompanionCliScreen(),
        ),
      ),
    );
  }

  testWidgets('sends a local command and shows the reply', (tester) async {
    final connector = _FakeCompanion();
    addTearDown(connector.dispose);
    await pumpCli(tester, connector);

    expect(find.textContaining('not over LoRa'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'get name');
    await tester.pump();
    await tester.tap(find.byTooltip('Send command'));
    await tester.pump();

    expect(connector.commands, <String>['get name']);
    expect(find.text('> get name'), findsOneWidget);
    expect(find.text('Test Companion'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear'));
    await tester.pump();
    expect(find.text('No commands sent yet'), findsOneWidget);
  });

  testWidgets('prevents overlapping commands and displays failures', (
    tester,
  ) async {
    final connector = _FakeCompanion();
    addTearDown(connector.dispose);
    final pending = Completer<String>();
    connector.nextReply = pending.future;
    await pumpCli(tester, connector);

    await tester.enterText(find.byType(TextField), 'get radio');
    await tester.pump();
    await tester.tap(find.byTooltip('Send command'));
    await tester.pump();
    expect(connector.commands, <String>['get radio']);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, false);

    pending.completeError(StateError('command failed'));
    await tester.pump();
    expect(find.textContaining('command failed'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, true);
  });

  testWidgets('explains disconnected and unsupported companions', (
    tester,
  ) async {
    final connector = _FakeCompanion(connected: false);
    addTearDown(connector.dispose);
    await pumpCli(tester, connector);
    expect(
      find.text('Connect to a Companion to send commands.'),
      findsOneWidget,
    );
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, false);

    connector.update(connected: true, protocol: 13);
    await tester.pumpAndSettle();
    expect(
      find.text('Local CLI requires Companion protocol version 14 or newer.'),
      findsOneWidget,
    );
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, false);
  });

  testWidgets('fits a compact Android display', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final connector = _FakeCompanion();
    addTearDown(connector.dispose);

    await pumpCli(tester, connector);
    await tester.enterText(find.byType(TextField), 'get name');
    await tester.pump();
    await tester.tap(find.byTooltip('Send command'));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Test Companion'), findsOneWidget);
  });

  testWidgets('Settings exposes the direct Companion CLI', (tester) async {
    PackageInfo.setMockInitialValues(
      appName: 'MeshCore Open',
      packageName: 'com.meshcore.meshcore_open',
      version: '9.5.5',
      buildNumber: '23',
      buildSignature: '',
    );
    final connector = _FakeCompanion();
    addTearDown(connector.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<MeshCoreConnector>.value(
        value: connector,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SettingsScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.scrollUntilVisible(find.text('Companion CLI'), 300);
    await tester.tap(find.text('Companion CLI'));
    await tester.pumpAndSettle();
    expect(find.byType(CompanionCliScreen), findsOneWidget);
  });
}

class _FakeCompanion extends MeshCoreConnector {
  _FakeCompanion({this.connected = true});

  bool connected;
  int protocol = 14;
  Future<String>? nextReply;
  final List<String> commands = [];

  @override
  bool get isConnected => connected;

  @override
  int? get firmwareVerCode => protocol;

  @override
  String get deviceDisplayName => 'Test Companion';

  @override
  Future<String> executeLocalCliCommand(
    String command, {
    Duration timeout = const Duration(seconds: 8),
  }) {
    commands.add(command);
    return nextReply ?? Future<String>.value('Test Companion');
  }

  void update({required bool connected, required int protocol}) {
    this.connected = connected;
    this.protocol = protocol;
    notifyListeners();
  }
}
