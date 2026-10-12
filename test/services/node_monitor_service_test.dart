import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/services/node_monitor_service.dart';
import 'package:meshcore_open/storage/node_monitor_store.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firmware_controls_test.dart' show ControlTestConnector;
import 'repeater_filter_batch_test.dart' show batchContact;

class MonitorTestConnector extends ControlTestConnector {
  final List<Contact> nodes = [
    batchContact(42, 'Alpha repeater'),
    batchContact(43, 'Bravo room', type: advTypeRoom),
    batchContact(44, 'Charlie chat', type: advTypeChat),
    batchContact(45, 'Delta sensor', type: advTypeSensor),
  ];
  void Function(Uint8List)? onSend;
  MonitorTestConnector() {
    identity = 'aa' * 32;
  }
  @override
  List<Contact> get contacts => nodes;
  @override
  Future<void> sendFrame(
    Uint8List frame, {
    String? channelSendQueueId,
    bool expectsGenericAck = false,
    bool waitForGenericAck = false,
  }) async {
    sentFrames.add(frame);
    onSend?.call(frame);
  }

  void status(int index, {int battery = 4140}) =>
      frames.add(monitorStatus(nodes[index], battery: battery));
  void change({String? key, bool? connection}) {
    if (key != null) identity = key;
    if (connection != null) connected = connection;
    notifyListeners();
  }
}

Uint8List monitorStatus(Contact contact, {int battery = 4140}) {
  final frame = Uint8List(64);
  frame[0] = pushCodeStatusResponse;
  frame.setRange(2, 8, contact.publicKey.take(6));
  final data = ByteData.sublistView(frame, 8);
  data.setUint16(0, battery, Endian.little);
  data.setInt16(6, -87, Endian.little);
  data.setUint32(8, 1234, Endian.little);
  data.setUint32(12, 567, Endian.little);
  data.setUint32(20, 90000, Endian.little);
  data.setInt16(42, 47, Endian.little);
  return frame;
}

Future<void> monitorPrefs() async {
  SharedPreferences.setMockInitialValues({});
  PrefsManager.reset();
  await PrefsManager.initialize();
}

void main() {
  late MonitorTestConnector c;
  late NodeMonitorService monitor;
  setUp(() async {
    await monitorPrefs();
    c = MonitorTestConnector();
    monitor = NodeMonitorService(c);
  });
  tearDown(() {
    monitor.dispose();
    c.dispose();
  });

  test('watchlist and intervals persist by full Companion identity', () async {
    await monitor.select({c.nodes[0].publicKeyHex});
    await monitor.setInterval(86400);
    final store = NodeMonitorStore();
    expect(store.load(c.identity), {c.nodes[0].publicKeyHex});
    c.change(key: 'bb' * 32);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(monitor.selected, isEmpty);
    expect(monitor.intervalSeconds, 43200);
    c.change(key: 'aa' * 32);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(monitor.selected, {c.nodes[0].publicKeyHex});
    expect(monitor.intervalSeconds, 86400);
    await monitor.setInterval(1);
    expect(monitor.intervalSeconds, 86400);
  });

  test('old short refresh intervals migrate to twelve hours', () async {
    final store = NodeMonitorStore();
    final key = 'monitor_interval_${c.identity}';
    for (final old in [300, 900, 1800, 43199]) {
      await PrefsManager.instance.setInt(key, old);
      expect(store.interval(c.identity), 43200);
      expect(PrefsManager.instance.getInt(key), 43200);
    }
    await store.saveInterval(c.identity, 0);
    expect(store.interval(c.identity), 0);
    await store.saveInterval(c.identity, 172800);
    expect(store.interval(c.identity), 172800);
  });

  test(
    'automatic intervals below twelve hours are rejected centrally',
    () async {
      for (final interval in [1, 300, 900, 1800, 43199, -1]) {
        await monitor.setInterval(interval);
        expect(monitor.intervalSeconds, 43200);
      }
    },
  );

  test('only selected node is read; no settings commands or login', () async {
    await monitor.select({c.nodes[0].publicKeyHex});
    c.onSend = (_) => c.status(0);
    await monitor.refresh();
    expect(
      c.sentFrames.single,
      buildSendStatusRequestFrame(c.nodes[0].publicKey),
    );
    final reading = monitor.readings[c.nodes[0].publicKeyHex]!;
    expect(reading.status, 'Updated');
    expect(reading.batteryMv, 4140);
    expect(reading.stats!.lastSnr, 11.75);
    expect(reading.receivedAt, isNotNull);
  });

  test('room and repeater requests run sequentially', () async {
    await monitor.select({c.nodes[0].publicKeyHex, c.nodes[1].publicKeyHex});
    final future = monitor.refresh();
    await Future<void>.delayed(Duration.zero);
    expect(c.sentFrames.length, 1);
    c.status(0);
    await Future<void>.delayed(Duration.zero);
    expect(c.sentFrames.length, 2);
    c.status(1);
    await future;
    expect(monitor.readings.values.every((r) => r.status == 'Updated'), true);
  });

  test(
    'chat and sensor requests use telemetry; wrong node and response ignored',
    () async {
      await monitor.select({c.nodes[2].publicKeyHex, c.nodes[3].publicKeyHex});
      c.onSend = (frame) {
        final node = c.nodes.firstWhere((n) => n.publicKey[0] == frame[4]);
        c.status(0);
        c.frames.add(
          Uint8List.fromList([
            pushCodeTelemetryResponse,
            0,
            ...node.publicKey.take(6),
            1,
            116,
            1,
            158,
            2,
            103,
            0,
            215,
          ]),
        );
      };
      await monitor.refresh();
      expect(c.sentFrames.map((f) => f[0]), [
        cmdSendTelemetryReq,
        cmdSendTelemetryReq,
      ]);
      expect(monitor.readings.values.every((r) => r.batteryMv == 4140), true);
      expect(monitor.readings.values.every((r) => r.temperature == 21.5), true);
    },
  );

  test('zero battery voltage is not shown', () async {
    await monitor.select({c.nodes[0].publicKeyHex});
    c.onSend = (_) => c.status(0, battery: 0);
    await monitor.refresh();
    expect(monitor.readings.values.single.batteryMv, isNull);
  });

  test('removed contacts and colliding prefixes are not queried', () async {
    await monitor.select({c.nodes[0].publicKeyHex, c.nodes[1].publicKeyHex});
    final key = Uint8List.fromList(c.nodes[0].publicKey)..[31] = 99;
    c.nodes.add(c.nodes[0].copyWith(publicKey: key));
    c.nodes.removeAt(1);
    await monitor.refresh();
    expect(c.sentFrames, isEmpty);
    expect(
      monitor.readings.values.map((r) => r.status),
      containsAll(['Contact unavailable', 'Ambiguous reply prefix']),
    );
  });

  testWidgets('timeout keeps older reading, continues, and never retries', (
    tester,
  ) async {
    await monitor.select({c.nodes[0].publicKeyHex});
    c.onSend = (_) => c.status(0);
    await monitor.refresh();
    final received = monitor.readings.values.single.receivedAt;
    await monitor.select({c.nodes[0].publicKeyHex, c.nodes[1].publicKeyHex});
    c.onSend = (frame) {
      if (frame[1] == 43) c.status(1);
    };
    final future = monitor.refresh();
    await tester.pump();
    await tester.pump(const Duration(seconds: 31));
    await future;
    expect(c.sentFrames.length, 3);
    expect(monitor.readings[c.nodes[0].publicKeyHex]!.receivedAt, received);
    expect(
      monitor.readings[c.nodes[0].publicKeyHex]!.status,
      startsWith('No reply'),
    );
    expect(monitor.readings[c.nodes[1].publicKeyHex]!.status, 'Updated');
  });

  test('stop refresh skips remaining nodes and rejects late data', () async {
    await monitor.select({c.nodes[0].publicKeyHex, c.nodes[1].publicKeyHex});
    final future = monitor.refresh();
    await Future<void>.delayed(Duration.zero);
    monitor.stop();
    c.status(0);
    await future;
    expect(c.sentFrames.length, 1);
    expect(monitor.readings.values.single.receivedAt, isNull);
    expect(monitor.busy, false);
  });

  test('switch Companion or disconnect cancels in-flight refresh', () async {
    await monitor.select({c.nodes[0].publicKeyHex, c.nodes[1].publicKeyHex});
    final future = monitor.refresh();
    await Future<void>.delayed(Duration.zero);
    c.change(key: 'cc' * 32);
    c.status(0);
    await future;
    expect(c.sentFrames.length, 1);
    expect(monitor.readings, isEmpty);
    expect(monitor.selected, isEmpty);
    await monitor.select({c.nodes[0].publicKeyHex});
    final next = monitor.refresh();
    await Future<void>.delayed(Duration.zero);
    c.change(connection: false);
    await next;
    expect(monitor.readings.values.single.status, 'Refresh stopped');
  });
}
