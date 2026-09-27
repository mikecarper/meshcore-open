import 'ble_mota_catalog.dart';

/// Read-only target identity used to reject incompatible packages before a
/// temporary-radio handoff or LoRa download begins.
class LoraOtaTargetInfo {
  const LoraOtaTargetInfo({
    required this.environment,
    required this.applicationTargetId,
    required this.bootloaderTargetId,
    required this.baseHashPrefix,
    required this.bootloaderStorageCaps,
    required this.receiverStorage,
    required this.trustedSignerFingerprints,
  });

  final String environment;
  final int applicationTargetId;
  final int bootloaderTargetId;
  final String baseHashPrefix;
  final int bootloaderStorageCaps;
  final String receiverStorage;
  final Set<String> trustedSignerFingerprints;

  static LoraOtaTargetInfo parse({
    required String status,
    required String self,
    required String bootloader,
    required String keys,
  }) {
    String value(String text, RegExp pattern, String label) {
      final match = pattern.firstMatch(text);
      if (match == null) throw FormatException('Target did not report $label');
      return match.group(1)!;
    }

    final environment = value(
      status,
      RegExp(r'\benv:([A-Za-z0-9_]+)'),
      'its build profile',
    );
    final applicationId = int.parse(
      value(status, RegExp(r'\btarget:([0-9A-Fa-f]{8})'), 'application target'),
      radix: 16,
    );
    final bootloaderId = int.parse(
      value(
        bootloader,
        RegExp(r'\btarget=([0-9A-Fa-f]{8})'),
        'bootloader target',
      ),
      radix: 16,
    );
    final baseHash = value(
      self,
      RegExp(r'\bbase_hash=([0-9A-Fa-f]{16})'),
      'its firmware hash',
    ).toUpperCase();
    final storageCaps = int.parse(
      value(
        bootloader,
        RegExp(r'\bcaps=([0-9A-Fa-f]{2})'),
        'bootloader storage',
      ),
      radix: 16,
    );
    final receiverStorage = switch (storageCaps) {
      0x09 => 'external_sd',
      0x0E => 'external_qspi',
      0x0A => 'internal_flash',
      _ => throw const FormatException('Unknown target bootloader storage'),
    };
    final keySection = keys.contains(':') ? keys.split(':').last : '';
    final fingerprints = RegExp(r'[0-9A-Fa-f]{16}')
        .allMatches(keySection)
        .map((match) => match.group(0)!.toUpperCase())
        .toSet();
    return LoraOtaTargetInfo(
      environment: environment,
      applicationTargetId: applicationId,
      bootloaderTargetId: bootloaderId,
      baseHashPrefix: baseHash,
      bootloaderStorageCaps: storageCaps,
      receiverStorage: receiverStorage,
      trustedSignerFingerprints: fingerprints,
    );
  }

  void validatePackage(BleMotaFile file) {
    final expectedId = file.isBootloader
        ? bootloaderTargetId
        : applicationTargetId;
    if (file.targetId != expectedId) {
      throw StateError('${file.name} targets a different radio');
    }
    if (file.isBootloader) {
      if (file.bootloaderStorageCaps != bootloaderStorageCaps) {
        throw StateError(
          '${file.name} has the wrong bootloader storage profile',
        );
      }
    } else if (!file.isFull && file.baseHashPrefix != baseHashPrefix) {
      throw StateError(
        '${file.name} needs a different installed firmware base',
      );
    }
  }

  Set<String> missingSigners(Iterable<BleMotaFile> files) {
    return files
        .where((file) => file.isSigned && !file.isBootloader)
        .map((file) => file.signerPublicKeyHex)
        .where(
          (key) =>
              key.isNotEmpty &&
              !trustedSignerFingerprints.contains(key.substring(0, 16)),
        )
        .toSet();
  }
}
