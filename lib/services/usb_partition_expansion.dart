import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'usb_firmware_package.dart';

class UsbFlashPartition {
  const UsbFlashPartition({
    required this.name,
    required this.type,
    required this.subtype,
    required this.offset,
    required this.size,
    this.flags = 0,
  });
  final String name;
  final int type, subtype, offset, size, flags;
}

class UsbMigrationTarget {
  const UsbMigrationTarget(this.board, this.target);
  final String board, target;
  int get targetId => usbUint32(
    Uint8List.fromList(crypto.sha256.convert(ascii.encode(target)).bytes),
    0,
  );
}

class UsbPartitionAnalysis {
  UsbPartitionAnalysis._({
    required this.image,
    required this.sourceTable,
    required this.partitions,
    required this.flashBytes,
    required this.chip,
    required this.needed,
    required this.appOffsets,
    required this.activeOffset,
    this.nvsOffset,
    this.nvsSize,
    this.otaOffset,
    this.otaSize,
    this.migrationTarget,
  });
  final UsbFirmwareImage image;
  final Uint8List sourceTable;
  final List<UsbFlashPartition> partitions;
  final int flashBytes, chip;
  final bool needed;
  final List<int> appOffsets;
  final int activeOffset;
  final int? nvsOffset, nvsSize, otaOffset, otaSize;
  final UsbMigrationTarget? migrationTarget;
  String? get packageUrl {
    final release = image.release;
    final target = migrationTarget;
    if (release == null || target == null) return null;
    final source = release.sourceCommit.substring(0, 8);
    final tag = 'utility-${release.version}-$source';
    final name = '${target.board}-${release.version}-$source-migration.zip';
    return 'https://github.com/mikecarper/MeshCore/releases/download/$tag/$name';
  }
}

class UsbPartitionPlan {
  UsbPartitionPlan._({
    required this.image,
    required this.bridge,
    required this.targetTable,
    required this.bridgeOffsets,
    required this.sourceTableSha256,
    required this.chip,
    required this.flashBytes,
    required this.board,
    required this.target,
    required this.packageSha256,
    required this.firmwareVersion,
    required this.sourceCommit,
    this.usbSetSha256,
  }) : imageSha256 = image.sha256,
       bridgeSha256 = usbSha256(bridge),
       targetTableSha256 = usbSha256(targetTable);
  final UsbFirmwareImage image;
  final Uint8List bridge, targetTable;
  final List<int> bridgeOffsets;
  final String sourceTableSha256, targetTableSha256, imageSha256, bridgeSha256;
  final String board, target, packageSha256, firmwareVersion, sourceCommit;
  final String? usbSetSha256;
  final int chip, flashBytes;
  bool get automaticRomReturn => chip != 0;
  bool get uartCompletionStatus => chip == 0;
  bool get atomicPowerLossRecovery => false;

  /// Recheck immutable public artifacts immediately before each write.
  void verifyArtifacts() {
    if (usbSha256(image.bytes) != imageSha256 ||
        usbSha256(bridge) != bridgeSha256 ||
        usbSha256(targetTable) != targetTableSha256 ||
        !usbBytesEqual(
          targetTable,
          UsbPartitionExpansion.canonicalTable(flashBytes),
        )) {
      usbReject('Partition expansion artifacts changed before flashing.');
    }
    UsbPartitionExpansion.validateUsbImage(bridge, chip, flashBytes);
  }
}

class UsbPartitionRecovery {
  const UsbPartitionRecovery(this.appOffsets, this.activeOffset);
  final List<int> appOffsets;
  final int activeOffset;
  bool get identityRestored => true;
  bool get configurationRestored => true;
}

class UsbMigrationNvsMarkers {
  const UsbMigrationNvsMarkers({
    this.namespaceExists = false,
    this.configurationRestored = false,
    this.configurationPending = false,
    this.identityPending = false,
  });
  final bool namespaceExists,
      configurationRestored,
      configurationPending,
      identityPending;
  bool get unfinished =>
      configurationPending ||
      identityPending ||
      (namespaceExists && !configurationRestored);
}

/// Pure port of meshfirmware's reviewed partition policy. No USB, downloads,
/// cache writes or device secrets leave this service. The caller owns a
/// durable per-ROM-MAC pending journal, explicit consent and stable power.
class UsbPartitionExpansion {
  static const pinnedUsbSetUrl =
      'https://github.com/mikecarper/MeshCore/releases/download/utility-usb-partition-v1-3d3d5827/meshcore-usb-partition-bridges.zip';
  static const pinnedUsbSetSha256 =
      '187cac4f3f716d5df50e123a03ba51da637356874a434a72a60d9eb99d988ed8';
  static const tableOffset = 0x8000, tableSize = 0x1000;
  static const nvsOffset = 0x9000, nvsSize = 0x5000;
  static const otaOffset = 0xe000, otaSize = 0x2000;
  static const usbBridgeMarker = 'MeshCore USB partition migration bridge v1';
  static const usbNvsGuardMarker = 'MeshCore USB NVS no-autoerase guard v1';
  static const _layouts = <int, List<int>>{
    4 << 20: [0x1f0000, 0x200000, 0x3f0000, 0x10000],
    8 << 20: [0x330000, 0x340000, 0x670000, 0x180000],
    16 << 20: [0x640000, 0x650000, 0xc90000, 0x360000],
  };
  static const _usbProfiles = {
    (0, 4 << 20),
    (0, 8 << 20),
    (5, 4 << 20),
    (9, 4 << 20),
    (9, 8 << 20),
    (9, 16 << 20),
  };

  static UsbPartitionAnalysis analyze({
    required UsbFirmwareImage image,
    required Uint8List table,
    required int flashBytes,
    required int chip,
    Uint8List? otadata,
    Uint8List? nvs,
  }) {
    if (flashBytes <= 0 ||
        image.chip != chip ||
        image.declaredFlashBytes > flashBytes) {
      usbReject(
        'Selected application does not match the physical ESP32 chip/flash.',
      );
    }
    final parts = parseTable(table, flashBytes);
    final (offsets, active, ota) = _appWriteOrder(parts, otadata);
    final nvss = parts.where((p) => p.type == 1 && p.subtype == 2).toList();
    if (nvss.length > 1) usbReject('NVS partitions are ambiguous.');
    var markers = const UsbMigrationNvsMarkers();
    if (nvss.isNotEmpty) {
      if (nvs == null || nvs.length != nvss.single.size) {
        usbReject('A live NVS snapshot matching actual geometry is required.');
      }
      markers = parseNvsMarkers(nvs, allowMissing: true, exactSize: false);
    }
    final fits = parts
        .where((p) => p.type == 0)
        .every((p) => image.bytes.length <= p.size);
    UsbMigrationTarget? target;
    if (fits) {
      if (markers.unfinished) {
        usbReject(
          'Live NVS reports unfinished partition migration; final flashing is refused.',
        );
      }
    } else {
      if (!_layouts.containsKey(flashBytes) || !{0, 5, 9}.contains(chip)) {
        usbReject(
          'No reviewed USB partition expansion exists for this chip/flash.',
        );
      }
      final endf = image.endf;
      if (endf == null) {
        usbReject('Expansion requires verified MeshCore EndF identity.');
      }
      target = catalog[endf.targetId];
      if (target == null) {
        usbReject(
          'No reviewed preservation bridge exists for this exact hardware/role.',
        );
      }
      // Required stable source geometry can be checked before downloading.
      _validateSource(parts, 0);
    }
    return UsbPartitionAnalysis._(
      image: image,
      sourceTable: Uint8List.fromList(table).asUnmodifiableView(),
      partitions: List.unmodifiable(parts),
      flashBytes: flashBytes,
      chip: chip,
      needed: !fits,
      appOffsets: List.unmodifiable(offsets),
      activeOffset: active,
      nvsOffset: nvss.isEmpty ? null : nvss.single.offset,
      nvsSize: nvss.isEmpty ? null : nvss.single.size,
      otaOffset: ota?.offset,
      otaSize: ota == null ? null : UsbPartitionExpansion.otaSize,
      migrationTarget: target,
    );
  }

  static UsbPartitionPlan createPlan({
    required UsbPartitionAnalysis analysis,
    required Uint8List packageZip,
    Uint8List? usbSetZip,
    bool requirePinnedUsbSet = true,
  }) {
    if (!analysis.needed ||
        analysis.migrationTarget == null ||
        analysis.image.endf == null) {
      usbReject('A validated expansion-needed analysis is required.');
    }
    final image = analysis.image;
    final endf = image.endf!;
    final reviewed = analysis.migrationTarget!;
    final package = UsbVerifiedPackage.fromZip(packageZip);
    final manifest = package.manifest;
    final files = package.files;
    final release = image.release;
    final version = manifest['firmware_version'];
    final source = manifest['source_commit'];
    if (version is! String ||
        source is! String ||
        !RegExp(r'^[0-9a-f]{8,40}$').hasMatch(source) ||
        UsbFirmwareRelease.numericVersion(version) != endf.version ||
        (release != null &&
            (version != release.version ||
                source.substring(0, 8) !=
                    release.sourceCommit.substring(0, 8))) ||
        manifest['board'] != reviewed.board ||
        manifest['target'] != reviewed.target ||
        manifest['hardware_id'] != endf.hardwareId ||
        manifest['target_id'] !=
            '0x${endf.targetId.toRadixString(16).padLeft(8, '0')}' ||
        !{'repeater', 'room-server', 'sensor'}.contains(manifest['role']) ||
        manifest['flash_bytes'] is! int ||
        manifest['flash_bytes'] != analysis.flashBytes ||
        manifest['atomic_power_loss_recovery'] != false ||
        manifest['legacy_slot_bytes'] is! int ||
        manifest['legacy_slot_bytes'] != 0x140000 ||
        !usbBytesEqual(files['full-application.bin']!, image.bytes)) {
      usbReject(
        'Migration package does not match the exact firmware, target or release.',
      );
    }
    final targetTable = canonicalTable(analysis.flashBytes);
    if (!usbBytesEqual(files['target-partitions.bin']!, targetTable)) {
      usbReject(
        'Target partition table is not the reviewed canonical expansion.',
      );
    }
    final targetApps = parseTable(
      targetTable,
      analysis.flashBytes,
    ).where((p) => p.type == 0).toList();
    if (manifest['expanded_slot_bytes'] is! int ||
        manifest['expanded_slot_bytes'] != targetApps.first.size ||
        targetApps.any((p) => image.bytes.length > p.size)) {
      usbReject('Selected firmware does not fit reviewed expanded OTA slots.');
    }
    final caps = usbStrictJson(files['capabilities.json']!);
    if (caps is! Map ||
        caps['target'] != reviewed.target ||
        caps['build_profile'] != 'full' ||
        caps['platform'] != 'ESP32_PLATFORM' ||
        caps['ota_update_verified'] != true) {
      usbReject('Full application qualification does not match this target.');
    }
    Uint8List bridge;
    String? usbSetHash;
    if (usbSetZip != null) {
      if (requirePinnedUsbSet && usbSha256(usbSetZip) != pinnedUsbSetSha256) {
        usbReject('Pinned USB migration set SHA-256 verification failed.');
      }
      bridge = bridgeFromUsbSet(usbSetZip, analysis.chip, analysis.flashBytes);
      usbSetHash = usbSha256(usbSetZip);
    } else {
      final usb = manifest['usb_migration'];
      if (!manifest.containsKey('usb_migration') &&
          !files.containsKey('usb-bridge.bin')) {
        // Only a fully qualified exact Full package reaches this fallback.
        // Partial/malformed embedded USB metadata is not a missing utility.
        usbReject(
          'This package has no USB-safe bridge. Download the pinned USB set; a Wi-Fi bridge will not be substituted.',
          code: 'usb_bridge_missing',
        );
      }
      if (usb is! Map ||
          !_validUsbMetadata(usb, analysis.chip) ||
          usb['format'] != 'meshcore-usb-partition-migration-v1' ||
          usb['bridge'] != 'usb-bridge.bin' ||
          !files.containsKey('usb-bridge.bin')) {
        usbReject(
          'This package has no USB-safe bridge. Download the pinned USB set; a Wi-Fi bridge will not be substituted.',
        );
      }
      bridge = files['usb-bridge.bin']!;
      validateUsbImage(bridge, analysis.chip, analysis.flashBytes);
    }
    _validateSource(analysis.partitions, bridge.length);
    if (usbBytesEqual(analysis.sourceTable, targetTable)) {
      usbReject('Already-expanded layout cannot be expanded further.');
    }
    return UsbPartitionPlan._(
      image: image,
      bridge: Uint8List.fromList(bridge).asUnmodifiableView(),
      targetTable: targetTable.asUnmodifiableView(),
      bridgeOffsets: List.unmodifiable(analysis.appOffsets),
      sourceTableSha256: usbSha256(analysis.sourceTable),
      chip: analysis.chip,
      flashBytes: analysis.flashBytes,
      board: reviewed.board,
      target: reviewed.target,
      packageSha256: package.sha256,
      firmwareVersion: version,
      sourceCommit: source,
      usbSetSha256: usbSetHash,
    );
  }

  static UsbPartitionRecovery verifyRecovery({
    required UsbPartitionPlan plan,
    required Uint8List table,
    required Uint8List nvs,
    required Uint8List otadata,
  }) {
    plan.verifyArtifacts();
    if (!usbBytesEqual(table, plan.targetTable) ||
        usbSha256(table) != plan.targetTableSha256) {
      usbReject(
        'Expanded partition table does not match the exact bridge plan.',
      );
    }
    final parts = parseTable(table, plan.flashBytes);
    final markers = parseNvsMarkers(nvs);
    if (!markers.configurationRestored ||
        markers.configurationPending ||
        markers.identityPending) {
      usbReject(
        'Bridge has not verified identity/configuration restoration; final flashing is refused.',
      );
    }
    final active = activeOtaOffset(parts, otadata);
    final apps = parts.where((p) => p.type == 0).toList()
      ..sort((a, b) => a.subtype.compareTo(b.subtype));
    if (apps.any((p) => plan.image.bytes.length > p.size)) {
      usbReject('Firmware does not fit the verified expanded layout.');
    }
    return UsbPartitionRecovery(
      List.unmodifiable([
        ...apps.where((p) => p.offset != active).map((p) => p.offset),
        active,
      ]),
      active,
    );
  }

  static Uint8List bridgeFromUsbSet(Uint8List zip, int chip, int flashBytes) {
    final package = UsbVerifiedPackage.fromZip(zip, usbOnly: true);
    final manifest = package.manifest;
    if (manifest['format'] != 'meshcore-usb-partition-bridges-v1' ||
        manifest['source_commit'] is! String ||
        !RegExp(
          r'^[0-9a-f]{8,40}$',
        ).hasMatch(manifest['source_commit'] as String) ||
        manifest['working_tree_dirty'] is! bool ||
        manifest['source_tree_sha256'] is! String ||
        !RegExp(
          r'^[0-9a-f]{64}$',
        ).hasMatch(manifest['source_tree_sha256'] as String) ||
        manifest['bridges'] is! List) {
      usbReject('USB migration set source/format metadata is invalid.');
    }
    final profiles = <(int, int)>{};
    final names = <String>{};
    Uint8List? selected;
    for (final record in manifest['bridges'] as List) {
      if (record is! Map ||
          record['chip'] is! int ||
          record['flash_bytes'] is! int ||
          record['file'] is! String) {
        usbReject('USB migration profile metadata is invalid.');
      }
      final profile = (record['chip'] as int, record['flash_bytes'] as int);
      final name = record['file'] as String;
      final bytes = package.files[name];
      if (!_usbProfiles.contains(profile) ||
          !profiles.add(profile) ||
          !names.add(name) ||
          bytes == null ||
          !_validUsbMetadata(record, profile.$1)) {
        usbReject(
          'USB set contains missing, duplicate or incompatible profiles.',
        );
      }
      validateUsbImage(bytes, profile.$1, profile.$2);
      if (profile == (chip, flashBytes)) selected = bytes;
    }
    final expectedNames = {
      ...names,
      'manifest.json',
      'SHA256SUMS.txt',
      'README.md',
    };
    if (profiles.length != _usbProfiles.length ||
        !profiles.containsAll(_usbProfiles) ||
        expectedNames.length != package.files.length ||
        !expectedNames.containsAll(package.files.keys) ||
        selected == null) {
      usbReject(
        'USB migration set must contain exactly six reviewed chip/flash profiles.',
      );
    }
    return selected;
  }

  static bool _validUsbMetadata(Map metadata, int chip) =>
      metadata['automatic_rom_return'] == (chip != 0) &&
      metadata['uart_completion_status'] == (chip == 0) &&
      metadata['host_software_bootloader_entry'] == true &&
      metadata['application_usb_cdc'] == false;

  static void validateUsbImage(Uint8List bridge, int chip, int flashBytes) {
    final header = UsbEspImageHeader.parse(bridge);
    if (header.chip != chip ||
        header.flashBytes != flashBytes ||
        bridge.length > 0x140000 ||
        !_containsBytes(bridge, ascii.encode(usbBridgeMarker)) ||
        !_containsBytes(bridge, ascii.encode(usbNvsGuardMarker))) {
      usbReject(
        'USB bridge chip/flash/size or automatic-ROM/NVS guard markers are incompatible.',
      );
    }
  }

  static List<UsbFlashPartition> parseTable(Uint8List data, int flashBytes) {
    if (data.length != tableSize) {
      usbReject('Partition table must be exactly 4096 bytes.');
    }
    final parts = <UsbFlashPartition>[];
    final names = <String>{};
    for (var offset = 0; offset < tableSize; offset += 32) {
      if (data[offset] == 0xff && data[offset + 1] == 0xff) {
        if (!_allErased(data, offset)) {
          usbReject('Partition table trailing data is malformed.');
        }
        break;
      }
      if (data[offset] == 0xeb && data[offset + 1] == 0xeb) {
        if (!data.sublist(offset + 2, offset + 16).every((b) => b == 0xff) ||
            !usbBytesEqual(
              data.sublist(offset + 16, offset + 32),
              crypto.md5.convert(data.sublist(0, offset)).bytes,
            ) ||
            !_allErased(data, offset + 32)) {
          usbReject('Partition table MD5 verification failed.');
        }
        break;
      }
      if (data[offset] != 0xaa || data[offset + 1] != 0x50) {
        usbReject('Partition table has an invalid entry.');
      }
      final rawName = data.sublist(offset + 12, offset + 28);
      final zero = rawName.indexOf(0);
      final name = _asciiLabel(rawName.sublist(0, zero < 0 ? 16 : zero));
      final p = UsbFlashPartition(
        name: name,
        type: data[offset + 2],
        subtype: data[offset + 3],
        offset: usbUint32(data, offset + 4),
        size: usbUint32(data, offset + 8),
        flags: usbUint32(data, offset + 28),
      );
      if (name.isEmpty ||
          !names.add(name) ||
          p.size == 0 ||
          p.offset < 0x9000 ||
          p.offset % 0x1000 != 0 ||
          p.size % 0x1000 != 0 ||
          p.offset + p.size > flashBytes ||
          p.flags & ~3 != 0 ||
          (p.type == 0 && p.offset % 0x10000 != 0)) {
        usbReject(
          'Partition table has duplicate or invalid/out-of-flash geometry.',
        );
      }
      parts.add(p);
    }
    if (parts.isEmpty) usbReject('Partition table is empty.');
    final sorted = [...parts]..sort((a, b) => a.offset.compareTo(b.offset));
    for (var i = 1; i < sorted.length; i++) {
      if (sorted[i - 1].offset + sorted[i - 1].size > sorted[i].offset) {
        usbReject('Partition table contains overlapping partitions.');
      }
    }
    return parts;
  }

  static Uint8List canonicalTable(int flashBytes) {
    final layout = _layouts[flashBytes];
    if (layout == null) {
      usbReject('Only reviewed 4/8/16 MiB expansion layouts are supported.');
    }
    final (slot, app1, fs, fsSize) = (
      layout[0],
      layout[1],
      layout[2],
      layout[3],
    );
    final entries = <UsbFlashPartition>[
      const UsbFlashPartition(
        name: 'nvs',
        type: 1,
        subtype: 2,
        offset: nvsOffset,
        size: nvsSize,
      ),
      const UsbFlashPartition(
        name: 'otadata',
        type: 1,
        subtype: 0,
        offset: otaOffset,
        size: otaSize,
      ),
      UsbFlashPartition(
        name: 'app0',
        type: 0,
        subtype: 0x10,
        offset: 0x10000,
        size: slot,
      ),
      UsbFlashPartition(
        name: 'app1',
        type: 0,
        subtype: 0x11,
        offset: app1,
        size: slot,
      ),
      UsbFlashPartition(
        name: 'spiffs',
        type: 1,
        subtype: 0x82,
        offset: fs,
        size: fsSize,
      ),
      if (flashBytes > 4 << 20)
        UsbFlashPartition(
          name: 'coredump',
          type: 1,
          subtype: 3,
          offset: flashBytes - 0x10000,
          size: 0x10000,
        ),
    ];
    final output = Uint8List(tableSize)..fillRange(0, tableSize, 0xff);
    final view = ByteData.sublistView(output);
    var cursor = 0;
    for (final p in entries) {
      output.fillRange(cursor, cursor + 32, 0);
      output[cursor] = 0xaa;
      output[cursor + 1] = 0x50;
      output[cursor + 2] = p.type;
      output[cursor + 3] = p.subtype;
      view.setUint32(cursor + 4, p.offset, Endian.little);
      view.setUint32(cursor + 8, p.size, Endian.little);
      output.setRange(
        cursor + 12,
        cursor + 12 + p.name.length,
        ascii.encode(p.name),
      );
      cursor += 32;
    }
    output[cursor] = output[cursor + 1] = 0xeb;
    output.setRange(
      cursor + 16,
      cursor + 32,
      crypto.md5.convert(output.sublist(0, cursor)).bytes,
    );
    return output;
  }

  static (List<int>, int, UsbFlashPartition?) _appWriteOrder(
    List<UsbFlashPartition> parts,
    Uint8List? otadata,
  ) {
    final apps = parts.where((p) => p.type == 0).toList();
    final factories = apps.where((p) => p.subtype == 0).toList();
    final otaApps = apps
        .where((p) => p.subtype >= 0x10 && p.subtype <= 0x1f)
        .toList();
    if (apps.isEmpty ||
        factories.length > 1 ||
        apps.map((p) => p.subtype).toSet().length != apps.length ||
        apps.length != factories.length + otaApps.length) {
      usbReject('ESP32 app layout is missing, duplicate or unsupported.');
    }
    UsbFlashPartition? ota;
    int active;
    if (otaApps.isNotEmpty) {
      final otas = parts.where((p) => p.type == 1 && p.subtype == 0).toList();
      if (otas.length != 1 || otas.single.size < otaSize || otadata == null) {
        usbReject(
          'A live OTA snapshot is required to safely order app writes.',
        );
      }
      active = activeOtaOffset(parts, otadata);
      ota = otas.single;
    } else if (factories.length == 1) {
      active = factories.single.offset;
    } else {
      usbReject('ESP32 layout has no supported bootable app slot.');
    }
    apps.sort((a, b) => a.subtype.compareTo(b.subtype));
    return (
      [...apps.where((p) => p.offset != active).map((p) => p.offset), active],
      active,
      ota,
    );
  }

  static int activeOtaOffset(List<UsbFlashPartition> parts, Uint8List data) {
    if (data.length != otaSize) {
      usbReject('OTA metadata must contain exactly 8192 bytes.');
    }
    final apps =
        parts
            .where((p) => p.type == 0 && p.subtype >= 0x10 && p.subtype <= 0x1f)
            .toList()
          ..sort((a, b) => a.subtype.compareTo(b.subtype));
    if (apps.isEmpty ||
        List.generate(
          apps.length,
          (i) => apps[i].subtype != 0x10 + i,
        ).any((bad) => bad)) {
      usbReject('OTA slot identities are not unique and contiguous.');
    }
    final sequences = <int>[];
    for (final offset in [0, 0x1000]) {
      final sequence = usbUint32(data, offset);
      final state = usbUint32(data, offset + 24);
      final crc = usbUint32(data, offset + 28);
      if (sequence != 0 &&
          sequence != 0xffffffff &&
          crc == usbCrc32(data.sublist(offset, offset + 4), 0xffffffff) &&
          state != 3 &&
          state != 4) {
        sequences.add(sequence);
      }
    }
    if (sequences.isEmpty) {
      if (!data.sublist(0, 32).every((b) => b == 0xff) ||
          !data.sublist(4096, 4128).every((b) => b == 0xff)) {
        usbReject(
          'OTA metadata has no valid active sequence and is not erased initial data.',
        );
      }
      final factory = parts.where((p) => p.type == 0 && p.subtype == 0);
      return factory.isEmpty ? apps.first.offset : factory.first.offset;
    }
    var newest = sequences.first;
    for (final sequence in sequences.skip(1)) {
      final delta = (sequence - newest) & 0xffffffff;
      if (delta == 0x80000000) {
        usbReject('OTA active sequence ordering is ambiguous.');
      }
      if (delta > 0 && delta < 0x80000000) newest = sequence;
    }
    return apps[(newest - 1) % apps.length].offset;
  }

  static void _validateSource(List<UsbFlashPartition> parts, int bridgeBytes) {
    UsbFlashPartition one(int type, int subtype) {
      final matching = parts
          .where((p) => p.type == type && p.subtype == subtype)
          .toList();
      if (matching.length != 1) {
        usbReject('Source layout lacks unique required migration partitions.');
      }
      return matching.single;
    }

    final nvs = one(1, 2), ota = one(1, 0);
    one(1, 0x82);
    final apps = parts.where((p) => p.type == 0).toList()
      ..sort((a, b) => a.subtype.compareTo(b.subtype));
    if (nvs.offset != nvsOffset ||
        nvs.size != nvsSize ||
        ota.offset != otaOffset ||
        ota.size != otaSize ||
        apps.length != 2 ||
        apps[0].subtype != 0x10 ||
        apps[1].subtype != 0x11 ||
        apps[0].offset != 0x10000 ||
        parts.any((p) => p.flags != 0) ||
        apps.any((p) => bridgeBytes > p.size)) {
      usbReject(
        'Source layout cannot safely run the reviewed partition bridge.',
      );
    }
  }

  static UsbMigrationNvsMarkers parseNvsMarkers(
    Uint8List data, {
    bool allowMissing = false,
    bool exactSize = true,
  }) {
    if ((exactSize && data.length != nvsSize) ||
        data.isEmpty ||
        data.length % 4096 != 0) {
      usbReject(
        'NVS snapshot must contain complete sectors and reviewed geometry.',
      );
    }
    final pages = <(int, Uint8List)>[];
    for (var offset = 0; offset < data.length; offset += 4096) {
      final page = Uint8List.sublistView(data, offset, offset + 4096);
      if (_allErased(page, 0)) continue;
      final state = usbUint32(page, 0), sequence = usbUint32(page, 4);
      if (!{0xfffffffe, 0xfffffffc}.contains(state) ||
          !{0xff, 0xfe}.contains(page[8]) ||
          !page.sublist(9, 28).every((b) => b == 0xff) ||
          usbUint32(page, 28) != usbCrc32(page.sublist(4, 28), 0xffffffff)) {
        usbReject('NVS page CRC verification failed or requires recovery.');
      }
      pages.add((sequence, page));
    }
    if (pages.isEmpty && allowMissing) return const UsbMigrationNvsMarkers();
    if (pages.isEmpty ||
        pages.map((p) => p.$1).toSet().length != pages.length ||
        pages.where((p) => usbUint32(p.$2, 0) == 0xfffffffe).length > 1) {
      usbReject('NVS page ordering is missing or ambiguous.');
    }
    int? oldest;
    for (final p in pages) {
      if (pages.every(
        (other) => ((other.$1 - p.$1) & 0xffffffff) < 0x80000000,
      )) {
        oldest = p.$1;
        break;
      }
    }
    if (oldest == null) usbReject('NVS sequence ordering is ambiguous.');
    final base = oldest;
    pages.sort(
      (a, b) =>
          ((a.$1 - base) & 0xffffffff).compareTo((b.$1 - base) & 0xffffffff),
    );
    final records = <(int, String), (int, Uint8List)>{};
    const primitives = {1, 2, 4, 8, 0x11, 0x12, 0x14, 0x18};
    for (final (_, page) in pages) {
      int entryState(int index) {
        final bit = index * 2;
        return (page[32 + bit ~/ 8] >> (bit % 8)) & 3;
      }

      var index = 0;
      while (index < 126) {
        final state = entryState(index);
        if (state == 0 || state == 3) {
          index++;
          continue;
        }
        if (state != 2) usbReject('NVS entry state is invalid.');
        final entry = Uint8List.sublistView(
          page,
          64 + 32 * index,
          96 + 32 * index,
        );
        final namespace = entry[0],
            kind = entry[1],
            span = entry[2],
            chunk = entry[3];
        if (usbUint32(entry, 4) !=
            usbCrc32([
              ...entry.sublist(0, 4),
              ...entry.sublist(8),
            ], 0xffffffff)) {
          usbReject('NVS entry CRC verification failed.');
        }
        final keyRaw = entry.sublist(8, 24);
        final zero = keyRaw.indexOf(0);
        if (zero < 1 ||
            span < 1 ||
            span > 126 - index ||
            !{...primitives, 0x21, 0x41, 0x42, 0x48}.contains(kind)) {
          usbReject('NVS entry format is invalid or unsupported.');
        }
        final key = _asciiLabel(keyRaw.sublist(0, zero));
        if (primitives.contains(kind) || kind == 0x48) {
          if (span != 1 || chunk != 0xff) {
            usbReject('NVS primitive geometry is invalid.');
          }
        } else {
          final size = usbUint16(entry, 24);
          if (span < 2 ||
              size > (span - 1) * 32 ||
              List.generate(
                span - 1,
                (i) => entryState(index + i + 1) != 2,
              ).any((b) => b)) {
            usbReject('NVS variable-length entry is incomplete.');
          }
          final body = page.sublist(
            64 + 32 * (index + 1),
            64 + 32 * (index + 1) + size,
          );
          if (usbUint32(entry, 28) != usbCrc32(body, 0xffffffff)) {
            usbReject('NVS variable-length data CRC verification failed.');
          }
        }
        // A new non-bool key supersedes an old bool too; never trust stale true.
        records[(namespace, key)] = (
          kind,
          Uint8List.fromList(entry.sublist(24, 32)),
        );
        index += span;
      }
    }
    final namespaceRecord = records[(0, 'mesh-pt-migrate')];
    if (namespaceRecord == null && allowMissing) {
      return const UsbMigrationNvsMarkers();
    }
    if (namespaceRecord == null ||
        namespaceRecord.$1 != 1 ||
        namespaceRecord.$2[0] < 1 ||
        namespaceRecord.$2[0] > 254) {
      usbReject('No verified partition migration NVS namespace exists.');
    }
    final namespace = namespaceRecord.$2[0];
    if (records.entries.any(
      (entry) =>
          entry.key.$1 == 0 &&
          entry.key.$2 != 'mesh-pt-migrate' &&
          entry.value.$1 == 1 &&
          entry.value.$2[0] == namespace,
    )) {
      usbReject('Partition migration NVS namespace identity is ambiguous.');
    }
    bool flag(String key) {
      final item = records[(namespace, key)];
      if (item != null && (item.$1 != 1 || !{0, 1}.contains(item.$2[0]))) {
        usbReject('NVS migration completion flag has an invalid type/value.');
      }
      return item != null && item.$2[0] == 1;
    }

    return UsbMigrationNvsMarkers(
      namespaceExists: true,
      configurationRestored: flag('cfg-restored'),
      configurationPending: flag('cfg-pending'),
      identityPending: flag('id-pending'),
    );
  }

  static final Map<int, UsbMigrationTarget> catalog = _buildCatalog();
}

bool _allErased(Uint8List data, int offset) =>
    data.skip(offset).every((byte) => byte == 0xff);
String _asciiLabel(List<int> bytes) {
  if (bytes.any((b) => b > 127)) {
    usbReject('Partition/NVS label contains invalid ASCII.');
  }
  return String.fromCharCodes(bytes);
}

bool _containsBytes(Uint8List haystack, List<int> needle) {
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    if (haystack[i] != needle[0]) continue;
    var match = true;
    for (var j = 1; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}

Map<int, UsbMigrationTarget> _buildCatalog() {
  final result = <int, UsbMigrationTarget>{};
  void add(String board, String target) {
    final record = UsbMigrationTarget(board, target);
    if (result.containsKey(record.targetId)) {
      throw StateError('Duplicate migration target.');
    }
    result[record.targetId] = record;
  }

  const exact = <(String, String)>[
    ('heltec-v4', 'heltec_v4_repeater'),
    ('xiao-s3-wio', 'Xiao_S3_WIO_repeater'),
    ('station-g2-repeater', 'Station_G2_repeater'),
    ('station-g2-room-server', 'Station_G2_room_server'),
    ('t3s3-sx1262-repeater', 'LilyGo_T3S3_sx1262_repeater'),
    ('t3s3-sx1262-room-server', 'LilyGo_T3S3_sx1262_room_server'),
    ('t3s3-sx1276-repeater', 'LilyGo_T3S3_sx1276_repeater'),
    ('t3s3-sx1276-room-server', 'LilyGo_T3S3_sx1276_room_server'),
    ('thinknode-m2-repeater', 'ThinkNode_M2_Repeater'),
    ('thinknode-m2-room-server', 'ThinkNode_M2_room_server'),
    ('heltec-v4-expansionkit-repeater', 'heltec_v4_expansionkit_repeater'),
    ('heltec-v4-room-server', 'heltec_v4_room_server'),
    ('heltec-v4-sensor', 'heltec_v4_sensor'),
    ('xiao-s3-wio-room-server', 'Xiao_S3_WIO_room_server'),
    ('xiao-s3-wio-sensor', 'Xiao_S3_WIO_sensor'),
    ('nibble-zero-repeater', 'nibble_zero_connect_repeater_'),
    ('nibble-zero-room-server', 'nibble_zero_connect_room_server_'),
    ('nibble-screen-repeater', 'nibble_screen_connect_repeater_'),
    ('nibble-screen-room-server', 'nibble_screen_connect_room_server_'),
    ('ebyte-eora-s3-repeater', 'Ebyte_EoRa-S3_Repeater'),
    ('ebyte-eora-s3-room-server', 'Ebyte_EoRa-S3_room_server'),
    ('thinknode-m5-repeater', 'ThinkNode_M5_Repeater'),
    ('thinknode-m5-room-server', 'ThinkNode_M5_room_server'),
    ('thinknode-m7-repeater', 'ThinkNode_M7_repeater'),
    ('thinknode-m7-room-server', 'ThinkNode_M7_room_server'),
    ('thinknode-m9-repeater', 'ThinkNode_M9_repeater_'),
    ('thinknode-m9-room-server', 'ThinkNode_M9_room_server_'),
    ('heltec-t190-repeater', 'Heltec_T190_repeater_'),
    ('heltec-t190-room-server', 'Heltec_T190_room_server_'),
    ('heltec-rc32-no-display-repeater', 'heltec_rc32_without_display_repeater'),
    (
      'heltec-rc32-no-display-room-server',
      'heltec_rc32_without_display_room_server',
    ),
    ('heltec-rc32-no-display-sensor', 'heltec_rc32_without_display_sensor'),
    ('lilygo-tdeck-repeater', 'LilyGo_TDeck_repeater'),
    ('lilygo-teth-elite-sx1262-repeater', 'LilyGo_TETH_Elite_sx1262_repeater'),
    (
      'lilygo-teth-elite-sx1262-room-server',
      'LilyGo_TETH_Elite_sx1262_room_server',
    ),
    ('t-beam-s3-supreme-sx1262-repeater', 'T_Beam_S3_Supreme_SX1262_repeater'),
    (
      't-beam-s3-supreme-sx1262-room-server',
      'T_Beam_S3_Supreme_SX1262_room_server',
    ),
    ('station-g3-esp32-repeater', 'Station_G3_ESP32_repeater'),
    ('station-g3-esp32-room-server', 'Station_G3_ESP32_room_server'),
    ('station-g3-esp32-logging-repeater', 'Station_G3_ESP32_logging_repeater'),
    ('station-g2-logging-repeater', 'Station_G2_logging_repeater'),
    ('heltec-ct62-repeater', 'Heltec_ct62_repeater'),
    ('heltec-ct62-sensor', 'Heltec_ct62_sensor'),
    ('tenstar-c3-sx1262-repeater', 'Tenstar_C3_sx1262_repeater'),
    ('tenstar-c3-sx1268-repeater', 'Tenstar_C3_sx1268_repeater'),
    ('generic-e22-sx1262-repeater', 'Generic_E22_sx1262_repeater'),
    ('generic-e22-sx1268-repeater', 'Generic_E22_sx1268_repeater'),
  ];
  for (final (board, target) in exact) {
    add(board, target);
  }
  const families = <(String, String, List<String>)>[
    (
      'heltec-wireless-tracker',
      'Heltec_Wireless_Tracker',
      ['repeater', 'room_server'],
    ),
    (
      'heltec-wireless-paper',
      'Heltec_Wireless_Paper',
      ['repeater', 'room_server'],
    ),
    (
      'heltec-tracker-v2',
      'heltec_tracker_v2',
      ['repeater', 'room_server', 'sensor'],
    ),
    ('heltec-v2', 'Heltec_v2', ['repeater', 'room_server']),
    ('heltec-v3', 'Heltec_v3', ['repeater', 'room_server', 'sensor']),
    ('heltec-wsl3', 'Heltec_WSL3', ['repeater', 'room_server', 'sensor']),
    ('xiao-s3', 'Xiao_S3', ['repeater', 'room_server', 'sensor']),
    ('xiao-c3', 'Xiao_C3', ['repeater', 'room_server']),
    ('mke-s3', 'MKE_s3', ['repeater', 'room_server', 'sensor']),
    ('rak-3112', 'RAK_3112', ['repeater', 'room_server', 'sensor']),
    ('heltec-e213', 'Heltec_E213', ['repeater', 'room_server']),
    ('heltec-e290', 'Heltec_E290', ['repeater', 'room_server']),
    ('heltec-rc32', 'heltec_rc32', ['repeater', 'room_server', 'sensor']),
    ('heltec-v4-tft', 'heltec_v4_tft', ['repeater', 'room_server', 'sensor']),
    ('heltec-v4-r8', 'heltec_v4_r8', ['repeater', 'room_server', 'sensor']),
    (
      'heltec-v4-r8-tft',
      'heltec_v4_r8_tft',
      ['repeater', 'room_server', 'sensor'],
    ),
    ('lilygo-tbeam-1w', 'LilyGo_TBeam_1W', ['repeater', 'room_server']),
    ('meshnology-w12', 'meshnology_w12', ['repeater', 'room_server', 'sensor']),
  ];
  for (final (family, stem, roles) in families) {
    for (final role in roles) {
      add('$family-${role.replaceAll('_', '-')}', '${stem}_$role');
    }
  }
  return Map.unmodifiable(result);
}
