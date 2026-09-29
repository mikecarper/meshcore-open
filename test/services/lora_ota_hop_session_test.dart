import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/lora_ota_hop_session.dart';
import 'package:meshcore_open/services/storage_service.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'minimum counts passive hashes, uses width, and covers every branch',
    () {
      for (var width = 1; width <= 4; width++) {
        expect(
          loraOtaMinimumHopLimit([
            [],
            List.filled(2 * width, 0x22),
            List.filled(5 * width, 0x33),
          ], width),
          5,
        );
      }
      expect(loraOtaMinimumHopLimit([[]], 1), 0);
      expect(loraOtaMinimumHopLimit([List.filled(32, 0)], 4), 8);
      expect(
        () => loraOtaMinimumHopLimit([
          [1],
        ], 2),
        throwsFormatException,
      );
      expect(() => loraOtaMinimumHopLimit([[]], 0), throwsFormatException);
      expect(
        () => loraOtaMinimumHopLimit([List.filled(9, 0)], 1),
        throwsStateError,
      );
    },
  );

  test('parses legacy, seeder-only, persisted and banner replies', () {
    for (var hops = 0; hops <= 8; hops++) {
      expect(
        parseLoraOtaHops('ota config: speed=1x hops=$hops keys=0 (persisted)'),
        hops,
      );
      expect(
        parseLoraOtaHops(
          '> ota config\r\n ota config: mode=seeder-only hops=$hops\r\n>',
        ),
        hops,
      );
    }
  });

  test(
    'never treats missing, ambiguous, erroneous or malformed policy as zero',
    () {
      for (final reply in [
        '',
        'Unknown command',
        'ERR admin required',
        'OK',
        'hops=0',
        'ota config: speed=1x',
        'ota config: hops=-1',
        'ota config: hops=9',
        'ota config: hops=0.0',
        'ota config: hops=00',
        'ota config: hops=0 hops=1',
        'ota config: hops=0\nota config: hops=1',
      ]) {
        expect(
          () => parseLoraOtaHops(reply),
          throwsFormatException,
          reason: reply,
        );
      }
    },
  );

  test('only explicit non-OTA relay reply allows opaque forwarding', () async {
    final h = _Harness();
    final relay = _Radio('relay', 0, 3)
      ..configReply =
          'LoRa OTA is not included in this build; tempradio cannot enable it. Use an OTA-enabled repeater firmware';
    await h.session.prepare([relay.participant(allowOpaque: true)], 1);
    await h.session.apply();
    expect(relay.writes, isEmpty);
    await expectLater(
      h.session.prepare([relay.participant()], 1),
      throwsFormatException,
    );
    relay.configReply = 'Unknown command';
    await expectLater(
      h.session.prepare([relay.participant(allowOpaque: true)], 1),
      throwsFormatException,
    );
  });

  test('direct sessions do not read or change policies', () async {
    final h = _Harness();
    final radio = _Radio('source', 0, 1);
    await h.session.prepare([radio.participant()], 0);
    await h.session.apply();
    await h.session.restore();
    expect(radio.calls, isEmpty);
    expect(h.saved, isEmpty);
  });

  for (final minimum in [1, 2, 3, 8]) {
    test(
      'raises only insufficient limits to $minimum and restores originals',
      () async {
        final h = _Harness();
        final source = _Radio('source', 0, 1);
        final target = _Radio('target', 0, 2);
        final relay = _Radio('relay', 8, 3);
        await h.session.prepare([
          source.participant(),
          target.participant(),
          relay.participant(),
        ], minimum);
        expect(source.writes, isEmpty);
        source.beforeWrite = () {
          expect(
            h.saved.map((record) => record.publicKey),
            contains(source.key),
          );
        };
        await h.session.apply();
        expect([source.hops, target.hops, relay.hops], [minimum, minimum, 8]);
        expect(relay.writes, isEmpty);
        await h.session.restore();
        expect([source.hops, target.hops, relay.hops], [0, 0, 8]);
        expect(h.saved, isEmpty);
        expect(h.session.needsRecovery, isFalse);
      },
    );
  }

  test(
    'unknown participant or timeout stops preflight without writes',
    () async {
      final h = _Harness();
      final source = _Radio('source', 0, 1);
      final target = _Radio('target', 0, 2)..unreachable = true;
      await expectLater(
        h.session.prepare([source.participant(), target.participant()], 1),
        throwsA(isA<TimeoutException>()),
      );
      await expectLater(h.session.apply(), throwsStateError);
      expect(source.writes, isEmpty);
      expect(h.saved, isEmpty);
    },
  );

  test(
    'rechecks every policy before first write and preserves external edits',
    () async {
      final h = _Harness();
      final source = _Radio('source', 0, 1);
      final target = _Radio('target', 0, 2);
      await h.session.prepare([source.participant(), target.participant()], 1);
      target.hops = 4;
      await expectLater(h.session.apply(), throwsStateError);
      expect(source.writes, isEmpty);
      expect(target.writes, isEmpty);
      expect(h.saved, isEmpty);
    },
  );

  test('reconnect verifies without overwriting unexpected policies', () async {
    final h = _Harness();
    final target = _Radio('target', 0, 2);
    await h.session.prepare([target.participant()], 1);
    await h.session.apply();
    await h.session.verifyTransfer();
    target.hops = 0;
    await expectLater(h.session.verifyTransfer(), throwsStateError);
    expect(target.writes, ['ota config hops 1']);
    await h.session.restore();
  });

  test('lost setter replies use readback, not a repeated write', () async {
    final h = _Harness();
    final target = _Radio('target', 0, 2)..loseWriteReply = true;
    await h.session.prepare([target.participant()], 1);
    await h.session.apply();
    expect(target.writes, ['ota config hops 1']);
    await h.session.restore();
    expect(target.writes, ['ota config hops 1', 'ota config hops 0']);
    expect(h.saved, isEmpty);
  });

  test(
    'readback mismatch rejects ACK and rolls back partially changed nodes',
    () async {
      final h = _Harness();
      final source = _Radio('source', 0, 1);
      final target = _Radio('target', 0, 2)..ignoreWrite = true;
      await h.session.prepare([source.participant(), target.participant()], 2);
      await expectLater(h.session.apply(), throwsStateError);
      expect(source.hops, 2);
      expect(h.saved.length, 2);
      await h.session.restore();
      expect(source.hops, 0);
      expect(target.writes, ['ota config hops 2']);
      expect(h.saved, isEmpty);
    },
  );

  test('failed save prevents any mutation', () async {
    final h = _Harness()..failSave = true;
    final target = _Radio('target', 0, 2);
    await h.session.prepare([target.participant()], 1);
    await expectLater(h.session.apply(), throwsStateError);
    expect(target.writes, isEmpty);
    expect(h.session.needsRecovery, isFalse);
  });

  test(
    'restoration attempts all nodes and retains unreachable recovery',
    () async {
      final h = _Harness();
      final source = _Radio('source', 0, 1);
      final target = _Radio('target', 0, 2);
      await h.session.prepare([source.participant(), target.participant()], 1);
      await h.session.apply();
      target.unreachable = true;
      await expectLater(h.session.restore(), throwsStateError);
      expect(source.hops, 0);
      expect(h.saved.single.publicKey, target.key);
      target.unreachable = false;
      await h.session.restore();
      expect(target.hops, 0);
      expect(h.saved, isEmpty);
    },
  );

  test(
    'restore preserves unexpected external policy and keeps recovery',
    () async {
      final h = _Harness();
      final target = _Radio('target', 0, 2);
      await h.session.prepare([target.participant()], 1);
      await h.session.apply();
      target.hops = 4;
      await expectLater(h.session.restore(), throwsStateError);
      expect(target.hops, 4);
      expect(target.writes.length, 1);
      expect(h.saved.single.original, 0);
      target.hops = 0; // Administrator restored the original manually.
      await h.session.restore();
      expect(target.writes.length, 1);
      expect(h.saved, isEmpty);
    },
  );

  test(
    'failed record removal keeps ownership until a verified retry',
    () async {
      final h = _Harness();
      final target = _Radio('target', 0, 2);
      await h.session.prepare([target.participant()], 1);
      await h.session.apply();
      h.failSave = true;
      await expectLater(h.session.restore(), throwsStateError);
      expect(target.hops, 0);
      expect(h.session.needsRecovery, isTrue);
      h.failSave = false;
      await h.session.restore();
      expect(target.writes.length, 2);
      expect(h.saved, isEmpty);
    },
  );

  test(
    'recovery rehydrates after restart without overwriting the original',
    () async {
      final h = _Harness();
      final target = _Radio('target', 0, 2);
      await h.session.prepare([target.participant()], 1);
      await h.session.apply();
      final record = LoraOtaHopRecovery.fromJson(
        jsonDecode(jsonEncode(h.saved.single.toJson())) as Map<String, dynamic>,
      );
      final restarted = _Harness();
      restarted.session.resumeRecovery(target.participant(), record);
      await expectLater(
        restarted.session.prepare([target.participant()], 1),
        throwsStateError,
      );
      await restarted.session.restore();
      expect(target.hops, 0);
      expect(restarted.session.needsRecovery, isFalse);
      expect(
        () => restarted.session.resumeRecovery(
          _Radio('other', 0, 4).participant(),
          record,
        ),
        throwsStateError,
      );
    },
  );

  test(
    'recovery stores paths and identity, not passwords, and rejects bad data',
    () {
      final record = LoraOtaHopRecovery(
        publicKey: '01' * 32,
        name: 'target',
        local: false,
        original: 0,
        transfer: 1,
        normalPath: List.filled(9, 0x22),
        temporaryPath: [0x33],
        hashWidth: 1,
      );
      expect(record.toJson().containsKey('password'), isFalse);
      expect(record.restoreCommand, 'ota config hops 0');
      expect(LoraOtaHopRecovery.fromJson(record.toJson()).normalPath.length, 9);
      expect(
        () => LoraOtaHopRecovery.fromJson({
          ...record.toJson(),
          'publicKey': 'short',
        }),
        throwsFormatException,
      );
      expect(
        () => LoraOtaHopRecovery.fromJson({...record.toJson(), 'original': 9}),
        throwsFormatException,
      );
      expect(
        () => LoraOtaHopRecovery.fromJson({
          ...record.toJson(),
          'normalPath': [-1],
        }),
        throwsFormatException,
      );
    },
  );

  test(
    'persistent recovery survives manager restart and is identity-scoped',
    () async {
      SharedPreferences.setMockInitialValues({});
      PrefsManager.reset();
      await PrefsManager.initialize();
      final storage = StorageService();
      final source = 'aa' * 32;
      final target = 'bb' * 32;
      final record = LoraOtaHopRecovery(
        publicKey: target,
        name: 'target',
        local: false,
        original: 0,
        transfer: 1,
        normalPath: [0x11],
        temporaryPath: [0x22],
        hashWidth: 1,
      );
      await storage.saveLoraOtaHopRecovery(source, target, [record]);
      PrefsManager.reset();
      await PrefsManager.initialize();
      expect(
        (await storage.loadLoraOtaHopRecovery(source, target)).single.original,
        0,
      );
      expect(await storage.loadLoraOtaHopRecovery('cc' * 32, target), isEmpty);
      expect(storage.hasOtherLoraOtaHopRecovery(source, 'dd' * 32), isTrue);
      expect(storage.hasOtherLoraOtaHopRecovery(source, target), isFalse);
      await storage.saveLoraOtaHopRecovery(source, target, []);
      expect(await storage.loadLoraOtaHopRecovery(source, target), isEmpty);
      await expectLater(
        storage.loadLoraOtaHopRecovery('short', target),
        throwsStateError,
      );
      await PrefsManager.instance.setString(
        'lora_ota_hop_recovery_${source}_$target',
        'not json',
      );
      await expectLater(
        storage.loadLoraOtaHopRecovery(source, target),
        throwsFormatException,
      );
    },
  );
}

class _Harness {
  List<LoraOtaHopRecovery> saved = [];
  bool failSave = false;
  late final session = LoraOtaHopSession(
    persist: (records) async {
      if (failSave) throw StateError('Storage unavailable');
      saved = records;
    },
    log: (_) {},
  );
}

class _Radio {
  final String name;
  final int keyByte;
  int hops;
  bool unreachable = false;
  bool loseWriteReply = false;
  bool ignoreWrite = false;
  String? configReply;
  void Function()? beforeWrite;
  final List<String> calls = [];
  _Radio(this.name, this.hops, this.keyByte);
  String get key => keyByte.toRadixString(16).padLeft(2, '0') * 32;
  List<String> get writes =>
      calls.where((command) => command.startsWith('ota config hops ')).toList();
  LoraOtaHopParticipant participant({bool allowOpaque = false}) =>
      LoraOtaHopParticipant(
        publicKey: key,
        name: name,
        allowOpaque: allowOpaque,
        command: (command) async {
          calls.add(command);
          if (unreachable) throw TimeoutException('no response');
          if (command == 'ota config') {
            return configReply ?? 'ota config: speed=1x hops=$hops keys=0';
          }
          beforeWrite?.call();
          final desired = int.parse(command.split(' ').last);
          if (!ignoreWrite) hops = desired;
          if (loseWriteReply) throw TimeoutException('setter response lost');
          return 'OK OTA reach = $desired hops (saved)';
        },
      );
}
