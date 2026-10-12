import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../helpers/cayenne_lpp.dart';
import '../models/contact.dart';
import '../models/remote_node_stats.dart';
import '../storage/node_monitor_store.dart';

class NodeMonitorReading {
  RemoteNodeStats? stats;
  List<Map<String, dynamic>> telemetry = [];
  DateTime? receivedAt;
  String status = 'Not refreshed';

  int? get batteryMv {
    if (stats != null) return stats!.batteryMv > 0 ? stats!.batteryMv : null;
    for (final entry in telemetry) {
      if (entry['channel'] == 1 && entry['type'] == CayenneLpp.lppVoltage) {
        final value = entry['value'];
        if (value is num && value > 0) return (value * 1000).round();
      }
    }
    return null;
  }

  double? get temperature {
    for (final entry in telemetry) {
      if (entry['type'] == CayenneLpp.lppTemperature && entry['value'] is num) {
        return (entry['value'] as num).toDouble();
      }
    }
    return null;
  }
}

/// A dashboard owns this reader. It never logs in, changes settings, or retries.
class NodeMonitorService extends ChangeNotifier {
  NodeMonitorService(this.connector, {NodeMonitorStore? store})
    : _store = store ?? NodeMonitorStore() {
    _syncCompanion();
    connector.addListener(_onConnectorChanged);
    _frames = connector.receivedFrames.listen(_onFrame);
  }

  final MeshCoreConnector connector;
  final NodeMonitorStore _store;
  late final StreamSubscription<Uint8List> _frames;
  final Map<String, NodeMonitorReading> readings = {};
  Set<String> _selected = {};
  String companionKey = '';
  int intervalSeconds = NodeMonitorStore.defaultIntervalSeconds;
  bool busy = false;
  bool _disposed = false;
  int _epoch = 0;
  String? progress;
  Contact? _pendingContact;
  Completer<bool>? _pending;

  Set<String> get selected => Set.unmodifiable(_selected);
  List<Contact> get available =>
      connector.contacts
          .where(
            (c) =>
                c.isActive &&
                c.publicKey.length == 32 &&
                [
                  advTypeRepeater,
                  advTypeRoom,
                  advTypeChat,
                  advTypeSensor,
                ].contains(c.type),
          )
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  Contact? contact(String key) {
    final matches = available.where((c) => c.publicKeyHex == key).toList();
    return matches.length == 1 ? matches.single : null;
  }

  bool _uniquePrefix(Contact target) =>
      connector.contacts
          .where(
            (c) =>
                c.publicKey.length >= 6 &&
                c.publicKeyHex.substring(0, 12) ==
                    target.publicKeyHex.substring(0, 12),
          )
          .length ==
      1;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _syncCompanion() {
    final key = connector.selfPublicKeyHex;
    if (key.isEmpty || key == companionKey) return;
    stop();
    companionKey = key;
    readings.clear();
    _selected = _store.load(key);
    intervalSeconds = _store.interval(key);
    progress = null;
  }

  void _onConnectorChanged() {
    if (!connector.isConnected) stop();
    _syncCompanion();
    _notify();
  }

  Future<void> select(Set<String> keys) async {
    if (busy) return;
    _selected = Set.of(keys);
    readings.removeWhere((key, _) => !_selected.contains(key));
    final scope = companionKey;
    _notify();
    await _store.save(scope, _selected);
  }

  Future<void> setInterval(int seconds) async {
    if (!NodeMonitorStore.intervals.contains(seconds)) return;
    intervalSeconds = seconds;
    final scope = companionKey;
    _notify();
    await _store.saveInterval(scope, seconds);
  }

  void stop() {
    _epoch++;
    final pending = _pending;
    if (pending != null && !pending.isCompleted) pending.complete(false);
  }

  bool _valid(int epoch) =>
      !_disposed &&
      epoch == _epoch &&
      connector.isConnected &&
      connector.selfPublicKeyHex == companionKey;

  Future<void> refresh({String? only}) async {
    if (busy || !connector.isConnected || companionKey.isEmpty) return;
    final keys = only == null
        ? _selected.toList()
        : [if (_selected.contains(only)) only];
    final epoch = _epoch;
    busy = true;
    _notify();
    try {
      for (var i = 0; i < keys.length; i++) {
        if (!_valid(epoch)) break;
        final key = keys[i];
        final reading = readings.putIfAbsent(key, NodeMonitorReading.new);
        final target = contact(key);
        if (target == null || !_uniquePrefix(target)) {
          reading.status = target == null
              ? 'Contact unavailable'
              : 'Ambiguous reply prefix';
          _notify();
          continue;
        }
        progress = 'Refreshing ${target.name} (${i + 1}/${keys.length})';
        reading.status = 'Waiting for reply';
        _notify();
        try {
          final route = await connector.preparePathForContactSend(target);
          if (!_valid(epoch)) {
            reading.status = 'Refresh stopped';
            break;
          }
          final current = contact(key);
          if (current == null || !_uniquePrefix(current)) {
            reading.status = 'Contact changed - refresh again';
            continue;
          }
          final waiter = Completer<bool>();
          _pendingContact = current;
          _pending = waiter;
          final statusNode =
              current.type == advTypeRepeater || current.type == advTypeRoom;
          final timeout = math.max(
            30000,
            connector.calculateTimeout(
              pathLength: route.useFlood ? -1 : route.hopCount,
              messageBytes: maxFrameSize,
            ),
          );
          await connector.sendFrame(
            statusNode
                ? buildSendStatusRequestFrame(current.publicKey)
                : buildSendTelemetryReq(current.publicKey),
          );
          final replied = await waiter.future.timeout(
            Duration(milliseconds: timeout),
            onTimeout: () => false,
          );
          if (!replied) {
            reading.status = _valid(epoch)
                ? 'No reply - login or telemetry permission may be required'
                : 'Refresh stopped';
          }
        } catch (_) {
          reading.status = 'Request failed - reconnect or refresh again';
        } finally {
          _pending = null;
          _pendingContact = null;
          _notify();
        }
      }
    } finally {
      busy = false;
      progress = _valid(epoch) ? 'Refresh complete' : 'Refresh stopped';
      _notify();
    }
  }

  void _onFrame(Uint8List frame) {
    final target = _pendingContact;
    final waiter = _pending;
    if (_disposed ||
        target == null ||
        waiter == null ||
        waiter.isCompleted ||
        !connector.isConnected ||
        connector.selfPublicKeyHex != companionKey ||
        frame.length < 8 ||
        !_uniquePrefix(target) ||
        contact(target.publicKeyHex) == null) {
      return;
    }
    if (!listEquals(frame.sublist(2, 8), target.publicKey.take(6).toList())) {
      return;
    }
    final statusNode =
        target.type == advTypeRepeater || target.type == advTypeRoom;
    final reading = readings[target.publicKeyHex]!;
    if (statusNode && frame[0] == pushCodeStatusResponse) {
      final stats = RemoteNodeStats.tryParse(
        frame,
        isRoom: target.type == advTypeRoom,
      );
      if (stats == null) return;
      reading.stats = stats;
    } else if (!statusNode && frame[0] == pushCodeTelemetryResponse) {
      final values = CayenneLpp.parse(Uint8List.sublistView(frame, 8));
      if (values.isEmpty) return;
      reading.telemetry = values;
    } else {
      return;
    }
    reading.receivedAt = DateTime.now();
    reading.status = 'Updated';
    waiter.complete(true);
    final battery = reading.batteryMv;
    if (battery != null) {
      connector.updateRepeaterBatterySnapshot(
        target.publicKeyHex,
        battery,
        source: statusNode ? 'monitor_status' : 'monitor_telemetry',
      );
    }
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    connector.removeListener(_onConnectorChanged);
    _frames.cancel();
    super.dispose();
  }
}
