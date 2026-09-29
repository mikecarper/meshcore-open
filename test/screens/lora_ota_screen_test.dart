import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/models/path_selection.dart';
import 'package:meshcore_open/screens/lora_ota_screen.dart';
import 'package:meshcore_open/services/ble_mota_catalog.dart';
import 'package:meshcore_open/services/repeater_command_service.dart';
import 'package:meshcore_open/services/lora_ota_hop_session.dart';
import 'package:meshcore_open/services/storage_service.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:meshcore_open/theme/mesh_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/mota_test_data.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
  });
  testWidgets('restores saved path when both preflight routes time out', (
    tester,
  ) async {
    final target = Contact(
      publicKey: Uint8List.fromList(
        List<int>.generate(pubKeySize, (index) => index + 16),
      ),
      name: 'Unreachable repeater',
      type: advTypeRepeater,
      pathLength: 1,
      path: Uint8List.fromList(<int>[0x77]),
      lastSeen: DateTime(2026, 9, 26),
    );
    final connector = _FakeMotaConnector(target, null);
    final commands = _FakeRepeaterCommandService(
      connector,
      unreachableProbeContact: target.name,
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<MeshCoreConnector>.value(
        value: connector,
        child: MaterialApp(
          home: LoRaOtaScreen(repeater: target, commandService: commands),
        ),
      ),
    );
    final button = find.text('Find updates on GitHub');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
    await tester.pump();
    expect(commands.calls[0].path, <int>[0x77]);
    expect(commands.calls[1].path, <int>[]);
    expect(connector.preparedPaths.last, <int>[0x77]);
    await tester.pumpWidget(const SizedBox.shrink());
    await connector.closeFake();
  });

  testWidgets(
    'runs phone OTA workflow and renders both progress measures',
    (tester) async {
      tester.view.physicalSize = const Size(430, 932);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final catalog = (await tester.runAsync(
        () => BleMotaCatalog.load(<XFile>[
          XFile.fromData(
            buildTestFullMotaContainer(),
            path: 'TEST_BOARD-full-v1.17.1.2.mota',
            name: 'TEST_BOARD-full-v1.17.1.2.mota',
          ),
        ]),
      ))!;
      final target = Contact(
        publicKey: Uint8List.fromList(
          List<int>.generate(pubKeySize, (index) => index + 16),
        ),
        name: 'Test repeater',
        type: advTypeRepeater,
        pathLength: 2,
        path: Uint8List.fromList(<int>[0xA1, 0xB2]),
        lastSeen: DateTime(2026, 8, 26),
      );
      final connector = _FakeMotaConnector(
        target,
        catalog,
        radioFrequencyHz: 910525000,
        radioBandwidthHz: 62500,
        radioSf: 7,
        radioCr: 5,
      );
      final commands = _FakeRepeaterCommandService(connector);

      await tester.pumpWidget(
        ChangeNotifierProvider<MeshCoreConnector>.value(
          value: connector,
          child: MaterialApp(
            theme: MeshTheme.dark().copyWith(
              splashFactory: NoSplash.splashFactory,
            ),
            home: LoRaOtaScreen(repeater: target, commandService: commands),
          ),
        ),
      );

      expect(find.text('Encrypted mOTA channel: Ready'), findsOneWidget);
      final pageScroll = find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.textContaining('Passive hops need no entry'),
        300,
        scrollable: pageScroll,
      );
      expect(find.textContaining('Passive hops need no entry'), findsOneWidget);

      final start = find.text('Test radios and start source');
      await tester.scrollUntilVisible(start, 300, scrollable: pageScroll);
      final startButton = find.ancestor(
        of: start,
        matching: find.byWidgetPredicate((widget) => widget is FilledButton),
      );
      final startCallback = tester.widget<FilledButton>(startButton).onPressed;
      expect(startCallback, isNotNull);
      startCallback!();
      for (var tick = 0; tick < 40; tick++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(
        connector.localCommands
            .where((command) => command != 'ota config')
            .take(3),
        <String>[
          'tempradio 910.525,62.5,7,5,3',
          'tempradio',
          'tempradio 910.525,62.5,7,5,120',
        ],
      );
      final radioCalls = commands.calls.where(
        (call) => call.command != 'ota config',
      );
      expect(radioCalls.take(4).map((call) => call.command), <String>[
        'tempradio 910.525,62.5,7,5,3',
        'ota status',
        'tempradio 910.525,62.5,7,5,120',
        'ota ls',
      ]);
      expect(radioCalls.take(4).map((call) => call.minimumTimeoutMs), <int>[
        15000,
        20000,
        15000,
        20000,
      ]);
      expect(connector.sourceStarts, 1);

      final pull = find.text('Pull');
      await tester.scrollUntilVisible(pull, -300, scrollable: pageScroll);
      expect(pull, findsOneWidget);
      await tester.tap(pull);
      await tester.pump();
      await tester.tap(find.text('Start download'));
      await tester.pump();
      await tester.pump();

      final file = catalog.files.single;
      await tester.runAsync(() => file.read(file.payloadOffset, 1024));
      await tester.pump(const Duration(seconds: 2));

      final check = find.text('Check download');
      await tester.scrollUntilVisible(check, 300, scrollable: pageScroll);
      await tester.ensureVisible(check);
      await tester.pump();
      expect(check, findsOneWidget);
      await tester.tap(check);
      await tester.pump();
      await tester.pump();

      expect(find.text('Sent / queued by source'), findsOneWidget);
      expect(find.text('1 / 3 blocks'), findsOneWidget);
      expect(find.text('Confirmed by target'), findsOneWidget);
      expect(find.text('1 / 3 verified blocks'), findsOneWidget);
      expect(find.text('LoRa source packets: 42'), findsOneWidget);
      expect(commands.commands, contains('ota pull ${file.manifestId} flash'));

      final stop = find.text('Stop and restore controlled radios');
      await tester.scrollUntilVisible(stop, 300, scrollable: pageScroll);
      final stopButton = find.ancestor(
        of: stop,
        matching: find.byWidgetPredicate((widget) => widget is OutlinedButton),
      );
      final stopCallback = tester.widget<OutlinedButton>(stopButton).onPressed;
      expect(stopCallback, isNotNull);
      stopCallback!();
      await tester.pump();
      await tester.pump();
      expect(connector.bleMotaCatalog, isNull);

      final remove = find.byTooltip(
        'Remove TEST_BOARD-full-v1.17.1.2.mota from catalog',
      );
      await tester.scrollUntilVisible(remove, -300, scrollable: pageScroll);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('No packages selected'),
        -300,
        scrollable: pageScroll,
      );
      expect(find.text('No packages selected'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await connector.closeFake();
    },
  );

  testWidgets('rejects non-finite frequencies before sending radio commands', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final catalog = (await tester.runAsync(
      () => BleMotaCatalog.load(<XFile>[
        XFile.fromData(
          buildTestFullMotaContainer(),
          path: 'TEST_BOARD-full-v1.17.1.2.mota',
          name: 'TEST_BOARD-full-v1.17.1.2.mota',
        ),
      ]),
    ))!;
    final target = Contact(
      publicKey: Uint8List.fromList(
        List<int>.generate(pubKeySize, (index) => index + 24),
      ),
      name: 'Finite-frequency target',
      type: advTypeRepeater,
      pathLength: 0,
      path: Uint8List(0),
      lastSeen: DateTime(2026, 8, 30),
    );
    final connector = _FakeMotaConnector(target, catalog);
    final commands = _FakeRepeaterCommandService(connector);

    await tester.pumpWidget(
      ChangeNotifierProvider<MeshCoreConnector>.value(
        value: connector,
        child: MaterialApp(
          theme: MeshTheme.dark().copyWith(
            splashFactory: NoSplash.splashFactory,
          ),
          home: LoRaOtaScreen(repeater: target, commandService: commands),
        ),
      ),
    );

    final pageScroll = find
        .descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        )
        .first;
    final frequencyField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.labelText == 'Frequency (MHz)',
    );

    for (final (index, invalidFrequency) in <String>[
      'NaN',
      'Infinity',
    ].indexed) {
      await tester.scrollUntilVisible(
        frequencyField,
        index == 0 ? 300 : -300,
        scrollable: pageScroll,
      );
      await tester.enterText(frequencyField, invalidFrequency);
      final start = find.text('Test radios and start source');
      await tester.scrollUntilVisible(start, 300, scrollable: pageScroll);
      tester
          .widget<FilledButton>(
            find.ancestor(
              of: start,
              matching: find.byWidgetPredicate(
                (widget) => widget is FilledButton,
              ),
            ),
          )
          .onPressed!();
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Frequency must be 150-2500 MHz.'),
        findsWidgets,
      );
      expect(commands.commands, isEmpty);
      expect(connector.localCommands, isEmpty);
      expect(connector.sourceStarts, 0);
    }

    await tester.pumpWidget(const SizedBox.shrink());
    await connector.closeFake();
  });

  testWidgets('recovers lost pull reply and bootloader install reply', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final catalog = (await tester.runAsync(
      () async => BleMotaCatalog.load(<XFile>[
        XFile.fromData(
          await buildTestBootloaderMotaContainer(),
          path: 'GAT562-bootloader-2.4.5.mota',
          name: 'GAT562-bootloader-2.4.5.mota',
        ),
      ]),
    ))!;
    final file = catalog.files.single;
    final target = Contact(
      publicKey: Uint8List.fromList(
        List<int>.generate(pubKeySize, (index) => index + 80),
      ),
      name: 'Remote GAT562',
      type: advTypeRepeater,
      pathLength: 0,
      path: Uint8List(0),
      lastSeen: DateTime(2026, 9, 5),
    );
    final connector = _FakeMotaConnector(target, catalog);
    final commands = _FakeRepeaterCommandService(
      connector,
      readyToInstall: true,
      statusManifestId: file.manifestId,
      pullReplyTimesOut: true,
      installReplyTimesOut: true,
      bootloaderStatus:
          'BL board=239A0029 target=D50D2D44 name=GAT562_DFU '
          'crc=12345678 abi=3 caps=0A | staged:ready '
          'mid=${file.manifestId} hash=${file.imageHashPrefix}',
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<MeshCoreConnector>.value(
        value: connector,
        child: MaterialApp(
          theme: MeshTheme.dark().copyWith(
            splashFactory: NoSplash.splashFactory,
          ),
          home: LoRaOtaScreen(repeater: target, commandService: commands),
        ),
      ),
    );

    final pageScroll = find
        .descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        )
        .first;
    final start = find.text('Test radios and start source');
    await tester.scrollUntilVisible(start, 300, scrollable: pageScroll);
    tester
        .widget<FilledButton>(
          find.ancestor(
            of: start,
            matching: find.byWidgetPredicate(
              (widget) => widget is FilledButton,
            ),
          ),
        )
        .onPressed!();
    for (var tick = 0; tick < 40; tick++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final pull = find.text('Pull');
    await tester.scrollUntilVisible(pull, -300, scrollable: pageScroll);
    await tester.tap(pull);
    await tester.pump();
    await tester.tap(find.text('Start download'));
    await tester.pump();
    await tester.pump();

    final check = find.text('Check download');
    await tester.scrollUntilVisible(check, 300, scrollable: pageScroll);
    await tester.ensureVisible(check);
    await tester.pump();
    await tester.tap(check);
    await tester.pump();
    await tester.pump();
    expect(find.text('READY TO INSTALL'), findsOneWidget);

    await tester.tap(find.text('Install and reboot'));
    await tester.pump();
    expect(find.text('Install staged bootloader?'), findsOneWidget);
    expect(find.textContaining(file.manifestId), findsWidgets);
    expect(find.textContaining(file.imageHashPrefix), findsOneWidget);
    await tester.tap(find.text('Install and reboot').last);
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));

    expect(commands.commands, contains('ota bootloader'));
    expect(
      commands.commands,
      contains(
        'ota bootloader install ${file.manifestId} ${file.imageHashPrefix}',
      ),
    );
    expect(commands.commands, isNot(contains('ota install')));
    expect(connector.localCommands, contains('normalradio'));
    expect(connector.sourceStops, greaterThan(0));
    expect(commands.commands, isNot(contains('normalradio')));
    expect(find.textContaining('Installing firmware failed'), findsNothing);
    expect(find.text('Verify installed update'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await connector.closeFake();
  });

  testWidgets('restores radios when the three-minute target probe fails', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final catalog = (await tester.runAsync(
      () => BleMotaCatalog.load(<XFile>[
        XFile.fromData(
          buildTestFullMotaContainer(),
          path: 'TEST_BOARD-full-v1.17.1.2.mota',
          name: 'TEST_BOARD-full-v1.17.1.2.mota',
        ),
      ]),
    ))!;
    final target = Contact(
      publicKey: Uint8List.fromList(
        List<int>.generate(pubKeySize, (index) => index + 48),
      ),
      name: 'Unreachable repeater',
      type: advTypeRepeater,
      pathLength: 0,
      path: Uint8List(0),
      lastSeen: DateTime(2026, 8, 27),
    );
    final connector = _FakeMotaConnector(target, catalog);
    final commands = _FakeRepeaterCommandService(
      connector,
      unreachableProbeContact: target.name,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<MeshCoreConnector>.value(
        value: connector,
        child: MaterialApp(
          theme: MeshTheme.dark().copyWith(
            splashFactory: NoSplash.splashFactory,
          ),
          home: LoRaOtaScreen(repeater: target, commandService: commands),
        ),
      ),
    );

    final pageScroll = find
        .descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        )
        .first;
    final start = find.text('Test radios and start source');
    await tester.scrollUntilVisible(start, 300, scrollable: pageScroll);
    tester
        .widget<FilledButton>(
          find.ancestor(
            of: start,
            matching: find.byWidgetPredicate(
              (widget) => widget is FilledButton,
            ),
          ),
        )
        .onPressed!();
    for (var tick = 0; tick < 40; tick++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(connector.sourceStarts, 0);
    expect(commands.commands, <String>[
      'tempradio 909.950,250,5,5,3',
      'ota status',
      'normalradio',
    ]);
    expect(connector.localCommands, <String>[
      'tempradio 909.950,250,5,5,3',
      'tempradio',
      'normalradio',
    ]);
    expect(connector.bleMotaCatalog, isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await connector.closeFake();
  });

  testWidgets('blocks the source when a controlled relay probe fails', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Contact repeater(String name, int prefix, List<int> path) => Contact(
      publicKey: Uint8List.fromList(<int>[
        prefix,
        ...List<int>.generate(pubKeySize - 1, (index) => index + prefix + 1),
      ]),
      name: name,
      type: advTypeRepeater,
      pathLength: path.length,
      path: Uint8List.fromList(path),
      lastSeen: DateTime(2026, 8, 27),
    );

    final relay = repeater('Unreachable relay', 0x41, const <int>[]);
    final target = repeater('Reachable target', 0x62, <int>[
      relay.publicKey.first,
    ]);
    final catalog = (await tester.runAsync(
      () => BleMotaCatalog.load(<XFile>[
        XFile.fromData(
          buildTestFullMotaContainer(),
          path: 'TEST_BOARD-full-v1.17.1.2.mota',
          name: 'TEST_BOARD-full-v1.17.1.2.mota',
        ),
      ]),
    ))!;
    final connector = _FakeMotaConnector(
      target,
      catalog,
      additionalContacts: <Contact>[relay],
    );
    final commands = _FakeRepeaterCommandService(
      connector,
      unreachableProbeContact: relay.name,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<MeshCoreConnector>.value(
        value: connector,
        child: MaterialApp(
          theme: MeshTheme.dark().copyWith(
            splashFactory: NoSplash.splashFactory,
          ),
          home: LoRaOtaScreen(repeater: target, commandService: commands),
        ),
      ),
    );

    final pageScroll = find
        .descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        )
        .first;
    final add = find.text('Add controlled intermediate');
    await tester.scrollUntilVisible(add, 300, scrollable: pageScroll);
    await tester.pumpAndSettle();
    await tester.tap(add);
    await tester.pumpAndSettle();
    await tester.tap(find.text(relay.name));
    await tester.pumpAndSettle();

    final start = find.text('Test radios and start source');
    await tester.scrollUntilVisible(start, 300, scrollable: pageScroll);
    tester
        .widget<FilledButton>(
          find.ancestor(
            of: start,
            matching: find.byWidgetPredicate(
              (widget) => widget is FilledButton,
            ),
          ),
        )
        .onPressed!();
    for (var tick = 0; tick < 40; tick++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(connector.sourceStarts, 0);
    expect(commands.commands.where((command) => command == 'ver').length, 1);
    expect(
      commands.commands.where(
        (command) => command == 'tempradio 909.950,250,5,5,120',
      ),
      isEmpty,
    );
    expect(
      commands.calls
          .where((call) => call.command == 'normalradio')
          .map((call) => call.contact),
      <String>['Reachable target', 'Unreachable relay'],
    );
    expect(connector.localCommands.last, 'normalradio');
    expect(connector.bleMotaCatalog, isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await connector.closeFake();
  });

  testWidgets('orders controlled multi-hop handoffs and restores end to end', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Contact repeater(String name, int prefix, List<int> path) => Contact(
      publicKey: Uint8List.fromList(<int>[
        prefix,
        ...List<int>.generate(pubKeySize - 1, (index) => index + prefix + 1),
      ]),
      name: name,
      type: advTypeRepeater,
      pathLength: path.length,
      path: Uint8List.fromList(path),
      lastSeen: DateTime(2026, 8, 26),
    );

    final near = repeater('Near relay', 0x31, const <int>[]);
    final far = repeater('Far relay', 0x52, <int>[near.publicKey.first]);
    final target = repeater('Target repeater', 0x73, <int>[
      near.publicKey.first,
      far.publicKey.first,
    ]);
    final catalog = (await tester.runAsync(
      () => BleMotaCatalog.load(<XFile>[
        XFile.fromData(
          buildTestFullMotaContainer(),
          path: 'TEST_BOARD-full-v1.17.1.2.mota',
          name: 'TEST_BOARD-full-v1.17.1.2.mota',
        ),
      ]),
    ))!;
    final connector = _FakeMotaConnector(
      target,
      catalog,
      additionalContacts: <Contact>[near, far],
    );
    final commands = _FakeRepeaterCommandService(connector);
    connector.otaHops = 0;
    commands.otaHops.addAll({target.name: 0, far.name: 0, near.name: 8});

    await tester.pumpWidget(
      ChangeNotifierProvider<MeshCoreConnector>.value(
        value: connector,
        child: MaterialApp(
          theme: MeshTheme.dark().copyWith(
            splashFactory: NoSplash.splashFactory,
          ),
          home: LoRaOtaScreen(repeater: target, commandService: commands),
        ),
      ),
    );

    final pageScroll = find
        .descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        )
        .first;
    final add = find.text('Add controlled intermediate');
    await tester.scrollUntilVisible(add, 300, scrollable: pageScroll);
    await tester.pumpAndSettle();
    await tester.tap(add);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Far relay'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(add, -300, scrollable: pageScroll);
    await tester.pumpAndSettle();
    await tester.tap(add);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Near relay'));
    await tester.pumpAndSettle();

    final start = find.text('Test radios and start source');
    await tester.scrollUntilVisible(start, 300, scrollable: pageScroll);
    final startButton = find.ancestor(
      of: start,
      matching: find.byWidgetPredicate((widget) => widget is FilledButton),
    );
    final startCallback = tester.widget<FilledButton>(startButton).onPressed;
    expect(startCallback, isNotNull);
    startCallback!();
    for (var tick = 0; tick < 40; tick++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final setup = commands.calls
        .where((call) => call.command.startsWith('tempradio '))
        .map((call) => '${call.contact}: ${call.command}')
        .toList();
    expect(setup, <String>[
      'Target repeater: tempradio 909.950,250,5,5,3',
      'Far relay: tempradio 909.950,250,5,5,3',
      'Near relay: tempradio 909.950,250,5,5,3',
      'Target repeater: tempradio 909.950,250,5,5,120',
      'Far relay: tempradio 909.950,250,5,5,120',
      'Near relay: tempradio 909.950,250,5,5,120',
    ]);
    final probes = commands.calls
        .where((call) => call.command == 'ota status' || call.command == 'ver')
        .map((call) => call.contact)
        .toList();
    expect(probes, <String>['Target repeater', 'Far relay', 'Near relay']);
    expect(connector.sourceStarts, 1);
    expect(connector.otaHops, 2);
    expect(commands.otaHops, {target.name: 2, far.name: 2, near.name: 8});
    expect(
      (await StorageService().loadLoraOtaHopRecovery(
        connector.selfPublicKeyHex,
        target.publicKeyHex,
      )).length,
      3,
    );

    final stop = find.text('Stop and restore controlled radios');
    await tester.scrollUntilVisible(stop, 300, scrollable: pageScroll);
    final stopButton = find.ancestor(
      of: stop,
      matching: find.byWidgetPredicate((widget) => widget is OutlinedButton),
    );
    final stopCallback = tester.widget<OutlinedButton>(stopButton).onPressed;
    expect(stopCallback, isNotNull);
    stopCallback!();
    await tester.pump();
    await tester.pump();

    await tester.pumpAndSettle();
    final restore = commands.calls
        .where((call) => call.command == 'normalradio')
        .map((call) => call.contact)
        .toList();
    expect(restore, <String>['Target repeater', 'Far relay', 'Near relay']);
    expect(connector.otaHops, 0);
    expect(commands.otaHops, {target.name: 0, far.name: 0, near.name: 8});
    expect(
      await StorageService().loadLoraOtaHopRecovery(
        connector.selfPublicKeyHex,
        target.publicKeyHex,
      ),
      isEmpty,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await connector.closeFake();
  });

  testWidgets('reattaches the BLE source and resumes after a link loss', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final catalog = (await tester.runAsync(
      () => BleMotaCatalog.load(<XFile>[
        XFile.fromData(
          buildTestFullMotaContainer(),
          path: 'TEST_BOARD-full-v1.17.1.2.mota',
          name: 'TEST_BOARD-full-v1.17.1.2.mota',
        ),
      ]),
    ))!;
    final target = Contact(
      publicKey: Uint8List.fromList(
        List<int>.generate(pubKeySize, (index) => index + 32),
      ),
      name: 'Resume repeater',
      type: advTypeRepeater,
      pathLength: 0,
      path: Uint8List(0),
      lastSeen: DateTime(2026, 8, 27),
    );
    final connector = _FakeMotaConnector(target, catalog);
    final commands = _FakeRepeaterCommandService(connector);

    await tester.pumpWidget(
      ChangeNotifierProvider<MeshCoreConnector>.value(
        value: connector,
        child: MaterialApp(
          theme: MeshTheme.dark().copyWith(
            splashFactory: NoSplash.splashFactory,
          ),
          home: LoRaOtaScreen(repeater: target, commandService: commands),
        ),
      ),
    );

    final pageScroll = find
        .descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        )
        .first;
    final start = find.text('Test radios and start source');
    await tester.scrollUntilVisible(start, 300, scrollable: pageScroll);
    final startButton = find.ancestor(
      of: start,
      matching: find.byWidgetPredicate((widget) => widget is FilledButton),
    );
    tester.widget<FilledButton>(startButton).onPressed!();
    for (var tick = 0; tick < 40; tick++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(connector.sourceStarts, 1);
    expect(connector.attached, isTrue);

    connector.simulateDisconnect();
    // MeshCoreConnector intentionally batches UI notifications for 50 ms.
    await tester.pump(const Duration(milliseconds: 100));
    expect(connector.attached, isFalse);

    // The Companion connection can return before protected-service discovery
    // and notification subscription finish.  Do not issue source commands
    // until that channel-ready transition is reported.
    connector.simulateReconnect(channelReady: false);
    await tester.pump(const Duration(seconds: 1));
    expect(connector.sourceStarts, 1);
    connector.setChannelReady(true);
    for (var tick = 0; tick < 40; tick++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(connector.sourceStarts, 2);
    expect(connector.attached, isTrue);
    expect(
      connector.localCommands
          .where((command) => command.startsWith('tempradio '))
          .length,
      3,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await connector.closeFake();
  });

  testWidgets(
    'passive route raises source and target, then restores before install',
    (tester) async {
      final h = await _HopScreenHarness.mount(tester, readyToInstall: true);
      h.connector.otaHops = 0;
      h.commands.otaHops[h.target.name] = 0;
      await h.start(tester);
      expect(h.connector.sourceStarts, 1);
      expect(h.connector.otaHops, 2);
      expect(h.commands.otaHops[h.target.name], 2);
      expect((await h.saved()).length, 2);
      expect(
        h.commands.calls
            .where((call) => call.command == 'ota config')
            .every((call) => call.path.length == 2),
        isTrue,
      );
      await h.click(tester, 'Pull');
      await tester.tap(find.text('Start download'));
      await tester.pumpAndSettle();
      await h.click(tester, 'Check download');
      h.commands.inspectCommand = (command) {
        if (command == 'ota install') {
          expect(h.connector.attached, isFalse);
          expect(h.connector.otaHops, 0);
          expect(h.commands.otaHops[h.target.name], 0);
          expect(
            PrefsManager.instance.getKeys().where(
              (key) => key.startsWith('lora_ota_hop_recovery_'),
            ),
            isEmpty,
          );
        }
      };
      await h.click(tester, 'Install and reboot');
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, 'Install and reboot'),
        ),
      );
      for (var tick = 0; tick < 30; tick++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(h.commands.commands, contains('ota install'));
      expect(await h.saved(), isEmpty);
      await h.close(tester);
    },
  );

  for (final failure in ['unknown', 'probe', 'write']) {
    testWidgets(
      '$failure failure prevents source and cleans up partial hop changes',
      (tester) async {
        final h = await _HopScreenHarness.mount(
          tester,
          unreachableProbe: failure == 'probe',
        );
        h.connector.otaHops = 0;
        h.commands.otaHops[h.target.name] = 0;
        if (failure == 'unknown') h.commands.hopConfigError = 'Unknown command';
        if (failure == 'write') h.commands.failHopSetter = true;
        await h.start(tester);
        expect(h.connector.sourceStarts, 0);
        expect(h.connector.otaHops, 0);
        expect(h.commands.otaHops[h.target.name], 0);
        expect(await h.saved(), isEmpty);
        if (failure != 'write') {
          expect(
            h.connector.localCommands.where(
              (command) => command.startsWith('ota config hops'),
            ),
            isEmpty,
          );
        }
        await h.close(tester);
      },
    );
  }

  testWidgets('failed restore blocks install, stays saved, and is retryable', (
    tester,
  ) async {
    final h = await _HopScreenHarness.mount(tester, readyToInstall: true);
    h.connector.otaHops = 5; // A higher existing policy must remain unchanged.
    h.commands.otaHops[h.target.name] = 0;
    await h.start(tester);
    await h.click(tester, 'Pull');
    await tester.tap(find.text('Start download'));
    await tester.pumpAndSettle();
    await h.click(tester, 'Check download');
    h.commands.failHopRestore = true;
    await h.click(tester, 'Install and reboot');
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Install and reboot'),
      ),
    );
    await tester.pumpAndSettle();
    expect(h.commands.commands, isNot(contains('ota install')));
    expect((await h.saved()).single.original, 0);
    await h.click(tester, 'Stop and restore controlled radios');
    expect(h.connector.otaHops, 5);
    expect(h.commands.otaHops[h.target.name], 2);
    expect((await h.saved()).single.original, 0);
    tester.state<ScrollableState>(h.scroll).position.jumpTo(0);
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('Test radios and start source'),
      200,
      scrollable: h.scroll,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.ancestor(
              of: find.text('Test radios and start source'),
              matching: find.byWidgetPredicate(
                (widget) => widget is FilledButton,
              ),
            ),
          )
          .onPressed,
      isNull,
    );
    h.commands.failHopRestore = false;
    await h.click(tester, 'Retry hop-limit restore');
    expect(h.commands.otaHops[h.target.name], 0);
    expect(await h.saved(), isEmpty);
    await h.close(tester);
  });

  testWidgets('multi-byte paths count hops and reconnect preserves recovery', (
    tester,
  ) async {
    final h = await _HopScreenHarness.mount(tester, hashWidth: 2);
    h.connector.otaHops = 0;
    h.commands.otaHops[h.target.name] = 0;
    await h.start(tester);
    expect(h.connector.otaHops, 2);
    final original = (await h.saved())
        .map((record) => record.toJson())
        .toList();
    h.connector.simulateDisconnect();
    await tester.pump(const Duration(milliseconds: 100));
    h.connector.simulateReconnect(channelReady: true);
    for (var tick = 0; tick < 40; tick++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(h.connector.sourceStarts, 2);
    expect(
      (await h.saved()).map((record) => record.toJson()).toList(),
      original,
    );
    await h.click(tester, 'Stop and restore controlled radios');
    expect(h.connector.otaHops, 0);
    expect(h.commands.otaHops[h.target.name], 0);
    expect(await h.saved(), isEmpty);
    await h.close(tester);
  });

  testWidgets(
    'reading an old attached session cannot bypass pre-install recovery',
    (tester) async {
      final h = await _HopScreenHarness.mount(tester, readyToInstall: true);
      h.connector.otaHops = 0;
      h.commands.otaHops[h.target.name] = 0;
      await h.start(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await h.show(
        tester,
      ); // Navigation recreated the screen; source still attached.
      await h.click(tester, 'Read source status');
      await h.click(tester, 'Check download');
      await h.click(tester, 'Install and reboot');
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, 'Install and reboot'),
        ),
      );
      await tester.pumpAndSettle();
      expect(h.commands.commands, isNot(contains('ota install')));
      expect((await h.saved()).length, 2);
      await h.click(tester, 'Stop and restore controlled radios');
      await h.click(tester, 'Retry hop-limit restore');
      expect(await h.saved(), isEmpty);
      expect(h.connector.otaHops, 0);
      expect(h.commands.otaHops[h.target.name], 0);
      await h.close(tester);
    },
  );

  testWidgets('app restart displays and restores saved original limits', (
    tester,
  ) async {
    final h = await _HopScreenHarness.mount(tester);
    h.connector.otaHops = 0;
    h.commands.otaHops[h.target.name] = 0;
    await h.start(tester);
    expect((await h.saved()).length, 2);
    await tester.pumpWidget(
      const SizedBox.shrink(),
    ); // App was killed, no cleanup.
    h.connector.simulateDisconnect();
    h.connector.simulateReconnect(channelReady: true);
    await h.show(tester);
    final start = find.ancestor(
      of: find.text('Test radios and start source'),
      matching: find.byWidgetPredicate((widget) => widget is FilledButton),
    );
    await tester.scrollUntilVisible(start, 300, scrollable: h.scroll);
    expect(tester.widget<FilledButton>(start).onPressed, isNull);
    await h.click(tester, 'Retry hop-limit restore');
    expect(h.connector.otaHops, 0);
    expect(h.commands.otaHops[h.target.name], 0);
    expect(await h.saved(), isEmpty);
    expect(h.commands.calls.last.path, h.target.path);
    await h.close(tester);
  });
}

class _HopScreenHarness {
  final Contact target;
  final _FakeMotaConnector connector;
  final _FakeRepeaterCommandService commands;
  _HopScreenHarness(this.target, this.connector, this.commands);

  static Future<_HopScreenHarness> mount(
    WidgetTester tester, {
    bool readyToInstall = false,
    bool unreachableProbe = false,
    int hashWidth = 1,
  }) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final catalog = (await tester.runAsync(
      () => BleMotaCatalog.load([
        XFile.fromData(
          buildTestFullMotaContainer(),
          path: 'TEST_BOARD-full-v1.17.1.2.mota',
          name: 'TEST_BOARD-full-v1.17.1.2.mota',
        ),
      ]),
    ))!;
    final target = Contact(
      publicKey: Uint8List.fromList(
        List.generate(pubKeySize, (index) => index + 32),
      ),
      name: 'Hop target',
      type: advTypeRepeater,
      pathLength: 2,
      path: Uint8List.fromList(
        List.generate(2 * hashWidth, (index) => index + 0x55),
      ),
      lastSeen: DateTime(2026, 9, 29),
    );
    final connector = _FakeMotaConnector(target, catalog);
    connector.hashWidth = hashWidth;
    final commands = _FakeRepeaterCommandService(
      connector,
      readyToInstall: readyToInstall,
      statusManifestId: catalog.files.single.manifestId,
      unreachableProbeContact: unreachableProbe ? target.name : null,
    );
    final h = _HopScreenHarness(target, connector, commands);
    await h.show(tester);
    return h;
  }

  Finder get scroll => find
      .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
      .first;
  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<MeshCoreConnector>.value(
        value: connector,
        child: MaterialApp(
          theme: MeshTheme.dark().copyWith(
            splashFactory: NoSplash.splashFactory,
          ),
          home: LoRaOtaScreen(repeater: target, commandService: commands),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> click(WidgetTester tester, String label) async {
    tester.state<ScrollableState>(scroll).position.jumpTo(0);
    await tester.pump();
    final text = find.text(label);
    await tester.scrollUntilVisible(text, 200, scrollable: scroll);
    await tester.ensureVisible(text);
    await tester.pumpAndSettle();
    await tester.tap(text);
    await tester.pumpAndSettle();
  }

  Future<void> start(WidgetTester tester) async {
    await click(tester, 'Test radios and start source');
    for (var tick = 0; tick < 40; tick++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<List<LoraOtaHopRecovery>> saved() => StorageService()
      .loadLoraOtaHopRecovery(connector.selfPublicKeyHex, target.publicKeyHex);
  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await connector.closeFake();
  }
}

class _FakeMotaConnector extends MeshCoreConnector {
  final Contact target;
  final List<Contact> additionalContacts;
  final int? radioFrequencyHz;
  final int? radioBandwidthHz;
  final int? radioSf;
  final int? radioCr;
  final StreamController<Uint8List> _frames =
      StreamController<Uint8List>.broadcast();
  BleMotaCatalog? _catalog;
  bool _attached = false;
  bool _channelReady = true;
  MeshCoreConnectionState _fakeState = MeshCoreConnectionState.connected;
  int sourceStarts = 0;
  int sourceStops = 0;
  int otaHops = 3;
  int hashWidth = 1;
  final List<List<int>> preparedPaths = <List<int>>[];
  final List<String> localCommands = <String>[];

  _FakeMotaConnector(
    this.target,
    this._catalog, {
    this.additionalContacts = const <Contact>[],
    this.radioFrequencyHz,
    this.radioBandwidthHz,
    this.radioSf,
    this.radioCr,
  });

  @override
  int? get currentFreqHz => radioFrequencyHz;

  @override
  int? get currentBwHz => radioBandwidthHz;

  @override
  int? get currentSf => radioSf;

  @override
  int? get currentCr => radioCr;

  @override
  List<Contact> get contacts => <Contact>[target, ...additionalContacts];

  @override
  List<Contact> get allContactsUnfiltered => <Contact>[
    target,
    ...additionalContacts,
  ];

  @override
  Stream<Uint8List> get receivedFrames => _frames.stream;

  @override
  MeshCoreConnectionState get state => _fakeState;

  @override
  bool get isConnected => _fakeState == MeshCoreConnectionState.connected;

  @override
  String get selfPublicKeyHex => 'aa' * 32;

  @override
  MeshCoreTransportType get activeTransport => MeshCoreTransportType.bluetooth;

  @override
  bool get isBleMotaChannelReady => isConnected && _channelReady;

  @override
  String? get bleMotaChannelError => null;

  @override
  BleMotaCatalog? get bleMotaCatalog => _catalog;

  @override
  int get pathHashByteWidth => hashWidth;

  @override
  void setBleMotaCatalog(BleMotaCatalog? catalog) {
    _catalog = catalog;
  }

  @override
  Future<String> executeLocalOtaControl(String command) async {
    localCommands.add(command);
    if (command == 'ota config') {
      return 'ota config: mode=seeder-only hops=$otaHops';
    }
    if (command.startsWith('ota config hops ')) {
      otaHops = int.parse(command.split(' ').last);
      return 'OK OTA reach = $otaHops hops (saved)';
    }
    return switch (command) {
      'normalradio' => 'OK normal radio',
      'tempradio' => 'TempRadio active: 909.950,250.00,5,5 177s left',
      _ => 'OK temporary radio',
    };
  }

  @override
  Future<BleMotaSourceStatus> controlBleMotaSource(int action) async {
    if (!isBleMotaChannelReady) {
      throw StateError('Bluetooth mOTA channel is not ready');
    }
    if (action == bleMotaActionStart) {
      sourceStarts++;
      _attached = true;
    }
    if (action == bleMotaActionStop) {
      sourceStops++;
      _attached = false;
    }
    return BleMotaSourceStatus(
      action: action,
      flags: bleMotaFlagChannelReady | (_attached ? bleMotaFlagAttached : 0),
      offered: _catalog?.files.length ?? 0,
      advertised: _catalog?.files.length ?? 0,
      packetsSent: action == bleMotaActionStart ? 0 : 42,
    );
  }

  bool get attached => _attached;

  void simulateDisconnect() {
    _attached = false;
    _channelReady = false;
    _fakeState = MeshCoreConnectionState.disconnected;
    notifyListeners();
  }

  void simulateReconnect({required bool channelReady}) {
    _fakeState = MeshCoreConnectionState.connected;
    _channelReady = channelReady;
    notifyListeners();
  }

  void setChannelReady(bool ready) {
    _channelReady = ready;
    notifyListeners();
  }

  @override
  Future<PathSelection> preparePathForContactSend(
    Contact contact, {
    PathSelection? explicitSelection,
  }) async {
    preparedPaths.add(
      List<int>.from(explicitSelection?.pathBytes ?? contact.path),
    );
    return explicitSelection ??
        PathSelection(
          pathBytes: contact.path,
          hopCount: contact.pathLength,
          useFlood: false,
        );
  }

  @override
  Future<void> sendFrame(
    Uint8List frame, {
    String? channelSendQueueId,
    bool expectsGenericAck = false,
    bool waitForGenericAck = false,
  }) async {
    if (frame.length >= pubKeySize + 1 && frame[0] == cmdSendLogin) {
      final response = Uint8List.fromList(<int>[
        pushCodeLoginSuccess,
        1,
        ...frame.sublist(1, 7),
      ]);
      Timer(const Duration(milliseconds: 1), () => _frames.add(response));
    }
  }

  Future<void> closeFake() => _frames.close();
}

class _FakeRepeaterCommandService extends RepeaterCommandService {
  final String? unreachableProbeContact;
  final bool readyToInstall;
  final String? statusManifestId;
  final bool pullReplyTimesOut;
  final bool installReplyTimesOut;
  final String? bootloaderStatus;
  final List<String> commands = <String>[];
  final Map<String, int> otaHops = {};
  String? hopConfigError;
  bool failHopSetter = false;
  bool failHopRestore = false;
  void Function(String command)? inspectCommand;
  final List<
    ({String contact, String command, List<int> path, int minimumTimeoutMs})
  >
  calls =
      <
        ({String contact, String command, List<int> path, int minimumTimeoutMs})
      >[];

  _FakeRepeaterCommandService(
    super.connector, {
    this.unreachableProbeContact,
    this.readyToInstall = false,
    this.statusManifestId,
    this.pullReplyTimesOut = false,
    this.installReplyTimesOut = false,
    this.bootloaderStatus,
  });

  @override
  Future<String> sendCommand(
    Contact repeater,
    String command, {
    Function(String)? onResponse,
    Function(int)? onAttempt,
    void Function()? onPacketSent,
    PathSelection? pathSelection,
    int retries = RepeaterCommandService.maxRetries,
    int minimumTimeoutMs = 0,
    bool raw = false,
  }) async {
    commands.add(command);
    calls.add((
      contact: repeater.name,
      command: command,
      path: List<int>.from(pathSelection?.pathBytes ?? const <int>[]),
      minimumTimeoutMs: minimumTimeoutMs,
    ));
    onAttempt?.call(1);
    onPacketSent?.call();
    inspectCommand?.call(command);
    if (command == 'ota config') {
      return hopConfigError ??
          'ota config: speed=1x hops=${otaHops[repeater.name] ?? 3} keys=0';
    }
    if (command.startsWith('ota config hops ')) {
      final hops = int.parse(command.split(' ').last);
      if (failHopSetter || (failHopRestore && hops == 0)) {
        return 'ERR could not save';
      }
      otaHops[repeater.name] = hops;
      return 'OK OTA reach = $hops hops (saved)';
    }
    if (pullReplyTimesOut && command.startsWith('ota pull ')) {
      throw StateError('Command timeout after 20 seconds');
    }
    if (installReplyTimesOut &&
        (command == 'ota install' ||
            command.startsWith('ota bootloader install '))) {
      throw StateError('Command timeout after 20 seconds');
    }
    if (repeater.name == unreachableProbeContact &&
        (command == 'ota status' || command == 'ver')) {
      throw TimeoutException('${repeater.name} did not answer on TempRadio');
    }
    final response = switch (command) {
      'ota ls' => '44332211  TEST_BOARD full 1.17.1.2',
      'ota status' =>
        readyToInstall
            ? 'OTA | target:11223344 env:TEST_BOARD_repeat | '
                  'download: 40/40 (100%) ready to install '
                  'id=$statusManifestId'
            : 'download: 1/3 (33%)',
      'ota self' => 'self base_hash=0000000000000000',
      'ota key' => 'no trusted signer keys yet',
      String value when value.startsWith('ota pull ') => 'OK download started',
      'ota bootloader' => bootloaderStatus ?? 'staged:none mid=- hash=-',
      String value when value.startsWith('ota bootloader install ') =>
        'OK bootloader update armed',
      'ota install' => 'OK installing',
      'normalradio' => 'OK normal radio',
      String value when value.startsWith('tempradio ') => 'OK temporary radio',
      _ => 'OK',
    };
    onResponse?.call(response);
    return response;
  }

  @override
  void dispose() {}
}
