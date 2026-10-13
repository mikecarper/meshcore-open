import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/companion_board_catalog.dart';
import 'package:meshcore_open/services/companion_image_validator.dart';
import 'package:meshcore_open/services/nrf_dfu_package.dart';
import 'package:meshcore_open/services/usb_firmware_package.dart';

import '../support/companion_firmware_test_data.dart';

void main() {
  Uint8List package({String binName = 'application.bin'}) {
    return testNrfDfuZip(binName: binName);
  }

  test('recognizes a standard application DFU distribution', () {
    final parsed = NrfDfuPackage.inspect(package());
    expect(parsed.components, ['application']);
  });

  test('rejects a missing manifest member or path traversal', () {
    expect(
      () => NrfDfuPackage.inspect(testNrfDfuZip(omitDat: true)),
      throwsFormatException,
    );
    expect(
      () => NrfDfuPackage.inspect(package(binName: '../application.bin')),
      throwsFormatException,
    );
  });

  test('uses the exact DFU address reported by the radio', () {
    expect(
      NrfDfuPackage.macFromStartReply('OK - mac: 44:1b:f6:69:cf:99'),
      '44:1B:F6:69:CF:99',
    );
    expect(() => NrfDfuPackage.macFromStartReply('OK'), throwsFormatException);
    expect(
      NrfDfuPackage.bootloaderAddress('EB:9D:56:B2:48:48'),
      'EB:9D:56:B2:48:49',
    );
    expect(
      NrfDfuPackage.bootloaderAddress('eb:9d:56:b2:48:ff'),
      'EB:9D:56:B2:48:00',
    );
  });

  test('valid marked exact-board application passes', () {
    NrfDfuPackage.inspect(package()).validateForBoard('Heltec T096');
  });
  test(
    'read-only application identity and base hash come from verified EndF',
    () {
      final parsed = NrfDfuPackage.inspect(package());
      expect(parsed.applicationIdentity!.hardwareId, 'Heltec_t096');
      expect(
        parsed.applicationBaseHash,
        usbSha256(testNrfApplication(marked: false)).substring(0, 16),
      );
      final old = NrfDfuPackage.inspect(
        testNrfDfuZip(image: testNrfApplication(marked: false)),
      );
      expect(old.applicationIdentity, isNull);
      expect(old.applicationBaseHash, isNull);
      final system = NrfDfuPackage.inspect(
        testNrfDfuZip(component: 'bootloader'),
      );
      expect(system.applicationIdentity, isNull);
      expect(system.applicationBaseHash, isNull);
    },
  );
  test('S140 7.3 board has its own base and SoftDevice requirement', () {
    final image = testNrfApplication(
      hardwareId: 'Xiao_nrf52',
      applicationAddress: 0x27000,
    );
    NrfDfuPackage.inspect(
      testNrfDfuZip(image: image, softdevice: 0x123),
    ).validateForBoard('Seeed Xiao-nrf52');
    expect(
      () => NrfDfuPackage.inspect(
        testNrfDfuZip(image: image),
      ).validateForBoard('Seeed Xiao-nrf52'),
      throwsFormatException,
    );
    final wrongBase = testNrfApplication(hardwareId: 'Xiao_nrf52');
    expect(
      () => NrfDfuPackage.inspect(
        testNrfDfuZip(image: wrongBase, softdevice: 0x123),
      ).validateForBoard('Seeed Xiao-nrf52'),
      throwsFormatException,
    );
  });
  test('wrong board, unknown board and unsupported chip are blocked', () {
    final parsed = NrfDfuPackage.inspect(package());
    for (final board in ['Heltec T114', 'Unknown Heltec T096', 'Xiao C3']) {
      expect(() => parsed.validateForBoard(board), throwsFormatException);
    }
  });
  test('application DAT CRC is checked before device access', () {
    expect(
      () => NrfDfuPackage.inspect(testNrfDfuZip(corruptCrc: true)),
      throwsFormatException,
    );
  });
  test('ZIP CRC corruption and expansion bombs fail before use', () {
    final corrupt = package();
    corrupt[40] ^= 1;
    expect(() => NrfDfuPackage.inspect(corrupt), throwsFormatException);
    final bomb = package();
    final fields = ByteData.sublistView(bomb);
    final central = fields.getUint32(bomb.length - 6, Endian.little);
    fields.setUint32(central + 24, 3 * 1024 * 1024, Endian.little);
    expect(() => NrfDfuPackage.inspect(bomb), throwsFormatException);
  });
  test('duplicate ZIP names fail even with coherent local headers', () {
    final bytes = package();
    final fields = ByteData.sublistView(bytes);
    var cursor = fields.getUint32(bytes.length - 6, Endian.little);
    cursor +=
        46 +
        fields.getUint16(cursor + 28, Endian.little) +
        fields.getUint16(cursor + 30, Endian.little) +
        fields.getUint16(cursor + 32, Endian.little);
    final firstName = bytes.sublist(
      cursor + 46,
      cursor + 46 + fields.getUint16(cursor + 28, Endian.little),
    );
    cursor +=
        46 +
        fields.getUint16(cursor + 28, Endian.little) +
        fields.getUint16(cursor + 30, Endian.little) +
        fields.getUint16(cursor + 32, Endian.little);
    final local = fields.getUint32(cursor + 42, Endian.little);
    bytes.setAll(cursor + 46, firstName);
    bytes.setAll(local + 30, firstName);
    expect(() => NrfDfuPackage.inspect(bytes), throwsFormatException);
  });
  test('invalid present EndF hash cannot become an old unmarked image', () {
    final image = testNrfApplication()..[50] = 1;
    expect(
      () => NrfDfuPackage.inspect(testNrfDfuZip(image: image)),
      throwsFormatException,
    );
  });
  test('system update requires the dedicated migration workflow', () {
    final parsed = NrfDfuPackage.inspect(
      testNrfDfuZip(component: 'softdevice_bootloader'),
    );
    expect(() => parsed.validateForBoard('Heltec T096'), throwsFormatException);
  });
  test('wrong SoftDevice and vector geometry are not guessed compatible', () {
    expect(
      () => NrfDfuPackage.inspect(
        testNrfDfuZip(softdevice: 0x123),
      ).validateForBoard('Heltec T096'),
      throwsFormatException,
    );
    final body = testNrfApplication(marked: false);
    ByteData.sublistView(body).setUint32(4, 0x10081, Endian.little);
    expect(
      () => NrfDfuPackage.inspect(
        testNrfDfuZip(image: testEndf(body, 'Heltec_t096')),
      ).validateForBoard('Heltec T096'),
      throwsFormatException,
    );
  });
  test(
    'unmarked legacy application requires byte-bound trusted release provenance',
    () {
      final bytes = testNrfDfuZip(image: testNrfApplication(marked: false));
      final parsed = NrfDfuPackage.inspect(bytes);
      expect(
        () => parsed.validateForBoard('Heltec T096'),
        throwsFormatException,
      );
      final proof = CompanionFirmwareProvenance(
        boardId: CompanionBoardCatalog.lookup('Heltec T096')!.id,
        sha256: usbSha256(bytes),
        profile: 'ble',
      );
      parsed.validateForBoard('Heltec T096', provenance: proof);
      expect(
        () => parsed.validateForBoard('Heltec T114', provenance: proof),
        throwsFormatException,
      );
    },
  );
}
