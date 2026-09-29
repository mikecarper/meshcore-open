import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/models/path_selection.dart';
import 'package:meshcore_open/screens/nrf_bluetooth_dfu_screen.dart';
import 'package:meshcore_open/services/repeater_command_service.dart';
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

void main() {
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
