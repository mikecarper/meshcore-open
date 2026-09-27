import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/screens/companion_update_screen.dart';
import 'package:meshcore_open/theme/mesh_theme.dart';
import 'package:meshcore_open/widgets/update_status_card.dart';
import 'package:provider/provider.dart';

class _CompanionConnector extends MeshCoreConnector {
  _CompanionConnector({this.connected = true});

  final bool connected;

  @override
  bool get isConnected => connected;

  @override
  Future<String> executeLocalCliCommand(
    String command, {
    Duration timeout = const Duration(seconds: 8),
  }) async => command == 'board'
      ? 'Heltec T096'
      : 'v1.17.1.8-halo-keymind-cascade-dev-d4b3bb56';
}

void main() {
  for (final dark in [false, true]) {
    testWidgets(
      'firmware workflow fits API 22 phone, ${dark ? 'dark' : 'light'}',
      (tester) async {
        tester.view.physicalSize = const Size(480, 854);
        tester.view.devicePixelRatio = 1.5;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final connector = _CompanionConnector();
        addTearDown(connector.dispose);
        await tester.pumpWidget(
          ChangeNotifierProvider<MeshCoreConnector>.value(
            value: connector,
            child: MaterialApp(
              theme: dark ? MeshTheme.dark() : MeshTheme.light(),
              home: const CompanionUpdateScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text('Find updates on GitHub').hitTestable(),
          findsOneWidget,
        );
        expect(find.text('Use a firmware file').hitTestable(), findsOneWidget);
        expect(find.byType(UpdateStatusCard), findsOneWidget);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        await tester.tap(find.text('Use a firmware file'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Phone Downloads'));
        await tester.pumpAndSettle();
        expect(find.text('Phone Downloads').hitTestable(), findsOneWidget);
        await tester.ensureVisible(find.text('Browse files'));
        await tester.pumpAndSettle();
        expect(find.text('Browse files').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);

        tester.view.physicalSize = const Size(854, 480);
        tester.platformDispatcher.textScaleFactorTestValue = 1.6;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Browse files'));
        await tester.pumpAndSettle();
        expect(find.text('Browse files').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('transfer status has one progress bar with a percentage', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: UpdateStatusCard(
            message: 'Sending firmware',
            busy: true,
            progress: 42,
          ),
        ),
      ),
    );
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      0.42,
    );
    expect(find.text('42%'), findsOneWidget);
  });

  testWidgets(
    'disconnected Companion shows an actionable error and stops progress',
    (tester) async {
      final connector = _CompanionConnector(connected: false);
      addTearDown(connector.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider<MeshCoreConnector>.value(
          value: connector,
          child: const MaterialApp(home: CompanionUpdateScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Connect to a Companion first.'), findsOneWidget);
      expect(
        tester.widget<UpdateStatusCard>(find.byType(UpdateStatusCard)).isError,
        isTrue,
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
    },
  );
}
