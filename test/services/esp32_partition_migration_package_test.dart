import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/esp32_partition_migration_package.dart';

const _targetId = 0x11223344;

void main() {
  test('loads a verified two-stage bundle with a >1 MiB final image', () {
    final package = Esp32PartitionMigrationPackage.load(_bundle());
    expect(package.board, 'test-board');
    expect(package.targetId, _targetId);
    expect(package.bridge.length, 1024);
    expect(package.application.length, greaterThan(0x100000));
    expect(package.migrationApName, 'MeshCore-Migrate');
    expect(package.migrationApPassword, 'test-password');
  });

  test('rejects a modified bridge before it can be sent', () {
    expect(
      () => Esp32PartitionMigrationPackage.load(_bundle(tamperBridge: true)),
      throwsFormatException,
    );
  });

  test('rejects the wrong final application target', () {
    expect(
      () => Esp32PartitionMigrationPackage.load(_bundle(targetId: 2)),
      throwsFormatException,
    );
  });

  final fixture = Platform.environment['MESHCORE_MIGRATION_FIXTURE'];
  test(
    'accepts an actual MeshCore migration release ZIP',
    () async {
      final bytes = await File(fixture!).readAsBytes();
      final package = Esp32PartitionMigrationPackage.load(bytes);
      expect(package.application.length, greaterThan(0x100000));
      expect(package.targetId, isNonZero);
    },
    skip: fixture == null
        ? 'Set MESHCORE_MIGRATION_FIXTURE to a release ZIP'
        : false,
  );
}

Uint8List _bundle({bool tamperBridge = false, int targetId = _targetId}) {
  final bridge = Uint8List(1024)
    ..[0] = 0xE9
    ..[1] = 2;
  final body = Uint8List(0x110000)
    ..[0] = 0xE9
    ..[1] = 2;
  final app = Uint8List(body.length + 56)..setRange(0, body.length, body);
  final trailer = ByteData.sublistView(app, body.length);
  app.setRange(body.length, body.length + 4, 'EndF'.codeUnits);
  trailer.setUint32(4, body.length, Endian.little);
  app.setRange(
    body.length + 8,
    body.length + 16,
    sha256.convert(body).bytes.sublist(0, 8),
  );
  trailer.setUint32(16, 0x01110107, Endian.little);
  trailer.setUint32(20, targetId, Endian.little);
  app.setRange(body.length + 24, body.length + 34, 'TEST_BOARD'.codeUnits);
  final files = <String, Uint8List>{
    'wifi-bridge.bin': bridge,
    'full-application.bin': app,
    'target-partitions.bin': _partitionTable(),
    'README.md': Uint8List.fromList(
      utf8.encode(
        'Join `MeshCore-Migrate` (password `test-password`), then upload.',
      ),
    ),
  };
  final manifest = <String, Object>{
    'board': 'test-board',
    'role': 'repeater',
    'target': 'test_board_repeater',
    'target_id': '0x11223344',
    'hardware_id': 'TEST_BOARD',
    'firmware_version': 'v1.17.1.7-test',
    'flash_bytes': 0x800000,
    'legacy_slot_bytes': 0x140000,
    'expanded_slot_bytes': 0x330000,
    'atomic_power_loss_recovery': false,
    'files': <String, Object>{
      for (final entry in files.entries)
        entry.key: <String, Object>{
          'bytes': entry.value.length,
          'sha256': sha256.convert(entry.value).toString(),
        },
    },
  };
  if (tamperBridge) bridge[10] ^= 1;
  final archive = Archive();
  for (final entry in files.entries) {
    archive.add(ArchiveFile.bytes(entry.key, entry.value));
  }
  archive.add(
    ArchiveFile.bytes('manifest.json', utf8.encode(jsonEncode(manifest))),
  );
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Uint8List _partitionTable() {
  final table = Uint8List(4096);
  final data = ByteData.sublistView(table);
  void part(int index, int type, int subtype, int offset, int size) {
    final start = index * 32;
    table[start] = 0xAA;
    table[start + 1] = 0x50;
    table[start + 2] = type;
    table[start + 3] = subtype;
    data.setUint32(start + 4, offset, Endian.little);
    data.setUint32(start + 8, size, Endian.little);
  }

  part(0, 1, 0x02, 0x9000, 0x5000);
  part(1, 1, 0x00, 0xE000, 0x2000);
  part(2, 0, 0x10, 0x10000, 0x330000);
  part(3, 0, 0x11, 0x340000, 0x330000);
  return table;
}
