import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/screens/scanner_screen.dart';
import 'package:meshcore_open/theme/mesh_theme.dart';
import 'package:provider/provider.dart';

class _ScannerConnector extends MeshCoreConnector {
  MeshCoreConnectionState current = MeshCoreConnectionState.disconnected;
  int starts = 0;
  int stops = 0;

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
    current = MeshCoreConnectionState.disconnected;
    notifyListeners();
  }

  @override
  Future<void> disconnect({
    bool manual = true,
    bool skipBleDeviceDisconnect = false,
  }) async {}
}

void main() {
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
