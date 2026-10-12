import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/models/channel_message.dart';
import 'package:meshcore_open/services/fleet_management.dart';

import 'repeater_filter_batch_test.dart' show BatchTestConnector, batchContact;

class FleetTestConnector extends BatchTestConnector {
  final messages = <ChannelMessage>[];
  bool loaded = true, syncing = false;
  final created = <Channel>[];
  @override
  bool get hasLoadedChannels => loaded;
  @override
  bool get isLoadingChannels => syncing;
  @override
  bool get isSyncingChannels => syncing;
  @override
  Future<void> setChannel(int index, String name, Uint8List psk) async {
    final channel = Channel(index: index, name: name, psk: psk);
    created.add(channel);
    testChannels.add(channel);
  }

  static const sequence = 1791705600;
  FleetTestConnector() {
    identity = List.filled(64, '1').join();
    testChannels.add(
      Channel(
        index: 3,
        name: 'Private fleet',
        psk: Uint8List.fromList(List.generate(16, (i) => i + 1)),
      ),
    );
    login(nodes[0]);
    login(nodes[1]);
    handler = (command) async => command == 'fleet'
        ? 'Error: use fleet send <channel> [all|key|region:name|home:name|gps:lat,lon:km[;target...]] <command>'
        : 'OK - fleet command queued; seq=$sequence';
    answer = (_, command) async {
      if (command == 'get fleet.channel') {
        return 'off,controller=unset,store=ok,hash=00,last=0';
      }
      if (command == 'get fleet.controller') return 'unset';
      return 'OK';
    };
  }
  @override
  List<ChannelMessage> getChannelMessages(Channel channel) => messages;
}

void main() {
  late FleetTestConnector c;
  late FleetManagementService service;
  var now = DateTime(2026, 10, 11);
  setUp(() {
    c = FleetTestConnector();
    now = DateTime(2026, 10, 11);
    service = FleetManagementService(c, now: () => now);
  });
  tearDown(() {
    service.dispose();
    c.dispose();
  });
  FleetRequest request({
    String target = 'all',
    String command = 'get radio2',
  }) => FleetRequest(c.testChannels.last, FleetTargets.parse(target), command);

  test('opening service and selecting private channels send no requests', () {
    expect(service.available, true);
    expect(service.channels.map((c) => c.index), [3]);
    expect(service.administrators.length, 2);
    expect(c.commands, isEmpty);
  });
  test(
    'native control whitelist accepts firmware examples and compact FPF7 alias',
    () {
      for (final command in [
        'get radio2',
        'set radio2 off',
        'set radio2 910.5,500,8,5,rxtx,auto',
        'set tempradio2 910.5,500,8,5,rxtx,120',
        'get radio2.status',
        'get radio2.timing',
        'set radio2.cross auto',
        'set radioat 910.5,500,8,5,+5',
        'set tempradioat 910.5,500,8,5,+5,+15',
        'set radioat2 910.5,500,8,5,rxtx,+5',
        'set tempradioat2 910.5,500,8,5,rxtx,+5,+15',
        'get tempradioat2 1',
        'del tempradioat2 all',
        'clock',
        'clock sync',
        'time 1791705600',
        'set flood.rule.4 type=grp_txt hops=6+ drop',
        'set flood.rule 12 d f=t',
        'del flood.rule.4',
        'get flood.filter.blacklist',
        'set flood.moderation public "Alice" rate=5/min',
        'get flood.channel.scope.require.1',
        'set flood.channel.data on',
        'set flood.channel.data.hops 5',
        'set flood.max 6',
        'get flood.max.unscoped',
        'get flood.max.advert',
      ]) {
        expect(
          () => validateFleetCommand(command),
          returnsNormally,
          reason: command,
        );
      }
    },
  );
  test(
    'reboot, OTA, credentials, ACLs, immediate primary, arbitrary commands denied',
    () {
      for (final command in [
        'reboot',
        'ota apply',
        'get telemetry.temp',
        'set fleet.channel off',
        'set radio 910.5,500,8,5',
        'get public.key',
        'get password',
        'set acl x',
        'set powersaving on',
        'get radio2;reboot',
        'get radio2\nreboot',
        'get radio2|reboot',
        'get radio2`reboot',
        'get radio2\\reboot',
        'get radio2 &reboot',
        'get radio2 ',
        ' get radio2',
        'get radio2 x',
        'del radio2',
        'set radio2.status on',
        'set radio2.cross enabled',
        'get flood.rule.0',
        'get flood.rule.256',
        'set radioat 910.5,500,8,5',
        'set radioat2 910.5,500,8,5,tx,+5',
        'del radioat2 5',
        'time 0',
        'time 4294967296',
      ]) {
        expect(
          () => validateFleetCommand(command),
          throwsFormatException,
          reason: command,
        );
      }
    },
  );
  test(
    'full identities, prefixes, regions and GPS have exact encoded budgets',
    () {
      expect(FleetTargets.parse('all').headerBytes, 14);
      expect(FleetTargets.parse(c.nodes.first.publicKeyHex).headerBytes, 29);
      expect(FleetTargets.parse('1257aee5').recordBytes, 5);
      expect(FleetTargets.parse('1257aee5a754').recordBytes, 7);
      expect(FleetTargets.parse('region:sea;home:#pdx').recordBytes, 10);
      expect(FleetTargets.parse('gps:47.6062,-122.3321:25').recordBytes, 13);
      expect(
        FleetTargets.parse(
          'region:sea;home:pdx;gps:47.6062,-122.3321:25;1257aee5',
        ).count,
        4,
      );
    },
  );
  test(
    'empty, mixed all, malformed, too many and ambiguous targets never broadcast',
    () {
      for (final value in [
        '',
        'all;',
        ';all',
        'all;1257aee5',
        'sea',
        '1257aee',
        'zzzzzzzz',
        'region:',
        'region:sea;reboot',
        'region:two words',
        List.filled(64, '0').join(),
        List.filled(18, '1257aee5').join(';'),
        List.filled(6, c.nodes.first.publicKeyHex).join(';'),
        'gps:47.6062001,-122:25',
        'gps:91,0:25',
        'gps:0,181:25',
        'gps:0,0:0',
        'gps:0,0:20050.001',
        'gps:1e1,0:1',
        'gps:01,0:1',
        'gps:1,0:.5',
        'gps:1,0:-5',
        'gps:1,0:1.0001',
        'gps:1,0:1;all',
      ]) {
        expect(
          () => FleetTargets.parse(value),
          throwsFormatException,
          reason: value,
        );
      }
      expect(FleetTargets.parse('region:all').count, 1);
      expect(FleetTargets.parse('home:abcdefab').count, 1);
    },
  );
  test(
    'packet estimate matches firmware and app envelope limits are checked',
    () {
      final prefix = 'set flood.rule ';
      expect(
        request(
          command: prefix + List.filled(87 - prefix.length, 'x').join(),
        ).packets,
        1,
      );
      expect(
        request(
          command: prefix + List.filled(88 - prefix.length, 'x').join(),
        ).packets,
        2,
      );
      expect(
        request(
          target: '${c.nodes[0].publicKeyHex};${c.nodes[1].publicKeyHex}',
        ).targets.count,
        2,
      );
      expect(
        () => request(
          target: List.filled(3, c.nodes.first.publicKeyHex).join(';'),
        ),
        throwsFormatException,
      );
      expect(
        () => request(command: prefix + List.filled(220, 'x').join()),
        throwsFormatException,
      );
    },
  );
  test(
    'Public, hashtag, empty, and deterministic disguised hashtag keys excluded',
    () {
      for (final channel in [
        Channel.fromHex(0, 'Public', Channel.publicChannelPsk),
        Channel(index: 2, name: '#secret', psk: generateFleetChannelKey()),
        Channel.empty(3),
        Channel(
          index: 4,
          name: 'test',
          psk: Channel.derivePskFromHashtag('test'),
        ),
      ]) {
        expect(
          () => FleetRequest(channel, FleetTargets.parse('all'), 'clock'),
          throwsFormatException,
        );
      }
      final key = generateFleetChannelKey();
      expect(key.length, 16);
      expect(key, isNot(equals(generateFleetChannelKey())));
    },
  );
  test(
    'support probe is read only; sending uses local signer and explicit target',
    () async {
      await service.checkPublisher();
      expect(c.commands, ['fleet']);
      final result = await service.send(
        request(target: c.nodes.first.publicKeyHex),
      );
      expect(result.sequence, FleetTestConnector.sequence);
      expect(
        c.commands.last,
        'fleet send 3 ${c.nodes.first.publicKeyHex} get radio2',
      );
      expect(c.sentFrames, isEmpty);
    },
  );
  test('unsupported publisher sends no fleet requests', () async {
    c.handler = (_) async => 'Unknown command';
    await expectLater(service.checkPublisher(), throwsUnsupportedError);
    await expectLater(service.send(request()), throwsStateError);
    expect(c.commands, ['fleet']);
  });
  test(
    'queue errors and timeout are not retried; interval covers uncertain attempts',
    () async {
      await service.checkPublisher();
      c.handler = (_) async => throw TimeoutException('lost queue reply');
      await expectLater(
        service.send(request()),
        throwsA(isA<TimeoutException>()),
      );
      await expectLater(service.send(request()), throwsStateError);
      expect(c.commands.where((s) => s.startsWith('fleet send')).length, 1);
      now = now.add(const Duration(milliseconds: 1100));
      c.handler = (_) async => 'Error: queue unavailable';
      await expectLater(service.send(request()), throwsStateError);
      expect(service.dispatch, isNull);
    },
  );
  test('rate limit shared by separate screens on same Companion', () async {
    await service.checkPublisher();
    await service.send(request());
    final other = FleetManagementService(c, now: () => now);
    addTearDown(other.dispose);
    await other.checkPublisher();
    await expectLater(other.send(request()), throwsStateError);
    now = now.add(const Duration(milliseconds: 1100));
    await other.send(request());
  });
  test(
    'changed channel, identity, disconnection and mutable source key rejected',
    () async {
      await service.checkPublisher();
      final r = request();
      c.testChannels.last.psk[0] ^= 1;
      await expectLater(service.send(r), throwsStateError);
      c.connected = false;
      await expectLater(service.send(request()), throwsStateError);
      c.connected = true;
      c.identity = List.filled(64, '2').join();
      await expectLater(service.send(request()), throwsStateError);
      expect(c.commands, ['fleet']);
    },
  );
  test('switch away and back invalidates checked support', () async {
    await service.checkPublisher();
    c.connected = false;
    c.notifyListeners();
    // Connector coalesces UI notifications for 50 ms.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    c.connected = true;
    c.notifyListeners();
    await expectLater(service.send(request()), throwsStateError);
  });
  test(
    'only new matching channel reports are collected; never treated as verified',
    () async {
      ChannelMessage message(String id, String text, {bool outgoing = false}) =>
          ChannelMessage(
            senderName: 'Claimed sender',
            text: text,
            timestamp: DateTime(2026),
            messageId: id,
            isOutgoing: outgoing,
            channelIndex: 3,
          );
      c.messages.add(
        message('old', 'fleet ${FleetTestConnector.sequence} 2a2a2a2a2a2a: OK'),
      );
      await service.checkPublisher();
      await service.send(request());
      c.messages.addAll([
        message(
          'new',
          'fleet ${FleetTestConnector.sequence} 2a2a2a2a2a2a: OK - saved',
        ),
        message('wrong', 'fleet 1791705601 2a2a2a2a2a2a: OK'),
        message(
          'out',
          'fleet ${FleetTestConnector.sequence} 2a2a2a2a2a2a: OK',
          outgoing: true,
        ),
        message('junk', 'OK'),
      ]);
      expect(service.reports.length, 1);
      expect(service.reports.single.sender, 'Claimed sender');
      expect(service.reports.single.reply, 'OK - saved');
      c.testChannels.removeLast();
      expect(service.reports, isEmpty);
    },
  );
  test(
    'enrollment requires confirmed admin and a healthy supported read',
    () async {
      await service.checkPublisher();
      await expectLater(
        service.enroll(c.nodes[0], c.testChannels.last),
        throwsStateError,
      );
      await expectLater(service.inspect(c.nodes[2]), throwsStateError);
      c.answer = (_, _) async => 'Unknown command';
      await expectLater(service.inspect(c.nodes[0]), throwsUnsupportedError);
      expect(c.commands.where((s) => s.startsWith('set ')), isEmpty);
    },
  );
  test(
    'enrollment uses two individually authenticated commands, never shared-channel key broadcast',
    () async {
      await service.checkPublisher();
      await service.inspect(c.nodes[0]);
      await service.enroll(c.nodes[0], c.testChannels.last);
      expect(c.commands.where((s) => s.startsWith('set ')), [
        'set fleet.controller ${c.identity}',
        'set fleet.channel ${c.testChannels.last.pskHex}',
      ]);
      expect(service.checked, isEmpty);
      expect(c.commands.where((s) => s.startsWith('fleet send')), isEmpty);
    },
  );
  test(
    'failed enrollment preserves partial truth and cannot retry without new read',
    () async {
      await service.checkPublisher();
      await service.inspect(c.nodes[0]);
      c.answer = (_, command) async => command.startsWith('set fleet.channel')
          ? 'Err - store unavailable'
          : 'OK';
      await expectLater(
        service.enroll(c.nodes[0], c.testChannels.last),
        throwsA(
          predicate((e) => e.toString().contains('1 of 2 changes confirmed')),
        ),
      );
      await expectLater(
        service.enroll(c.nodes[0], c.testChannels.last),
        throwsStateError,
      );
      expect(c.commands.where((s) => s.startsWith('set ')).length, 2);
    },
  );
  test(
    'permission or channel change after first enrollment write prevents second',
    () async {
      await service.checkPublisher();
      await service.inspect(c.nodes[0]);
      c.answer = (_, command) async {
        c.login(c.nodes[0], admin: false);
        return 'OK';
      };
      await expectLater(
        service.enroll(c.nodes[0], c.testChannels.last),
        throwsStateError,
      );
      expect(c.commands.where((s) => s.startsWith('set ')).length, 1);
    },
  );
  test(
    'room admin eligible for fleet but not existing repeater filter batch',
    () {
      c.nodes.add(batchContact(45, 'Room', type: advTypeRoom));
      c.login(c.nodes.last);
      expect(service.administrators.length, 3);
      expect(c.repeaterAdminSessions.repeaters(c.nodes, c.identity).length, 2);
    },
  );
  test('closed service refuses actions without sending', () async {
    service.dispose();
    await expectLater(service.checkPublisher(), throwsStateError);
    service = FleetManagementService(c);
    expect(c.commands, isEmpty);
  });
  test(
    'channel creation requires a complete read and the confirmed free slot',
    () async {
      c.loaded = false;
      expect(() => service.freeChannelSlot, throwsStateError);
      await expectLater(service.createPrivateChannel(1), throwsStateError);
      c.loaded = true;
      c.syncing = true;
      await expectLater(service.createPrivateChannel(1), throwsStateError);
      c.syncing = false;
      expect(service.freeChannelSlot, 1);
      c.testChannels.add(
        Channel(index: 1, name: 'Occupied', psk: generateFleetChannelKey()),
      );
      await expectLater(service.createPrivateChannel(1), throwsStateError);
      expect(c.created, isEmpty);
      await service.createPrivateChannel(2);
      expect(c.created.single.index, 2);
      expect(isFleetChannel(c.created.single), true);
      expect(c.commands, isEmpty);
    },
  );
}
