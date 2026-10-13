import 'dart:typed_data';

import 'companion_board_catalog.dart';

enum Esp32FirmwareLayout { application, fullFlash }

/// Uses exact firmware board identities, not vendor/MCU substring guesses.
class CompanionFirmwareInspector {
  static bool isTowerV2Board(String? board) =>
      CompanionBoardCatalog.lookup(board)?.id == 'heltec-tower-v2';

  /// The file family does not itself promise an available wireless transport.
  /// For example, current Xiao C6 Companion firmware is known wired-only.
  static String? updateExtensionForBoard(String? board) =>
      CompanionBoardCatalog.lookup(board)?.updateExtension;

  /// The ESP image header alone occurs in both app-only and full-flash files.
  /// A partition table or an embedded second image marks a full-flash file.
  /// Such a file needs a wired installer and must never enter Wi-Fi OTA.
  static Esp32FirmwareLayout inspectEsp32(Uint8List image) {
    if (image.length < 1024 || image.length > 0x1000000) {
      throw const FormatException(
        'ESP32 image size is outside the supported range.',
      );
    }
    final startsAtZero = _imageHeaderAt(image, 0);
    final startsAt1000 = _imageHeaderAt(image, 0x1000);
    if (!startsAtZero && !startsAt1000) {
      throw const FormatException(
        'This file has no ESP32 firmware image header.',
      );
    }
    if (_partitionTableAt(image, 0x7000) ||
        _partitionTableAt(image, 0x8000) ||
        _imageHeaderAt(image, 0x10000) ||
        _imageHeaderAt(image, 0x150000)) {
      return Esp32FirmwareLayout.fullFlash;
    }
    return Esp32FirmwareLayout.application;
  }

  static bool _imageHeaderAt(Uint8List image, int offset) =>
      offset + 24 <= image.length &&
      image[offset] == 0xE9 &&
      image[offset + 1] >= 1 &&
      image[offset + 1] <= 16 &&
      image[offset + 2] <= 3;

  static bool _partitionTableAt(Uint8List image, int offset) =>
      offset + 32 <= image.length &&
      image[offset] == 0xAA &&
      image[offset + 1] == 0x50;
}
