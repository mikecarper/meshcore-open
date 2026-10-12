import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/screens/fleet_management_screen.dart';
import 'package:provider/provider.dart';

import '../services/fleet_management_test.dart' show FleetTestConnector;

Future<void> pumpFleet(
  WidgetTester tester,
  FleetTestConnector c, {
  String? command,
}) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<MeshCoreConnector>.value(
      value: c,
      child: MaterialApp(
        home: FleetManagementScreen(initialCommand: command),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> visible(WidgetTester tester, String text) async {
  await tester.scrollUntilVisible(
    find.text(text),
    180,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  late FleetTestConnector c;
  setUp(() => c = FleetTestConnector());
  tearDown(() => c.dispose());

  testWidgets('open is silent; only an explicit capability check sends', (
    tester,
  ) async {
    await pumpFleet(tester, c);
    expect(c.commands, isEmpty);
    expect(find.text('Fleet management'), findsOneWidget);
    expect(find.text('Private fleet (CH 3)'), findsOneWidget);
    expect(find.text('Public (CH 0)'), findsNothing);
    await tester.tap(find.text('Check publisher support'));
    await tester.pumpAndSettle();
    expect(c.commands, ['fleet']);
  });
  testWidgets('empty selection cannot silently send all', (tester) async {
    await pumpFleet(tester, c);
    await tester.tap(find.text('Check publisher support'));
    await tester.pumpAndSettle();
    await visible(tester, 'Review and send control');
    await tester.tap(find.text('Review and send control'));
    await tester.pumpAndSettle();
    expect(c.commands, ['fleet']);
    expect(find.byType(AlertDialog), findsNothing);
    await visible(tester, 'FormatException: Select at least one node.');
  });
  testWidgets('selected exact identity review can cancel without a broadcast', (
    tester,
  ) async {
    await pumpFleet(tester, c);
    await tester.tap(find.text('Check publisher support'));
    await tester.pumpAndSettle();
    await visible(tester, 'Choose nodes (0)');
    await tester.tap(find.text('Choose nodes (0)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alpha'));
    await tester.tap(find.text('Use selection'));
    await tester.pumpAndSettle();
    await visible(tester, 'Review and send control');
    await tester.tap(find.text('Review and send control'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Alpha (exact identity)'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(c.commands, ['fleet']);
  });
  testWidgets(
    'confirmed control uses actual signed sender and unverified report label',
    (tester) async {
      await pumpFleet(tester, c);
      await tester.tap(find.text('Check publisher support'));
      await tester.pumpAndSettle();
      await visible(tester, 'Choose nodes (0)');
      await tester.tap(find.text('Choose nodes (0)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alpha'));
      await tester.tap(find.text('Use selection'));
      await tester.pumpAndSettle();
      await visible(tester, 'Review and send control');
      await tester.tap(find.text('Review and send control'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send control'));
      await tester.pumpAndSettle();
      expect(
        c.commands.last,
        'fleet send 3 ${c.nodes.first.publicKeyHex} get radio2',
      );
      await visible(
        tester,
        'Unverified channel reports - sequence ${FleetTestConnector.sequence}',
      );
      expect(find.text('No matching reports received.'), findsOneWidget);
    },
  );
  testWidgets('channel change during confirmation sends nothing', (
    tester,
  ) async {
    await pumpFleet(tester, c);
    await tester.tap(find.text('Check publisher support'));
    await tester.pumpAndSettle();
    await visible(tester, 'Choose nodes (0)');
    await tester.tap(find.text('Choose nodes (0)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alpha'));
    await tester.tap(find.text('Use selection'));
    await tester.pumpAndSettle();
    await visible(tester, 'Review and send control');
    await tester.tap(find.text('Review and send control'));
    await tester.pumpAndSettle();
    c.testChannels.removeLast();
    c.testChannels.add(Channel.fromHex(3, 'Public', Channel.publicChannelPsk));
    c.notifyListeners();
    await tester.pump();
    await tester.tap(find.text('Send control'));
    await tester.pumpAndSettle();
    expect(c.commands, ['fleet']);
  });
  testWidgets('copied filter drafts do not write before confirmation', (
    tester,
  ) async {
    await pumpFleet(tester, c, command: 'set flood.rule 12 d f=t');
    expect(c.commands, isEmpty);
    await visible(tester, 'Setting value');
    expect(find.text('12 d f=t'), findsOneWidget);
  });
  testWidgets(
    '320dp enlarged text remains scrollable with no overflow or ellipsis',
    (tester) async {
      tester.view.physicalSize = const Size(480, 854);
      tester.view.devicePixelRatio = 1.5;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await pumpFleet(tester, c);
      expect(tester.takeException(), isNull);
      await visible(tester, 'Review and send control');
      expect(tester.takeException(), isNull);
      final labels = tester.widgetList<Text>(find.byType(Text));
      expect(labels.where((t) => t.data?.contains('...') ?? false), isEmpty);
    },
  );
}
