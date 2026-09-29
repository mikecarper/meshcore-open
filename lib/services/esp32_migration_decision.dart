import 'esp32_partition_catalog.dart';
import 'esp32_partition_migration_package.dart';

enum Esp32MigrationRoute { normalUpdate, bridge }

/// Choose the transport from the installed layout and the exact migration ZIP.
class Esp32MigrationDecision {
  static String _boardKey(String value) {
    var name = value.trim().toLowerCase().replaceFirst(RegExp(r'^>\s*'), '');
    name = name.replaceFirst(RegExp(r'^elecrow\s+'), '');
    name = name.replaceAll('v4.3', 'v4');
    name = name.replaceAll('t-beam', 'tbeam');
    name = name.replaceAll('wireless stick lite v3', 'wsl3');
    name = name.replaceAll('seeed xiao esp32-s3', 'xiao s3 wio');
    name = name.replaceFirst(RegExp(r'\s+oled$'), '');
    return name.replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  static String _physicalPackageBoard(String board, String role) =>
      board.replaceFirst(
        RegExp(role == 'room-server' ? r'-room-server$' : r'-repeater$'),
        '',
      );

  static bool matchesBoard({
    required String reportedBoard,
    required String packageBoard,
    required String role,
  }) =>
      _boardKey(reportedBoard) ==
      _boardKey(_physicalPackageBoard(packageBoard, role));

  static bool matchesAsset({
    required String reportedBoard,
    required String role,
    required String assetName,
  }) {
    final match = RegExp(
      r'^(.+)-v[0-9].+-migration\.zip$',
    ).firstMatch(assetName);
    if (match == null) return false;
    final board = match.group(1)!;
    if (role == 'room-server' && !board.endsWith('-room-server')) {
      return false;
    }
    if (role == 'repeater' &&
        (board.endsWith('-room-server') || board.endsWith('-sensor'))) {
      return false;
    }
    return matchesBoard(
      reportedBoard: reportedBoard,
      packageBoard: board,
      role: role,
    );
  }

  static Esp32MigrationRoute choose({
    required Esp32PartitionMigrationPackage package,
    required String reportedBoard,
    required String role,
    required Esp32PartitionAssessment currentLayout,
    required bool targetConfirmed,
  }) {
    if (package.role != role) {
      throw StateError('Migration ZIP is for ${package.role}, not $role.');
    }
    if (!targetConfirmed &&
        !matchesBoard(
          reportedBoard: reportedBoard,
          packageBoard: package.board,
          role: role,
        )) {
      throw StateError(
        'The migration ZIP board ${package.board} does not match '
        'the reported board $reportedBoard.',
      );
    }
    final liveFlash = currentLayout.flashBytes;
    if (liveFlash != null && liveFlash != package.flashBytes) {
      throw StateError(
        'The migration ZIP expects ${package.flashBytes ~/ 0x100000} MB '
        'flash, but the radio reports ${liveFlash ~/ 0x100000} MB.',
      );
    }
    return switch (currentLayout.action) {
      Esp32PartitionAction.fits => Esp32MigrationRoute.normalUpdate,
      Esp32PartitionAction.expand => Esp32MigrationRoute.bridge,
      Esp32PartitionAction.cableRequired => throw StateError(
        'This radio has no dual OTA slots. Use its exact-board cable image.',
      ),
      Esp32PartitionAction.unknown => throw StateError(
        'The current partition layout is unknown. Read the live storage '
        'layout or use an exact-board cable update before migrating.',
      ),
    };
  }
}
