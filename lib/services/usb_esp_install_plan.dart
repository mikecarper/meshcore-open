import 'dart:typed_data';

import 'usb_esp_flash_engine.dart';
import 'usb_firmware_package.dart';
import 'usb_partition_expansion.dart';

enum UsbEspInstallMode { bootloader, fullInstall }

class UsbEspInstallWrite {
  UsbEspInstallWrite(this.offset, Uint8List data)
    : bytes = Uint8List.fromList(data).asUnmodifiableView(),
      sha256 = usbSha256(data);
  final int offset;
  final Uint8List bytes;
  final String sha256;
}

class UsbEspInstallArtifact {
  UsbEspInstallArtifact._({
    required this.name,
    required Uint8List data,
    required this.mode,
    required this.chip,
    required this.bootOffset,
    required this.declaredFlashBytes,
    required List<UsbEspInstallWrite> writes,
    this.firmwareVersion,
    this.hardwareId,
  }) : bytes = Uint8List.fromList(data).asUnmodifiableView(),
       sha256 = usbSha256(data),
       writes = List.unmodifiable(writes);
  final String name, sha256;
  final Uint8List bytes;
  final UsbEspInstallMode mode;
  final int chip, bootOffset, declaredFlashBytes;
  final List<UsbEspInstallWrite> writes;
  final String? firmwareVersion, hardwareId;
  bool get requiresErase => mode == UsbEspInstallMode.fullInstall;

  /// Must run again immediately before any destructive operation. The native
  /// engine separately enforces ROM MAC, security state and readback integrity.
  void validateForChip(UsbEspChipInfo connected) {
    if (connected.chip != chip ||
        declaredFlashBytes > connected.flashBytes ||
        usbSha256(bytes) != sha256 ||
        writes.isEmpty) {
      usbReject(
        'ESP install image does not match the connected chip/capacity or changed.',
      );
    }
    for (final write in writes) {
      if (write.offset < 0 ||
          write.offset % 4096 != 0 ||
          write.bytes.isEmpty ||
          write.offset + ((write.bytes.length + 4095) & ~4095) >
              connected.flashBytes ||
          usbSha256(write.bytes) != write.sha256) {
        usbReject('ESP install write has invalid geometry or changed bytes.');
      }
    }
  }
}

/// Explicit ESP bootloader/full-install policy. No arbitrary-offset, erase or
/// USB API is exposed here. Full installs require separate whole-erase consent
/// in the controller; bootloader-only never changes table/settings/app slots.
class UsbEspInstallPlan {
  static const _bootOffsets = {0: 0x1000, 2: 0x1000, 5: 0, 9: 0, 12: 0};
  static const _appMagic = 0xabcd5432;

  static UsbEspInstallArtifact inspectBootloader({
    required String name,
    required Uint8List bytes,
  }) {
    _input(name, bytes);
    final header = usbVerifyEspBinary(bytes, allowBootloader: true);
    final offset = _bootOffset(header.chip);
    _bootloader(bytes, header.chip, offset);
    return UsbEspInstallArtifact._(
      name: name,
      data: bytes,
      mode: UsbEspInstallMode.bootloader,
      chip: header.chip,
      bootOffset: offset,
      declaredFlashBytes: header.flashBytes,
      writes: [UsbEspInstallWrite(offset, bytes)],
    );
  }

  static UsbEspInstallArtifact inspectFullInstall({
    required String name,
    required Uint8List bytes,
  }) {
    _input(name, bytes);
    if (bytes.length < 0x10020) {
      usbReject(
        'Full install requires a merged image starting at flash address zero.',
      );
    }
    // Only reviewed zero-based layouts are recognized; never guess a user offset.
    var boot = 0;
    if (bytes[0] != 0xe9) {
      if (!_erased(bytes, 0, 0x1000) || bytes[0x1000] != 0xe9) {
        usbReject('Merged image has no recognized zero-based ESP bootloader.');
      }
      boot = 0x1000;
    }
    final bootLength = _binaryLength(bytes, boot, 0x8000);
    final bootBytes = Uint8List.sublistView(bytes, boot, boot + bootLength);
    final header = usbVerifyEspBinary(bootBytes, allowBootloader: true);
    if (_bootOffset(header.chip) != boot || bytes.length > header.flashBytes) {
      usbReject(
        'Merged bootloader offset or image capacity is incompatible with its chip.',
      );
    }
    _bootloader(bootBytes, header.chip, boot);
    if (!_erased(bytes, boot + bootLength, 0x8000)) {
      usbReject(
        'Merged image has unrecognized data before the partition table.',
      );
    }
    final table = Uint8List.sublistView(bytes, 0x8000, 0x9000);
    final parts = UsbPartitionExpansion.parseTable(table, header.flashBytes);
    final apps = parts.where((p) => p.type == 0).toList()
      ..sort((a, b) => a.subtype.compareTo(b.subtype));
    if (apps.isEmpty ||
        apps.map((p) => p.subtype).toSet().length != apps.length ||
        apps.any(
          (p) => p.subtype != 0 && (p.subtype < 0x10 || p.subtype > 0x1f),
        ) ||
        parts.any((p) => p.flags != 0)) {
      usbReject(
        'Merged image has unsupported app slots or encrypted partition flags.',
      );
    }
    final writes = <UsbEspInstallWrite>[];
    final presentApps = <int, UsbFirmwareImage>{};
    final knownRanges = <(int, int)>[
      (boot, boot + bootLength),
      (0x8000, 0x9000),
    ];
    for (final p in parts) {
      final end = (p.offset + p.size).clamp(0, bytes.length);
      if (p.offset >= bytes.length || _erased(bytes, p.offset, end)) continue;
      if (p.type == 0) {
        final length = _binaryLength(bytes, p.offset, end);
        final data = Uint8List.sublistView(bytes, p.offset, p.offset + length);
        final image = UsbFirmwareImage.fromBytes('application.bin', data);
        if (image.chip != header.chip ||
            image.declaredFlashBytes > header.flashBytes ||
            data.length < 36 ||
            usbUint32(data, 32) != _appMagic ||
            !_erased(bytes, p.offset + length, end)) {
          usbReject(
            'Merged application identity, chip, size or trailing bytes are invalid.',
          );
        }
        presentApps[p.offset] = image;
        writes.add(UsbEspInstallWrite(p.offset, data));
        knownRanges.add((p.offset, p.offset + length));
      } else if (p.type == 1 && p.subtype == 0 && p.size >= 0x2000) {
        if (p.offset + p.size > bytes.length ||
            !_erased(bytes, p.offset + 0x2000, p.offset + p.size)) {
          usbReject(
            'Merged OTA metadata is incomplete or has unexpected data.',
          );
        }
        writes.add(
          UsbEspInstallWrite(
            p.offset,
            Uint8List.sublistView(bytes, p.offset, p.offset + 0x2000),
          ),
        );
        knownRanges.add((p.offset, p.offset + 0x2000));
      } else {
        // A factory image is not permission to import unverified private blobs.
        usbReject(
          'Merged image contains provisioned/unknown data partitions; only empty configuration is supported.',
        );
      }
    }
    final otas = parts.where((p) => p.type == 1 && p.subtype == 0).toList();
    final otaApps = apps
        .where((p) => p.subtype >= 0x10 && p.subtype <= 0x1f)
        .toList();
    int active;
    if (otaApps.isNotEmpty) {
      if (otas.length != 1 || otas.single.size < 0x2000) {
        usbReject(
          'Merged OTA app layout has no unique complete OTA metadata partition.',
        );
      }
      final ota = otas.single;
      final otaBytes = Uint8List(0x2000)..fillRange(0, 0x2000, 0xff);
      if (ota.offset < bytes.length) {
        final count = (bytes.length - ota.offset).clamp(0, 0x2000);
        otaBytes.setRange(
          0,
          count,
          bytes.sublist(ota.offset, ota.offset + count),
        );
      }
      active = UsbPartitionExpansion.activeOtaOffset(parts, otaBytes);
    } else {
      final factories = apps.where((p) => p.subtype == 0).toList();
      if (factories.length != 1) {
        usbReject('Merged image lacks a supported initial app slot.');
      }
      active = factories.single.offset;
    }
    final selected = presentApps[active];
    if (selected == null) {
      usbReject(
        'Merged OTA/factory selection points to an absent application.',
      );
    }
    final identity = selected.endf;
    for (final other in presentApps.values) {
      if (identity != null &&
          other.endf != null &&
          (other.endf!.targetId != identity.targetId ||
              other.endf!.hardwareId != identity.hardwareId ||
              other.endf!.version != identity.version)) {
        usbReject(
          'Merged applications target inconsistent hardware, roles or versions.',
        );
      }
    }
    // Every non-erased byte must belong to a verified component.
    knownRanges.sort((a, b) => a.$1.compareTo(b.$1));
    var cursor = 0;
    for (final range in knownRanges) {
      if (!_erased(bytes, cursor, range.$1)) {
        usbReject('Merged image contains unrecognized flash data.');
      }
      cursor = range.$2;
    }
    if (!_erased(bytes, cursor, bytes.length)) {
      usbReject('Merged image has arbitrary trailing data.');
    }
    writes.add(UsbEspInstallWrite(0x8000, table));
    // Publish the bootloader last, after all app/data/table transfers verify.
    writes.add(UsbEspInstallWrite(boot, bootBytes));
    final version = identity == null
        ? null
        : 'v${identity.version >> 24}.${(identity.version >> 16) & 255}.${(identity.version >> 8) & 255}.${identity.version & 255}';
    return UsbEspInstallArtifact._(
      name: name,
      data: bytes,
      mode: UsbEspInstallMode.fullInstall,
      chip: header.chip,
      bootOffset: boot,
      declaredFlashBytes: header.flashBytes,
      writes: writes,
      firmwareVersion: version,
      hardwareId: identity?.hardwareId,
    );
  }

  static void _input(String name, Uint8List bytes) {
    if (!name.toLowerCase().endsWith('.bin') ||
        bytes.isEmpty ||
        bytes.length > UsbVerifiedPackage.maxArchiveBytes) {
      usbReject(
        'Select a bounded plaintext ESP BIN for this explicit install action.',
      );
    }
  }

  static int _bootOffset(int chip) {
    final offset = _bootOffsets[chip];
    if (offset == null) {
      usbReject('This ESP chip has no reviewed bootloader/full-install plan.');
    }
    return offset;
  }

  static void _bootloader(Uint8List bytes, int chip, int offset) {
    if (bytes.length > 0x8000 - offset ||
        UsbEndfIdentity.inspect(bytes) != null ||
        bytes.length < 36 ||
        usbUint32(bytes, 32) == _appMagic) {
      usbReject(
        'Bootloader action cannot accept an application or overlap the partition table.',
      );
    }
    var cursor = 24;
    final entry = usbUint32(bytes, 4);
    var entryInSegment = false;
    for (var i = 0; i < bytes[1]; i++) {
      final address = usbUint32(bytes, cursor),
          length = usbUint32(bytes, cursor + 4);
      if (_flashMapped(chip, address) ||
          (length > 0 && _flashMapped(chip, address + length - 1))) {
        usbReject(
          'Bootloader action cannot accept flash-mapped application segments.',
        );
      }
      if (length > 0 &&
          entry >= address &&
          entry < address + length &&
          address != 0) {
        entryInSegment = true;
      }
      cursor += 8 + length;
    }
    if (!entryInSegment) {
      usbReject(
        'Bootloader entry point is not inside a validated loaded segment.',
      );
    }
  }

  static bool _flashMapped(int chip, int address) {
    final ranges = switch (chip) {
      0 => [(0x3f400000, 0x3f800000), (0x400d0000, 0x40400000)],
      2 => [(0x3f000000, 0x3f3f0000), (0x40080000, 0x40b80000)],
      5 => [(0x3c000000, 0x3c800000), (0x42000000, 0x42800000)],
      9 => [(0x3c000000, 0x3e000000), (0x42000000, 0x44000000)],
      12 => [(0x3c000000, 0x3c400000), (0x42000000, 0x42400000)],
      _ => <(int, int)>[],
    };
    return ranges.any((range) => address >= range.$1 && address < range.$2);
  }

  static int _binaryLength(Uint8List bytes, int start, int limit) {
    if (start < 0 || start + 32 > limit || limit > bytes.length) {
      usbReject('Merged ESP component header is truncated.');
    }
    final header = UsbEspImageHeader.parse(
      Uint8List.sublistView(bytes, start, limit),
    );
    var cursor = start + 24;
    for (var i = 0; i < bytes[start + 1]; i++) {
      if (cursor + 8 > limit) usbReject('Merged ESP segment is truncated.');
      final size = usbUint32(bytes, cursor + 4);
      cursor += 8;
      if (size > limit - cursor) {
        usbReject('Merged ESP segment exceeds its partition.');
      }
      cursor += size;
    }
    var length = (((cursor - start) ~/ 16) + 1) * 16;
    if (bytes[start + 23] == 1) length += 32;
    if (start + length > limit) {
      usbReject('Merged ESP checksum/hash is truncated.');
    }
    if (start + length + 56 <= limit &&
        usbBytesEqual(bytes.sublist(start + length, start + length + 4), [
          69,
          110,
          100,
          70,
        ])) {
      length += 56;
    }
    // Parse prevents unused invalid-header input from bypassing validation.
    if (header.flashBytes <= 0) usbReject('Merged ESP header is invalid.');
    return length;
  }

  static bool _erased(Uint8List bytes, int start, int end) {
    if (start < 0 || end < start || end > bytes.length) return false;
    for (var i = start; i < end; i++) {
      if (bytes[i] != 0xff) return false;
    }
    return true;
  }
}
