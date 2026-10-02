import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/models/path_selection.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/services/message_retry_service.dart';
import 'package:meshcore_open/services/path_history_service.dart';
import 'package:meshcore_open/services/repeater_command_service.dart';
import 'package:meshcore_open/services/storage_service.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _PathConnector extends MeshCoreConnector {
  final sent = <Uint8List>[];
  void Function(Uint8List)? onCliSend;

  @override
  bool get isConnected => true;

  @override
  Future<void> sendFrame(
    Uint8List frame, {
    String? channelSendQueueId,
    bool expectsGenericAck = false,
    bool waitForGenericAck = false,
  }) async {
    sent.add(frame);
    if (frame[0] == cmdSendTxtMsg) onCliSend?.call(frame);
  }
}

Contact _contact({
  required int hops,
  required List<int> path,
  int width = 1,
  int? override,
  List<int>? overrideBytes,
}) => Contact(
  publicKey: Uint8List.fromList(List.generate(32, (i) => i + 1)),
  name: 'RAK4631',
  type: advTypeRepeater,
  pathLength: hops,
  path: Uint8List.fromList(path),
  pathHashWidth: width,
  pathOverride: override,
  pathOverrideBytes: overrideBytes == null
      ? null
      : Uint8List.fromList(overrideBytes),
  lastSeen: DateTime.utc(2026, 10, 1),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
  });

  test(
    'automatic history can select a 2-byte route for a zero-hop contact',
    () async {
      final connector = _PathConnector();
      final settings = AppSettingsService();
      final history = PathHistoryService(StorageService());
      final retries = MessageRetryService();
      addTearDown(connector.dispose);
      addTearDown(settings.dispose);
      addTearDown(history.dispose);
      addTearDown(retries.dispose);
      await settings.updateSettings(
        settings.settings.copyWith(autoRouteRotationEnabled: true),
      );
      history.handlePathUpdated(
        _contact(hops: 1, path: [0xA1, 0xA2], width: 2),
      );
      await Future<void>.delayed(Duration.zero);
      connector.initialize(
        retryService: retries,
        pathHistoryService: history,
        appSettingsService: settings,
      );

      final selection = await connector.preparePathForContactSend(
        _contact(hops: 0, path: []),
      );

      expect(selection.useFlood, isFalse);
      expect(selection.hopCount, 1);
      expect(selection.pathBytes, [0xA1, 0xA2]);
      expect(connector.pathHashByteWidth, 1);
      expect(connector.sent.single[35], 0x41);
      expect(connector.sent.single.sublist(36, 38), [0xA1, 0xA2]);
    },
  );

  for (final width in [2, 3]) {
    test(
      'start ota preserves a learned $width-byte route in 1-byte mode',
      () async {
        final connector = _PathConnector();
        final commands = RepeaterCommandService(connector);
        addTearDown(commands.dispose);
        addTearDown(connector.dispose);
        final path = List.generate(width, (i) => 0xA0 + i);
        final target = _contact(hops: 1, path: path, width: width);
        connector.onCliSend = (frame) {
          final prefix = utf8.decode(frame.sublist(13, 16));
          commands.handleResponse(
            target,
            '${prefix}OK - mac: C3:C6:A8:FC:AD:A6',
          );
        };

        final response = await commands.sendCommand(
          target,
          'start ota',
          retries: 1,
        );

        expect(response, 'OK - mac: C3:C6:A8:FC:AD:A6');
        expect(connector.pathHashByteWidth, 1);
        expect(connector.sent.map((frame) => frame[0]), [
          cmdAddUpdateContact,
          cmdSendTxtMsg,
        ]);
        expect(connector.sent.first[35], ((width - 1) << 6) | 1);
        expect(connector.sent.first.sublist(36, 36 + width), path);
        expect(utf8.decode(connector.sent.last.sublist(16)), 'start ota\u0000');
      },
    );
  }

  test(
    'a learned 1-byte route remains usable after switching to 3-byte mode',
    () async {
      final connector = _PathConnector();
      addTearDown(connector.dispose);
      await connector.setPathHashMode(2);
      connector.sent.clear();

      await connector.preparePathForContactSend(
        _contact(hops: 1, path: [0xA1]),
      );

      expect(connector.pathHashByteWidth, 3);
      expect(connector.sent.single[35], 1);
      expect(connector.sent.single[36], 0xA1);
    },
  );

  test(
    'an explicit multi-byte route uses its own complete hop groups',
    () async {
      final connector = _PathConnector();
      addTearDown(connector.dispose);
      await connector.preparePathForContactSend(
        _contact(hops: 0, path: []),
        explicitSelection: const PathSelection(
          pathBytes: [0xA1, 0xA2, 0xB1, 0xB2],
          hopCount: 2,
          useFlood: false,
        ),
      );

      expect(connector.sent.single[35], 0x42);
      expect(connector.sent.single.sublist(36, 40), [0xA1, 0xA2, 0xB1, 0xB2]);
    },
  );

  test(
    'a saved manual route retains its width after the current mode changes',
    () async {
      final connector = _PathConnector();
      addTearDown(connector.dispose);
      await connector.preparePathForContactSend(
        _contact(hops: 0, path: [], override: 1, overrideBytes: [0xA1, 0xA2]),
      );

      expect(connector.sent.single[35], 0x41);
      expect(connector.sent.single.sublist(36, 38), [0xA1, 0xA2]);
    },
  );

  test('zero-hop direct still uses the current mode', () async {
    final connector = _PathConnector();
    addTearDown(connector.dispose);
    await connector.setPathHashMode(2);
    connector.sent.clear();

    final selection = await connector.preparePathForContactSend(
      _contact(hops: 0, path: []),
    );

    expect(selection.useFlood, isFalse);
    expect(selection.hopCount, 0);
    expect(connector.sent.single[35], 0x80);
  });

  test(
    'a malformed learned route is rejected before any frame is sent',
    () async {
      final connector = _PathConnector();
      addTearDown(connector.dispose);

      await expectLater(
        connector.preparePathForContactSend(
          _contact(hops: 1, path: [0xA1], width: 2),
        ),
        throwsArgumentError,
      );

      expect(connector.sent, isEmpty);
    },
  );

  for (final selection in [
    const PathSelection(pathBytes: [1], hopCount: 0, useFlood: false),
    const PathSelection(pathBytes: [], hopCount: 64, useFlood: false),
    const PathSelection(pathBytes: [1, 2, 3], hopCount: 2, useFlood: false),
    const PathSelection(pathBytes: [1, 2, 3, 4], hopCount: 1, useFlood: false),
    PathSelection(pathBytes: List.filled(66, 1), hopCount: 33, useFlood: false),
  ]) {
    test(
      'invalid explicit route ${selection.pathBytes.length}/${selection.hopCount} is rejected',
      () async {
        final connector = _PathConnector();
        addTearDown(connector.dispose);

        await expectLater(
          connector.preparePathForContactSend(
            _contact(hops: 0, path: []),
            explicitSelection: selection,
          ),
          throwsArgumentError,
        );

        expect(connector.sent, isEmpty);
      },
    );
  }
}
