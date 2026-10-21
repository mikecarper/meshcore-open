import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/screens/companion_update_screen.dart';
import 'package:meshcore_open/services/nrf_dfu_recovery.dart';
import 'package:meshcore_open/theme/mesh_theme.dart';
import 'package:meshcore_open/widgets/update_status_card.dart';
import 'package:provider/provider.dart';

class _CompanionConnector extends MeshCoreConnector {
  _CompanionConnector({this.connected = true, this.board = 'Heltec V4.3 OLED'});

  bool connected;
  final String board;
  String address = 'EB:9D:56:B2:48:48';
  final events = <String>[];

  @override
  bool get isConnected => connected;

  @override
  String get deviceIdLabel => address;

  @override
  String get selfPublicKeyHex => address;

  @override
  MeshCoreTransportType get activeTransport => MeshCoreTransportType.bluetooth;

  @override
  Future<void> stopScan() async {
    events.add('stop scan');
  }

  @override
  Future<void> disconnect({
    bool manual = true,
    bool skipBleDeviceDisconnect = false,
  }) async {
    events.add('disconnect/$manual');
    connected = false;
    notifyListeners();
  }

  @override
  Future<String> executeLocalCliCommand(
    String command, {
    Duration timeout = const Duration(seconds: 8),
  }) async => command == 'board'
      ? board
      : 'v1.17.1.8-halo-keymind-cascade-dev-d4b3bb56';
}

Future<void> _loadDfuScreen(
  WidgetTester tester,
  _CompanionConnector connector,
  NrfDfuRecovery recovery,
) async {
  final directory = (await tester.runAsync(
    () => Directory.systemTemp.createTemp('companion-dfu-test-'),
  ))!;
  addTearDown(
    () => tester.runAsync(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    }),
  );
  const provider = MethodChannel('plugins.flutter.io/path_provider');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    provider,
    (_) async => directory.path,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      provider,
      null,
    ),
  );
  final archive = Archive()
    ..add(
      ArchiveFile.bytes(
        'manifest.json',
        utf8.encode(
          jsonEncode({
            'manifest': {
              'application': {
                'bin_file': 'application.bin',
                'dat_file': 'application.dat',
              },
            },
          }),
        ),
      ),
    )
    ..add(ArchiveFile.bytes('application.bin', List<int>.filled(1024, 0x55)))
    ..add(ArchiveFile.bytes('application.dat', List<int>.filled(32, 0x33)));
  final zip = XFile.fromData(
    Uint8List.fromList(ZipEncoder().encode(archive)),
    path: 'T096_companion.zip',
  );
  await tester.pumpWidget(
    ChangeNotifierProvider<MeshCoreConnector>.value(
      value: connector,
      child: MaterialApp(
        home: CompanionUpdateScreen(
          pickFirmware: () async => zip,
          dfuRecovery: recovery,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(
    find.textContaining('Nordic DFU .zip - Bluetooth update'),
    findsWidgets,
  );
  expect(find.textContaining('ESP32 application .bin'), findsNothing);
  await tester.tap(find.text('Use a firmware file'));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('Browse files'));
  await tester.pumpAndSettle();
  final browse = tester.widget<TextButton>(
    find.ancestor(
      of: find.text('Browse files'),
      matching: find.byWidgetPredicate((widget) => widget is TextButton),
    ),
  );
  // This fixture copies a real ZIP. Await its callback in real async time;
  // a wall-clock polling budget flakes under concurrent full-suite builds.
  final choose = browse.onPressed! as Future<void> Function();
  await tester.runAsync(choose);
  await tester.pumpAndSettle();
  expect(find.text('Update over Bluetooth'), findsOneWidget);
}

Future<void> _tapDfu(WidgetTester tester, String label) async {
  if (find.text(label).evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      find.text(label),
      150,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await tester.ensureVisible(find.text(label));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'T096 timeout recovers at bootloader address after releasing Companion',
    (tester) async {
      final connector = _CompanionConnector(board: 'Heltec T096');
      addTearDown(connector.dispose);
      var scans = 0, transfers = 0;
      final recovery = NrfDfuRecovery(
        probe: (_, _) async => true,
        scan: (addresses, _) async {
          connector.events.add('DFU scan');
          expect(addresses, ['EB:9D:56:B2:48:48', 'EB:9D:56:B2:48:49']);
          scans++;
          return scans == 1
              ? []
              : [
                  const DfuAdvertisement('EB:9D:56:B2:48:49', 'T096_DFU', [
                    legacyDfuServiceUuid,
                  ]),
                ];
        },
        wait: (_) async {},
        transfer: (address, _, force, _) async {
          connector.events.add('DFU transfer');
          transfers++;
          if (transfers == 1) {
            expect(force, isFalse);
            throw PlatformException(code: '8', message: 'GATT CONN TIMEOUT');
          }
          expect(address, 'EB:9D:56:B2:48:49');
          expect(force, isTrue);
        },
      );
      await _loadDfuScreen(tester, connector, recovery);
      await _tapDfu(tester, 'Update over Bluetooth');
      expect(connector.events, isEmpty);
      await tester.tap(find.text('Update'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(connector.events.take(2), ['stop scan', 'disconnect/true']);
      expect(transfers, 2);
      expect(connector.preserveUpdateScreenOnDisconnect, isTrue);
      final card = tester.widget<UpdateStatusCard>(
        find.byType(UpdateStatusCard),
      );
      expect(card.isError, isFalse);
      expect(card.progress, 100);
      expect(card.message, contains('check its version'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      expect(connector.preserveUpdateScreenOnDisconnect, isFalse);
    },
  );

  testWidgets(
    'manual bootloader retry freshly discovers the same T096 and fits the small phone',
    (tester) async {
      tester.view.physicalSize = const Size(480, 854);
      tester.view.devicePixelRatio = 1.5;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final connector = _CompanionConnector(board: 'Heltec T096');
      addTearDown(connector.dispose);
      var inBootloader = false, calls = 0;
      final recovery = NrfDfuRecovery(
        probe: (_, _) async => true,
        scan: (_, _) async => inBootloader
            ? [
                const DfuAdvertisement('EB:9D:56:B2:48:49', 'T096_DFU', [
                  legacyDfuServiceUuid,
                ]),
              ]
            : [],
        wait: (_) async {},
        transfer: (address, _, force, _) async {
          calls++;
          if (!inBootloader) throw PlatformException(code: '8');
          expect(address, 'EB:9D:56:B2:48:49');
          expect(force, isTrue);
        },
      );
      await _loadDfuScreen(tester, connector, recovery);
      await _tapDfu(tester, 'Update over Bluetooth');
      await tester.tap(find.text('Update'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      var card = tester.widget<UpdateStatusCard>(find.byType(UpdateStatusCard));
      expect(card.isError, isTrue);
      expect(card.progress, isNull);
      expect(card.message, contains('enter BT OTA mode'));
      expect(calls, 1);
      expect(tester.takeException(), isNull);
      inBootloader = true;
      await _tapDfu(tester, 'Retry bootloader');
      await tester.tap(find.text('Update'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      card = tester.widget<UpdateStatusCard>(find.byType(UpdateStatusCard));
      expect(card.isError, isFalse);
      expect(card.progress, 100);
      expect(calls, 2);
      expect(
        connector.events.where((s) => s == 'disconnect/true'),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final change in [false, true]) {
    testWidgets(
      change
          ? 'changing Companion during confirmation blocks DFU'
          : 'canceling confirmation never disconnects or starts DFU',
      (tester) async {
        final connector = _CompanionConnector(board: 'Heltec T096');
        addTearDown(connector.dispose);
        final recovery = NrfDfuRecovery(
          probe: (_, _) async => true,
          scan: (_, _) async => throw StateError('Must not scan'),
          transfer: (_, _, _, _) async => fail('Must not send firmware'),
        );
        await _loadDfuScreen(tester, connector, recovery);
        await _tapDfu(tester, 'Update over Bluetooth');
        if (change) connector.address = 'AA:BB:CC:DD:EE:01';
        await tester.tap(find.text(change ? 'Update' : 'Cancel'));
        await tester.pumpAndSettle();
        expect(connector.events, isEmpty);
        expect(connector.connected, isTrue);
        if (change) {
          expect(
            find.textContaining('Connection changed during confirmation'),
            findsOneWidget,
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final dark in [false, true]) {
    testWidgets(
      'firmware workflow fits API 22 phone, ${dark ? 'dark' : 'light'}',
      (tester) async {
        tester.view.physicalSize = const Size(480, 854);
        tester.view.devicePixelRatio = 1.5;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final connector = _CompanionConnector();
        addTearDown(connector.dispose);
        await tester.pumpWidget(
          ChangeNotifierProvider<MeshCoreConnector>.value(
            value: connector,
            child: MaterialApp(
              theme: dark ? MeshTheme.dark() : MeshTheme.light(),
              home: const CompanionUpdateScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text('Find updates on GitHub').hitTestable(),
          findsOneWidget,
        );
        expect(find.text('Use a firmware file').hitTestable(), findsOneWidget);
        expect(find.textContaining('ESP32 application .bin'), findsWidgets);
        expect(find.byType(UpdateStatusCard), findsOneWidget);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        await tester.tap(find.text('Use a firmware file'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Phone Downloads'));
        await tester.pumpAndSettle();
        expect(find.text('Phone Downloads').hitTestable(), findsOneWidget);
        await tester.ensureVisible(find.text('Browse files'));
        await tester.pumpAndSettle();
        expect(find.text('Browse files').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);

        tester.view.physicalSize = const Size(854, 480);
        tester.platformDispatcher.textScaleFactorTestValue = 1.6;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Browse files'));
        await tester.pumpAndSettle();
        expect(find.text('Browse files').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('transfer status has one progress bar with a percentage', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: UpdateStatusCard(
            message: 'Sending firmware',
            busy: true,
            progress: 42,
          ),
        ),
      ),
    );
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      0.42,
    );
    expect(find.text('42%'), findsOneWidget);
  });

  testWidgets('Nordic board asks for a DFU ZIP', (tester) async {
    final connector = _CompanionConnector(board: 'RAK4631');
    addTearDown(connector.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<MeshCoreConnector>.value(
        value: connector,
        child: const MaterialApp(home: CompanionUpdateScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Nordic DFU .zip'), findsWidgets);
    expect(find.textContaining('ESP32 application .bin'), findsNothing);
  });

  testWidgets('full ESP32 image cannot start a phone OTA update', (
    tester,
  ) async {
    final connector = _CompanionConnector();
    addTearDown(connector.dispose);
    final image = Uint8List(0x21000);
    image[0] = 0xE9;
    image[1] = 1;
    image[2] = 2;
    image[0x8000] = 0xAA;
    image[0x8001] = 0x50;
    final picked = XFile.fromData(image, path: 'ordinary-name.bin');
    await tester.pumpWidget(
      ChangeNotifierProvider<MeshCoreConnector>.value(
        value: connector,
        child: MaterialApp(
          home: CompanionUpdateScreen(pickFirmware: () async => picked),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use a firmware file'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Browse files'));
    await tester.tap(find.text('Browse files'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<UpdateStatusCard>(find.byType(UpdateStatusCard)).message,
      contains('full/erase ESP32 image'),
    );
    expect(find.text('Start Wi-Fi updater'), findsNothing);
  });

  testWidgets(
    'disconnected Companion shows an actionable error and stops progress',
    (tester) async {
      final connector = _CompanionConnector(connected: false);
      addTearDown(connector.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider<MeshCoreConnector>.value(
          value: connector,
          child: const MaterialApp(home: CompanionUpdateScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Connect to a Companion first.'), findsOneWidget);
      expect(
        tester.widget<UpdateStatusCard>(find.byType(UpdateStatusCard)).isError,
        isTrue,
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
    },
  );
}
