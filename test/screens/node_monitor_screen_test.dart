import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/screens/node_monitor_screen.dart';
import 'package:meshcore_open/storage/node_monitor_store.dart';
import 'package:provider/provider.dart';

import '../services/node_monitor_service_test.dart';

Future<void> pumpMonitor(
  WidgetTester tester,
  MonitorTestConnector c, {
  bool settle = true,
}) async {
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
  await tester.pumpWidget(
    ChangeNotifierProvider<MeshCoreConnector>.value(
      value: c,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const NodeMonitorScreen(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.2)),
          child: child!,
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

void main() {
  setUp(monitorPrefs);

  testWidgets('empty dashboard sends nothing and explains selection', (
    tester,
  ) async {
    final c = MonitorTestConnector();
    await pumpMonitor(tester, c);
    expect(find.text('0 selected nodes'), findsOneWidget);
    expect(
      find.textContaining('Select the nodes you want to monitor.'),
      findsOneWidget,
    );
    expect(c.sentFrames, isEmpty);
  });

  testWidgets(
    'selection sends nothing; explicit refresh reads the chosen node',
    (tester) async {
      final c = MonitorTestConnector();
      c.onSend = (_) => c.status(0);
      await pumpMonitor(tester, c);
      await tester.tap(find.text('Select nodes'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Alpha');
      await tester.pumpAndSettle();
      expect(find.text('Bravo room'), findsNothing);
      await tester.tap(find.text('Alpha repeater'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Monitor 1 nodes'));
      await tester.pumpAndSettle();
      expect(c.sentFrames, isEmpty);
      await tester.tap(find.text('Refresh all'));
      await tester.pumpAndSettle();
      expect(c.sentFrames.length, 1);
      expect(NodeMonitorStore().load(c.identity), {c.nodes[0].publicKeyHex});
      await tester.scrollUntilVisible(
        find.text('Battery 4.14 V'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Battery 4.14 V'), findsOneWidget);
      expect(find.text('Uptime 1d 1h'), findsOneWidget);
      expect(find.text('Packets RX 1234 / TX 567'), findsOneWidget);
    },
  );

  testWidgets(
    'automatic refresh waits twelve hours and pause prevents further sends',
    (tester) async {
      final c = MonitorTestConnector();
      await NodeMonitorStore().save(c.identity, {c.nodes[0].publicKeyHex});
      c.onSend = (_) => c.status(0);
      await pumpMonitor(tester, c);
      expect(find.text('Every 12 hours'), findsOneWidget);
      expect(find.text('Every 5 minutes'), findsNothing);
      await tester.pump(const Duration(seconds: 43199));
      expect(c.sentFrames, isEmpty);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(c.sentFrames.length, 1);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(hours: 24));
      expect(c.sentFrames.length, 1);
    },
  );

  testWidgets('background and covered dashboard do not start automatic reads', (
    tester,
  ) async {
    final c = MonitorTestConnector();
    await NodeMonitorStore().save(c.identity, {c.nodes[0].publicKeyHex});
    c.onSend = (_) => c.status(0);
    await pumpMonitor(tester, c);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(hours: 13));
    expect(c.sentFrames, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.tap(find.text('Select nodes'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(hours: 13));
    expect(c.sentFrames, isEmpty);
  });

  testWidgets('manual refresh resets the next automatic twelve-hour wait', (
    tester,
  ) async {
    final c = MonitorTestConnector();
    await NodeMonitorStore().save(c.identity, {c.nodes[0].publicKeyHex});
    c.onSend = (_) => c.status(0);
    await pumpMonitor(tester, c);
    await tester.pump(const Duration(hours: 6));
    expect(c.sentFrames, isEmpty);
    await tester.tap(find.text('Refresh all'));
    await tester.pumpAndSettle();
    expect(c.sentFrames.length, 1);
    await tester.pump(const Duration(hours: 11, minutes: 59));
    expect(c.sentFrames.length, 1);
    await tester.pump(const Duration(minutes: 1));
    await tester.pumpAndSettle();
    expect(c.sentFrames.length, 2);
  });

  testWidgets('manual-only mode stays quiet for days until Refresh is tapped', (
    tester,
  ) async {
    final c = MonitorTestConnector();
    await NodeMonitorStore().save(c.identity, {c.nodes[0].publicKeyHex});
    await NodeMonitorStore().saveInterval(c.identity, 0);
    c.onSend = (_) => c.status(0);
    await pumpMonitor(tester, c);
    await tester.pump(const Duration(days: 2));
    expect(c.sentFrames, isEmpty);
    await tester.tap(find.text('Refresh all'));
    await tester.pumpAndSettle();
    expect(c.sentFrames.length, 1);
  });

  testWidgets('stopping an in-flight refresh sends no next-node request', (
    tester,
  ) async {
    final c = MonitorTestConnector();
    await NodeMonitorStore().save(c.identity, {
      c.nodes[0].publicKeyHex,
      c.nodes[1].publicKeyHex,
    });
    await pumpMonitor(tester, c, settle: false);
    expect(c.sentFrames, isEmpty);
    await tester.tap(find.text('Refresh all'));
    await tester.pump();
    expect(c.sentFrames.length, 1);
    await tester.tap(find.text('Stop refresh'));
    await tester.pumpAndSettle();
    expect(c.sentFrames.length, 1);
    expect(find.text('Refresh stopped'), findsWidgets);
  });

  testWidgets(
    'dashboard and node picker fit a 320dp phone with enlarged text',
    (tester) async {
      tester.view.physicalSize = const Size(480, 854);
      tester.view.devicePixelRatio = 1.5;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = MonitorTestConnector();
      c.nodes[0] = c.nodes[0].copyWith(
        name: 'Very long repeater name that should wrap without losing text',
      );
      await NodeMonitorStore().save(c.identity, {c.nodes[0].publicKeyHex});
      c.onSend = (_) => c.status(0);
      await pumpMonitor(tester, c);
      await tester.tap(find.text('Refresh all'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Battery 4.14 V'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.takeException(), isNull);
      await tester.fling(
        find.byType(Scrollable).first,
        const Offset(0, 2000),
        1500,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select nodes'));
      await tester.pumpAndSettle();
      expect(find.text('Monitor 1 nodes'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
