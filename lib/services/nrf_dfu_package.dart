import 'dart:typed_data';

import 'companion_board_catalog.dart';
import 'companion_image_validator.dart';
import 'nrf_dfu_target_catalog.dart';
import 'usb_firmware_package.dart';

enum NrfDfuApplicationRole { companion, repeater, roomServer }

/// A Nordic DFU distribution ZIP is distinct from a LoRa .mota container.
/// Check its manifest and referenced binaries before asking the bootloader
/// to accept it. Board compatibility must still be confirmed by the user.
class NrfDfuPackage {
  NrfDfuPackage._({
    required this.components,
    required this.size,
    required this.sha256,
    required Map<String, Uint8List> binaries,
    required Map<String, List<int>> softdeviceIds,
    required Map<String, int> deviceTypes,
    required this.applicationIdentity,
    required this.applicationBaseHash,
  }) : _binaries = binaries,
       _softdeviceIds = softdeviceIds,
       _deviceTypes = deviceTypes;

  final List<String> components;
  final int size;
  final String sha256;

  /// Verified application trailer, absent for old or system-update packages.
  final UsbEndfIdentity? applicationIdentity;

  /// First eight SHA-256 bytes, as reported by the authenticated `ota self`.
  final String? applicationBaseHash;
  final Map<String, Uint8List> _binaries;
  final Map<String, List<int>> _softdeviceIds;
  final Map<String, int> _deviceTypes;

  static String macFromStartReply(String reply) {
    final match = RegExp(
      r'\bmac:\s*([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5})\b',
    ).firstMatch(reply);
    if (match == null) {
      throw const FormatException(
        'The radio did not return a Bluetooth DFU address.',
      );
    }
    return match.group(1)!.toUpperCase();
  }

  /// The legacy Nordic bootloader advertises at the application's address +1.
  /// Match Nordic's last-octet wrap without carrying into the preceding octet.
  static String bootloaderAddress(String address) {
    if (!RegExp(r'^[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}$').hasMatch(address)) {
      throw const FormatException('Invalid Bluetooth DFU address.');
    }
    final next = (int.parse(address.substring(15), radix: 16) + 1) & 0xff;
    return '${address.substring(0, 15).toUpperCase()}${next.toRadixString(16).padLeft(2, '0').toUpperCase()}';
  }

  static NrfDfuPackage inspect(Uint8List bytes) {
    try {
      final files = checkedZipEntries(
        bytes,
        maxArchiveBytes: 4 * 1024 * 1024,
        maxExpandedBytes: 2 * 1024 * 1024,
        maxEntries: 9,
      );
      final manifestBytes = files['manifest.json'];
      if (manifestBytes == null || manifestBytes.length > 65536) {
        throw const FormatException('Nordic DFU ZIP has no bounded manifest.');
      }
      final decoded = usbStrictJson(manifestBytes);
      if (decoded is! Map || decoded['manifest'] is! Map) {
        throw const FormatException('Nordic DFU manifest is invalid.');
      }
      final manifest = decoded['manifest'] as Map;
      const kinds = {
        'application',
        'bootloader',
        'softdevice',
        'softdevice_bootloader',
      };
      if (manifest.keys.any(
            (key) => !kinds.contains(key) && key != 'dfu_version',
          ) ||
          (manifest['dfu_version'] != null && manifest['dfu_version'] != 0.5)) {
        throw const FormatException('Unsupported Nordic DFU manifest version.');
      }
      final binaries = <String, Uint8List>{};
      final ids = <String, List<int>>{};
      final deviceTypes = <String, int>{};
      final inventory = <String>{'manifest.json'};
      UsbEndfIdentity? applicationIdentity;
      for (final kind in kinds) {
        final entry = manifest[kind];
        if (entry == null) continue;
        if (entry is! Map ||
            entry['bin_file'] is! String ||
            entry['dat_file'] is! String) {
          throw FormatException('$kind is missing its Nordic DFU files.');
        }
        final binName = entry['bin_file'] as String;
        final datName = entry['dat_file'] as String;
        if (!binName.endsWith('.bin') ||
            !datName.endsWith('.dat') ||
            !inventory.add(binName) ||
            !inventory.add(datName) ||
            files[binName] == null ||
            files[datName] == null) {
          throw const FormatException('Nordic DFU file inventory is invalid.');
        }
        final image = files[binName]!;
        final init = files[datName]!;
        if (image.length < 8 ||
            image.length > 1024 * 1024 ||
            init.length < 12 ||
            init.length > 76) {
          throw const FormatException(
            'Nordic DFU binary or init size is invalid.',
          );
        }
        final data = ByteData.sublistView(init);
        final count = data.getUint16(8, Endian.little);
        final crcOffset = 10 + count * 2;
        final crc = _crc16(image);
        if (count > 32 ||
            init.length != crcOffset + 2 ||
            data.getUint16(crcOffset, Endian.little) != crc) {
          throw const FormatException(
            'Nordic DFU init packet CRC does not match its binary.',
          );
        }
        final metadata = entry['init_packet_data'];
        if (metadata != null && metadata is! Map) {
          throw const FormatException('Nordic DFU init metadata is invalid.');
        }
        if (metadata is Map &&
            ((metadata['firmware_crc16'] != null &&
                    metadata['firmware_crc16'] != crc) ||
                (metadata['device_type'] != null &&
                    metadata['device_type'] !=
                        data.getUint16(0, Endian.little)) ||
                (metadata['device_revision'] != null &&
                    metadata['device_revision'] !=
                        data.getUint16(2, Endian.little)))) {
          throw const FormatException(
            'Nordic DFU manifest differs from its init packet.',
          );
        }
        final identity = UsbEndfIdentity.inspect(image);
        if (kind == 'application') applicationIdentity = identity;
        binaries[kind] = image;
        deviceTypes[kind] = data.getUint16(0, Endian.little);
        ids[kind] = List<int>.unmodifiable([
          for (var index = 0; index < count; index++)
            data.getUint16(10 + index * 2, Endian.little),
        ]);
      }
      if (binaries.isEmpty ||
          inventory.length != files.length ||
          !inventory.containsAll(files.keys) ||
          (binaries.containsKey('softdevice_bootloader') &&
              (binaries.containsKey('softdevice') ||
                  binaries.containsKey('bootloader')))) {
        throw const FormatException(
          'Nordic DFU ZIP contains an ambiguous file inventory.',
        );
      }
      return NrfDfuPackage._(
        components: List.unmodifiable(binaries.keys),
        size: bytes.length,
        sha256: usbSha256(bytes),
        binaries: Map.unmodifiable(binaries),
        softdeviceIds: Map.unmodifiable(ids),
        deviceTypes: Map.unmodifiable(deviceTypes),
        applicationIdentity: binaries.length == 1 ? applicationIdentity : null,
        applicationBaseHash: binaries.length == 1 && applicationIdentity != null
            ? binaries['application']!
                  .sublist(
                    binaries['application']!.length - 48,
                    binaries['application']!.length - 40,
                  )
                  .map((b) => b.toRadixString(16).padLeft(2, '0'))
                  .join()
            : null,
      );
    } on UsbFirmwareValidationException catch (error) {
      throw FormatException(error.message);
    }
  }

  void validateForBoard(
    String board, {
    CompanionFirmwareProvenance? provenance,
    NrfDfuApplicationRole role = NrfDfuApplicationRole.companion,
    int? expectedTargetId,
  }) {
    final spec = CompanionBoardCatalog.lookup(board);
    if (spec == null || spec.family != CompanionChipFamily.nrf52) {
      throw const FormatException('A supported exact nRF52 board is required.');
    }
    if (components.length != 1 || components.single != 'application') {
      throw const FormatException(
        'Wireless updates accept application-only ZIPs. '
        'Bootloader or SoftDevice updates require their board-specific migration workflow.',
      );
    }
    final image = _binaries['application']!;
    final identity = UsbEndfIdentity.inspect(image);
    final executableBytes = image.length - (identity == null ? 0 : 56);
    final base = spec.nrfApplicationAddress;
    final maximum = role == NrfDfuApplicationRole.companion || identity == null
        ? spec.nrfApplicationMaxSize
        : NrfDfuTargetCatalog.applicationMaximum(
                identity.targetId,
                spec,
                role.name,
                expectedTargetId: expectedTargetId,
              ) ??
              spec.nrfApplicationMaxSize;
    if (base == null || maximum == null || spec.nrfSoftdeviceIds.isEmpty) {
      throw const FormatException(
        'No verified application flash layout is available for this nRF52 board.',
      );
    }
    final vector = ByteData.sublistView(image);
    final sp = vector.getUint32(0, Endian.little),
        reset = vector.getUint32(4, Endian.little);
    if (_deviceTypes['application'] != 82 ||
        image.length > maximum ||
        sp < 0x20000000 ||
        sp > 0x20040000 ||
        sp % 8 != 0 ||
        reset & 1 == 0 ||
        (reset & ~1) < base ||
        (reset & ~1) >= base + executableBytes) {
      throw const FormatException(
        'nRF52840 application vectors or flash geometry are invalid.',
      );
    }
    final requiredIds = _softdeviceIds['application']!;
    if (requiredIds.isEmpty ||
        !requiredIds.every(spec.nrfSoftdeviceIds.contains)) {
      throw const FormatException(
        'The package requires a SoftDevice not verified for this board layout.',
      );
    }
    if (identity != null) {
      if (!spec.hardwareIds.contains(identity.hardwareId)) {
        throw const FormatException(
          'Nordic firmware hardware identity does not match this board.',
        );
      }
      if (role == NrfDfuApplicationRole.companion) {
        CompanionImageValidator.validateCompanionTarget(
          identity,
          spec,
          digest: sha256,
          provenance: provenance,
        );
      } else if (!NrfDfuTargetCatalog.supports(
        identity.targetId,
        spec,
        role.name,
        expectedTargetId: expectedTargetId,
      )) {
        throw const FormatException(
          'This image is not a reviewed build of the selected repeater/server role and exact board. '
          'Use a supported release or exact-board wired installer.',
        );
      }
    } else if (provenance == null || !provenance.matches(spec, sha256)) {
      throw const FormatException(
        'This older ZIP has no verified board identity. '
        'Use a digest-checked exact-board GitHub release or an exact-board wired installer.',
      );
    }
    if (identity == null && role != NrfDfuApplicationRole.companion) {
      throw const FormatException(
        'Infrastructure wireless updates require a verified board and role identity in the image.',
      );
    }
  }

  static int _crc16(List<int> bytes) {
    var crc = 0xffff;
    for (final byte in bytes) {
      crc ^= byte << 8;
      for (var bit = 0; bit < 8; bit++) {
        crc = ((crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1) & 0xffff;
      }
    }
    return crc;
  }
}
