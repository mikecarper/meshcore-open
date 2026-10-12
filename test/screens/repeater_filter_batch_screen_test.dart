import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/screens/repeater_filter_batch_screen.dart';
import 'package:meshcore_open/screens/node_filters_screen.dart';
import 'package:provider/provider.dart';

import '../services/repeater_filter_batch_test.dart'
    show BatchTestConnector, batchReply;

Future<void> pumpBatch(
  WidgetTester tester,
  BatchTestConnector c, {
  Widget? home,
}) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<MeshCoreConnector>.value(
      value: c,
      child: MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home:
            home ??
            RepeaterFilterBatchScreen(
              command: 'set fr 12 d f=t',
              description: 'OTA drop; skip during temporary radio',
              sourceKey: c.nodes.first.publicKeyHex,
            ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.2)),
          child: child!,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> visible(WidgetTester tester, String label) async {
  await tester.scrollUntilVisible(
    find.text(label),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('read-only checks can be cancelled without changing settings', (
    tester,
  ) async {
    final c = BatchTestConnector();
    c.remoteHandler = null;
    addTearDown(c.dispose);
    await pumpBatch(tester, c);
    await visible(tester, 'Check selected repeaters');
    await tester.tap(find.text('Check selected repeaters'));
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('Cancel checks'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Cancel checks'));
    await tester.pumpAndSettle();
    expect(c.sentFrames.length, 1);
    await visible(tester, 'Apply to selected repeaters');
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Apply to selected repeaters'),
          )
          .onPressed,
      isNull,
    );
  });
  testWidgets(
    'editor copies current rule without its source slot or early writes',
    (tester) async {
      final c = BatchTestConnector();
      addTearDown(c.dispose);
      c.answer = (_, command) async {
        if (command == 'get flood.filter.blacklist' ||
            command == 'get flood.moderation') {
          return 'off';
        }
        if (command == 'get flood.channel.scope') return '0/31 active';
        return batchReply(command);
      };
      await pumpBatch(
        tester,
        c,
        home: NodeFiltersScreen(target: c.nodes.first),
      );
      await visible(tester, 'Apply to selected repeaters');
      await tester.tap(find.text('Apply to selected repeaters'));
      await tester.pumpAndSettle();
      expect(find.byType(RepeaterFilterBatchScreen), findsOneWidget);
      expect(
        find.textContaining('Skip during temporary radio'),
        findsOneWidget,
      );
      expect(c.commands.where((s) => s.startsWith('set ')), isEmpty);
      await visible(tester, 'Check selected repeaters');
      await tester.tap(find.text('Check selected repeaters'));
      await tester.pumpAndSettle();
      await visible(tester, 'Apply to selected repeaters');
      await tester.tap(find.text('Apply to selected repeaters'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply filter'));
      await tester.pumpAndSettle();
      expect(c.commands.where((s) => s.startsWith('set ')), [
        'set fr 12 d f=t',
      ]);
    },
  );
  testWidgets('only admin repeaters appear; empty list explains login', (
    tester,
  ) async {
    final c = BatchTestConnector();
    addTearDown(c.dispose);
    await pumpBatch(tester, c, home: const LoggedInRepeaterFiltersScreen());
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Bravo'), findsOneWidget);
    expect(find.text('Guest'), findsNothing);
    c.login(c.nodes[0], fail: true);
    c.login(c.nodes[1], admin: false);
    await tester.pumpAndSettle();
    expect(find.textContaining('No confirmed admin logins'), findsOneWidget);
    expect(c.commands, isEmpty);
  });
  testWidgets(
    'read-only check, explicit selection, cancel and confirmed apply',
    (tester) async {
      final c = BatchTestConnector();
      addTearDown(c.dispose);
      await pumpBatch(tester, c);
      await tester.tap(find.text('Bravo'));
      await tester.pumpAndSettle();
      await visible(tester, 'Apply to selected repeaters');
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Apply to selected repeaters'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Check selected repeaters'));
      await tester.pumpAndSettle();
      expect(c.commands.every((s) => s.startsWith('get ')), true);
      await visible(tester, 'Apply to selected repeaters');
      await tester.tap(find.text('Apply to selected repeaters'));
      await tester.pumpAndSettle();
      expect(find.text('Apply to 2 repeater(s)?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(c.commands.where((s) => s.startsWith('set ')), isEmpty);
      await tester.tap(find.text('Apply to selected repeaters'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply filter'));
      await tester.pumpAndSettle();
      expect(c.commands.where((s) => s.startsWith('set ')).length, 2);
      expect(
        find.textContaining('2 of 2 repeater(s) acknowledged'),
        findsOneWidget,
      );
      await visible(tester, 'Apply to selected repeaters');
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Apply to selected repeaters'),
            )
            .onPressed,
        isNull,
      );
    },
  );
  testWidgets(
    'selection change invalidates checks and prevents repeat insert',
    (tester) async {
      final c = BatchTestConnector();
      addTearDown(c.dispose);
      await pumpBatch(tester, c);
      await visible(tester, 'Check selected repeaters');
      await tester.tap(find.text('Check selected repeaters'));
      await tester.pumpAndSettle();
      await visible(tester, 'Bravo');
      await tester.tap(find.text('Bravo'));
      await tester.pumpAndSettle();
      await visible(tester, 'Apply to selected repeaters');
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Apply to selected repeaters'),
            )
            .onPressed,
        isNull,
      );
      expect(c.commands.where((s) => s.startsWith('set ')), isEmpty);
    },
  );
  testWidgets('unsupported selected node disables apply', (tester) async {
    final c = BatchTestConnector();
    addTearDown(c.dispose);
    c.answer = (key, command) async =>
        key == 43 ? 'Unknown command' : batchReply(command);
    await pumpBatch(tester, c);
    await tester.tap(find.text('Bravo'));
    await tester.pumpAndSettle();
    await visible(tester, 'Check selected repeaters');
    await tester.tap(find.text('Check selected repeaters'));
    await tester.pumpAndSettle();
    await visible(tester, 'Apply to selected repeaters');
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Apply to selected repeaters'),
          )
          .onPressed,
      isNull,
    );
    expect(find.textContaining('Some repeaters are not ready'), findsOneWidget);
  });
  testWidgets('admin revocation while confirming prevents sending', (
    tester,
  ) async {
    final c = BatchTestConnector();
    addTearDown(c.dispose);
    await pumpBatch(tester, c);
    await visible(tester, 'Check selected repeaters');
    await tester.tap(find.text('Check selected repeaters'));
    await tester.pumpAndSettle();
    await visible(tester, 'Apply to selected repeaters');
    await tester.tap(find.text('Apply to selected repeaters'));
    await tester.pumpAndSettle();
    c.login(c.nodes[0], fail: true);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply filter'));
    await tester.pumpAndSettle();
    expect(c.commands.where((s) => s.startsWith('set ')), isEmpty);
  });
  testWidgets('320dp phone at enlarged text has no horizontal overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = BatchTestConnector();
    addTearDown(c.dispose);
    c.nodes[0] = c.nodes[0].copyWith(
      name: 'Long repeater name on a small phone',
    );
    await pumpBatch(tester, c);
    await visible(tester, 'Check selected repeaters');
    await tester.tap(find.text('Check selected repeaters'));
    await tester.pumpAndSettle();
    await visible(tester, 'Apply to selected repeaters');
    await tester.tap(find.text('Apply to selected repeaters'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
