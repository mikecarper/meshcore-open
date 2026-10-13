import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/screens/scanner_screen.dart';
import 'package:meshcore_open/theme/mesh_theme.dart';
import 'package:meshcore_open/services/nrf_dfu_recovery_store.dart';
import 'package:meshcore_open/screens/channels_screen.dart';
import 'package:meshcore_open/screens/companion_update_screen.dart';
import 'package:provider/provider.dart';

class _ScannerConnector extends MeshCoreConnector {
  MeshCoreConnectionState current = MeshCoreConnectionState.disconnected;
  int starts = 0;
  int stops = 0;
  int reconnects = 0;
  Completer<void>? delayedStop;

  @override
  Future<bool> tryAutoReconnect() async {
    reconnects++;
    return false;
  }

  @override
  MeshCoreConnectionState get state => current;

  @override
  Future<void> startScan({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    starts++;
    current = MeshCoreConnectionState.scanning;
    notifyListeners();
  }

  @override
  Future<void> stopScan() async {
    stops++;
    await delayedStop?.future;
    current = MeshCoreConnectionState.disconnected;
    notifyListeners();
  }

  @override
  Future<void> disconnect({
    bool manual = true,
    bool skipBleDeviceDisconnect = false,
  }) async {}
}

class _ScannerRecoveryStore extends NrfDfuRecoveryStore {
  bool active = false, fail = false;
  NrfDfuRecoveryRecord? record;
  @override
  Future<bool> hasUnconfirmedNativeTransfer() async {
    if (fail) throw StateError('Storage unavailable');
    return active;
  }

  @override
  Future<NrfDfuRecoveryRecord?> load() async => record;
}

NrfDfuRecoveryRecord _record() => NrfDfuRecoveryRecord(
  path: '/test/recovery.zip',
  originalAddress: 'EB:9D:56:B2:48:48',
  board: 'Heltec T096',
  publicKey: 'a' * 64,
  filename: 'exact-board.zip',
  applicationOnly: true,
  expiresAt: DateTime.utc(2026, 10, 13),
  nativeMayBeActive: false,
);

Future<void> _mountScanner(
  WidgetTester tester,
  _ScannerConnector connector,
  _ScannerRecoveryStore store, {
  WidgetBuilder? recoveryBuilder,
}) => tester.pumpWidget(
  ChangeNotifierProvider<MeshCoreConnector>.value(
    value: connector,
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ScannerScreen(
        recoveryStore: store,
        recoveryBuilder: recoveryBuilder,
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'no saved recovery leaves exactly the ordinary scan button and autoreconnect',
    (tester) async {
      final connector = _ScannerConnector();
      addTearDown(connector.dispose);
      await _mountScanner(tester, connector, _ScannerRecoveryStore());
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('scanner_dfu_recovery')), findsNothing);
      expect(find.text('Scan'), findsOneWidget);
      expect(connector.reconnects, 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final pending in [false, true]) {
    testWidgets(
      'disconnected scanner exposes ${pending ? 'pending native' : 'verified ZIP'} recovery without autoreconnect',
      (tester) async {
        final connector = _ScannerConnector();
        addTearDown(connector.dispose);
        final store = _ScannerRecoveryStore()
          ..active = pending
          ..record = pending ? null : _record();
        await _mountScanner(
          tester,
          connector,
          store,
          recoveryBuilder: (_) => const Scaffold(body: Text('Recovery view')),
        );
        await tester.pumpAndSettle();
        final recovery = find.byKey(const ValueKey('scanner_dfu_recovery'));
        expect(recovery.hitTestable(), findsOneWidget);
        expect(find.text('Scan'), findsOneWidget);
        expect(connector.reconnects, 0);
        final stops = connector.stops;
        await tester.tap(recovery);
        await tester.pumpAndSettle();
        expect(connector.stops, stops + 1);
        expect(connector.preserveUpdateScreenOnDisconnect, isTrue);
        expect(find.text('Recovery view'), findsOneWidget);
        store.active = false;
        store.record = null;
        tester.state<NavigatorState>(find.byType(Navigator)).pop();
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('scanner_dfu_recovery')),
          findsNothing,
        );
        expect(connector.preserveUpdateScreenOnDisconnect, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'recovery navigation blocks connected-route push before and while view is open',
    (tester) async {
      final connector = _ScannerConnector();
      addTearDown(connector.dispose);
      final store = _ScannerRecoveryStore()..record = _record();
      await _mountScanner(
        tester,
        connector,
        store,
        recoveryBuilder: (_) => const Scaffold(body: Text('Recovery view')),
      );
      await tester.pumpAndSettle();
      connector.delayedStop = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('scanner_dfu_recovery')));
      await tester.pump();
      connector.current = MeshCoreConnectionState.connected;
      connector.notifyListeners();
      await tester.pump();
      expect(find.byType(ChannelsScreen), findsNothing);
      connector.delayedStop!.complete();
      connector.delayedStop = null;
      await tester.pumpAndSettle();
      expect(find.text('Recovery view'), findsOneWidget);
      connector.current = MeshCoreConnectionState.connected;
      connector.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byType(ChannelsScreen), findsNothing);
      expect(find.text('Recovery view'), findsOneWidget);
      connector.current = MeshCoreConnectionState.disconnected;
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'default recovery entry opens actual Companion updater for a pending native lease',
    (tester) async {
      final connector = _ScannerConnector();
      addTearDown(connector.dispose);
      await _mountScanner(
        tester,
        connector,
        _ScannerRecoveryStore()..active = true,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('scanner_dfu_recovery')));
      await tester.pumpAndSettle();
      expect(find.byType(CompanionUpdateScreen), findsOneWidget);
      expect(find.text('Check stopped Bluetooth updater'), findsOneWidget);
      expect(find.byType(ChannelsScreen), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'recovery storage failure is handled without extra controls or unsafe autoreconnect',
    (tester) async {
      final connector = _ScannerConnector();
      addTearDown(connector.dispose);
      await _mountScanner(
        tester,
        connector,
        _ScannerRecoveryStore()..fail = true,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('scanner_dfu_recovery')), findsNothing);
      expect(find.text('Scan'), findsOneWidget);
      expect(connector.reconnects, 0);
      expect(tester.takeException(), isNull);
    },
  );

  for (final dark in [false, true]) {
    testWidgets(
      'one reachable scan action in ${dark ? 'dark' : 'light'} theme',
      (tester) async {
        tester.view.physicalSize = const Size(480, 854);
        tester.view.devicePixelRatio = 1.5;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final connector = _ScannerConnector();
        addTearDown(connector.dispose);
        await tester.pumpWidget(
          ChangeNotifierProvider<MeshCoreConnector>.value(
            value: connector,
            child: MaterialApp(
              theme: dark ? MeshTheme.dark() : MeshTheme.light(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const ScannerScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final action = find.byKey(const ValueKey('scanner_scan_action'));
        expect(find.text('Scan'), findsOneWidget);
        expect(action.hitTestable(), findsOneWidget);
        expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
        expect(find.byType(FloatingActionButton), findsNothing);

        await tester.tap(action);
        await tester.pump(const Duration(milliseconds: 400));
        expect(connector.starts, 1);
        expect(find.text('Stop'), findsOneWidget);
        expect(find.text('Scan'), findsNothing);
        final stops = connector.stops;
        await tester.tap(action);
        await tester.pumpAndSettle();
        expect(connector.stops, stops + 1);
        expect(find.text('Scan'), findsOneWidget);

        connector.current = MeshCoreConnectionState.connecting;
        connector.notifyListeners();
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.widget<FilledButton>(action).onPressed, isNull);
        expect(tester.takeException(), isNull);

        // Landscape and large text must still leave the action reachable.
        tester.view.physicalSize = const Size(854, 480);
        tester.platformDispatcher.textScaleFactorTestValue = 1.6;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pump(const Duration(milliseconds: 400));
        expect(action.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
    );
  }
}
