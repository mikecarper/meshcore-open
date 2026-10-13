import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/companion_firmware_validation.dart';
import 'package:meshcore_open/services/companion_image_validator.dart';
import 'package:meshcore_open/services/nrf_dfu_package.dart';
import 'package:meshcore_open/services/usb_firmware_package.dart';

import '../support/companion_firmware_test_data.dart';

void main() {
  test(
    'Nordic worker preserves synchronous validation result and caller bytes',
    () async {
      final bytes = testNrfDfuZip();
      final original = Uint8List.fromList(bytes);
      final sync = NrfDfuPackage.inspect(bytes)
        ..validateForBoard('Heltec T096');
      final result = await CompanionFirmwareValidation.inspectNordic(
        bytes,
        board: 'Heltec T096',
      );
      expect(result.sha256, sync.sha256);
      expect(result.components, sync.components);
      expect(
        result.applicationIdentity!.targetId,
        sync.applicationIdentity!.targetId,
      );
      expect(bytes, original);
      expect(() => result.components.add('bootloader'), throwsUnsupportedError);
    },
  );

  test(
    'Nordic worker rejects wrong board, malformed init and wrong role',
    () async {
      for (final bytes in [
        testNrfDfuZip(corruptCrc: true),
        testNrfDfuZip(
          image: testNrfApplication(targetEnv: 'Heltec_t096_repeater'),
        ),
      ]) {
        await expectLater(
          CompanionFirmwareValidation.inspectNordic(
            bytes,
            board: 'Heltec T096',
          ),
          throwsFormatException,
        );
      }
      await expectLater(
        CompanionFirmwareValidation.inspectNordic(
          testNrfDfuZip(),
          board: 'Heltec T114',
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'Nordic worker accepts only explicitly selected reviewed infrastructure role',
    () async {
      final bytes = testNrfDfuZip(
        image: testNrfApplication(targetEnv: 'Heltec_t096_repeater'),
      );
      final result = await CompanionFirmwareValidation.inspectNordic(
        bytes,
        board: 'Heltec T096',
        role: NrfDfuApplicationRole.repeater,
      );
      expect(result.components, ['application']);
      await expectLater(
        CompanionFirmwareValidation.inspectNordic(
          bytes,
          board: 'Heltec T096',
          role: NrfDfuApplicationRole.roomServer,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'structural migration worker does not grant Companion permission',
    () async {
      final bytes = testNrfDfuZip(component: 'softdevice_bootloader');
      final result = await CompanionFirmwareValidation.inspectNordicPackage(
        bytes,
      );
      expect(result.components, ['softdevice_bootloader']);
      await expectLater(
        CompanionFirmwareValidation.inspectNordic(bytes, board: 'Heltec T096'),
        throwsFormatException,
      );
    },
  );

  test(
    'ESP worker returns immutable validated image without modifying source',
    () async {
      final bytes = testEspApplication();
      final original = Uint8List.fromList(bytes);
      final sync = CompanionImageValidator.validateEsp32(
        'app.bin',
        bytes,
        'Heltec V4 OLED',
      );
      final result = await CompanionFirmwareValidation.inspectEsp32(
        'app.bin',
        bytes,
        board: 'Heltec V4 OLED',
      );
      expect(result.sha256, sync.sha256);
      expect(result.chip, sync.chip);
      expect(result.endf!.hardwareId, sync.endf!.hardwareId);
      expect(bytes, original);
      expect(() => result.bytes[32] ^= 1, throwsUnsupportedError);
    },
  );

  test('ESP worker rejects wrong board and corrupt present EndF', () async {
    await expectLater(
      CompanionFirmwareValidation.inspectEsp32(
        'app.bin',
        testEspApplication(),
        board: 'Heltec V3',
      ),
      throwsFormatException,
    );
    final corrupt = testEspApplication()..[32] ^= 1;
    await expectLater(
      CompanionFirmwareValidation.inspectEsp32(
        'app.bin',
        corrupt,
        board: 'Heltec V4 OLED',
      ),
      throwsA(isA<UsbFirmwareValidationException>()),
    );
  });

  test(
    'workers retain digest-bound trusted legacy provenance, without promoting missing proof',
    () async {
      final bytes = testNrfDfuZip(image: testNrfApplication(marked: false));
      final proof = CompanionFirmwareProvenance(
        boardId: 'heltec-t096',
        sha256: usbSha256(bytes),
        profile: 'ble',
      );
      expect(
        (await CompanionFirmwareValidation.inspectNordic(
          bytes,
          board: 'Heltec T096',
          provenance: proof,
        )).sha256,
        proof.sha256,
      );
      await expectLater(
        CompanionFirmwareValidation.inspectNordic(bytes, board: 'Heltec T096'),
        throwsFormatException,
      );
    },
  );
}
