import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/models/path_selection.dart';
import 'package:meshcore_open/services/repeater_command_service.dart';

void main() {
  test('rejects a guessed live prefix from a different contact', () async {
    final connector = _CommandConnector();
    final service = RepeaterCommandService(connector);
    addTearDown(service.dispose);
    final victim = _contact('Victim', 0x10);
    final attacker = _contact('Attacker', 0x80);

    final result = service.sendCommand(victim, 'tempradio 909.95,250,5,5,3');
    final frame = await connector.nextFrame();
    final prefix = _commandPrefix(frame);
    var completed = false;
    unawaited(
      result.then<void>(
        (_) => completed = true,
        onError: (Object _, StackTrace _) => completed = true,
      ),
    );

    service.handleResponse(attacker, '${prefix}OK forged');
    await _flushMicrotasks();
    expect(completed, isFalse);

    service.handleResponse(victim, '${prefix}OK accepted');
    await expectLater(result, completion('OK accepted'));
  });

  test('an attacker cannot cancel the victim pending command', () async {
    final connector = _CommandConnector();
    final service = RepeaterCommandService(connector);
    addTearDown(service.dispose);
    final victim = _contact('Victim', 0x20);
    final attacker = _contact('Attacker', 0x90);

    final result = service.sendCommand(victim, 'ota status');
    final prefix = _commandPrefix(await connector.nextFrame());

    for (var attempt = 0; attempt < 4; attempt++) {
      service.handleResponse(attacker, '${prefix}ERR forged $attempt');
    }
    await _flushMicrotasks();

    service.handleResponse(victim, '${prefix}download: 3/40 (7%)');
    await expectLater(result, completion('download: 3/40 (7%)'));
  });

  test(
    'a rejected cross-contact reply leaves the normal timeout armed',
    () async {
      final connector = _CommandConnector(timeoutMs: 20);
      final service = RepeaterCommandService(connector);
      addTearDown(service.dispose);
      final victim = _contact('Victim', 0x28);
      final attacker = _contact('Attacker', 0x98);

      final result = service.sendCommand(victim, 'ota status');
      final prefix = _commandPrefix(await connector.nextFrame());
      service.handleResponse(attacker, '${prefix}OK forged');

      await expectLater(
        result,
        throwsA(equals('Command timeout after 1 seconds')),
      );
    },
  );

  test(
    'ignores a replayed completed prefix while another command waits',
    () async {
      final connector = _CommandConnector();
      final service = RepeaterCommandService(connector);
      addTearDown(service.dispose);
      final contact = _contact('Repeater', 0x30);

      final first = service.sendCommand(contact, 'ver');
      final firstPrefix = _commandPrefix(await connector.nextFrame());
      service.handleResponse(contact, '${firstPrefix}1.17.1.5');
      await expectLater(first, completion('1.17.1.5'));

      final second = service.sendCommand(contact, 'ota status');
      final secondPrefix = _commandPrefix(await connector.nextFrame());
      expect(secondPrefix, isNot(firstPrefix));
      var secondCompleted = false;
      unawaited(
        second.then<void>(
          (_) => secondCompleted = true,
          onError: (Object _, StackTrace _) => secondCompleted = true,
        ),
      );

      service.handleResponse(contact, '${firstPrefix}replayed response');
      await _flushMicrotasks();
      expect(secondCompleted, isFalse);

      service.handleResponse(contact, '${secondPrefix}download: idle');
      await expectLater(second, completion('download: idle'));
    },
  );

  test('keeps concurrent contacts and their prefixes isolated', () async {
    final connector = _CommandConnector();
    final service = RepeaterCommandService(connector);
    addTearDown(service.dispose);
    final firstContact = _contact('First', 0x40);
    final secondContact = _contact('Second', 0xA0);

    final first = service.sendCommand(firstContact, 'ota status');
    final second = service.sendCommand(secondContact, 'ver');
    final frames = <Uint8List>[
      await connector.nextFrame(),
      await connector.nextFrame(),
    ];
    final firstPrefix = _commandPrefix(
      frames.singleWhere((frame) => _targets(frame, firstContact)),
    );
    final secondPrefix = _commandPrefix(
      frames.singleWhere((frame) => _targets(frame, secondContact)),
    );
    expect(secondPrefix, isNot(firstPrefix));

    service.handleResponse(secondContact, '${firstPrefix}OK wrong contact');
    service.handleResponse(firstContact, '${secondPrefix}OK wrong contact');
    await _flushMicrotasks();

    service.handleResponse(secondContact, '${secondPrefix}second reply');
    service.handleResponse(firstContact, '${firstPrefix}first reply');
    await expectLater(first, completion('first reply'));
    await expectLater(second, completion('second reply'));
  });

  test(
    'continues to accept an untagged legacy reply from the same contact',
    () async {
      final connector = _CommandConnector();
      final service = RepeaterCommandService(connector);
      addTearDown(service.dispose);
      final contact = _contact('Legacy', 0x50);

      final result = service.sendCommand(contact, 'clock');
      await connector.nextFrame();
      service.handleResponse(contact, 'clock: 1770000000');

      await expectLater(result, completion('clock: 1770000000'));
    },
  );

  test(
    'reuses completed prefixes after wrap; transport owns replay rejection',
    () async {
      final connector = _CommandConnector();
      final service = RepeaterCommandService(connector);
      addTearDown(service.dispose);
      final contact = _contact('Repeater', 0x60);
      String? firstPrefix;

      // The two-hex tag is an application correlation key, not a replay
      // nonce. Mesh transport authentication/replay filtering happens before
      // handleResponse. This test proves only that completed tags become
      // available again and continue to bind to the same authenticated sender.
      for (var index = 0; index <= 256; index++) {
        final result = service.sendCommand(contact, 'ver');
        final prefix = _commandPrefix(await connector.nextFrame());
        firstPrefix ??= prefix;
        if (index == 256) expect(prefix, firstPrefix);
        service.handleResponse(contact, '${prefix}reply $index');
        await expectLater(result, completion('reply $index'));
      }
    },
  );

  test('fails closed when all 256 live prefixes are occupied', () async {
    final connector = _CommandConnector();
    final service = RepeaterCommandService(connector);
    addTearDown(service.dispose);
    final contact = _contact('Repeater', 0x60);
    final pending = <Future<String>>[];
    final prefixes = <String>{};

    for (var index = 0; index < 256; index++) {
      pending.add(service.sendCommand(contact, 'ota status'));
    }
    for (var index = 0; index < 256; index++) {
      prefixes.add(_commandPrefix(await connector.nextFrame()));
    }
    expect(prefixes, hasLength(256));

    await expectLater(
      service.sendCommand(contact, 'ota status'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'All repeater command correlation prefixes are in use',
        ),
      ),
    );
    expect(connector.queuedFrameCount, 0);

    for (final prefix in prefixes) {
      service.handleResponse(contact, '${prefix}OK');
    }
    await expectLater(Future.wait(pending), completion(everyElement('OK')));
  });
}

Contact _contact(String name, int seed) {
  return Contact(
    publicKey: Uint8List.fromList(
      List<int>.generate(pubKeySize, (index) => (seed + index) & 0xFF),
    ),
    name: name,
    type: advTypeRepeater,
    pathLength: 0,
    path: Uint8List(0),
    lastSeen: DateTime(2026, 8, 30),
  );
}

String _commandPrefix(Uint8List frame) {
  expect(frame[0], cmdSendTxtMsg);
  const textOffset = 13;
  final terminator = frame.indexOf(0, textOffset);
  final command = utf8.decode(frame.sublist(textOffset, terminator));
  expect(command.length, greaterThanOrEqualTo(3));
  expect(command[2], '|');
  return command.substring(0, 3);
}

bool _targets(Uint8List frame, Contact contact) {
  if (frame.length < 13 || contact.publicKey.length < 6) return false;
  for (var index = 0; index < 6; index++) {
    if (frame[index + 7] != contact.publicKey[index]) return false;
  }
  return true;
}

Future<void> _flushMicrotasks() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

class _CommandConnector extends MeshCoreConnector {
  final int timeoutMs;
  final Queue<Uint8List> _sentFrames = Queue<Uint8List>();
  final Queue<Completer<Uint8List>> _frameWaiters =
      Queue<Completer<Uint8List>>();

  _CommandConnector({this.timeoutMs = 60000});

  int get queuedFrameCount => _sentFrames.length;

  Future<Uint8List> nextFrame() {
    if (_sentFrames.isNotEmpty) {
      return Future<Uint8List>.value(_sentFrames.removeFirst());
    }
    final waiter = Completer<Uint8List>();
    _frameWaiters.addLast(waiter);
    return waiter.future;
  }

  @override
  Future<PathSelection> preparePathForContactSend(
    Contact contact, {
    PathSelection? explicitSelection,
  }) async {
    return explicitSelection ??
        PathSelection(pathBytes: Uint8List(0), hopCount: 0, useFlood: false);
  }

  @override
  int calculateTimeout({
    required int pathLength,
    int messageBytes = 100,
    String? contactKey,
    int? deviceTimeoutMs,
  }) {
    return timeoutMs;
  }

  @override
  void trackRepeaterAck({
    required Contact contact,
    required PathSelection selection,
    required String text,
    required int timestampSeconds,
    int attempt = 0,
    void Function()? onPacketSent,
  }) {
    onPacketSent?.call();
  }

  @override
  Future<void> sendFrame(
    Uint8List frame, {
    String? channelSendQueueId,
    bool expectsGenericAck = false,
    bool waitForGenericAck = false,
  }) async {
    final copy = Uint8List.fromList(frame);
    if (_frameWaiters.isNotEmpty) {
      _frameWaiters.removeFirst().complete(copy);
    } else {
      _sentFrames.addLast(copy);
    }
  }
}
