import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'esp32_wifi_ota_service.dart';
import 'local_mota_builder.dart';

/// A board-specific two-stage bundle from MeshCore's partition migration
/// packager. Internal digests detect damaged or mixed files; they do not
/// authenticate where a user-selected ZIP came from.
class Esp32PartitionMigrationPackage {
  Esp32PartitionMigrationPackage._({
    required this.board,
    required this.role,
    required this.target,
    required this.targetId,
    required this.hardwareId,
    required this.version,
    required this.flashBytes,
    required this.expandedSlotBytes,
    required this.bridge,
    required this.application,
    required this.migrationApName,
    required this.migrationApPassword,
  });

  final String board;
  final String role;
  final String target;
  final int targetId;
  final String hardwareId;
  final String version;
  final int flashBytes;
  final int expandedSlotBytes;
  final Uint8List bridge;
  final Uint8List application;
  final String migrationApName;
  final String migrationApPassword;

  static Esp32PartitionMigrationPackage load(Uint8List zipBytes) {
    if (zipBytes.isEmpty || zipBytes.length > 32 * 1024 * 1024) {
      throw const FormatException('Migration ZIP is empty or too large.');
    }
    final archive = ZipDecoder().decodeBytes(zipBytes, verify: true);
    final entries = <String, Uint8List>{};
    var totalBytes = 0;
    for (final entry in archive.files) {
      if (!entry.isFile ||
          entry.name.contains('/') ||
          entry.name.contains('\\') ||
          entries.containsKey(entry.name)) {
        throw const FormatException('Migration ZIP has unsafe file names.');
      }
      totalBytes += entry.size;
      if (entry.size > 16 * 1024 * 1024 ||
          totalBytes > 32 * 1024 * 1024 ||
          archive.files.length > 24) {
        throw const FormatException('Migration ZIP exceeds safe limits.');
      }
      final bytes = entry.readBytes();
      if (bytes == null || bytes.length != entry.size) {
        throw const FormatException('Migration ZIP has an unreadable file.');
      }
      entries[entry.name] = Uint8List.fromList(bytes);
    }
    final manifestBytes = entries['manifest.json'];
    if (manifestBytes == null || manifestBytes.length > 65536) {
      throw const FormatException(
        'Migration manifest is missing or too large.',
      );
    }
    final decoded = jsonDecode(utf8.decode(manifestBytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Migration manifest is invalid.');
    }
    final manifest = decoded;
    final files = manifest['files'];
    final board = manifest['board'];
    final role = manifest['role'];
    final target = manifest['target'];
    final hardware = manifest['hardware_id'];
    final version = manifest['firmware_version'];
    final targetIdText = manifest['target_id'];
    final flashBytes = manifest['flash_bytes'];
    final oldSlot = manifest['legacy_slot_bytes'];
    final newSlot = manifest['expanded_slot_bytes'];
    if (files is! Map<String, dynamic> ||
        board is! String ||
        target is! String ||
        hardware is! String ||
        version is! String ||
        targetIdText is! String ||
        !RegExp(r'^0x[0-9a-fA-F]{8}$').hasMatch(targetIdText) ||
        !<String>{'repeater', 'room-server'}.contains(role) ||
        manifest['atomic_power_loss_recovery'] != false ||
        flashBytes is! int ||
        !<int>{0x400000, 0x800000, 0x1000000}.contains(flashBytes) ||
        oldSlot is! int ||
        oldSlot <= 0 ||
        newSlot is! int ||
        newSlot <= oldSlot ||
        !RegExp(r'^[a-z0-9_-]+$').hasMatch(board) ||
        !RegExp(r'^[A-Za-z0-9_]+$').hasMatch(target) ||
        !RegExp(r'^[A-Za-z0-9_]+$').hasMatch(hardware)) {
      throw const FormatException('Migration manifest has unsupported layout.');
    }
    for (final item in files.entries) {
      final meta = item.value;
      final bytes = entries[item.key];
      if (meta is! Map ||
          meta['bytes'] is! int ||
          meta['sha256'] is! String ||
          bytes == null ||
          bytes.length != meta['bytes'] ||
          sha256.convert(bytes).toString() != meta['sha256']) {
        throw FormatException('Migration ZIP hash failed for ${item.key}.');
      }
    }
    final bridge = entries['wifi-bridge.bin'];
    final application = entries['full-application.bin'];
    final table = entries['target-partitions.bin'];
    final readme = entries['README.md'];
    if (bridge == null ||
        application == null ||
        table?.length != 4096 ||
        !files.containsKey('wifi-bridge.bin') ||
        !files.containsKey('full-application.bin') ||
        !files.containsKey('target-partitions.bin') ||
        readme == null ||
        !files.containsKey('README.md')) {
      throw const FormatException(
        'Migration ZIP lacks a required image or table.',
      );
    }
    final apMatch = RegExp(
      r'Join `([^`]+)` \(password `([^`]+)`\)',
    ).firstMatch(utf8.decode(readme));
    if (apMatch == null ||
        apMatch.group(1) != 'MeshCore-Migrate' ||
        apMatch.group(2)!.length < 8 ||
        apMatch.group(2)!.length > 63) {
      throw const FormatException(
        'Migration ZIP has no valid bridge Wi-Fi instructions.',
      );
    }
    Esp32WifiOtaService.validateImage('wifi-bridge.bin', bridge);
    Esp32WifiOtaService.validateImage('full-application.bin', application);
    if (bridge.length > oldSlot || application.length >= newSlot) {
      throw const FormatException('Migration image does not fit its OTA slot.');
    }
    _validatePartitionTable(table!, flashBytes, newSlot);
    final identity = FirmwareImageIdentity.read(
      application,
      maxSize: 0x1000000,
    );
    final targetId = int.parse(targetIdText.substring(2), radix: 16);
    if (identity.targetId != targetId || identity.hardwareId != hardware) {
      throw const FormatException('Full application has a different target.');
    }
    if (!version.startsWith('v${identity.versionLabel}')) {
      throw const FormatException('Full application version differs from ZIP.');
    }
    return Esp32PartitionMigrationPackage._(
      board: board,
      role: role as String,
      target: target,
      targetId: targetId,
      hardwareId: hardware,
      version: version,
      flashBytes: flashBytes,
      expandedSlotBytes: newSlot,
      bridge: bridge,
      application: application,
      migrationApName: apMatch.group(1)!,
      migrationApPassword: apMatch.group(2)!,
    );
  }

  static void _validatePartitionTable(
    Uint8List table,
    int flashBytes,
    int slotBytes,
  ) {
    final data = ByteData.sublistView(table);
    final parts = <String, (int, int)>{};
    for (var offset = 0; offset + 32 <= table.length; offset += 32) {
      if (table[offset] != 0xAA || table[offset + 1] != 0x50) continue;
      final type = table[offset + 2];
      final subtype = table[offset + 3];
      final name = switch ((type, subtype)) {
        (0, 0x10) => 'app0',
        (0, 0x11) => 'app1',
        (1, 0x02) => 'nvs',
        (1, 0x00) => 'otadata',
        _ => null,
      };
      if (name == null) continue;
      if (parts.containsKey(name)) {
        throw const FormatException('Migration table repeats a partition.');
      }
      parts[name] = (
        data.getUint32(offset + 4, Endian.little),
        data.getUint32(offset + 8, Endian.little),
      );
    }
    if (parts['nvs'] != (0x9000, 0x5000) ||
        parts['otadata'] != (0xE000, 0x2000) ||
        parts['app0'] != (0x10000, slotBytes) ||
        parts['app1'] != (0x10000 + slotBytes, slotBytes) ||
        0x10000 + 2 * slotBytes > flashBytes) {
      throw const FormatException(
        'Migration partition table does not match ZIP.',
      );
    }
  }
}
