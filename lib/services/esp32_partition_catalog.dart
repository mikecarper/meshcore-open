import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum Esp32PartitionSource { device, releaseCatalog, unknown }

enum Esp32PartitionAction { fits, expand, cableRequired, unknown }

class Esp32PartitionAssessment {
  const Esp32PartitionAssessment({
    required this.source,
    required this.action,
    this.slotBytes,
    this.detail = '',
  });

  final Esp32PartitionSource source;
  final Esp32PartitionAction action;
  final int? slotBytes;
  final String detail;

  bool get blocksUpload =>
      action == Esp32PartitionAction.expand ||
      action == Esp32PartitionAction.cableRequired;

  String get message {
    final capacity = slotBytes == null
        ? ''
        : ' OTA slot: ${(slotBytes! / 1024).floor()} KB.';
    final result = switch (action) {
      Esp32PartitionAction.fits => 'The selected image fits.$capacity',
      Esp32PartitionAction.expand =>
        'Partition expansion is needed before this image can be installed.'
            '$capacity Use an exact-board two-step migration ZIP below.',
      Esp32PartitionAction.cableRequired =>
        'This layout has no dual OTA slots. A cable installation is required; '
            'do not send a migration bridge through this updater.',
      Esp32PartitionAction.unknown =>
        'Partition capacity could not be determined. Expansion cannot be '
            'chosen automatically. The radio updater must check image size.',
    };
    final origin = switch (source) {
      Esp32PartitionSource.device => 'Read from the radio.',
      Esp32PartitionSource.releaseCatalog =>
        'Estimated from published board/version images. Earlier OTA updates '
            'can leave a different partition table installed.',
      Esp32PartitionSource.unknown => detail,
    };
    return '$result $origin';
  }
}

/// Offline snapshot of the canonical LUT in mikecarper/MeshCore. A release
/// version describes a factory image, never proves a device's current layout.
/// The migration bridge must still validate the real table before rewriting it.
class Esp32PartitionCatalog {
  Esp32PartitionCatalog.fromJson(Map<String, dynamic> json)
    : _builds = List<Map<String, dynamic>>.from(json['builds'] as List),
      _layouts = Map<String, dynamic>.from(json['layouts'] as Map) {
    if (json['schema'] != 1) {
      throw const FormatException('Unsupported partition catalog schema.');
    }
  }

  final List<Map<String, dynamic>> _builds;
  final Map<String, dynamic> _layouts;
  static Future<Esp32PartitionCatalog>? _bundled;

  static Future<Esp32PartitionCatalog> load() => _bundled ??= rootBundle
      .loadString('assets/firmware/esp32_partition_catalog.json')
      .then((text) => compute(_decodeCatalog, text));

  static String _boardKey(String value) =>
      value.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

  /// Ignore only presentation wrappers, not version/profile suffixes. In
  /// particular 1.17.1, 1.17.1.6 and PowerSaving17.1.3 are different versions.
  static String versionKey(String value) {
    var result = value.trim().toLowerCase();
    result = result.replaceFirst(RegExp(r'^>\s*'), '');
    result = result.replaceFirst(RegExp(r'^companion\s+'), '');
    result = result.split(RegExp(r'\s*\((?:build:|protocol\s)')).first.trim();
    if (RegExp(r'^v\d').hasMatch(result)) result = result.substring(1);
    return result;
  }

  static Esp32PartitionAssessment? fromDevice(String reply, int imageBytes) {
    final header = RegExp(r'int:esp32=(\d+)K ext:none;\s*').firstMatch(reply);
    if (header == null) return null;
    final flashKib = int.tryParse(header.group(1)!);
    if (flashKib == null || flashKib < 512 || flashKib > 16384) return null;
    final flash = flashKib * 1024;
    final matches = RegExp(
      r'(?:^|,)\s*([A-Za-z0-9_]+)\*?@0x([0-9a-fA-F]+)\+(\d+)K(?=,|$)',
    ).allMatches(reply.substring(header.end).trim());
    final slots = <String, int>{};
    final regions = <(int, int)>[];
    var filesystem = false;
    var otaData = false;
    for (final match in matches) {
      final name = match.group(1)!;
      final start = int.tryParse(match.group(2)!, radix: 16);
      final sizeKib = int.tryParse(match.group(3)!);
      if (start == null || sizeKib == null || sizeKib <= 0 || sizeKib > 16384) {
        return null;
      }
      final size = sizeKib * 1024;
      if (start < 0x9000 || start > flash || start + size > flash) return null;
      if (regions.any((r) => start < r.$2 && start + size > r.$1)) {
        return null;
      }
      regions.add((start, start + size));
      if (name == 'otadata' && size >= 0x2000) otaData = true;
      if (name == 'spiffs' || name == 'ffat') filesystem = true;
      if (RegExp(r'^(app[01]|ota_[01])$').hasMatch(name)) {
        if (start % 0x10000 != 0 || slots.containsKey(name)) return null;
        slots[name] = size;
      }
    }
    if (slots.length == 1 &&
        filesystem &&
        !reply.substring(header.end).contains('...') &&
        matches.length ==
            reply.substring(header.end).trim().split(',').length) {
      return const Esp32PartitionAssessment(
        source: Esp32PartitionSource.device,
        action: Esp32PartitionAction.cableRequired,
      );
    }
    // A bounded CLI reply can be truncated. Missing slots do NOT prove that
    // there is no OTA partition. Try the version catalog instead.
    final pair = slots.containsKey('app0') && slots.containsKey('app1')
        ? ['app0', 'app1']
        : ['ota_0', 'ota_1'];
    if (!otaData || pair.any((name) => !slots.containsKey(name))) return null;
    final capacity = slots[pair[0]]! < slots[pair[1]]!
        ? slots[pair[0]]!
        : slots[pair[1]]!;
    return _assessment(Esp32PartitionSource.device, capacity, imageBytes);
  }

  Esp32PartitionAssessment assess({
    required String board,
    required String version,
    required String role,
    required int imageBytes,
    String? storageReply,
  }) {
    if (storageReply != null) {
      final live = fromDevice(storageReply, imageBytes);
      if (live != null) return live;
    }
    final boardKey = _boardKey(board);
    final boards = <String>{boardKey};
    // These are display names used by HeltecV4Board. Keep R8 candidates too:
    // its manufacturer string does not identify flash/RAM configuration.
    if (boardKey == 'heltecv4oled' || boardKey == 'heltecv4') {
      boards.addAll(['heltecv4', 'heltecv4r8']);
    } else if (boardKey == 'heltecv43oled') {
      boards.add('heltecv43');
    } else if (boardKey == 'heltecv4tft') {
      boards.add('heltecv4r8tft');
    } else if (boardKey == 'xiaos3wio') {
      boards.add('xiaos3');
    } else if (boardKey == 'heltecwirelesssticklitev3') {
      boards.addAll(['heltecwsl3', 'heltecwslv3']);
    }
    final key = versionKey(version);
    final baseKey = key.replaceFirst(RegExp(r'-[0-9a-f]{7,40}$'), '');
    final boardCandidates = _builds
        .where(
          (build) =>
              boards.contains(_boardKey(build['board'] as String)) &&
              ((build['role'] == role) ||
                  (build['role'] as String).startsWith('${role}_')),
        )
        .toList();
    final exactBuilds = boardCandidates
        .where(
          (build) =>
              build['buildVersion'] is String &&
              versionKey(build['buildVersion'] as String) == key,
        )
        .toList();
    final candidates = key != baseKey && exactBuilds.isNotEmpty
        ? exactBuilds
        : boardCandidates.where(
            (build) => versionKey(build['version'] as String) == baseKey,
          );
    final capacities = <int?>{};
    for (final build in candidates) {
      final layout = _layouts[build['layout']];
      if (layout is! Map || layout['dualOta'] is! bool) return _unknown;
      final slot = layout['slotBytes'];
      if (layout['dualOta'] == false && slot == null) {
        capacities.add(null);
      } else if (layout['dualOta'] == true &&
          slot is int &&
          slot > 0 &&
          slot <= 0x1000000) {
        capacities.add(slot);
      } else {
        return _unknown;
      }
    }
    if (capacities.isEmpty) return _unknown;
    if (capacities.length != 1) {
      // Different layouts are usable only when every candidate agrees about
      // this image. Never select a convenient profile to make an image fit.
      if (!capacities.contains(null)) {
        final sizes = capacities.cast<int>().toList()..sort();
        if (imageBytes <= sizes.first || imageBytes > sizes.last) {
          return _assessment(
            Esp32PartitionSource.releaseCatalog,
            imageBytes <= sizes.first ? sizes.first : sizes.last,
            imageBytes,
          );
        }
      }
      return const Esp32PartitionAssessment(
        source: Esp32PartitionSource.unknown,
        action: Esp32PartitionAction.unknown,
        detail:
            'Published builds of this board/version have different layouts.',
      );
    }
    final capacity = capacities.single;
    if (capacity == null) {
      return const Esp32PartitionAssessment(
        source: Esp32PartitionSource.releaseCatalog,
        action: Esp32PartitionAction.cableRequired,
      );
    }
    return _assessment(
      Esp32PartitionSource.releaseCatalog,
      capacity,
      imageBytes,
    );
  }

  static const _unknown = Esp32PartitionAssessment(
    source: Esp32PartitionSource.unknown,
    action: Esp32PartitionAction.unknown,
    detail: 'No exact board/version match in the bundled release catalog.',
  );

  static Esp32PartitionAssessment _assessment(
    Esp32PartitionSource source,
    int capacity,
    int imageBytes,
  ) => Esp32PartitionAssessment(
    source: source,
    action: imageBytes <= capacity
        ? Esp32PartitionAction.fits
        : Esp32PartitionAction.expand,
    slotBytes: capacity,
  );

  /// Firmware that does not implement the diagnostic can time out or return
  /// an error string. Both cases transparently fall back to the offline LUT.
  static Future<Esp32PartitionAssessment> check({
    required Future<String> Function() readStorage,
    required String board,
    required String version,
    required String role,
    required int imageBytes,
  }) async {
    String? reply;
    try {
      reply = await readStorage();
    } catch (_) {
      // Expected on older releases; no CLI interaction is needed from users.
    }
    final live = reply == null ? null : fromDevice(reply, imageBytes);
    if (live != null) return live;
    try {
      return (await load()).assess(
        board: board,
        version: version,
        role: role,
        imageBytes: imageBytes,
      );
    } catch (_) {
      return _unknown;
    }
  }
}

Esp32PartitionCatalog _decodeCatalog(String text) =>
    Esp32PartitionCatalog.fromJson(jsonDecode(text));
