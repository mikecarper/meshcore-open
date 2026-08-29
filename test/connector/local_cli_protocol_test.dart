import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';

void main() {
  group('local CLI protocol', () {
    test('uses command 66 and reply 29', () {
      expect(cmdRunCliCommand, 0x42);
      expect(respCodeCliReply, 0x1D);
    });

    test('builds bounded UTF-8 frames with an optional correlation tag', () {
      final frame = buildRunCliCommandFrame(
        'get radio.rxgain',
        correlationTag: 'a7',
      );
      expect(frame.first, cmdRunCliCommand);
      expect(utf8.decode(frame.sublist(1)), 'A7|get radio.rxgain');

      final maximum = '${List.filled(84, 'e').join()}x';
      final maximumFrame = buildRunCliCommandFrame(
        maximum,
        correlationTag: '00',
      );
      expect(maximumFrame.length, 89);

      final multibyteMaximum = List.filled(84, '\u00e9').join();
      expect(
        buildRunCliCommandFrame(multibyteMaximum, correlationTag: '00').length,
        maxFrameSize,
      );
      expect(
        () => buildRunCliCommandFrame(
          '$multibyteMaximum\u00e9',
          correlationTag: '00',
        ),
        throwsArgumentError,
      );
    });

    test('rejects empty, NUL-containing, and invalid-tag commands', () {
      expect(() => buildRunCliCommandFrame(''), throwsArgumentError);
      expect(
        () => buildRunCliCommandFrame('get\u0000radio'),
        throwsArgumentError,
      );
      expect(
        () => buildRunCliCommandFrame('get radio', correlationTag: 'G7'),
        throwsArgumentError,
      );
    });

    test('strictly parses CLI replies', () {
      final reply = Uint8List.fromList(<int>[
        respCodeCliReply,
        ...utf8.encode('A7|on'),
      ]);
      expect(parseRunCliCommandResponse(reply), 'A7|on');

      expect(
        () => parseRunCliCommandResponse(Uint8List(0)),
        throwsFormatException,
      );
      expect(
        () => parseRunCliCommandResponse(Uint8List.fromList(<int>[respCodeOk])),
        throwsFormatException,
      );
      expect(
        () => parseRunCliCommandResponse(
          Uint8List.fromList(<int>[respCodeCliReply, 0]),
        ),
        throwsFormatException,
      );
      expect(
        () => parseRunCliCommandResponse(
          Uint8List.fromList(<int>[respCodeCliReply, 0xC3]),
        ),
        throwsFormatException,
      );
      expect(
        () => parseRunCliCommandResponse(
          Uint8List.fromList(<int>[respCodeErr, 1]),
        ),
        throwsStateError,
      );
      expect(
        () => parseRunCliCommandResponse(
          Uint8List.fromList(<int>[respCodeErr, 1, 0]),
        ),
        throwsFormatException,
      );
    });
  });

  group('local CLI connector API', () {
    test('sends a correlated local frame and strips the reply tag', () async {
      final connector = _FakeLocalCliConnector();
      addTearDown(connector.close);
      connector.onSend = (frame) {
        final request = utf8.decode(frame.sublist(1));
        final prefix = request.substring(0, 3);
        connector.emit(<int>[respCodeCliReply, ...utf8.encode('${prefix}max')]);
      };

      final reply = await connector.executeLocalCliCommand(
        'get wifi.powersave',
      );

      expect(reply, 'max');
      expect(connector.sentFrames, hasLength(1));
      expect(connector.sentFrames.single.first, cmdRunCliCommand);
      expect(connector.sentFrames.single.first, isNot(cmdSendTxtMsg));
      expect(
        utf8.decode(connector.sentFrames.single.sublist(1)),
        matches(RegExp(r'^[0-9A-F]{2}\|get wifi\.powersave$')),
      );
    });

    test('ignores a valid reply carrying the wrong correlation tag', () async {
      final connector = _FakeLocalCliConnector();
      addTearDown(connector.close);
      connector.onSend = (frame) {
        final request = utf8.decode(frame.sublist(1));
        final prefix = request.substring(0, 3);
        connector.emit(<int>[respCodeCliReply, ...utf8.encode('FF|stale')]);
        scheduleMicrotask(() {
          connector.emit(<int>[
            respCodeCliReply,
            ...utf8.encode('${prefix}fresh'),
          ]);
        });
      };

      expect(await connector.executeLocalCliCommand('get board'), 'fresh');
    });

    test('rejects overlapping local requests', () async {
      final connector = _FakeLocalCliConnector();
      addTearDown(connector.close);

      final first = connector.executeLocalCliCommand(
        'get board',
        timeout: const Duration(seconds: 1),
      );
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        connector.executeLocalCliCommand('get radio.rxgain'),
        throwsStateError,
      );

      final request = utf8.decode(connector.sentFrames.single.sublist(1));
      connector.emit(<int>[
        respCodeCliReply,
        ...utf8.encode('${request.substring(0, 3)}ok'),
      ]);
      expect(await first, 'ok');
    });

    test('ignores an unrelated generic error response', () async {
      final connector = _FakeLocalCliConnector();
      addTearDown(connector.close);
      connector.onSend = (frame) {
        final request = utf8.decode(frame.sublist(1));
        connector.emit(<int>[respCodeErr, 1]);
        scheduleMicrotask(() {
          connector.emit(<int>[
            respCodeCliReply,
            ...utf8.encode('${request.substring(0, 3)}ok'),
          ]);
        });
      };

      expect(await connector.executeLocalCliCommand('get board'), 'ok');
    });

    test('rejects firmware older than protocol version 14', () async {
      final connector = _FakeLocalCliConnector(firmwareVersion: 13);
      addTearDown(connector.close);

      await expectLater(
        connector.executeLocalCliCommand('get board'),
        throwsUnsupportedError,
      );
      expect(connector.sentFrames, isEmpty);
    });
  });
}

class _FakeLocalCliConnector extends MeshCoreConnector {
  _FakeLocalCliConnector({this.firmwareVersion = 14});

  final int firmwareVersion;
  final StreamController<Uint8List> _frames =
      StreamController<Uint8List>.broadcast();
  final List<Uint8List> sentFrames = <Uint8List>[];
  void Function(Uint8List frame)? onSend;

  @override
  bool get isConnected => true;

  @override
  int? get firmwareVerCode => firmwareVersion;

  @override
  Stream<Uint8List> get receivedFrames => _frames.stream;

  @override
  Future<void> sendFrame(
    Uint8List data, {
    String? channelSendQueueId,
    bool expectsGenericAck = false,
    bool waitForGenericAck = false,
  }) async {
    final copy = Uint8List.fromList(data);
    sentFrames.add(copy);
    onSend?.call(copy);
  }

  void emit(List<int> frame) {
    _frames.add(Uint8List.fromList(frame));
  }

  Future<void> close() async {
    await _frames.close();
    dispose();
  }
}
