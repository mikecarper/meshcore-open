import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/models/path_selection.dart';
import 'package:meshcore_open/screens/esp32_wifi_ota_screen.dart';
import 'package:meshcore_open/screens/companion_update_screen.dart';
import 'package:meshcore_open/services/esp32_partition_catalog.dart';
import 'package:meshcore_open/services/repeater_command_service.dart';
import 'package:provider/provider.dart';

const _layout =
    '> int:esp32=4096K ext:none; '
    'nvs@0x9000+20K,otadata@0xE000+8K,'
    'app0*@0x10000+1280K,app1@0x150000+1280K,spiffs@0x290000+1472K';

XFile _image(int size) => XFile.fromData(
  Uint8List(size)
    ..[0] = 0xe9
    ..[1] = 2,
  name: 'Heltec_v3-application.bin',
  path: 'Heltec_v3-application.bin',
);

class _Commands extends RepeaterCommandService {
  _Commands(super.connector, {this.storage = _layout});
  final String storage;
  final calls = <String>[];

  @override
  Future<String> sendCommand(
    Contact repeater,
    String command, {
    Function(String)? onResponse,
    Function(int)? onAttempt,
    void Function()? onPacketSent,
    PathSelection? pathSelection,
    int retries = 5,
    int minimumTimeoutMs = 0,
    bool raw = false,
  }) async {
    calls.add(command);
    return switch (command) {
      'board' => 'Heltec V3',
      'ver' => 'v1.17.1-d929643 (Build: today)',
      'get storage.layout' => storage,
      'start ota' => 'Started: http://192.168.4.1/update',
      _ => throw StateError('Unexpected command: $command'),
    };
  }
}

class _Companion extends MeshCoreConnector {
  final calls = <String>[];
  @override
  bool get isConnected => true;
  @override
  Future<String> executeLocalCliCommand(
    String command, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    calls.add(command);
    return switch (command) {
      'board' => 'Heltec V3',
      'version' => 'Companion v1.17.1-d929643 (protocol 14, build today)',
      'get storage.layout' => _layout,
      _ => throw StateError('Unexpected command: $command'),
    };
  }
}

void main() {
  for (final useCatalog in [false, true]) {
    testWidgets(
      'remote oversized image blocks start via ${useCatalog ? 'LUT' : 'live'}',
      (tester) async {
        await tester.runAsync(Esp32PartitionCatalog.load);
        final connector = MeshCoreConnector();
        addTearDown(connector.dispose);
        final commands = _Commands(
          connector,
          storage: useCatalog ? 'Unknown command' : _layout,
        );
        var size = 4000000;
        final target = Contact(
          publicKey: Uint8List(32),
          name: 'Test target',
          type: advTypeRepeater,
          pathLength: 0,
          path: Uint8List(0),
          lastSeen: DateTime(2026),
        );
        await tester.pumpWidget(
          ChangeNotifierProvider<MeshCoreConnector>.value(
            value: connector,
            child: MaterialApp(
              home: Esp32WifiOtaScreen(
                repeater: target,
                commandService: commands,
                pickApplication: () async => _image(size),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Choose application .bin'));
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => tester.tap(find.text('Start updater on radio')),
        );
        await tester.pumpAndSettle();
        expect(commands.calls, ['board', 'ver', 'get storage.layout']);
        expect(
          find.textContaining('Partition expansion is needed'),
          findsWidgets,
        );
        expect(
          tester
              .widget<ExpansionTile>(find.byType(ExpansionTile))
              .initiallyExpanded,
          isTrue,
        );
        expect(find.text('Upload and reboot'), findsNothing);

        // Changing files invalidates both the result and any old endpoint.
        size = 2048;
        await tester.ensureVisible(find.text('Choose application .bin'));
        await tester.tap(find.text('Choose application .bin'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Partition expansion is needed'),
          findsNothing,
        );
        await tester.runAsync(
          () => tester.tap(find.text('Start updater on radio')),
        );
        await tester.pumpAndSettle();
        expect(commands.calls.last, 'start ota');
        expect(find.textContaining('The selected image fits'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('Companion blocks a too-large image before enabling Wi-Fi', (
    tester,
  ) async {
    final connector = _Companion();
    addTearDown(connector.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<MeshCoreConnector>.value(
        value: connector,
        child: MaterialApp(
          home: CompanionUpdateScreen(
            pickFirmware: () async => _image(2000000),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Use a firmware file'));
    await tester.tap(find.text('Use a firmware file'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Browse files'));
    await tester.tap(find.text('Browse files'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Start Wi-Fi updater'));
    await tester.tap(find.text('Start Wi-Fi updater'));
    await tester.pumpAndSettle();
    expect(connector.calls, ['board', 'version', 'get storage.layout']);
    expect(
      find.textContaining('image exceeds the Companion OTA slot'),
      findsWidgets,
    );
    expect(find.text('Upload firmware'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
