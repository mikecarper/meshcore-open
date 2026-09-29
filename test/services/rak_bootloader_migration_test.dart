import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/rak_bootloader_migration.dart';

void main() {
  const identities = <(String, String, String?)>[
    ('RAK 3401', '3401_DFU', null),
    ('RAK 3401', '3401_AUTO_DFU', 'wiscore_rak3401_auto'),
    ('RAK 3401', '3401_W25Q16_DFU', 'wiscore_rak3401_rak13302_w25q16'),
    ('RAK 4631', '4631_DFU', null),
    ('RAK 4631', '4631_AUTO_DFU', 'wiscore_rak4631_auto'),
    ('RAK 4631', '4631_W25Q16_DFU', 'wiscore_rak4631_w25q16'),
    ('RAK 4631', '4631_15001C_DFU', 'wiscore_rak4631_board_rak15001_slot_c'),
    ('RAK 4631', 'GAT562_DFU', 'gat562'),
  ];

  for (final (board, name, profile) in identities) {
    test('routes $board $name by installed identity', () {
      final plan = RakBootloaderMigration.fromReplies(
        board: board,
        bootloader: 'BL target=23818A80 name=$name abi=3 caps=0A',
      );
      expect(plan.installedName, name);
      expect(plan.recoveryProfile, profile);
      expect(plan.needsRecovery, profile != null);
      expect(plan.normalProfile, 'wiscore_rak${plan.model}_auto');
      expect(plan.canSelfUpdate, profile == null);
    });
  }

  test('refuses wrong model and unavailable installed identity', () {
    expect(
      () => RakBootloaderMigration.fromReplies(
        board: 'RAK 3401',
        bootloader: 'BL name=4631_AUTO_DFU abi=2 caps=02',
      ),
      throwsStateError,
    );
    expect(
      () => RakBootloaderMigration.fromReplies(
        board: 'RAK 4631',
        bootloader: 'LoRa OTA is not included in this build',
      ),
      throwsStateError,
    );
  });

  test('standard identity without format-3 apply uses local DFU directly', () {
    final plan = RakBootloaderMigration.fromReplies(
      board: 'RAK4631',
      bootloader: 'BL name=4631_DFU abi=2 caps=02',
    );
    expect(plan.needsRecovery, isFalse);
    expect(plan.canSelfUpdate, isFalse);
  });
}
