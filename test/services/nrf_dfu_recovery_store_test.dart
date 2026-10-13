import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/companion_image_validator.dart';
import 'package:meshcore_open/services/nrf_dfu_recovery_store.dart';

import '../support/companion_firmware_test_data.dart';

void main() {
  late Directory support;
  late DateTime now;
  late NrfDfuRecoveryStore store;
  const address = 'EB:9D:56:B2:48:48';
  final publicKey = List.filled(64, 'a').join();

  setUp(() async {
    support = await Directory.systemTemp.createTemp('mesh-dfu-recovery-test-');
    now = DateTime.utc(2026, 10, 12);
    store = NrfDfuRecoveryStore(directory: () async => support, now: () => now);
  });
  tearDown(() async {
    await support.delete(recursive: true);
  });

  Future<NrfDfuRecoveryRecord> save({
    String originalAddress = address,
    String board = 'Heltec T096',
    bool marked = true,
    bool applicationOnly = true,
    String? verifiedBootloaderAddress,
    CompanionFirmwareProvenance? provenance,
  }) async {
    final source = File('${support.path}/selected.zip');
    await source.writeAsBytes(
      testNrfDfuZip(image: testNrfApplication(marked: marked)),
    );
    return store.save(
      sourcePath: source.path,
      originalAddress: originalAddress,
      board: board,
      publicKey: publicKey,
      filename: 't096-full.zip',
      applicationOnly: applicationOnly,
      verifiedBootloaderAddress: verifiedBootloaderAddress,
      provenance: provenance,
    );
  }

  Future<Map<String, dynamic>> metadata() async => Map<String, dynamic>.from(
    jsonDecode(
          await File('${support.path}/dfu-recovery/record.json').readAsString(),
        )
        as Map,
  );
  Future<void> change(Map<String, dynamic> data) => File(
    '${support.path}/dfu-recovery/record.json',
  ).writeAsString(jsonEncode(data));

  test(
    'iOS UUID survives real persistence and the native transfer lease',
    () async {
      const uuid = '24680abc-1234-5678-9abc-0123456789ab';
      final saved = await save(originalAddress: uuid);
      expect(saved.originalAddress, uuid.toUpperCase());
      final reopened = NrfDfuRecoveryStore(
        directory: () async => support,
        now: () => now,
      );
      expect((await reopened.load())!.originalAddress, uuid.toUpperCase());
      await reopened.markTransferActive();
      expect(await reopened.hasUnconfirmedNativeTransfer(), isTrue);
      expect((await reopened.load())!.canRetry, isFalse);
      await reopened.markTransferSettled();
      await reopened.clear();
      await reopened.markExternalTransferActive(
        address: uuid,
        board: 'Heltec T096',
        publicKey: publicKey,
      );
      expect(await reopened.hasUnconfirmedNativeTransfer(), isTrue);
      await reopened.markExternalTransferSettled();
    },
  );

  test(
    'invalid original identifiers do not become saved recovery targets',
    () async {
      for (final invalid in [
        'MeshCore-T096',
        'EB:9D:56:B2:48',
        '24680abc-1234-5678-9abc-0123456789',
        '24680abc-1234-5678-9abc-0123456789ab/other',
      ]) {
        await expectLater(
          save(originalAddress: invalid),
          throwsFormatException,
        );
      }
    },
  );

  test('external native guard rejects a symlinked recovery root', () async {
    final outside = await Directory('${support.path}/unrelated').create();
    await Link('${support.path}/dfu-recovery').create(outside.path);
    await expectLater(
      store.markExternalTransferActive(
        address: address,
        board: 'Heltec T096',
        publicKey: publicKey,
      ),
      throwsA(anyOf(isA<FileSystemException>(), isA<StateError>())),
    );
    expect(await outside.list().isEmpty, isTrue);
  });

  test(
    'retains validated copy, public identity and expiry across store instances',
    () async {
      final record = await save(verifiedBootloaderAddress: 'CC:01:02:03:04:05');
      await File('${support.path}/selected.zip').delete();
      final reopened = NrfDfuRecoveryStore(
        directory: () async => support,
        now: () => now,
      );
      final loaded = await reopened.load();
      expect(loaded, isNotNull);
      expect(loaded!.path, record.path);
      expect(loaded.originalAddress, address);
      expect(loaded.publicKey, publicKey);
      expect(loaded.board, 'Heltec T096');
      expect(loaded.verifiedBootloaderAddress, 'CC:01:02:03:04:05');
      expect(loaded.expiresAt, now.add(const Duration(hours: 24)));
      expect(loaded.canRetry, isTrue);
      final data = await metadata();
      expect(data.keys, isNot(contains('path')));
      for (final name in [
        'pin',
        'password',
        'privateKey',
        'cli',
        'sourcePath',
      ]) {
        expect(data.keys, isNot(contains(name)));
      }
    },
  );

  test(
    'pending native state survives restart and does not authorize a retry',
    () async {
      await save();
      await store.markTransferActive();
      final loaded = await store.load();
      expect(loaded!.nativeMayBeActive, isTrue);
      expect(loaded.canRetry, isFalse);
      await store.markTransferSettled();
      expect((await store.load())!.canRetry, isTrue);
    },
  );

  test(
    'expiry or corrupt firmware cannot discard unconfirmed native ownership',
    () async {
      final record = await save();
      await store.markTransferActive();
      now = now.add(const Duration(hours: 25));
      expect((await store.load())!.canRetry, isFalse);
      expect(await store.hasUnconfirmedNativeTransfer(), isTrue);
      await expectLater(save(), throwsStateError);
      await expectLater(store.clear(), throwsStateError);
      await File(record.path).delete();
      expect(await store.load(), isNull);
      expect(await store.hasUnconfirmedNativeTransfer(), isTrue);
      await expectLater(save(), throwsStateError);
      await store.clear(nativeTerminationConfirmed: true);
      expect(await store.hasUnconfirmedNativeTransfer(), isFalse);
    },
  );

  test(
    'torn native metadata is failclosed until independent terminal proof',
    () async {
      await save();
      await File(
        '${support.path}/dfu-recovery/record.json',
      ).writeAsString('{torn');
      expect(await store.load(), isNull);
      expect(await store.hasUnconfirmedNativeTransfer(), isTrue);
      await expectLater(save(), throwsStateError);
      await expectLater(store.clear(), throwsStateError);
      await store.clear(nativeTerminationConfirmed: true);
      expect(await store.hasUnconfirmedNativeTransfer(), isFalse);
    },
  );

  test('expires and rejects altered expiry or future creation', () async {
    await save();
    now = now.add(const Duration(hours: 24));
    expect(await store.load(), isNull);
    now = DateTime.utc(2026, 10, 12);
    await save();
    var data = await metadata();
    data['expiresAt'] = now.add(const Duration(days: 30)).toIso8601String();
    await change(data);
    expect(await store.load(), isNull);
    await save();
    data = await metadata();
    data['createdAt'] = now.add(const Duration(hours: 1)).toIso8601String();
    data['expiresAt'] = now.add(const Duration(hours: 25)).toIso8601String();
    await change(data);
    expect(await store.load(), isNull);
  });

  test(
    'external workflows share durable guard without masquerading as an application ZIP',
    () async {
      await store.markExternalTransferActive(
        address: address,
        board: 'Heltec T096',
        publicKey: publicKey,
      );
      expect(await store.load(), isNull);
      expect(await store.hasUnconfirmedNativeTransfer(), isTrue);
      await expectLater(save(), throwsStateError);
      await expectLater(
        store.confirmNativeStopped(verifyStopped: () async => false),
        completion(isFalse),
      );
      expect(await store.hasUnconfirmedNativeTransfer(), isTrue);
      expect(
        await store.confirmNativeStopped(
          verifyStopped: () async => throw StateError('OS unavailable'),
        ),
        isFalse,
      );
      expect(await store.hasUnconfirmedNativeTransfer(), isTrue);
      expect(
        await store.confirmNativeStopped(verifyStopped: () async => true),
        isTrue,
      );
      expect(await store.hasUnconfirmedNativeTransfer(), isFalse);
    },
  );

  test(
    'positive native verifier clears only active flags, retaining exact ZIP identity',
    () async {
      final record = await save();
      await store.markTransferActive();
      expect(
        await store.confirmNativeStopped(verifyStopped: () async => false),
        isFalse,
      );
      expect((await store.load())!.nativeMayBeActive, isTrue);
      expect(
        await store.confirmNativeStopped(verifyStopped: () async => true),
        isTrue,
      );
      final loaded = await store.load();
      expect(loaded!.nativeMayBeActive, isFalse);
      expect(loaded.path, record.path);
      expect(loaded.publicKey, record.publicKey);
      expect(loaded.expiresAt, record.expiresAt);
      expect(await File(record.path).exists(), isTrue);
    },
  );

  test('modified or missing ZIP cannot become a recovery write', () async {
    final record = await save();
    final file = File(record.path);
    final bytes = await file.readAsBytes();
    bytes[bytes.length ~/ 2] ^= 1;
    await file.writeAsBytes(bytes);
    expect(await store.load(), isNull);
    await file.delete();
    expect(await store.load(), isNull);
    await expectLater(store.markTransferActive(), throwsStateError);
  });

  test(
    'board mismatch, invalid public identity and unknown board fail closed',
    () async {
      await expectLater(save(board: 'Heltec T114'), throwsFormatException);
      await expectLater(save(board: 'Custom nRF52'), throwsFormatException);
      await expectLater(save(applicationOnly: false), throwsFormatException);
      final source = File('${support.path}/source.zip');
      await source.writeAsBytes(testNrfDfuZip());
      await expectLater(
        store.save(
          sourcePath: source.path,
          originalAddress: address,
          board: 'Heltec T096',
          publicKey: 'not-a-key',
          filename: 'app.zip',
          applicationOnly: true,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'trusted unmarked release proof is copied and digest-bound when reopening',
    () async {
      final bytes = testNrfDfuZip(image: testNrfApplication(marked: false));
      final proof = CompanionFirmwareProvenance(
        boardId: 'heltec-t096',
        sha256: sha256.convert(bytes).toString(),
        profile: 'full',
      );
      await save(marked: false, provenance: proof);
      var loaded = await store.load();
      expect(loaded!.provenance!.sha256, proof.sha256);
      final data = await metadata();
      (data['provenance'] as Map)['boardId'] = 'heltec-t114';
      await change(data);
      loaded = await store.load();
      expect(loaded, isNull);
    },
  );

  test(
    'unmarked local firmware is not promoted to trusted provenance',
    () async {
      await expectLater(save(marked: false), throwsFormatException);
    },
  );

  test(
    'serialized outside path is never followed and clear removes only owned files',
    () async {
      await save();
      final outside = File('${support.path}/must-stay.txt');
      await outside.writeAsString('unrelated');
      final data = await metadata();
      data['path'] = outside.path;
      await change(data);
      final loaded = await store.load();
      expect(loaded!.path, '${support.path}/dfu-recovery/recovery.zip');
      await store.clear();
      expect(await store.load(), isNull);
      expect(await outside.readAsString(), 'unrelated');
      expect(await File(loaded.path).exists(), isFalse);
    },
  );

  test('symlinked recovery ZIP is rejected without modifying target', () async {
    final record = await save();
    final outside = File('${support.path}/outside.zip');
    await File(record.path).rename(outside.path);
    await Link(record.path).create(outside.path);
    expect(await store.load(), isNull);
    await expectLater(save(), throwsA(isA<FileSystemException>()));
    await store.clear();
    expect(await outside.exists(), isTrue);
  });
}
