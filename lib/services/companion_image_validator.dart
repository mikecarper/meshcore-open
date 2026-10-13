import 'dart:typed_data';

import 'companion_board_catalog.dart';
import 'companion_target_catalog.dart';
import 'usb_firmware_package.dart';

/// Created after a trusted release download passed its SHA-256 check. The
/// digest binds the board/profile metadata to the exact selected bytes.
class CompanionFirmwareProvenance {
  const CompanionFirmwareProvenance({
    required this.boardId,
    required this.sha256,
    required this.profile,
  });
  final String boardId;
  final String sha256;
  final String profile;

  bool matches(CompanionBoardSpec board, String digest) =>
      boardId == board.id &&
      RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256) &&
      sha256 == digest &&
      (profile == 'full' || profile == 'ble');
}

class CompanionImageValidator {
  static void validateCompanionTarget(
    UsbEndfIdentity identity,
    CompanionBoardSpec board, {
    required String digest,
    CompanionFirmwareProvenance? provenance,
  }) {
    if (identity.targetId == 0) {
      if (provenance == null ||
          provenance.profile != 'full' ||
          !provenance.matches(board, digest)) {
        throw const FormatException(
          'This source-only image has no independently verified Companion role. '
          'Choose its digest-checked Full GitHub release or use a wired installer.',
        );
      }
      return;
    }
    final profile = CompanionTargetCatalog.profileFor(identity.targetId, board);
    if (profile == null) {
      throw const FormatException(
        'Firmware target is not a reviewed Companion build for this exact board. '
        'Repeater, server and unknown custom images need a wired installer.',
      );
    }
    if (provenance != null &&
        (!provenance.matches(board, digest) || provenance.profile != profile)) {
      throw const FormatException(
        'Release profile differs from the firmware Companion target.',
      );
    }
  }

  static UsbFirmwareImage validateEsp32(
    String name,
    Uint8List bytes,
    String board, {
    CompanionFirmwareProvenance? provenance,
  }) {
    final spec = CompanionBoardCatalog.lookup(board);
    if (spec == null ||
        spec.family != CompanionChipFamily.esp32 ||
        spec.espChipId == null) {
      throw const FormatException(
        'The Companion did not report a supported exact ESP32 board.',
      );
    }
    final image = UsbFirmwareImage.fromBytes(name, bytes);
    if (image.chip != spec.espChipId) {
      throw const FormatException(
        'ESP32 image chip does not match this board.',
      );
    }
    final identity = image.endf;
    if (identity != null) {
      if (!spec.hardwareIds.contains(identity.hardwareId)) {
        throw const FormatException(
          'Firmware hardware identity does not match this Companion board.',
        );
      }
      validateCompanionTarget(
        identity,
        spec,
        digest: image.sha256,
        provenance: provenance,
      );
    } else if (provenance == null || !provenance.matches(spec, image.sha256)) {
      throw const FormatException(
        'This older image has no verified board identity. Use a digest-checked '
        'exact-board GitHub release or an exact-board wired installer.',
      );
    }
    // Invalid present EndF is rejected above, never treated as unmarked.
    return image;
  }
}
