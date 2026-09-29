/// The installed bootloader identity determines whether a local recovery
/// bridge is needed before the unified RAK bootloader can be installed.
class RakBootloaderMigration {
  const RakBootloaderMigration({
    required this.model,
    required this.installedName,
    required this.normalProfile,
    required this.recoveryProfile,
    required this.canSelfUpdate,
  });

  final int model;
  final String installedName;
  final String normalProfile;
  final String? recoveryProfile;
  final bool canSelfUpdate;

  bool get needsRecovery => recoveryProfile != null;

  static RakBootloaderMigration fromReplies({
    required String board,
    required String bootloader,
  }) {
    final modelMatch = RegExp(
      r'\bRAK\s*(3401|4631)\b',
      caseSensitive: false,
    ).firstMatch(board);
    if (modelMatch == null) {
      throw StateError('This is not a confirmed RAK3401 or RAK4631 board.');
    }
    final model = int.parse(modelMatch.group(1)!);
    final nameMatch = RegExp(r'\bname=([A-Za-z0-9_]+)').firstMatch(bootloader);
    if (nameMatch == null) {
      throw StateError(
        'The installed bootloader identity is unavailable. Update the '
        'repeater application to one that reports `ota bootloader`, or '
        'inspect INFO_UF2.TXT over USB before selecting recovery.',
      );
    }
    final name = nameMatch.group(1)!.toUpperCase();
    final recovery = switch ((model, name)) {
      (3401, '3401_DFU') => null,
      (3401, '3401_AUTO_DFU') => 'wiscore_rak3401_auto',
      (3401, '3401_W25Q16_DFU') => 'wiscore_rak3401_rak13302_w25q16',
      (4631, '4631_DFU') => null,
      (4631, '4631_AUTO_DFU') => 'wiscore_rak4631_auto',
      (4631, '4631_W25Q16_DFU') => 'wiscore_rak4631_w25q16',
      (4631, '4631_15001C_DFU') => 'wiscore_rak4631_board_rak15001_slot_c',
      (4631, 'GAT562_DFU') => 'gat562',
      _ => throw StateError(
        'Bootloader $name is not a known RAK$model identity. '
        'Inspect the installed image before selecting recovery.',
      ),
    };
    final abi = int.tryParse(
      RegExp(r'\babi=(\d+)').firstMatch(bootloader)?.group(1) ?? '',
    );
    final caps = int.tryParse(
      RegExp(r'\bcaps=([0-9A-Fa-f]{2})').firstMatch(bootloader)?.group(1) ?? '',
      radix: 16,
    );
    return RakBootloaderMigration(
      model: model,
      installedName: name,
      normalProfile: 'wiscore_rak${model}_auto',
      recoveryProfile: recovery,
      canSelfUpdate:
          recovery == null && (abi ?? 0) >= 3 && ((caps ?? 0) & 0x08) != 0,
    );
  }
}
