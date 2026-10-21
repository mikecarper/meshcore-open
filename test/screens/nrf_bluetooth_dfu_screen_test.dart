import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/models/path_selection.dart';
import 'package:meshcore_open/screens/nrf_bluetooth_dfu_screen.dart';
import 'package:meshcore_open/services/repeater_command_service.dart';
import 'package:meshcore_open/services/nrf_dfu_recovery.dart';
import 'package:provider/provider.dart';

class _DfuConnector extends MeshCoreConnector {
  final frames = StreamController<Uint8List>.broadcast();
  final sent = <Uint8List>[];

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

class _ReadBoardCommands extends RepeaterCommandService {
  _ReadBoardCommands(super.connector);
  final commands = <String>[];
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
    expect(retries, 1);
    commands.add(command);
    return switch (command) {
      'board' => 'RAK 4631',
      'start ota' => 'OK - mac: D2:90:05:46:31:01',
      _ => throw StateError('Unexpected command'),
    };
  }
}

void main() {
  testWidgets(
    'repeater application uses authenticated board and shared factory recovery',
    (tester) async {
      final connector = _DfuConnector();
      final commands = _ReadBoardCommands(connector);
      addTearDown(connector.dispose);
      addTearDown(commands.dispose);
      addTearDown(connector.frames.close);
      final scratch = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('repeater-dfu-'),
      ))!;
      addTearDown(() => tester.runAsync(() => scratch.delete(recursive: true)));
      const provider = MethodChannel('plugins.flutter.io/path_provider');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        provider,
        (_) async => scratch.path,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          provider,
          null,
        ),
      );
      final archive = Archive()
        ..add(
          ArchiveFile.bytes(
            'manifest.json',
            utf8.encode(
              jsonEncode({
                'manifest': {
                  'application': {'bin_file': 'app.bin', 'dat_file': 'app.dat'},
                },
              }),
            ),
          ),
        )
        ..add(ArchiveFile.bytes('app.bin', List<int>.filled(1024, 0x55)))
        ..add(ArchiveFile.bytes('app.dat', List<int>.filled(32, 0x33)));
      final file = XFile.fromData(
        Uint8List.fromList(ZipEncoder().encode(archive)),
        path: 'repeater.zip',
      );
      final steps = <String>[];
      var scans = 0;
      final recovery = NrfDfuRecovery(
        scan: (_, _) async => ++scans == 1
            ? []
            : [
                const DfuAdvertisement('C3:C6:A8:FC:AD:A6', '4631_DFU', [
                  legacyDfuServiceUuid,
                ]),
              ],
        wait: (_) async {},
        probe: (address, board) async {
          steps.add('probe:$address:$board');
          return true;
        },
        transfer: (address, _, force, events) async {
          steps.add('transfer:$address:$force');
          if (!force) {
            events.onEnablingDfuMode?.call(address);
            throw PlatformException(code: '8');
          }
        },
      );
      final target = Contact(
        publicKey: Uint8List.fromList(List.generate(32, (i) => i + 1)),
        name: 'Test repeater',
        type: advTypeRepeater,
        pathLength: 0,
        path: Uint8List(0),
        lastSeen: DateTime(2026),
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<MeshCoreConnector>.value(
          value: connector,
          child: MaterialApp(
            home: NrfBluetoothDfuScreen(
              repeater: target,
              commandService: commands,
              dfuRecovery: recovery,
              pickFirmware: () async => file,
            ),
          ),
        ),
      );
      Future<void> press(String text) async {
        await tester.ensureVisible(find.text(text));
        await tester.pumpAndSettle();
        final button = tester.widget<ButtonStyleButton>(
          find.ancestor(
            of: find.text(text),
            matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
          ),
        );
        await tester.runAsync(
          () => (button.onPressed! as Future<void> Function())(),
        );
        await tester.pumpAndSettle();
      }

      await press('Choose DFU ZIP');
      await press('Enable radio updater');
      expect(commands.commands, ['board', 'start ota']);
      await tester.ensureVisible(find.text('Start Bluetooth update'));
      await tester.tap(find.text('Start Bluetooth update'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start Bluetooth update').last);
      await tester.pumpAndSettle();
      expect(steps, [
        'transfer:D2:90:05:46:31:01:false',
        'probe:C3:C6:A8:FC:AD:A6:RAK 4631',
        'transfer:C3:C6:A8:FC:AD:A6:true',
      ]);
      await tester.pumpWidget(const SizedBox());
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
