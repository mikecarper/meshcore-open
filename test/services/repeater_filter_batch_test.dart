import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/services/firmware_controls.dart';
import 'package:meshcore_open/services/repeater_filter_batch.dart';

import 'firmware_controls_test.dart' show ControlTestConnector;

Contact batchContact(int key, String name, {int type = advTypeRepeater}) =>
    Contact(
      publicKey: Uint8List.fromList(List.filled(32, key)),
      name: name,
      type: type,
      pathLength: 0,
      path: Uint8List(0),
      lastSeen: DateTime(2026, 10, 1),
    );

class BatchTestConnector extends ControlTestConnector {
  final List<Contact> nodes = [
    batchContact(42, 'Alpha'),
    batchContact(43, 'Bravo'),
    batchContact(44, 'Guest'),
  ];
  final List<(int, String)> addressedCommands = [];
  Future<String> Function(int, String)? answer;
  @override
  List<Contact> get contacts => nodes;
  BatchTestConnector() {
    remoteHandler = (command) async {
      final key = sentFrames.last[7];
      addressedCommands.add((key, command));
      return answer != null ? answer!(key, command) : batchReply(command);
    };
    login(nodes[0]);
    login(nodes[1]);
    login(nodes[2], admin: false);
  }
  void login(Contact node, {bool admin = true, bool fail = false}) {
    handleFrameForTest([
      fail ? pushCodeLoginFail : pushCodeLoginSuccess,
      admin ? 1 : 0,
      ...node.publicKey.take(6),
    ]);
  }
}

String batchReply(String command) {
  if (command == 'get fr') return '1=ota~radio@all!drop~tempradio';
  if (command == 'get fr.1') return 'set fr.1 12 d f=t';
  return 'OK';
}

void main() {
  late BatchTestConnector c;
  late RepeaterFilterBatch b;
  setUp(() {
    c = BatchTestConnector();
    b = RepeaterFilterBatch(c);
  });
  tearDown(() {
    b.dispose();
    c.dispose();
  });
  test('actual eight-byte push records only admin repeater logins', () {
    expect(loggedInFilterRepeaters(c).map((n) => n.name), ['Alpha', 'Bravo']);
    c.nodes.add(batchContact(45, 'Room', type: advTypeRoom));
    c.login(c.nodes.last);
    expect(loggedInFilterRepeaters(c).length, 2);
  });
  test('failed login and guest downgrade revoke admin', () {
    c.login(c.nodes[0], fail: true);
    c.login(c.nodes[1], admin: false);
    expect(loggedInFilterRepeaters(c), isEmpty);
  });
  test('sessions survive same Companion reconnect, not identity changes', () {
    c.connected = false;
    expect(loggedInFilterRepeaters(c), isEmpty);
    c.connected = true;
    expect(loggedInFilterRepeaters(c).length, 2);
    c.repeaterAdminSessions.bindCompanion('another-device');
    expect(loggedInFilterRepeaters(c), isEmpty);
    c.repeaterAdminSessions.bindCompanion(c.identity);
    expect(loggedInFilterRepeaters(c), isEmpty);
  });
  test('removed, inactive and malformed contacts are excluded', () {
    c.nodes[0] = c.nodes[0].copyWith(isActive: false);
    c.nodes.removeAt(1);
    c.nodes.add(c.nodes.last.copyWith(publicKey: Uint8List(1)));
    expect(loggedInFilterRepeaters(c), isEmpty);
  });
  test('colliding six-byte reply prefixes are excluded and revoked', () {
    final key = Uint8List.fromList(c.nodes.first.publicKey)..[31] = 88;
    c.nodes.add(c.nodes.first.copyWith(publicKey: key, name: 'Collision'));
    expect(loggedInFilterRepeaters(c).map((n) => n.name), ['Bravo']);
    c.login(c.nodes.first);
    c.nodes.removeLast();
    expect(loggedInFilterRepeaters(c).map((n) => n.name), ['Bravo']);
  });
  test('insert flag never copies source slot onto other nodes', () {
    final r = ForwardingRule.parse('set fr.53 12 d f=t');
    expect(r.command(remote: true, insert: true), 'set fr 12 d f=t');
    expect(r.slot, 53);
  });
  test(
    'checks only read; writes address selected nodes sequentially once',
    () async {
      final a = await b.check(c.nodes[0]);
      final d = await b.check(c.nodes[1]);
      expect(c.commands, ['get fr', 'get fr.1', 'get fr', 'get fr.1']);
      final results = await b.apply([a, d], 'set fr 12 d f=t');
      expect(results.every((r) => r.applied), true);
      expect(c.addressedCommands.where((x) => x.$2.startsWith('set ')), [
        (42, 'set fr 12 d f=t'),
        (43, 'set fr 12 d f=t'),
      ]);
      await expectLater(b.apply([a], 'set fr 12 d f=t'), throwsStateError);
    },
  );
  test('single selected node does not change other logged-in nodes', () async {
    final a = await b.check(c.nodes[0]);
    await b.apply([a], 'set fr 12 d f=t');
    expect(c.addressedCommands.every((x) => x.$1 == 42), true);
  });
  test('empty or legacy tables are not evidence of supported FPF7', () async {
    c.answer = (_, command) async => command == 'get fr' ? 'off' : 'OK';
    final empty = await b.check(c.nodes[0]);
    expect(empty.ready, false);
    await expectLater(b.apply([empty], 'set fr 12 d f=t'), throwsStateError);
    c.answer = (_, command) async =>
        command == 'get fr' ? '1=txt' : 'type=txt action=drop';
    expect((await b.check(c.nodes[1])).ready, false);
    expect(c.commands.where((x) => x.startsWith('set ')), isEmpty);
  });
  test(
    'forged and different-batch ready checks cannot authorize writes',
    () async {
      final checked = await b.check(c.nodes[0]);
      await expectLater(
        b.apply([
          RepeaterFilterCheck(c.nodes[1], true, 'Ready'),
        ], 'set fr 12 d f=t'),
        throwsStateError,
      );
      final other = RepeaterFilterBatch(c);
      addTearDown(other.dispose);
      await expectLater(
        other.apply([checked], 'set fr 12 d f=t'),
        throwsStateError,
      );
    },
  );
  test('replacing slots, injected and oversized rules are rejected', () async {
    final checked = await b.check(c.nodes[0]);
    for (final command in [
      'set fr.1 12 d',
      'set fr 12 d\nreboot',
      'set fr 12 d c=${List.filled(160, 'a').join()}',
    ]) {
      await expectLater(b.apply([checked], command), throwsFormatException);
    }
    expect(c.commands.where((x) => x.startsWith('set ')), isEmpty);
  });
  test('duplicate and empty selections fail before sending', () async {
    final checked = await b.check(c.nodes[0]);
    await expectLater(
      b.apply([checked, checked], 'set fr 12 d f=t'),
      throwsStateError,
    );
    await expectLater(b.apply([], 'set fr 12 d f=t'), throwsStateError);
    expect(c.commands.where((x) => x.startsWith('set ')), isEmpty);
  });
  test('permission downgrade between check and write is not sent', () async {
    final checked = await b.check(c.nodes[0]);
    c.login(c.nodes[0], admin: false);
    final result = (await b.apply([checked], 'set fr 12 d f=t')).single;
    expect(result.applied, false);
    expect(result.message, startsWith('Not sent.'));
    expect(c.commands.where((x) => x.startsWith('set ')), isEmpty);
  });
  test('guard rechecks permission after onSending callback', () async {
    final checked = await b.check(c.nodes[0]);
    final result = (await b.apply(
      [checked],
      'set fr 12 d f=t',
      onSending: (node) => c.login(node, fail: true),
    )).single;
    expect(result.message, startsWith('Not sent.'));
    expect(c.commands.where((x) => x.startsWith('set ')), isEmpty);
  });
  test(
    'switching away and back invalidates the old batch generation',
    () async {
      final checked = await b.check(c.nodes[0]);
      c.repeaterAdminSessions.bindCompanion('other');
      c.login(c.nodes[0]);
      final result = (await b.apply([checked], 'set fr 12 d f=t')).single;
      expect(result.message, contains('Companion changed'));
      expect(c.commands.where((x) => x.startsWith('set ')), isEmpty);
    },
  );
  test(
    'one unconfirmed write never retries or hides later node results',
    () async {
      final a = await b.check(c.nodes[0]), d = await b.check(c.nodes[1]);
      c.answer = (key, command) async {
        if (key == 42 && command.startsWith('set ')) {
          throw StateError('lost response');
        }
        return 'OK';
      };
      final results = await b.apply([a, d], 'set fr 12 d f=t');
      expect(
        results[0].message,
        startsWith('Not confirmed. It may have applied;'),
      );
      expect(results[1].applied, true);
      expect(c.commands.where((x) => x.startsWith('set ')).length, 2);
    },
  );
  test('non-ACK reply is not claimed as a successful save', () async {
    final a = await b.check(c.nodes[0]);
    c.answer = (_, _) async => 'saved perhaps';
    expect((await b.apply([a], 'set fr 12 d f=t')).single.applied, false);
  });
  test('stop after current does not send to remaining nodes', () async {
    final a = await b.check(c.nodes[0]), d = await b.check(c.nodes[1]);
    final results = await b.apply(
      [a, d],
      'set fr 12 d f=t',
      onResult: (_) => b.stopAfterCurrent(),
    );
    expect(results.first.applied, true);
    expect(results.last.message, contains('Stopped before writing'));
    expect(c.commands.where((x) => x.startsWith('set ')).length, 1);
  });
  test(
    'removed target is re-resolved rather than using a stale contact',
    () async {
      final a = await b.check(c.nodes[0]);
      c.nodes.removeAt(0);
      expect(
        (await b.apply([a], 'set fr 12 d f=t')).single.message,
        startsWith('Not sent.'),
      );
    },
  );
}
