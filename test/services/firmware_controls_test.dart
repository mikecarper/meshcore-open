import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/models/path_selection.dart';
import 'package:meshcore_open/services/firmware_controls.dart';

void main() {
  testWidgets('remote controls accept a reply beyond the airtime timeout', (
    tester,
  ) async {
    final c = _FastTimeoutControlConnector();
    final e = FirmwareControlEndpoint(c, target: controlTestContact());
    addTearDown(() {
      e.dispose();
      c.dispose();
    });
    var done = false;
    final request = e.read('get fr.1').then((reply) {
      done = true;
      return reply;
    });
    await tester.pump();
    await tester.pump(const Duration(seconds: 12));
    expect(done, false);
    final sent = c.sentFrames.single;
    final prefix = utf8.decode(sent.sublist(13, 16));
    c.frames.add(
      Uint8List.fromList([
        respCodeContactMsgRecv,
        ...controlTestContact().publicKey.take(6),
        0,
        txtTypeCliData,
        0,
        0,
        0,
        0,
        ...utf8.encode('${prefix}set fr.1 12 d f=t'),
        0,
      ]),
    );
    await tester.pump();
    expect(await request, 'set fr.1 12 d f=t');
    expect(c.sentFrames.length, 1);
  });
  testWidgets('remote writes still time out without a retry', (tester) async {
    final c = _FastTimeoutControlConnector();
    final e = FirmwareControlEndpoint(c, target: controlTestContact());
    addTearDown(() {
      e.dispose();
      c.dispose();
    });
    final request = e
        .apply(['set fr 12 d f=t'])
        .then((_) => 'saved', onError: (Object error) => error.toString());
    await tester.pump();
    await tester.pump(const Duration(seconds: 31));
    expect(await request, contains('Command timeout after 30 seconds'));
    expect(c.sentFrames.length, 1);
  });
  test(
    'channel moderation uses real sender table, rate limits and hop cutoff',
    () {
      final rule = ChannelModerationRule()..sender = 'Noisy User';
      expect(
        rule.command(),
        'set flood.moderation public "Noisy User" rate=5/min',
      );
      final saved = ChannelModerationRule.parse(
        '> 3 channel=#local sender="Alice" path=A1B2 rate=4/min hops=5',
      );
      expect(
        saved.command(),
        'set flood.moderation.3 #local "Alice" rate=4/min hops=5 path=A1B2',
      );
      rule.sender = '*';
      expect(() => rule.command(), throwsFormatException);
      rule.action = 'hops';
      expect(() => rule.command(), throwsFormatException);
      rule.hops = '5';
      expect(rule.command(), contains('hops=5'));
      rule.sender = 'Alice: admin';
      expect(() => rule.command(), throwsFormatException);
      rule.sender = 'Alice" reboot';
      expect(() => rule.command(), throwsFormatException);
      rule.sender = 'Alice';
      rule.path = 'AA,AABB';
      expect(() => rule.command(), throwsFormatException);
    },
  );
  test('batch guards recheck state before each separate write', () async {
    final c = ControlTestConnector();
    final e = FirmwareControlEndpoint(c);
    addTearDown(() {
      e.dispose();
      c.dispose();
    });
    var count = 0;
    await expectLater(
      e.apply(
        ['set notify.led on', 'set notify.screen on'],
        guard: () {
          if (++count == 2) throw StateError('channel replaced');
        },
      ),
      throwsStateError,
    );
    expect(c.commands, ['set notify.led on']);
  });
  test('notification caps and supported masks come from firmware', () {
    final c = NotificationCapabilities.parse(
      '> enabled=on outputs=5 supported=13 active=off rules=12',
    );
    expect(c.enabled, true);
    expect(c.outputs, 5);
    expect(c.supported, 13);
    expect(
      () => NotificationCapabilities.parse('Unknown command'),
      throwsFormatException,
    );
    expect(
      () => NotificationCapabilities.parse(
        'enabled=on outputs=255 supported=255',
      ),
      throwsFormatException,
    );
  });
  test('strict pulse limits and selector validation', () {
    expect(parseNotificationPulse('50,300,40,20,500'), [50, 300, 40, 20, 500]);
    expect(parseNotificationPulse('inherit'), isEmpty);
    for (final value in [
      '0',
      '60001',
      '50,',
      '50, 40',
      List.filled(13, '10').join(','),
    ]) {
      expect(() => parseNotificationPulse(value), throwsFormatException);
    }
    final key = List.filled(64, 'a').join();
    expect(
      notificationRuleCommand('contact:$key@disconnected', 'repeat', 'forever'),
      'set notify.repeat contact:$key@disconnected forever',
    );
    expect(
      () => notificationRuleCommand('all\nreboot', 'led', '100'),
      throwsFormatException,
    );
    expect(
      () => notificationRuleCommand('all', 'remote', 'on'),
      throwsFormatException,
    );
    expect(
      () => notificationRuleCommand('contact:$key@connected', 'remote', 'on'),
      throwsFormatException,
    );
    expect(
      notificationRuleCommand('room:$key', 'remote', 'on'),
      'set notify.remote room:$key on',
    );
  });
  test('GPIO approved pins only; range and stop controls validated', () {
    expect(
      notificationRuleCommand(
        'channel:1',
        'gpio',
        '22:100,200',
        gpioPins: {22},
      ),
      'set notify.gpio channel:1 22:100,200',
    );
    expect(
      () => notificationRuleCommand('all', 'gpio', '23:100', gpioPins: {22}),
      throwsFormatException,
    );
    expect(
      () => notificationRuleCommand('all', 'repeat', '0'),
      throwsFormatException,
    );
    expect(
      () => notificationRuleCommand('all', 'gap', '60001'),
      throwsFormatException,
    );
    expect(
      () => notificationRuleCommand('all', 'stop', 'reboot'),
      throwsFormatException,
    );
  });
  test('RTTTL matches firmware safe parser and duration arithmetic', () {
    expect(notificationSoundDuration('Alert:d=8,o=5,b=120:c,e,g'), 750);
    expect(notificationSoundDuration('X:d=4,o=7,b=120:a#.7,p'), 1250);
    for (final value in [
      'x:d=4,o=3,b=120:c',
      'x:d=4,o=5,b=0:c',
      'x:d=3,o=5,b=120:c',
      'x:d=4,o=5,b=120:b#',
      'x:d=4,o=5,b=120:c04',
      'x:d=4,o=5,b=120:c..',
      'x:d=4,o=5,b=120:c,',
      'x:d=1,o=5,b=25:${List.filled(10, 'c').join(',')}',
    ]) {
      expect(
        () => notificationSoundDuration(value),
        throwsFormatException,
        reason: value,
      );
    }
  });
  test('Radio 2 getter parsing and setter match firmware tuple', () {
    expect(SecondaryRadioProfile.parse('> off').command(), 'set radio2 off');
    final p = SecondaryRadioProfile.parse(
      '> 910.525,250.000,8,5,rxtx,32 (auto); chirp warning',
    );
    expect(p.command(), 'set radio2 910.525,250.0,8,5,rxtx,auto');
    expect(
      p.command(minutes: 120),
      'set tempradio2 910.525,250.0,8,5,rxtx,120,auto',
    );
    for (final p in [
      const SecondaryRadioProfile(frequency: 149, mode: 'rx'),
      const SecondaryRadioProfile(bandwidth: 123, mode: 'rx'),
      const SecondaryRadioProfile(sf: 13, mode: 'rx'),
      const SecondaryRadioProfile(cr: 4, mode: 'rx'),
      const SecondaryRadioProfile(preamble: '7', mode: 'rx'),
    ]) {
      expect(() => p.command(), throwsFormatException);
    }
    expect(
      () => const SecondaryRadioProfile(mode: 'rx').command(minutes: 10081),
      throwsFormatException,
    );
  });
  test('channel routes select numeric slots and preserve active warnings', () {
    expect(
      parseChannelRadioRoute(
        '> tx.channel 0 "Public" both; active=radio (radio2 unavailable for TX)',
      ),
      'both',
    );
    expect(channelRadioRouteCommand(0, 'radio2'), 'set tx.channel 0 radio2');
    expect(
      () => channelRadioRouteCommand(0, 'radio2\nreboot'),
      throwsFormatException,
    );
    expect(() => parseChannelRadioRoute('OK'), throwsFormatException);
  });
  test('FPF7 compact rows round trip all flags without widening matches', () {
    for (final line in [
      'set fr.1 12 d f=t',
      'set fr.2 any 5+ c=#wardriving d',
      'set fr.3 any m=bc c=#wardriving d',
      'set fr.9 6 m=c 2-6 c=hash:A7 p=860C,12A4 i=s:#usa s=#BlackHole86 q=10 pri=7 s f=str',
      'set fr.8 5 c=key:AABBCCDD i=r:west r=west q=0',
    ]) {
      final first = ForwardingRule.parse(line);
      final second = ForwardingRule.parse(first.command());
      expect(second.command(), first.command(), reason: line);
      expect(second.slot, first.slot);
      expect(second.action, first.action);
      expect(second.mode, first.mode);
    }
    expect(
      () => ForwardingRule.parse('set fr.1 any d mystery=on'),
      throwsFormatException,
    );
    expect(
      () => ForwardingRule.parse('> 1 type=ota hops=all drop'),
      throwsFormatException,
    );
    final r = ForwardingRule()
      ..action = 'none'
      ..rate = '65535';
    expect(() => r.command(), throwsFormatException);
    r.rate = '';
    r.retry = true;
    r.action = 'drop';
    expect(() => r.command(), throwsFormatException);
  });
  test(
    'filters enforce room restrictions, path widths, injection and size',
    () {
      final r = ForwardingRule()..prefix = '86,860C';
      expect(() => r.command(), throwsFormatException);
      r.prefix = 'blacklist';
      expect(() => r.command(room: true), throwsFormatException);
      r.prefix = '';
      r.hops = '6-2';
      expect(() => r.command(), throwsFormatException);
      r.hops = 'all';
      r.channel = '#test reboot';
      expect(() => r.command(), throwsFormatException);
      expect(
        () => validateFirmwareCommand('set radio2 off\nreboot'),
        throwsFormatException,
      );
      expect(
        () => validateFirmwareCommand('a' * 156, remote: true),
        throwsFormatException,
      );
      expect(() => validateFirmwareCommand('a' * 169), throwsFormatException);
    },
  );
  test(
    'blacklist and scope rows target the actual separate firmware tables',
    () {
      expect(
        filterBlacklistCommand('abcdef, 123456'),
        'set flood.filter.blacklist ABCDEF,123456',
      );
      expect(
        filterBlacklistCommand('ABCDEF', slot: 3),
        'set flood.filter.blacklist.3 ABCDEF',
      );
      expect(() => filterBlacklistCommand('ABCD'), throwsFormatException);
      expect(
        () => filterBlacklistCommand('ABCDEF,abcdef'),
        throwsFormatException,
      );
      final s = ScopeRewriteRule.parse(
        '> 3 match=txt:* path=bucket:2 scope=#usa tx=slow',
      );
      expect(() => s.command(), throwsFormatException);
      s.directScope = true;
      expect(
        s.command(),
        'set flood.channel.scope.3 txt:* scope=#usa path=bucket:2 tx=slow',
      );
      final region = ScopeRewriteRule.parse('> 4 match=public scope=west');
      region.directScope = false;
      expect(region.command(), 'set flood.channel.scope.4 public west');
      expect(
        () => ScopeRewriteRule.parse('> 3 match=txt:* scope=id:4?'),
        throwsFormatException,
      );
    },
  );
  test(
    'batch preflight stops invalid writes; failures preserve partial truth',
    () async {
      final connector = ControlTestConnector();
      final e = FirmwareControlEndpoint(connector);
      addTearDown(() {
        e.dispose();
        connector.dispose();
      });
      await expectLater(
        e.apply(['set notify.led on', 'reboot\n']),
        throwsFormatException,
      );
      expect(connector.commands, isEmpty);
      connector.replies['set notify.sound on'] = 'Error: save failed';
      await expectLater(
        e.apply([
          'set notify.led on',
          'set notify.sound on',
          'set notify.screen on',
        ]),
        throwsA(predicate((e) => '$e'.contains('1 of 3 changes confirmed'))),
      );
      expect(connector.commands, ['set notify.led on', 'set notify.sound on']);
    },
  );
  test(
    'read rejects unknown features and changed devices; no optimistic ACK',
    () async {
      final connector = ControlTestConnector();
      final e = FirmwareControlEndpoint(connector);
      addTearDown(() {
        e.dispose();
        connector.dispose();
      });
      connector.replies['get notify'] = 'Unknown command';
      await expectLater(e.read('get notify'), throwsUnsupportedError);
      connector.replies['set notify.led on'] = 'accepted maybe';
      await expectLater(e.apply(['set notify.led on']), throwsStateError);
      connector.identity = 'different';
      await expectLater(e.read('get notify'), throwsStateError);
    },
  );
  test(
    'remote endpoint ignores other contacts and ordinary text replies',
    () async {
      final connector = ControlTestConnector();
      final target = controlTestContact();
      final e = FirmwareControlEndpoint(connector, target: target);
      addTearDown(() {
        e.dispose();
        connector.dispose();
      });
      final pending = e.read('get fr.1');
      await Future<void>.delayed(Duration.zero);
      final prefix = utf8.decode(connector.sentFrames.single.sublist(13, 16));
      var done = false;
      pending.then((_) {
        done = true;
      });
      connector.frames.add(
        Uint8List.fromList([
          7,
          ...List.filled(6, 88),
          0,
          1,
          0,
          0,
          0,
          0,
          ...utf8.encode('${prefix}forged'),
          0,
        ]),
      );
      connector.frames.add(
        Uint8List.fromList([
          7,
          ...target.publicKey.take(6),
          0,
          0,
          0,
          0,
          0,
          0,
          ...utf8.encode('${prefix}ordinary'),
          0,
        ]),
      );
      await Future<void>.delayed(Duration.zero);
      expect(done, false);
      connector.frames.add(
        Uint8List.fromList([
          7,
          ...target.publicKey.take(6),
          0,
          1,
          0,
          0,
          0,
          0,
          ...utf8.encode('${prefix}set fr.1 12 d f=t'),
          0,
        ]),
      );
      expect(await pending, 'set fr.1 12 d f=t');
    },
  );
}

Contact controlTestContact() => Contact(
  publicKey: Uint8List.fromList(List.filled(32, 42)),
  name: 'Test repeater',
  type: advTypeRepeater,
  pathLength: 0,
  path: Uint8List(0),
  lastSeen: DateTime.now(),
);

class _FastTimeoutControlConnector extends ControlTestConnector {
  @override
  int calculateTimeout({
    required int pathLength,
    int messageBytes = 100,
    String? contactKey,
    int? deviceTimeoutMs,
  }) => 1000;
}

class ControlTestConnector extends MeshCoreConnector {
  bool connected = true;
  String identity = 'test-device';
  int protocol = 14;
  final Map<String, String> replies = {};
  final List<String> commands = [];
  final List<Uint8List> sentFrames = [];
  final List<Channel> testChannels = [
    Channel.fromHex(0, 'Public', Channel.publicChannelPsk),
  ];
  final frames = StreamController<Uint8List>.broadcast();
  Future<String> Function(String)? handler;
  Future<String> Function(String)? remoteHandler;
  @override
  List<Channel> get channels => testChannels;
  @override
  bool get isConnected => connected;
  @override
  int? get firmwareVerCode => protocol;
  @override
  String get selfPublicKeyHex => identity;
  @override
  String? get selfName => 'Test Companion';
  @override
  Stream<Uint8List> get receivedFrames => frames.stream;
  @override
  Future<String> executeLocalCliCommand(
    String command, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    commands.add(command);
    return handler != null ? handler!(command) : replies[command] ?? 'OK';
  }

  @override
  Future<void> sendFrame(
    Uint8List frame, {
    String? channelSendQueueId,
    bool expectsGenericAck = false,
    bool waitForGenericAck = false,
  }) async {
    sentFrames.add(frame);
    if (remoteHandler != null) {
      final text = utf8.decode(frame.sublist(13, frame.length - 1));
      final command = text.substring(3);
      commands.add(command);
      final reply = await remoteHandler!(command);
      frames.add(
        Uint8List.fromList([
          respCodeContactMsgRecv,
          ...frame.sublist(7, 13),
          0,
          txtTypeCliData,
          0,
          0,
          0,
          0,
          ...utf8.encode('${text.substring(0, 3)}$reply'),
          0,
        ]),
      );
    }
  }

  @override
  Future<PathSelection> preparePathForContactSend(
    Contact contact, {
    PathSelection? explicitSelection,
  }) async =>
      explicitSelection ??
      PathSelection(pathBytes: Uint8List(0), hopCount: 0, useFlood: false);
  @override
  void dispose() {
    frames.close();
    super.dispose();
  }
}
