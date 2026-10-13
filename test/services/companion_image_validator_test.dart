import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/companion_board_catalog.dart';
import 'package:meshcore_open/services/companion_image_validator.dart';
import 'package:meshcore_open/services/usb_firmware_package.dart';

import '../support/companion_firmware_test_data.dart';

void main() {
  test('marked image passes only exact board and chip', () {
    final bytes = testEspApplication();
    expect(
      CompanionImageValidator.validateEsp32(
        'app.bin',
        bytes,
        'Heltec V4 OLED',
      ).chip,
      9,
    );
    for (final board in [
      'Heltec V4 R8 OLED',
      'Heltec V3',
      'Heltec T096',
      'Unknown Heltec V4',
    ]) {
      expect(
        () => CompanionImageValidator.validateEsp32('app.bin', bytes, board),
        throwsA(isA<Exception>()),
      );
    }
  });
  test('present invalid EndF is never accepted as unmarked', () {
    final bytes = testEspApplication()..[32] ^= 1;
    final proof = CompanionFirmwareProvenance(
      boardId: CompanionBoardCatalog.lookup('Heltec V4 OLED')!.id,
      sha256: usbSha256(bytes),
      profile: 'full',
    );
    expect(
      () => CompanionImageValidator.validateEsp32(
        'app.bin',
        bytes,
        'Heltec V4 OLED',
        provenance: proof,
      ),
      throwsA(isA<UsbFirmwareValidationException>()),
    );
  });
  test('segment checksum and appended SHA-256 fail closed', () {
    final checksum = testEspApplication(marked: false)..[47] ^= 1;
    final hash = testEspApplication(marked: false);
    hash[hash.length - 1] ^= 1;
    for (final bytes in [checksum, hash]) {
      expect(
        () => CompanionImageValidator.validateEsp32(
          'app.bin',
          bytes,
          'Heltec V4 OLED',
        ),
        throwsA(isA<UsbFirmwareValidationException>()),
      );
    }
  });
  test('unmarked legacy image needs exact digest and board provenance', () {
    final bytes = testEspApplication(marked: false);
    final spec = CompanionBoardCatalog.lookup('Heltec V4 OLED')!;
    expect(
      () => CompanionImageValidator.validateEsp32(
        'app.bin',
        bytes,
        'Heltec V4 OLED',
      ),
      throwsFormatException,
    );
    final proof = CompanionFirmwareProvenance(
      boardId: spec.id,
      sha256: usbSha256(bytes),
      profile: 'ble',
    );
    CompanionImageValidator.validateEsp32(
      'app.bin',
      bytes,
      'Heltec V4 OLED',
      provenance: proof,
    );
    expect(
      () => CompanionImageValidator.validateEsp32(
        'app.bin',
        testEspApplication(marked: false, appendedHash: false),
        'Heltec V4 OLED',
        provenance: proof,
      ),
      throwsFormatException,
    );
  });
}
