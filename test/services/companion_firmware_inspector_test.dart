import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/companion_firmware_inspector.dart';
import 'package:meshcore_open/services/esp32_wifi_ota_service.dart';

Uint8List _image({int length = 0x21000}) {
  final bytes = Uint8List(length);
  bytes[0] = 0xE9;
  bytes[1] = 1;
  bytes[2] = 2;
  return bytes;
}

void main() {
  test('known boards select only their phone-update format', () {
    expect(
      CompanionFirmwareInspector.updateExtensionForBoard('Heltec V4.3 OLED'),
      'bin',
    );
    expect(
      CompanionFirmwareInspector.updateExtensionForBoard('XIAO S3 Wio'),
      'bin',
    );
    expect(
      CompanionFirmwareInspector.updateExtensionForBoard('RAK4631'),
      'zip',
    );
    expect(
      CompanionFirmwareInspector.updateExtensionForBoard('Heltec T114'),
      'zip',
    );
    expect(
      CompanionFirmwareInspector.updateExtensionForBoard('Heltec T096'),
      'zip',
    );
    expect(
      CompanionFirmwareInspector.updateExtensionForBoard('Unknown board'),
      isNull,
    );
  });

  test('only exact Tower V2 board aliases select Nordic ZIP', () {
    for (final board in [
      'Heltec Tower V2',
      'Heltec Mesh Tower V2',
      'MeshTower V2',
      'tower_v2',
      'Heltec Tower V2 SD',
      'Heltec MeshTower V2 SD',
      'MeshTower V2 SD',
      'tower_v2_sd',
      'Heltec_tower_v2_sdcard',
      'Heltec_mesh_tower_v2_sdcard',
      'mesh_tower_v2_sdcard',
      'tower_v2_sdcard',
    ]) {
      expect(CompanionFirmwareInspector.isTowerV2Board(board), isTrue);
      expect(CompanionFirmwareInspector.updateExtensionForBoard(board), 'zip');
    }
    for (final board in [
      null,
      'Heltec Tower V3',
      'Unknown Heltec Tower V2',
      'tower_v2_custom',
      'ESP32 Tower V2',
    ]) {
      expect(CompanionFirmwareInspector.isTowerV2Board(board), isFalse);
    }
  });

  test('app-only ESP32 bytes are a phone-update image', () {
    final image = _image();

    expect(
      CompanionFirmwareInspector.inspectEsp32(image),
      Esp32FirmwareLayout.application,
    );
    expect(
      () => Esp32WifiOtaService.validateImage('app.bin', image),
      returnsNormally,
    );
  });

  test('partition table marks full/erase even with an ordinary filename', () {
    final image = _image();
    image[0x8000] = 0xAA;
    image[0x8001] = 0x50;
    image[0x10000] = 0xE9;
    image[0x10001] = 1;
    image[0x10002] = 2;

    expect(
      CompanionFirmwareInspector.inspectEsp32(image),
      Esp32FirmwareLayout.fullFlash,
    );
    expect(
      () => Esp32WifiOtaService.validateImage('app.bin', image),
      throwsFormatException,
    );
  });

  test('merged image at flash 0x1000 is not accepted as a phone update', () {
    final image = Uint8List(0x21000);
    image[0x1000] = 0xE9;
    image[0x1001] = 1;
    image[0x1002] = 2;
    image[0x7000] = 0xAA;
    image[0x7001] = 0x50;

    expect(
      CompanionFirmwareInspector.inspectEsp32(image),
      Esp32FirmwareLayout.fullFlash,
    );
    expect(
      () => Esp32WifiOtaService.validateImage('firmware.bin', image),
      throwsFormatException,
    );
  });

  test('mislabeled and non-ESP images are refused', () {
    final image = _image();

    expect(
      () => Esp32WifiOtaService.validateImage('factory-merged.bin', image),
      throwsFormatException,
    );
    expect(
      () => CompanionFirmwareInspector.inspectEsp32(Uint8List(2048)),
      throwsFormatException,
    );
  });
}
