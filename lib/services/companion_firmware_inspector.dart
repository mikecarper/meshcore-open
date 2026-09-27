import 'dart:typed_data';

enum Esp32FirmwareLayout { application, fullFlash }

/// Selects the phone-update format only when the reported board family is
/// unambiguous. Unknown boards keep both file types available for inspection.
class CompanionFirmwareInspector {
  static String? updateExtensionForBoard(String? board) {
    if (board == null) return null;
    final name = board.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (name.isEmpty || name.startsWith('unknown')) return null;

    if (name.contains('xiaos3') ||
        name.contains('xiaoesp32') ||
        name.contains('esp32') ||
        name.startsWith('heltecv') ||
        name.startsWith('heltecwireless') ||
        name.contains('stationg2') ||
        name.contains('eoras3') ||
        name.contains('tdeck') ||
        name.contains('tbeam') ||
        name.contains('tlora') ||
        name.contains('sensecapindicator')) {
      return 'bin';
    }
    if (name.contains('nrf52') ||
        name.contains('rak4631') ||
        name.contains('rak3401') ||
        name.contains('t114') ||
        name.contains('techo') ||
        name.contains('t1000') ||
        name.contains('thinknode') ||
        name.startsWith('xiao')) {
      return 'zip';
    }
    return null;
  }

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
