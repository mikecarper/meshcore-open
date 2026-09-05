import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/lora_ota_bootloader_install.dart';

void main() {
  group('confirmedBootloaderInstallCommand', () {
    test('builds the explicit command only after an exact staged match', () {
      expect(
        confirmedBootloaderInstallCommand(
          status:
              'BL board=239A0029 target=D50D2D44 name=GAT562_DFU '
              'crc=12345678 abi=3 caps=0A | staged:ready mid=0e2de4b7 '
              'hash=b23ad0e2e86c38e2',
          expectedManifestId: '0E2DE4B7',
          expectedImageHashPrefix: 'B23AD0E2E86C38E2',
        ),
        'ota bootloader install 0E2DE4B7 B23AD0E2E86C38E2',
      );
    });

    test('refuses a different staged manifest or image hash', () {
      expect(
        () => confirmedBootloaderInstallCommand(
          status: 'staged:ready mid=FFFFFFFF hash=B23AD0E2E86C38E2',
          expectedManifestId: '0E2DE4B7',
          expectedImageHashPrefix: 'B23AD0E2E86C38E2',
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        () => confirmedBootloaderInstallCommand(
          status: 'staged:ready mid=0E2DE4B7 hash=0000000000000000',
          expectedManifestId: '0E2DE4B7',
          expectedImageHashPrefix: 'B23AD0E2E86C38E2',
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('refuses missing or incomplete staged confirmation', () {
      for (final status in <String>[
        'staged:none mid=- hash=-',
        'Bootloader update unavailable',
        'staged:ready mid=0E2DE4B7 hash=B23AD0E2',
      ]) {
        expect(
          () => confirmedBootloaderInstallCommand(
            status: status,
            expectedManifestId: '0E2DE4B7',
            expectedImageHashPrefix: 'B23AD0E2E86C38E2',
          ),
          throwsA(isA<StateError>()),
        );
      }
    });
  });
}
