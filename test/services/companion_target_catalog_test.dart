import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/companion_board_catalog.dart';
import 'package:meshcore_open/services/companion_image_validator.dart';
import 'package:meshcore_open/services/companion_target_catalog.dart';
import 'package:meshcore_open/services/nrf_dfu_package.dart';
import 'package:meshcore_open/services/usb_firmware_package.dart';

import '../support/companion_firmware_test_data.dart';

void main() {
  test(
    'exact reviewed source and historical targets classify without guesses',
    () {
      final t096 = CompanionBoardCatalog.lookup('Heltec T096')!;
      expect(
        CompanionTargetCatalog.profileFor(
          CompanionTargetCatalog.targetIdForEnvironment(
            'Heltec_t096_companion_radio_ble',
          ),
          t096,
        ),
        'ble',
      );
      expect(
        CompanionTargetCatalog.profileFor(
          CompanionTargetCatalog.targetIdForEnvironment(
            'Heltec_t096_companion_radio_ble_femon',
          ),
          t096,
        ),
        'ble',
      );
      expect(CompanionTargetCatalog.profileFor(0, t096), isNull);
      expect(
        CompanionTargetCatalog.profileFor(
          CompanionTargetCatalog.targetIdForEnvironment('Heltec_t096_repeater'),
          t096,
        ),
        isNull,
      );
      expect(
        CompanionTargetCatalog.profileFor(
          CompanionTargetCatalog.targetIdForEnvironment(
            'Heltec_t096_companion_radio_ble_custom',
          ),
          t096,
        ),
        isNull,
      );
      expect(
        CompanionTargetCatalog.profileFor(
          CompanionTargetCatalog.targetIdForEnvironment(
            'Heltec_t096_companion_radio_ble',
          ),
          CompanionBoardCatalog.lookup('Heltec T114')!,
        ),
        isNull,
      );
    },
  );
  test('same-board marked repeater image is not a Companion application', () {
    final nrf = testNrfDfuZip(
      image: testNrfApplication(targetEnv: 'Heltec_t096_repeater'),
    );
    expect(
      () => NrfDfuPackage.inspect(nrf).validateForBoard('Heltec T096'),
      throwsFormatException,
    );
    final esp = testEspApplication(targetEnv: 'heltec_v4_repeater');
    expect(
      () => CompanionImageValidator.validateEsp32(
        'app.bin',
        esp,
        'Heltec V4 OLED',
      ),
      throwsFormatException,
    );
  });
  test(
    'zero-target Full seeder is structurally valid but needs bound Full metadata',
    () {
      final image = testEspApplication(targetId: 0);
      expect(UsbFirmwareImage.fromBytes('full.bin', image).endf!.targetId, 0);
      expect(
        () => CompanionImageValidator.validateEsp32(
          'full.bin',
          image,
          'Heltec V4 OLED',
        ),
        throwsFormatException,
      );
      final spec = CompanionBoardCatalog.lookup('Heltec V4 OLED')!;
      final proof = CompanionFirmwareProvenance(
        boardId: spec.id,
        sha256: usbSha256(image),
        profile: 'full',
      );
      CompanionImageValidator.validateEsp32(
        'full.bin',
        image,
        'Heltec V4 OLED',
        provenance: proof,
      );
      final ble = CompanionFirmwareProvenance(
        boardId: spec.id,
        sha256: usbSha256(image),
        profile: 'ble',
      );
      expect(
        () => CompanionImageValidator.validateEsp32(
          'full.bin',
          image,
          'Heltec V4 OLED',
          provenance: ble,
        ),
        throwsFormatException,
      );
    },
  );
  test('Nordic zero target preserves real Full release compatibility', () {
    final bytes = testNrfDfuZip(image: testNrfApplication(targetId: 0));
    final package = NrfDfuPackage.inspect(bytes);
    expect(package.applicationIdentity!.targetId, 0);
    expect(
      () => package.validateForBoard('Heltec T096'),
      throwsFormatException,
    );
    final proof = CompanionFirmwareProvenance(
      boardId: CompanionBoardCatalog.lookup('Heltec T096')!.id,
      sha256: package.sha256,
      profile: 'full',
    );
    package.validateForBoard('Heltec T096', provenance: proof);
  });
  test('Full release metadata cannot relabel a known BLE application', () {
    final image = testEspApplication();
    final proof = CompanionFirmwareProvenance(
      boardId: CompanionBoardCatalog.lookup('Heltec V4 OLED')!.id,
      sha256: usbSha256(image),
      profile: 'full',
    );
    expect(
      () => CompanionImageValidator.validateEsp32(
        'full.bin',
        image,
        'Heltec V4 OLED',
        provenance: proof,
      ),
      throwsFormatException,
    );
  });
}
