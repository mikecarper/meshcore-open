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
import 'package:meshcore_open/theme/mesh_theme.dart';
import 'package:provider/provider.dart';

import '../support/mota_test_data.dart';

void main() {
  testWidgets('runs phone OTA workflow and renders both progress measures', (
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
        List<int>.generate(pubKeySize, (index) => index + 16),
      ),
      name: 'Test repeater',
      type: advTypeRepeater,
      pathLength: 2,
      path: Uint8List.fromList(<int>[0xA1, 0xB2]),
      lastSeen: DateTime(2026, 8, 26),
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

    expect(find.text('Encrypted mOTA channel: Ready'), findsOneWidget);
    expect(find.textContaining('Passive hops need no entry'), findsOneWidget);
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
      matching: find.byType(FilledButton),
    );
    final startCallback = tester.widget<FilledButton>(startButton).onPressed;
    expect(startCallback, isNotNull);
    startCallback!();
    for (var tick = 0; tick < 40; tick++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(connector.localCommands.take(3), <String>[
      'tempradio 909.950,250,5,5,3',
      'tempradio',
      'tempradio 909.950,250,5,5,120',
    ]);
    expect(commands.calls.take(4).map((call) => call.command), <String>[
      'tempradio 909.950,250,5,5,3',
      'ota status',
      'tempradio 909.950,250,5,5,120',
      'ota ls',
    ]);
    expect(connector.sourceStarts, 1);

    await tester.drag(pageScroll, const Offset(0, 2000));
    await tester.pump();
    final pull = find.text('Pull');
    expect(pull, findsOneWidget);
    await tester.tap(pull);
    await tester.pump();
    await tester.tap(find.text('Start download'));
    await tester.pump();
    await tester.pump();

    final file = catalog.files.single;
    await tester.runAsync(() => file.read(file.payloadOffset, 1024));
    await tester.pump(const Duration(seconds: 2));

    await tester.drag(pageScroll, const Offset(0, -2400));
    await tester.pump();
    final check = find.text('Check download');
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
      matching: find.byType(OutlinedButton),
    );
    final stopCallback = tester.widget<OutlinedButton>(stopButton).onPressed;
    expect(stopCallback, isNotNull);
    stopCallback!();
    await tester.pump();
    await tester.pump();
    expect(connector.bleMotaCatalog, isNull);

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
          find.ancestor(of: start, matching: find.byType(FilledButton)),
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
    await tester.ensureVisible(add);
    await tester.pumpAndSettle();
    await tester.tap(add);
    await tester.pumpAndSettle();
    await tester.tap(find.text(relay.name));
    await tester.pumpAndSettle();

    final start = find.text('Test radios and start source');
    await tester.scrollUntilVisible(start, 300, scrollable: pageScroll);
    tester
        .widget<FilledButton>(
          find.ancestor(of: start, matching: find.byType(FilledButton)),
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
    await tester.ensureVisible(add);
    await tester.pumpAndSettle();
    await tester.tap(add);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Far relay'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(add);
    await tester.pumpAndSettle();
    await tester.tap(add);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Near relay'));
    await tester.pumpAndSettle();

    final start = find.text('Test radios and start source');
    await tester.scrollUntilVisible(start, 300, scrollable: pageScroll);
    final startButton = find.ancestor(
      of: start,
      matching: find.byType(FilledButton),
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

    final stop = find.text('Stop and restore controlled radios');
    await tester.scrollUntilVisible(stop, 300, scrollable: pageScroll);
    final stopButton = find.ancestor(
      of: stop,
      matching: find.byType(OutlinedButton),
    );
    final stopCallback = tester.widget<OutlinedButton>(stopButton).onPressed;
    expect(stopCallback, isNotNull);
    stopCallback!();
    await tester.pump();
    await tester.pump();

    final restore = commands.calls
        .where((call) => call.command == 'normalradio')
        .map((call) => call.contact)
        .toList();
    expect(restore, <String>['Target repeater', 'Far relay', 'Near relay']);

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
      matching: find.byType(FilledButton),
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
}

class _FakeMotaConnector extends MeshCoreConnector {
  final Contact target;
  final List<Contact> additionalContacts;
  final StreamController<Uint8List> _frames =
      StreamController<Uint8List>.broadcast();
  BleMotaCatalog? _catalog;
  bool _attached = false;
  bool _channelReady = true;
  MeshCoreConnectionState _fakeState = MeshCoreConnectionState.connected;
  int sourceStarts = 0;
  final List<String> localCommands = <String>[];

  _FakeMotaConnector(
    this.target,
    this._catalog, {
    this.additionalContacts = const <Contact>[],
  });

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
  MeshCoreTransportType get activeTransport => MeshCoreTransportType.bluetooth;

  @override
  bool get isBleMotaChannelReady => isConnected && _channelReady;

  @override
  String? get bleMotaChannelError => null;

  @override
  BleMotaCatalog? get bleMotaCatalog => _catalog;

  @override
  int get pathHashByteWidth => 1;

  @override
  void setBleMotaCatalog(BleMotaCatalog? catalog) {
    _catalog = catalog;
  }

  @override
  Future<String> executeLocalOtaControl(String command) async {
    localCommands.add(command);
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
    if (action == bleMotaActionStop) _attached = false;
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
  final List<String> commands = <String>[];
  final List<({String contact, String command, List<int> path})> calls =
      <({String contact, String command, List<int> path})>[];

  _FakeRepeaterCommandService(super.connector, {this.unreachableProbeContact});

  @override
  Future<String> sendCommand(
    Contact repeater,
    String command, {
    Function(String)? onResponse,
    Function(int)? onAttempt,
    void Function()? onPacketSent,
    PathSelection? pathSelection,
    int retries = RepeaterCommandService.maxRetries,
  }) async {
    commands.add(command);
    calls.add((
      contact: repeater.name,
      command: command,
      path: List<int>.from(pathSelection?.pathBytes ?? const <int>[]),
    ));
    onAttempt?.call(1);
    onPacketSent?.call();
    if (repeater.name == unreachableProbeContact &&
        (command == 'ota status' || command == 'ver')) {
      throw TimeoutException('${repeater.name} did not answer on TempRadio');
    }
    final response = switch (command) {
      'ota ls' => '44332211  TEST_BOARD full 1.17.1.2',
      'ota status' => 'download: 1/3 (33%)',
      String value when value.startsWith('ota pull ') => 'OK download started',
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
