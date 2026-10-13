import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/companion_board_catalog.dart';
import 'package:meshcore_open/services/companion_target_catalog.dart';
import 'package:meshcore_open/services/nrf_dfu_package.dart';
import 'package:meshcore_open/services/nrf_dfu_target_catalog.dart';

import '../support/companion_firmware_test_data.dart';

void main() {
  test('exact reviewed infrastructure targets require their actual role', () {
    final board = CompanionBoardCatalog.lookup('Heltec T096')!;
    final repeater = CompanionTargetCatalog.targetIdForEnvironment(
      'Heltec_t096_repeater',
    );
    expect(NrfDfuTargetCatalog.supports(repeater, board, 'repeater'), isTrue);
    expect(
      NrfDfuTargetCatalog.supports(repeater, board, 'roomServer'),
      isFalse,
    );
    expect(
      NrfDfuTargetCatalog.supports(
        repeater,
        CompanionBoardCatalog.lookup('Heltec T114')!,
        'repeater',
      ),
      isFalse,
    );
    expect(
      NrfDfuTargetCatalog.supports(
        CompanionTargetCatalog.targetIdForEnvironment(
          'Heltec_t096_repeater_custom',
        ),
        board,
        'repeater',
        expectedTargetId: CompanionTargetCatalog.targetIdForEnvironment(
          'Heltec_t096_repeater_custom',
        ),
      ),
      isFalse,
    );
    expect(
      NrfDfuTargetCatalog.supports(0, board, 'repeater', expectedTargetId: 0),
      isFalse,
    );
  });

  test(
    'marked T096 repeater and room packages are accepted only for that role',
    () {
      for (final pair in [
        ('Heltec_t096_repeater', NrfDfuApplicationRole.repeater),
        ('Heltec_t096_room_server', NrfDfuApplicationRole.roomServer),
      ]) {
        final package = NrfDfuPackage.inspect(
          testNrfDfuZip(image: testNrfApplication(targetEnv: pair.$1)),
        );
        package.validateForBoard('Heltec T096', role: pair.$2);
        expect(
          () => package.validateForBoard('Heltec T096'),
          throwsFormatException,
        );
        expect(
          () => package.validateForBoard(
            'Heltec T096',
            role: pair.$2 == NrfDfuApplicationRole.repeater
                ? NrfDfuApplicationRole.roomServer
                : NrfDfuApplicationRole.repeater,
          ),
          throwsFormatException,
        );
        expect(
          () => package.validateForBoard('Heltec T114', role: pair.$2),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'Companion, unmarked and zero identities cannot bypass infrastructure roles',
    () {
      for (final image in [
        testNrfApplication(),
        testNrfApplication(marked: false),
        testNrfApplication(targetId: 0),
      ]) {
        final package = NrfDfuPackage.inspect(testNrfDfuZip(image: image));
        for (final role in [
          NrfDfuApplicationRole.repeater,
          NrfDfuApplicationRole.roomServer,
        ]) {
          expect(
            () => package.validateForBoard('Heltec T096', role: role),
            throwsFormatException,
          );
        }
      }
    },
  );

  test(
    'Tower base and SD roles use only their reviewed larger flash layout',
    () {
      final board = CompanionBoardCatalog.lookup('MeshTower V2 SD')!;
      const maximum = 0xc7000;
      expect(board.nrfApplicationMaxSize, lessThan(maximum));
      for (final pair in [
        ('Heltec_tower_v2_repeater', NrfDfuApplicationRole.repeater),
        (
          'Heltec_tower_v2_repeater_lora_ota_no_external_sensors',
          NrfDfuApplicationRole.repeater,
        ),
        (
          'Heltec_tower_v2_sdcard_repeater_lora_ota_no_external_sensors',
          NrfDfuApplicationRole.repeater,
        ),
        ('Heltec_tower_v2_room_server', NrfDfuApplicationRole.roomServer),
      ]) {
        final image = testNrfApplication(
          hardwareId: 'Heltec_tower_v2',
          size: maximum - 56,
          targetEnv: pair.$1,
        );
        final package = NrfDfuPackage.inspect(testNrfDfuZip(image: image));
        package.validateForBoard('MeshTower V2 SD', role: pair.$2);
        expect(
          NrfDfuTargetCatalog.applicationMaximum(
            package.applicationIdentity!.targetId,
            board,
            pair.$2.name,
          ),
          maximum,
        );
        final oversized = testNrfDfuZip(
          image: testNrfApplication(
            hardwareId: 'Heltec_tower_v2',
            size: maximum - 55,
            targetEnv: pair.$1,
          ),
        );
        expect(
          () => NrfDfuPackage.inspect(
            oversized,
          ).validateForBoard('MeshTower V2 SD', role: pair.$2),
          throwsFormatException,
        );
      }
      expect(
        NrfDfuTargetCatalog.applicationMaximum(
          CompanionTargetCatalog.targetIdForEnvironment('Heltec_t096_repeater'),
          CompanionBoardCatalog.lookup('Heltec T096')!,
          'repeater',
        ),
        isNull,
      );
    },
  );
}
