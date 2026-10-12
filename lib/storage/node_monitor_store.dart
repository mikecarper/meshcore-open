import 'dart:async';

import 'prefs_manager.dart';

/// Watchlists are local, scoped by the full Companion identity, not BLE ID.
class NodeMonitorStore {
  static const minimumIntervalSeconds = 12 * 60 * 60;
  static const defaultIntervalSeconds = minimumIntervalSeconds;
  static const intervals = [
    0,
    minimumIntervalSeconds,
    24 * 60 * 60,
    48 * 60 * 60,
  ];
  static final _key = RegExp(r'^[0-9a-f]{64}$');

  Set<String> load(String companion) => companion.isEmpty
      ? {}
      : (PrefsManager.instance.getStringList('monitor_nodes_$companion') ?? [])
            .where(_key.hasMatch)
            .toSet();

  Future<void> save(String companion, Set<String> keys) async {
    if (!_key.hasMatch(companion)) return;
    await PrefsManager.instance.setStringList(
      'monitor_nodes_$companion',
      keys.where(_key.hasMatch).toList()..sort(),
    );
  }

  int interval(String companion) {
    final value = PrefsManager.instance.getInt('monitor_interval_$companion');
    if (intervals.contains(value)) return value!;
    if (value != null && _key.hasMatch(companion)) {
      unawaited(_migrateInterval(companion));
    }
    return defaultIntervalSeconds;
  }

  Future<void> _migrateInterval(String companion) async {
    try {
      await saveInterval(companion, defaultIntervalSeconds);
    } catch (_) {
      // The validated default remains enforced even if persistence fails.
    }
  }

  Future<void> saveInterval(String companion, int seconds) async {
    if (!_key.hasMatch(companion) || !intervals.contains(seconds)) return;
    await PrefsManager.instance.setInt('monitor_interval_$companion', seconds);
  }
}
