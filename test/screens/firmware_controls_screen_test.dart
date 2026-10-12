import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/screens/node_notifications_screen.dart';
import 'package:meshcore_open/screens/secondary_radio_screen.dart';
import 'package:meshcore_open/screens/node_filters_screen.dart';
import 'package:meshcore_open/screens/fleet_management_screen.dart';
import 'package:provider/provider.dart';

import '../services/firmware_controls_test.dart'
    show ControlTestConnector, controlTestContact;

String _reply(String command) {
  if (command == 'get notify') {
    return '> enabled=on outputs=12 supported=12 active=off rules=12';
  }
  if (command == 'get notify.rules') return '> slots:';
  if (command.startsWith('get notify.remote')) return 'off';
  if (command.startsWith('get notify.')) return 'inherit';
  if (command == 'get radio2') return '> off';
  if (command == 'get radio2.status') {
    return '> off; RX=0,0 TX=0,0 switches=0 errors=0 max=0us preamble=32,32';
  }
  if (command == 'get radio2.cross') return '> auto';
  if (command == 'get radio2.timing' || command == 'get tempradio2') {
    return '> off';
  }
  if (command == 'get tx.channel 0') {
    return '> tx.channel 0 "Public" auto; active=radio';
  }
  if (command == 'get fr') return '> 1=ota~radio@all!drop~tempradio';
  if (command == 'get fr.1') return 'set fr.1 12 d f=t';
  if (command == 'get flood.filter.blacklist') return '> off';
  if (command == 'get flood.moderation') return '> off';
  if (command == 'get flood.channel.scope') {
    return '> 0/31 active; use get flood.channel.scope.<n>';
  }
  return 'OK';
}

Future<void> _pump(
  WidgetTester tester,
  ControlTestConnector c,
  Widget screen,
) async {
  c.handler ??= (command) async => _reply(command);
  c.remoteHandler ??= (command) async => _reply(command);
  await tester.pumpWidget(
    ChangeNotifierProvider<MeshCoreConnector>.value(
      value: c,
      child: MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: screen,
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

Future<void> _visible(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    250,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'filter editor copies an insert into fleet review without slot or send',
    (tester) async {
      final c = ControlTestConnector();
      addTearDown(c.dispose);
      await _pump(tester, c, NodeFiltersScreen(target: controlTestContact()));
      final before = List<String>.of(c.commands);
      await _visible(tester, find.text('Send rule over fleet channel'));
      await tester.tap(find.text('Send rule over fleet channel'));
      await tester.pumpAndSettle();
      expect(find.byType(FleetManagementScreen), findsOneWidget);
      expect(
        tester
            .widget<FleetManagementScreen>(find.byType(FleetManagementScreen))
            .initialCommand,
        'set flood.rule 12 d f=t',
      );
      expect(c.commands, before);
    },
  );
  testWidgets('Radio 2 editor copies a validated profile without changing it', (
    tester,
  ) async {
    final c = ControlTestConnector();
    addTearDown(c.dispose);
    await _pump(tester, c, const SecondaryRadioScreen());
    final before = List<String>.of(c.commands);
    await _visible(tester, find.text('Send profile over fleet channel'));
    await tester.tap(find.text('Send profile over fleet channel'));
    await tester.pumpAndSettle();
    expect(find.byType(FleetManagementScreen), findsOneWidget);
    expect(
      tester
          .widget<FleetManagementScreen>(find.byType(FleetManagementScreen))
          .initialCommand,
      'set radio2 off',
    );
    expect(c.commands, before);
  });
  testWidgets(
    'alerts read only on entry; unsupported outputs disabled; cancel never writes',
    (tester) async {
      final c = ControlTestConnector();
      addTearDown(c.dispose);
      await _pump(tester, c, const NodeNotificationsScreen());
      expect(c.commands.every((s) => s.startsWith('get ')), true);
      await _visible(tester, find.text('Find my node'));
      final vibration = tester.widget<TextField>(find.byType(TextField).first);
      expect(vibration.enabled, false);
      await _visible(tester, find.text('Find my node'));
      await tester.tap(find.text('Find my node'));
      await tester.pump();
      await _visible(tester, find.text('Save rule'));
      await tester.tap(find.text('Save rule'));
      await tester.pumpAndSettle();
      expect(find.text('Save to Companion?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(c.commands.where((s) => s.startsWith('set ')), isEmpty);
      await tester.tap(find.text('Save rule'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(c.commands.where((s) => s.startsWith('set ')), [
        'set notify.led all 200,200,200,200,600',
        'set notify.screen all on',
        'set notify.repeat all 10',
        'set notify.gap all 500',
        'set notify.stop all button',
      ]);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('older firmware feature failure leaves setters disabled', (
    tester,
  ) async {
    final c = ControlTestConnector()..handler = (_) async => 'Unknown command';
    addTearDown(c.dispose);
    await _pump(tester, c, const NodeNotificationsScreen());
    expect(find.textContaining('Unknown command'), findsOneWidget);
    await _visible(tester, find.text('Save rule'));
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save rule'))
          .onPressed,
      isNull,
    );
    expect(c.commands, ['get notify']);
  });
  testWidgets(
    'Radio 2 routing reads saved route and writes only after confirmation',
    (tester) async {
      final c = ControlTestConnector();
      addTearDown(c.dispose);
      await _pump(tester, c, SecondaryRadioScreen(channel: c.channels.first));
      expect(c.commands, contains('get tx.channel 0'));
      expect(c.commands.every((s) => s.startsWith('get ')), true);
      await tester.tap(find.text('Automatic'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Both profiles').last);
      await tester.pumpAndSettle();
      await _visible(tester, find.text('Save channel route'));
      await tester.tap(find.text('Save channel route'));
      await tester.pumpAndSettle();
      expect(c.commands.where((s) => s.startsWith('set ')), isEmpty);
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(c.commands.where((s) => s.startsWith('set ')), [
        'set tx.channel 0 both',
      ]);
      expect(find.text('Saved to device.'), findsOneWidget);
    },
  );
  testWidgets(
    'channel replacement is detected rather than writing new channel',
    (tester) async {
      final c = ControlTestConnector();
      addTearDown(c.dispose);
      await _pump(tester, c, SecondaryRadioScreen(channel: c.channels.first));
      c.testChannels.clear();
      await _visible(tester, find.text('Save channel route'));
      await tester.tap(find.text('Save channel route'));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView).first, const Offset(0, 1800));
      await tester.pumpAndSettle();
      expect(find.textContaining('This channel changed'), findsOneWidget);
      expect(c.commands.where((s) => s.startsWith('set ')), isEmpty);
    },
  );
  testWidgets(
    'filter GUI uses correlated LoRa commands; new rules never overwrite defaults',
    (tester) async {
      final c = ControlTestConnector();
      addTearDown(c.dispose);
      await _pump(tester, c, NodeFiltersScreen(target: controlTestContact()));
      expect(find.text('Editing saved rule 1'), findsOneWidget);
      expect(c.commands.every((s) => s.startsWith('get ')), true);
      await tester.tap(find.text('Add new rule'));
      await tester.pumpAndSettle();
      await _visible(tester, find.text('Add rule to device'));
      await tester.tap(find.text('Add rule to device'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(c.commands.where((s) => s.startsWith('set ')), isEmpty);
      await tester.tap(find.text('Add rule to device'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(c.commands.where((s) => s.startsWith('set ')), ['set fr any d']);
    },
  );
  testWidgets('unrepresented filter options cannot be silently overwritten', (
    tester,
  ) async {
    final c = ControlTestConnector()
      ..remoteHandler = (command) async =>
          command == 'get fr.1' ? 'set fr.1 any d future=on' : _reply(command);
    addTearDown(c.dispose);
    await _pump(tester, c, NodeFiltersScreen(target: controlTestContact()));
    expect(
      find.textContaining('Unrecognized saved rule option'),
      findsOneWidget,
    );
    await _visible(tester, find.text('Add rule to device'));
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Add rule to device'),
          )
          .onPressed,
      isNull,
    );
  });
  testWidgets(
    'small Android layouts remain usable with scaled text and keyboard',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final screen in [
        const NodeNotificationsScreen(),
        const SecondaryRadioScreen(),
        NodeFiltersScreen(target: controlTestContact()),
      ]) {
        final c = ControlTestConnector();
        await _pump(tester, c, screen);
        expect(tester.takeException(), isNull);
        final label = screen is NodeNotificationsScreen
            ? 'Repeat count'
            : screen is SecondaryRadioScreen
            ? 'Frequency (MHz)'
            : 'Received hops';
        await _visible(
          tester,
          find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.labelText == label,
          ),
        );
        tester.view.viewInsets = const FakeViewPadding(bottom: 230);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        tester.view.resetViewInsets();
        await tester.pumpWidget(const SizedBox());
        c.dispose();
      }
    },
  );
  testWidgets('overlapping reads do not send concurrent commands', (
    tester,
  ) async {
    final c = ControlTestConnector();
    final pending = Completer<String>();
    c.handler = (_) => pending.future;
    addTearDown(c.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<MeshCoreConnector>.value(
        value: c,
        child: const MaterialApp(home: NodeNotificationsScreen()),
      ),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Read device'));
    await tester.pump();
    expect(c.commands, ['get notify']);
    pending.complete('Unknown command');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
