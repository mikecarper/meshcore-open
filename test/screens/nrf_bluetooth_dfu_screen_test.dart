import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/models/path_selection.dart';
import 'package:meshcore_open/screens/nrf_bluetooth_dfu_screen.dart';
import 'package:meshcore_open/services/repeater_command_service.dart';
import 'package:meshcore_open/services/nrf_dfu_recovery.dart';
import 'package:meshcore_open/services/nrf_dfu_recovery_store.dart';
import 'package:meshcore_open/services/github_mota_release_service.dart';
import 'package:meshcore_open/services/rak_bootloader_migration.dart';
import 'package:provider/provider.dart';
import 'package:nordic_dfu/nordic_dfu.dart';

import '../support/companion_firmware_test_data.dart';

class _DfuCommands extends RepeaterCommandService {
  _DfuCommands(super.connector, {this.board = 'Heltec T096'});
  final String board;
  final calls = <String>[];
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
    calls.add(command);
    return switch (command) {
      'board' => board,
      'ota bootloader' => 'name=4631_AUTO_DFU abi=3 caps=08',
      'start ota' => 'OK - mac: EB:9D:56:B2:48:48',
      _ => throw StateError('Unexpected command'),
    };
  }
}

class _DfuMemoryStore extends NrfDfuRecoveryStore {
  bool active = false;
  @override
  Future<bool> hasUnconfirmedNativeTransfer() async => active;
  @override
  Future<void> markExternalTransferActive({
    required String address,
    required String board,
    required String publicKey,
  }) async {
    active = true;
  }

  @override
  Future<void> markExternalTransferSettled() async {
    active = false;
  }
}

class _RakReleases extends GitHubMotaReleaseService {
  @override
  Future<RakBootloaderDfuFiles> downloadRakBootloaderDfu(
    RakBootloaderMigration plan,
  ) async => RakBootloaderDfuFiles(
    tag: 'v0.11.0-OTAFIX2.4.11',
    normalName: 'verified-normal.zip',
    normalBytes: testNrfDfuZip(component: 'softdevice_bootloader'),
    recoveryName: 'verified-recovery.zip',
    recoveryBytes: testNrfDfuZip(component: 'softdevice_bootloader'),
  );
}

Future<void> _pressAndAwait(WidgetTester tester, String text) async {
  final finder = find
      .ancestor(
        of: find.text(text),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      )
      .first;
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  final button = tester.widget<ButtonStyleButton>(finder);
  await tester.runAsync(() => (button.onPressed! as Future<void> Function())());
  await tester.pumpAndSettle();
}

Future<void> _startAndConfirm(
  WidgetTester tester, {
  Future<void> Function()? during,
}) async {
  final finder = find.ancestor(
    of: find.text('Start Bluetooth update'),
    matching: find.byWidgetPredicate((widget) => widget is FilledButton),
  );
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      150,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await tester.ensureVisible(finder.first);
  await tester.pumpAndSettle();
  final button = tester.widget<FilledButton>(finder.first);
  await tester.runAsync(() async {
    final started = (button.onPressed! as Future<void> Function())();
    await tester.pumpAndSettle();
    final confirm = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Start Bluetooth update').last,
    );
    confirm.onPressed!();
    if (during != null) await during();
    await started;
  });
  await tester.pumpAndSettle();
}

Future<(_DfuCommands, _DfuMemoryStore)> _mountDfu(
  WidgetTester tester, {
  required NrfDfuRecovery recovery,
  Uint8List? bytes,
  String board = 'Heltec T096',
  bool savedActive = false,
  GitHubMotaReleaseService? releases,
}) async {
  final connector = _DfuConnector();
  final commands = _DfuCommands(connector, board: board);
  final store = _DfuMemoryStore()..active = savedActive;
  final directory = (await tester.runAsync(
    () => Directory.systemTemp.createTemp('repeater-dfu-test-'),
  ))!;
  addTearDown(
    () => tester.runAsync(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    }),
  );
  const provider = MethodChannel('plugins.flutter.io/path_provider');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    provider,
    (_) async => directory.path,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      provider,
      null,
    ),
  );
  addTearDown(commands.dispose);
  addTearDown(connector.dispose);
  addTearDown(connector.frames.close);
  final target = Contact(
    publicKey: Uint8List.fromList(List.generate(32, (i) => i + 1)),
    name: 'Test repeater',
    type: advTypeRepeater,
    pathLength: 0,
    path: Uint8List(0),
    lastSeen: DateTime(2026, 10, 12),
  );
  final file = XFile.fromData(
    bytes ??
        testNrfDfuZip(
          image: testNrfApplication(targetEnv: 'Heltec_t096_repeater'),
        ),
    path: 'repeater-application.zip',
  );
  await tester.pumpWidget(
    ChangeNotifierProvider<MeshCoreConnector>.value(
      value: connector,
      child: MaterialApp(
        home: NrfBluetoothDfuScreen(
          repeater: target,
          commandService: commands,
          dfuRecovery: recovery,
          recoveryStore: store,
          pickFirmware: () async => file,
          releaseService: releases,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (commands, store);
}

class _DfuConnector extends MeshCoreConnector {
  final frames = StreamController<Uint8List>.broadcast();
  final sent = <Uint8List>[];

  @override
  Future<void> stopScan() async {}

  @override
  Stream<Uint8List> get receivedFrames => frames.stream;

  @override
  Future<PathSelection> preparePathForContactSend(
    Contact contact, {
    PathSelection? explicitSelection,
  }) async =>
      PathSelection(pathBytes: Uint8List(0), hopCount: 0, useFlood: false);

  @override
  void trackRepeaterAck({
    required Contact contact,
    required PathSelection selection,
    required String text,
    required int timestampSeconds,
    int attempt = 0,
    void Function()? onPacketSent,
  }) {}

  @override
  Future<void> sendFrame(
    Uint8List frame, {
    String? channelSendQueueId,
    bool expectsGenericAck = false,
    bool waitForGenericAck = false,
  }) async => sent.add(frame);
}

void main() {
  testWidgets(
    'exact-board application uses shared coordinator and durable native guard',
    (tester) async {
      var writes = 0;
      final recovery = NrfDfuRecovery(
        scan: (_, _) async => [],
        transfer: (address, _, force, events) async {
          writes++;
          expect(address, 'EB:9D:56:B2:48:48');
          expect(force, isFalse);
          events.onDfuProcessStarted?.call(address);
          events.onProgressChanged?.call(address, 100, 0, 0, 1, 1);
        },
      );
      final (commands, store) = await _mountDfu(tester, recovery: recovery);
      await _pressAndAwait(tester, 'Choose DFU ZIP');
      expect(commands.calls, ['board']);
      await _pressAndAwait(tester, 'Enable radio updater');
      expect(commands.calls, ['board', 'board', 'start ota']);
      await _startAndConfirm(tester);
      expect(writes, 1);
      expect(store.active, isFalse);
      expect(
        find.textContaining('Nordic DFU completed. Verify'),
        findsOneWidget,
      );
    },
  );

  for (final reason in ['wrong board', 'unknown board', 'system ZIP']) {
    testWidgets(
      'manual $reason never enables the target or writes native firmware',
      (tester) async {
        var writes = 0;
        final recovery = NrfDfuRecovery(
          scan: (_, _) async => [],
          transfer: (_, _, _, _) async {
            writes++;
          },
        );
        final (commands, _) = await _mountDfu(
          tester,
          recovery: recovery,
          board: reason == 'wrong board'
              ? 'Heltec T114'
              : reason == 'unknown board'
              ? 'Custom nRF52'
              : 'Heltec T096',
          bytes: reason == 'system ZIP'
              ? testNrfDfuZip(component: 'softdevice_bootloader')
              : null,
        );
        await _pressAndAwait(tester, 'Choose DFU ZIP');
        expect(writes, 0);
        expect(commands.calls, ['board']);
        expect(
          find.widgetWithText(FilledButton, 'Start Bluetooth update'),
          findsNothing,
        );
        final enable = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Enable radio updater'),
        );
        expect(enable.onPressed, isNull);
      },
    );
  }

  testWidgets('saved unconfirmed native update blocks repeater workflows too', (
    tester,
  ) async {
    final recovery = NrfDfuRecovery(
      scan: (_, _) async => [],
      transfer: (_, _, _, _) async => fail('Saved service still pending'),
    );
    final (commands, store) = await _mountDfu(
      tester,
      recovery: recovery,
      savedActive: true,
    );
    await _pressAndAwait(tester, 'Choose DFU ZIP');
    expect(commands.calls, isEmpty);
    expect(store.active, isTrue);
    expect(
      find.textContaining('saved native Bluetooth update has not confirmed'),
      findsOneWidget,
    );
  });

  testWidgets('RAK 99 percent error is not presumed bridge success', (
    tester,
  ) async {
    var writes = 0;
    final recovery = NrfDfuRecovery(
      scan: (_, _) async => [],
      transfer: (address, _, _, events) async {
        writes++;
        events.onProgressChanged?.call(address, 99, 0, 0, 1, 1);
        throw PlatformException(code: '133', message: 'GATT failure');
      },
    );
    final (commands, store) = await _mountDfu(
      tester,
      recovery: recovery,
      board: 'RAK 4631',
      releases: _RakReleases(),
    );
    await _pressAndAwait(tester, 'Find the right RAK bootloader update');
    await _pressAndAwait(tester, 'Enable radio updater');
    await _startAndConfirm(tester);
    expect(writes, 1);
    expect(commands.calls.where((c) => c == 'start ota'), hasLength(1));
    expect(store.active, isFalse);
    expect(find.textContaining('Android could not connect'), findsOneWidget);
    expect(find.textContaining('Nordic DFU completed'), findsNothing);
  });

  testWidgets(
    'cancel update waits for native terminal proof and never starts another stage',
    (tester) async {
      late Completer<void> entered, native;
      await tester.runAsync(() async {
        entered = Completer<void>();
        native = Completer<void>();
      });
      late DfuEventHandler events;
      var writes = 0, aborts = 0;
      final recovery = NrfDfuRecovery(
        scan: (_, _) async => [],
        transfer: (_, _, _, callbacks) {
          events = callbacks;
          writes++;
          entered.complete();
          return native.future;
        },
        abort: () async {
          aborts++;
          events.onDfuAborted?.call('EB:9D:56:B2:48:48');
        },
      );
      final (_, store) = await _mountDfu(tester, recovery: recovery);
      await _pressAndAwait(tester, 'Choose DFU ZIP');
      await _pressAndAwait(tester, 'Enable radio updater');
      await _startAndConfirm(
        tester,
        during: () async {
          await entered.future;
          await tester.pump();
          final cancelFinder = find.ancestor(
            of: find.text('Cancel update'),
            matching: find.byWidgetPredicate(
              (widget) => widget is OutlinedButton,
            ),
          );
          if (cancelFinder.evaluate().isEmpty) {
            await tester.scrollUntilVisible(
              cancelFinder,
              -150,
              scrollable: find.byType(Scrollable).first,
            );
          }
          final cancel = tester.widget<OutlinedButton>(cancelFinder);
          await (cancel.onPressed! as Future<void> Function())();
        },
      );
      expect(writes, 1);
      expect(aborts, 1);
      expect(store.active, isFalse);
      expect(
        find.textContaining('No automatic firmware retry'),
        findsOneWidget,
      );
      native.complete();
      await tester.pump();
    },
  );

  testWidgets(
    'unknown native lifetime keeps guard and ZIP after screen disposal',
    (tester) async {
      final native = Completer<void>();
      String? selectedPath;
      var writes = 0;
      final recovery = NrfDfuRecovery(
        idleTimeout: const Duration(milliseconds: 10),
        abortTimeout: const Duration(milliseconds: 10),
        scan: (_, _) async => [],
        transfer: (_, path, _, _) {
          selectedPath = path;
          writes++;
          return native.future;
        },
        abort: () async {},
      );
      final (commands, store) = await _mountDfu(tester, recovery: recovery);
      await _pressAndAwait(tester, 'Choose DFU ZIP');
      await _pressAndAwait(tester, 'Enable radio updater');
      await _startAndConfirm(tester);
      expect(recovery.isQuarantined, isTrue);
      expect(store.active, isTrue);
      final before = commands.calls.length;
      await _pressAndAwait(tester, 'Choose DFU ZIP');
      expect(commands.calls, hasLength(before));
      expect(writes, 1);
      await tester.pumpWidget(const SizedBox());
      expect(await tester.runAsync(() => File(selectedPath!).exists()), isTrue);
      native.complete();
      await tester.pump();
      expect(recovery.isQuarantined, isFalse);
    },
  );

  for (final code in [respCodeContactMsgRecv, respCodeContactMsgRecvV3]) {
    testWidgets('Bluetooth updater receives matching reply frame $code', (
      tester,
    ) async {
      final connector = _DfuConnector();
      final commands = RepeaterCommandService(connector);
      addTearDown(commands.dispose);
      addTearDown(connector.dispose);
      addTearDown(connector.frames.close);
      final target = Contact(
        publicKey: Uint8List.fromList(List.generate(32, (i) => i + 1)),
        name: 'RAK4631',
        type: advTypeRepeater,
        pathLength: 0,
        path: Uint8List(0),
        lastSeen: DateTime(2026, 9, 29),
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<MeshCoreConnector>.value(
          value: connector,
          child: MaterialApp(
            home: NrfBluetoothDfuScreen(
              repeater: target,
              commandService: commands,
            ),
          ),
        ),
      );
      String? result;
      final pending = commands.sendCommand(target, 'start ota', retries: 1);
      unawaited(pending.then((value) => result = value));
      await tester.pump();
      final prefix = utf8.decode(connector.sent.single.sublist(13, 16));
      Uint8List reply(List<int> sender, String token) => Uint8List.fromList([
        code,
        if (code == respCodeContactMsgRecvV3) ...[0, 0, 0],
        ...sender,
        0,
        txtTypeCliData,
        0,
        0,
        0,
        0,
        ...utf8.encode('${token}OK - mac: C3:C6:A8:FC:AD:A6'),
        0,
      ]);
      connector.frames.add(Uint8List(0));
      connector.frames.add(Uint8List.fromList([code]));
      connector.frames.add(reply(List.filled(6, 0xFF), prefix));
      connector.frames.add(reply(target.publicKey.sublist(0, 6), 'FF|'));
      await tester.pump();
      expect(result, isNull);
      connector.frames.add(reply(target.publicKey.sublist(0, 6), prefix));
      await tester.pump();
      expect(result, 'OK - mac: C3:C6:A8:FC:AD:A6');
      await pending;
      await tester.pumpWidget(const SizedBox());
      expect(connector.frames.hasListener, isFalse);
    });
  }
}
