import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/models/path_selection.dart';
import 'package:meshcore_open/screens/esp32_wifi_ota_screen.dart';
import 'package:meshcore_open/services/esp32_migration_decision.dart';
import 'package:meshcore_open/services/esp32_partition_catalog.dart';
import 'package:meshcore_open/services/esp32_partition_migration_package.dart';
import 'package:meshcore_open/services/repeater_command_service.dart';
import 'package:provider/provider.dart';

const _targetId = 0x11223344;

void main() {
  test('loads a verified two-stage bundle with a >1 MiB final image', () {
    final package = Esp32PartitionMigrationPackage.load(_bundle());
    expect(package.board, 'test-board');
    expect(package.role, 'repeater');
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

  test('accepts a published room-server migration role', () {
    final package = Esp32PartitionMigrationPackage.load(
      _bundle(role: 'room-server', board: 'test-board-room-server'),
    );
    expect(package.role, 'room-server');
    expect(
      Esp32MigrationDecision.matchesAsset(
        reportedBoard: 'Test Board',
        role: 'room-server',
        assetName: 'test-board-room-server-v1.17.1.7-migration.zip',
      ),
      isTrue,
    );
    expect(
      Esp32MigrationDecision.matchesAsset(
        reportedBoard: 'Test Board',
        role: 'repeater',
        assetName: 'test-board-room-server-v1.17.1.7-migration.zip',
      ),
      isFalse,
    );
  });

  test('uses the bridge only when the full image exceeds the current slot', () {
    final package = Esp32PartitionMigrationPackage.load(_bundle());
    Esp32MigrationRoute route(Esp32PartitionAction action) =>
        Esp32MigrationDecision.choose(
          package: package,
          reportedBoard: 'Test Board',
          role: 'repeater',
          currentLayout: Esp32PartitionAssessment(
            source: Esp32PartitionSource.device,
            action: action,
            flashBytes: 0x800000,
          ),
          targetConfirmed: false,
        );
    expect(route(Esp32PartitionAction.fits), Esp32MigrationRoute.normalUpdate);
    expect(route(Esp32PartitionAction.expand), Esp32MigrationRoute.bridge);
    expect(() => route(Esp32PartitionAction.unknown), throwsStateError);
    expect(() => route(Esp32PartitionAction.cableRequired), throwsStateError);
    expect(
      () => Esp32MigrationDecision.choose(
        package: package,
        reportedBoard: 'Different board',
        role: 'repeater',
        currentLayout: const Esp32PartitionAssessment(
          source: Esp32PartitionSource.device,
          action: Esp32PartitionAction.expand,
          flashBytes: 0x800000,
        ),
        targetConfirmed: false,
      ),
      throwsStateError,
    );
    expect(
      () => Esp32MigrationDecision.choose(
        package: package,
        reportedBoard: 'Test Board',
        role: 'repeater',
        currentLayout: const Esp32PartitionAssessment(
          source: Esp32PartitionSource.device,
          action: Esp32PartitionAction.expand,
          flashBytes: 0x400000,
        ),
        targetConfirmed: false,
      ),
      throwsStateError,
    );
  });

  test('recognizes Heltec display names without crossing R8/TFT models', () {
    expect(
      Esp32MigrationDecision.matchesAsset(
        reportedBoard: 'Heltec V4.3 OLED',
        role: 'repeater',
        assetName: 'heltec-v4-v1.17.1.7-migration.zip',
      ),
      isTrue,
    );
    expect(
      Esp32MigrationDecision.matchesAsset(
        reportedBoard: 'Heltec V4 R8 TFT',
        role: 'repeater',
        assetName: 'heltec-v4-r8-tft-repeater-v1.17.1.7-migration.zip',
      ),
      isTrue,
    );
    expect(
      Esp32MigrationDecision.matchesAsset(
        reportedBoard: 'Heltec V4 OLED',
        role: 'repeater',
        assetName: 'heltec-v4-r8-tft-repeater-v1.17.1.7-migration.zip',
      ),
      isFalse,
    );
  });

  for (final role in ['repeater', 'room-server']) {
    testWidgets('$role uses the normal updater when the full image fits', (
      tester,
    ) async {
      final connector = MeshCoreConnector();
      addTearDown(connector.dispose);
      final commands = _MigrationCommands(connector, slotKib: 1280);
      final target = Contact(
        publicKey: Uint8List(32),
        name: 'Test Board',
        type: role == 'room-server' ? advTypeRoom : advTypeRepeater,
        pathLength: 0,
        path: Uint8List(0),
        lastSeen: DateTime(2026),
      );
      final zip = _bundle(
        role: role,
        board: role == 'room-server' ? 'test-board-room-server' : 'test-board',
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<MeshCoreConnector>.value(
          value: connector,
          child: MaterialApp(
            home: Esp32WifiOtaScreen(
              repeater: target,
              commandService: commands,
              pickMigration: () async => XFile.fromData(
                zip,
                name: 'test-board-migration.zip',
                path: 'test-board-migration.zip',
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Partition upgrade'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Choose migration ZIP'));
      await tester.tap(find.text('Choose migration ZIP'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Check this upgrade'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Check this upgrade'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('No partition bridge is needed'),
        findsOneWidget,
      );
      expect(commands.calls, contains('ota status'));
      expect(commands.calls, isNot(contains('start ota')));
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Start updater on radio'),
            )
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('oversized image offers a bridge only after confirmation', (
    tester,
  ) async {
    final connector = MeshCoreConnector();
    addTearDown(connector.dispose);
    final commands = _MigrationCommands(connector, slotKib: 1024);
    final target = Contact(
      publicKey: Uint8List(32),
      name: 'Test Board',
      type: advTypeRepeater,
      pathLength: 0,
      path: Uint8List(0),
      lastSeen: DateTime(2026),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<MeshCoreConnector>.value(
        value: connector,
        child: MaterialApp(
          home: Esp32WifiOtaScreen(
            repeater: target,
            commandService: commands,
            pickMigration: () async => XFile.fromData(
              _bundle(),
              name: 'test-board-migration.zip',
              path: 'test-board-migration.zip',
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Partition upgrade'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Choose migration ZIP'));
    await tester.tap(find.text('Choose migration ZIP'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Check this upgrade'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check this upgrade'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Step 1: expand partitions?'), findsOneWidget);
    expect(commands.calls, isNot(contains('start ota')));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(commands.calls, isNot(contains('start ota')));
    expect(find.textContaining('No partition bridge is needed'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
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

Uint8List _bundle({
  bool tamperBridge = false,
  int targetId = _targetId,
  String role = 'repeater',
  String board = 'test-board',
}) {
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
    'board': board,
    'role': role,
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

class _MigrationCommands extends RepeaterCommandService {
  _MigrationCommands(super.connector, {required this.slotKib});

  final int slotKib;
  final calls = <String>[];

  @override
  Future<String> sendCommand(
    Contact repeater,
    String command, {
    Function(String)? onResponse,
    Function(int)? onAttempt,
    void Function()? onPacketSent,
    PathSelection? pathSelection,
    int retries = 5,
    int minimumTimeoutMs = 0,
    bool raw = false,
  }) async {
    calls.add(command);
    final app1 = 0x10000 + slotKib * 1024;
    final spiffs = app1 + slotKib * 1024;
    return switch (command) {
      'board' => 'Test Board',
      'ver' => 'v1.17.1.5-test',
      'get storage.layout' =>
        'int:esp32=8192K ext:none; nvs@0x9000+20K,'
            'otadata@0xE000+8K,app0*@0x10000+${slotKib}K,'
            'app1@0x${app1.toRadixString(16)}+${slotKib}K,'
            'spiffs@0x${spiffs.toRadixString(16)}+1024K',
      _ => throw StateError('Unknown command'),
    };
  }
}
