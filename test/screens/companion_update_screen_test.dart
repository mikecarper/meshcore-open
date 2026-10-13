import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/screens/companion_update_screen.dart';
import 'package:meshcore_open/services/app_debug_log_service.dart';
import 'package:meshcore_open/services/nrf_dfu_recovery.dart';
import 'package:meshcore_open/services/nrf_dfu_recovery_store.dart';
import 'package:meshcore_open/services/nrf_dfu_package.dart';
import 'package:meshcore_open/services/companion_image_validator.dart';
import 'package:meshcore_open/services/companion_board_catalog.dart';
import 'package:meshcore_open/services/github_mota_release_service.dart';
import 'package:meshcore_open/theme/mesh_theme.dart';
import 'package:meshcore_open/utils/app_logger.dart';
import 'package:meshcore_open/widgets/update_status_card.dart';
import 'package:provider/provider.dart';
import '../support/companion_firmware_test_data.dart';

class _MemoryRecoveryStore extends NrfDfuRecoveryStore {
  NrfDfuRecoveryRecord? record;
  bool active = false;
  @override
  Future<bool> hasUnconfirmedNativeTransfer() async => active;
  @override
  Future<NrfDfuRecoveryRecord?> load() async => record;
  @override
  Future<NrfDfuRecoveryRecord> save({
    required String sourcePath,
    required String originalAddress,
    required String board,
    required String publicKey,
    required String filename,
    required bool applicationOnly,
    String? verifiedBootloaderAddress,
    CompanionFirmwareProvenance? provenance,
  }) async => record = NrfDfuRecoveryRecord(
    path: sourcePath,
    originalAddress: originalAddress,
    board: board,
    publicKey: publicKey,
    filename: filename,
    applicationOnly: applicationOnly,
    expiresAt: DateTime.now().add(const Duration(hours: 24)),
    nativeMayBeActive: false,
    verifiedBootloaderAddress: verifiedBootloaderAddress,
    provenance: provenance,
  );
  @override
  Future<void> markTransferActive() async {
    active = true;
  }

  @override
  Future<void> markTransferSettled() async {
    active = false;
  }

  @override
  Future<void> clear({bool nativeTerminationConfirmed = false}) async {
    record = null;
  }
}

class _CompanionConnector extends MeshCoreConnector {
  _CompanionConnector({this.connected = true, this.board = 'Heltec V4.3 OLED'});

  bool connected;
  final String board;
  String address = 'EB:9D:56:B2:48:48';
  final events = <String>[];
  bool dfuSupported = true;
  String? dfuRefreshError;
  String? dfuHandoffError;
  void Function()? afterDfuRefresh;
  String? selfReply;

  @override
  bool get isConnected => connected;

  @override
  String get deviceIdLabel => address;

  @override
  String get selfPublicKeyHex => '1234567890abcdef' * 4;

  @override
  bool get supportsNordicCompanionDfu => dfuSupported;

  @override
  Future<void> refreshNordicDfuService() async {
    if (dfuRefreshError != null) throw StateError(dfuRefreshError!);
    if (!dfuSupported) throw StateError('No writable Nordic DFU service.');
    afterDfuRefresh?.call();
  }

  @override
  Future<void> enterNordicDfu() async {
    events.add('enter DFU');
    if (dfuHandoffError != null) throw StateError(dfuHandoffError!);
  }

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
      : command == 'ota self'
      ? selfReply ?? 'ERR unavailable'
      : 'v1.17.1.8-halo-keymind-cascade-dev-d4b3bb56';
}

class _ReleaseSelectionService extends GitHubMotaReleaseService {
  _ReleaseSelectionService(String version)
    : asset = GitHubReleaseAsset.fromJson({
        'name': 'Heltec_t096_companion_radio_full-$version.zip',
      });
  final GitHubReleaseAsset asset;
  int downloads = 0;
  bool requestedHistory = false;

  @override
  Future<List<GitHubReleaseAsset>> findCompanionAssets(
    String board, {
    String? extension,
    bool preserveFullProfile = true,
    bool includeOlderVersions = false,
  }) async {
    requestedHistory = includeOlderVersions;
    return [asset];
  }

  @override
  Future<CompanionFirmwareDownload> downloadCompanionFirmware(
    GitHubReleaseAsset asset, {
    required String board,
  }) async {
    downloads++;
    throw const FormatException('Test download stopped before any flash.');
  }
}

Future<void> _loadDfuScreen(
  WidgetTester tester,
  _CompanionConnector connector,
  NrfDfuRecovery recovery, {
  _MemoryRecoveryStore? store,
  String? correctedBoard,
  bool acceptsFile = true,
}) async {
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
  final zip = XFile.fromData(testNrfDfuZip(), path: 'T096_companion.zip');
  await tester.pumpWidget(
    ChangeNotifierProvider<MeshCoreConnector>.value(
      value: connector,
      child: MaterialApp(
        home: CompanionUpdateScreen(
          pickFirmware: () async => zip,
          dfuRecovery: recovery,
          recoveryStore: store ?? _MemoryRecoveryStore(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (correctedBoard != null) {
    await _tapDfu(tester, 'Installed firmware');
    await _tapDfu(tester, 'Wrong board reported?');
    final apply = find.widgetWithText(FilledButton, 'Use selected board');
    expect(tester.widget<FilledButton>(apply).onPressed, isNull);
    await tester.tap(find.byType(DropdownButtonFormField<CompanionBoardSpec>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(correctedBoard).last);
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(apply).onPressed, isNull);
    await tester.tap(find.text('I checked the physical board model'));
    await tester.pumpAndSettle();
    await tester.tap(apply);
    await tester.pumpAndSettle();
    expect(find.textContaining('Hardware selected by you:'), findsWidgets);
    await _tapDfu(tester, 'Installed firmware');
  }
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
  expect(
    find.text('Update over Bluetooth'),
    acceptsFile ? findsOneWidget : findsNothing,
  );
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

AppDebugLogService _captureDfuLog() {
  final log = AppDebugLogService();
  appLogger.initialize(log, enabled: true);
  addTearDown(() {
    appLogger.setEnabled(false);
    log.dispose();
  });
  return log;
}

const _t096Bootloader = DfuAdvertisement('EB:9D:56:B2:48:49', 'T096_DFU', [
  legacyDfuServiceUuid,
]);

void main() {
  for (final confirm in [false, true]) {
    testWidgets('older version requires an explicit downgrade: $confirm', (
      tester,
    ) async {
      final connector = _CompanionConnector(board: 'Heltec T096');
      addTearDown(connector.dispose);
      final releases = _ReleaseSelectionService('v1.17.1.7');
      await tester.pumpWidget(
        ChangeNotifierProvider<MeshCoreConnector>.value(
          value: connector,
          child: MaterialApp(
            home: CompanionUpdateScreen(
              releases: releases,
              recoveryStore: _MemoryRecoveryStore(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Choose another version'));
      await tester.tap(find.text('Choose another version'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(releases.requestedHistory, isTrue);
      await tester.tap(
        find.text('${releases.asset.name}\nOlder version - downgrade'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Downgrade firmware?'), findsOneWidget);
      expect(
        find.textContaining('unable to read newer settings'),
        findsOneWidget,
      );
      expect(releases.downloads, 0);
      await tester.tap(find.text(confirm ? 'Downgrade' : 'Cancel'));
      await tester.pumpAndSettle();
      expect(releases.downloads, confirm ? 1 : 0);
      expect(connector.events, isEmpty);
      expect(
        find.text(
          confirm
              ? 'Test download stopped before any flash.'
              : 'Downgrade cancelled.',
        ),
        findsOneWidget,
      );
    });
  }

  for (final confirm in [false, true]) {
    testWidgets('equal version needs explicit reinstall: $confirm', (
      tester,
    ) async {
      final connector = _CompanionConnector(board: 'Heltec T096');
      addTearDown(connector.dispose);
      final releases = _ReleaseSelectionService('v1.17.1.8-other-build');
      await tester.pumpWidget(
        ChangeNotifierProvider<MeshCoreConnector>.value(
          value: connector,
          child: MaterialApp(
            home: CompanionUpdateScreen(
              releases: releases,
              recoveryStore: _MemoryRecoveryStore(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Find updates on GitHub'));
      await tester.tap(find.text('Find updates on GitHub'));
      // The pending selection keeps a progress indicator behind the modal.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(
        find.text('${releases.asset.name}\nSame version - reinstall'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Reinstall this version?'), findsOneWidget);
      expect(releases.downloads, 0);
      await tester.tap(find.text(confirm ? 'Reinstall' : 'Cancel'));
      await tester.pumpAndSettle();
      expect(releases.downloads, confirm ? 1 : 0);
      expect(connector.events, isEmpty);
      expect(
        find.text(
          confirm
              ? 'Test download stopped before any flash.'
              : 'Reinstall cancelled.',
        ),
        findsOneWidget,
      );
    });
  }

  testWidgets('older GitHub release remains blocked by normal selection', (
    tester,
  ) async {
    final connector = _CompanionConnector(board: 'Heltec T096');
    addTearDown(connector.dispose);
    final releases = _ReleaseSelectionService('v1.17.1.7');
    await tester.pumpWidget(
      ChangeNotifierProvider<MeshCoreConnector>.value(
        value: connector,
        child: MaterialApp(
          home: CompanionUpdateScreen(
            releases: releases,
            recoveryStore: _MemoryRecoveryStore(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _tapDfu(tester, 'Find updates on GitHub');
    expect(find.textContaining('No downgrade was selected.'), findsOneWidget);
    expect(find.text('Reinstall this version?'), findsNothing);
    expect(releases.downloads, 0);
    expect(connector.events, isEmpty);
  });

  for (final changedRadio in [false, true]) {
    testWidgets(
      'fresh DFU preflight blocks ${changedRadio ? 'a changed radio' : 'a failed GATT refresh'} before disconnect',
      (tester) async {
        final connector = _CompanionConnector(board: 'Heltec T096');
        addTearDown(connector.dispose);
        final recovery = NrfDfuRecovery(
          transfer: (_, _, _, _) async => fail('Must not start DFU'),
        );
        await _loadDfuScreen(tester, connector, recovery);
        if (changedRadio) {
          connector.afterDfuRefresh = () =>
              connector.address = 'AA:BB:CC:DD:EE:FF';
        } else {
          connector.dfuRefreshError = 'GATT refresh failed';
        }
        await _tapDfu(tester, 'Update over Bluetooth');
        await tester.tap(find.text('Update'));
        await tester.pumpAndSettle();
        expect(connector.events, ['stop scan']);
        expect(
          find.text(
            changedRadio
                ? 'Connection changed. Reopen the updater.'
                : 'GATT refresh failed',
          ),
          findsOneWidget,
        );
      },
    );
  }
  testWidgets(
    'incorrect reported board can recover after physical confirmation',
    (tester) async {
      final connector = _CompanionConnector(board: 'Incorrect firmware board');
      addTearDown(connector.dispose);
      final recovery = NrfDfuRecovery(
        transfer: (_, _, _, _) async => fail('No transfer yet'),
      );
      await _loadDfuScreen(
        tester,
        connector,
        recovery,
        correctedBoard: 'Heltec T096',
      );
      expect(find.text('Update over Bluetooth'), findsOneWidget);
      expect(connector.events, isNot(contains('disconnect/true')));
    },
  );

  testWidgets(
    'manual board selection still rejects firmware for another board',
    (tester) async {
      final connector = _CompanionConnector(board: 'Heltec T096');
      addTearDown(connector.dispose);
      final recovery = NrfDfuRecovery(
        transfer: (_, _, _, _) async =>
            fail('Wrong firmware must not transfer'),
      );
      await _loadDfuScreen(
        tester,
        connector,
        recovery,
        correctedBoard: 'Heltec T114',
        acceptsFile: false,
      );
      expect(find.text('Update over Bluetooth'), findsNothing);
      expect(connector.events, isNot(contains('disconnect/true')));
    },
  );

  testWidgets('without Nordic DFU wrong-board recovery directs to USB', (
    tester,
  ) async {
    final connector = _CompanionConnector()..dfuSupported = false;
    addTearDown(connector.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<MeshCoreConnector>.value(
        value: connector,
        child: MaterialApp(
          home: CompanionUpdateScreen(recoveryStore: _MemoryRecoveryStore()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _tapDfu(tester, 'Installed firmware');
    await _tapDfu(tester, 'Wrong board reported?');
    expect(find.text('Open USB installer'), findsOneWidget);
    expect(find.text('Use selected board'), findsNothing);
    expect(connector.events, isEmpty);
  });
  for (final correct in [false, true]) {
    testWidgets(
      'post-reboot body verification ${correct ? 'clears verified recovery' : 'retains mismatched recovery'}',
      (tester) async {
        final connector = _CompanionConnector(board: 'Heltec T096');
        addTearDown(connector.dispose);
        final store = _MemoryRecoveryStore();
        final recovery = NrfDfuRecovery(
          scan: (_, _) async => [_t096Bootloader],
          wait: (_) async {},
          transfer: (_, _, _, _) async {},
        );
        await _loadDfuScreen(tester, connector, recovery, store: store);
        await _tapDfu(tester, 'Update over Bluetooth');
        await tester.tap(find.text('Update'));
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(store.record, isNotNull);
        expect(store.active, isFalse);
        connector.connected = true;
        connector.selfReply =
            'self body=1024 image=1080 base_hash=${correct ? NrfDfuPackage.inspect(testNrfDfuZip()).applicationBaseHash : '0000000000000000'} | maxblk:128';
        final button = tester.widget<OutlinedButton>(
          find.ancestor(
            of: find.text('Verify reconnected Companion'),
            matching: find.byWidgetPredicate(
              (widget) => widget is OutlinedButton,
            ),
          ),
        );
        await tester.runAsync(button.onPressed! as Future<void> Function());
        await tester.pumpAndSettle();
        expect(store.record == null, correct);
        expect(
          find.textContaining(
            correct
                ? 'Update verified.'
                : 'has not confirmed the selected firmware body hash',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('missing application DFU service never disconnects or sends', (
    tester,
  ) async {
    final connector = _CompanionConnector(board: 'Heltec T096')
      ..dfuSupported = false;
    addTearDown(connector.dispose);
    final recovery = NrfDfuRecovery(
      transfer: (_, _, _, _) async => fail('Must not flash'),
      scan: (_, _) async => throw StateError('Must not scan'),
    );
    await _loadDfuScreen(tester, connector, recovery);
    await _tapDfu(tester, 'Update over Bluetooth');
    expect(find.text('Update Companion?'), findsNothing);
    expect(connector.events, isEmpty);
    expect(
      find.textContaining('does not expose a writable Nordic DFU'),
      findsOneWidget,
    );
  });

  testWidgets(
    'persisted unconfirmed native lease blocks even a connected updater',
    (tester) async {
      final connector = _CompanionConnector(board: 'Heltec T096');
      addTearDown(connector.dispose);
      final store = _MemoryRecoveryStore()..active = true;
      await tester.pumpWidget(
        ChangeNotifierProvider<MeshCoreConnector>.value(
          value: connector,
          child: MaterialApp(home: CompanionUpdateScreen(recoveryStore: store)),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          'previous native Bluetooth update has not confirmed termination',
        ),
        findsOneWidget,
      );
      expect(find.text('Check stopped Bluetooth updater'), findsOneWidget);
      expect(connector.events, isEmpty);
    },
  );

  testWidgets(
    'T096 uses the authenticated handoff before one exact bootloader transfer',
    (tester) async {
      final log = _captureDfuLog();
      final connector = _CompanionConnector(board: 'Heltec T096');
      addTearDown(connector.dispose);
      var scans = 0, transfers = 0;
      final recovery = NrfDfuRecovery(
        scan: (addresses, _) async {
          connector.events.add('DFU scan');
          expect(addresses, ['EB:9D:56:B2:48:48', 'EB:9D:56:B2:48:49']);
          scans++;
          return [_t096Bootloader];
        },
        wait: (_) async {},
        transfer: (address, _, force, events) async {
          connector.events.add('DFU transfer');
          transfers++;
          expect(address, 'EB:9D:56:B2:48:49');
          expect(force, isTrue);
          events.onProgressChanged?.call(address, 0, 1, 1, 1, 1);
          events.onProgressChanged?.call(address, 1, 1, 1, 1, 1);
          events.onProgressChanged?.call(address, 10, 1, 1, 1, 1);
          events.onProgressChanged?.call(address, 11, 1, 1, 1, 1);
          events.onProgressChanged?.call(address, 100, 1, 1, 1, 1);
          events.onFirmwareValidating?.call(address);
        },
      );
      await _loadDfuScreen(tester, connector, recovery);
      await _tapDfu(tester, 'Update over Bluetooth');
      expect(connector.events, isEmpty);
      await tester.tap(find.text('Update'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(connector.events, [
        'stop scan',
        'enter DFU',
        'disconnect/true',
        'DFU scan',
        'DFU transfer',
      ]);
      expect(scans, 1);
      expect(transfers, 1);
      expect(connector.preserveUpdateScreenOnDisconnect, isTrue);
      final card = tester.widget<UpdateStatusCard>(
        find.byType(UpdateStatusCard),
      );
      expect(card.isError, isFalse);
      expect(card.progress, 100);
      expect(card.message, contains('check its version'));
      final messages = log.entries
          .where((entry) => entry.tag == 'CompanionDFU')
          .map((entry) => entry.message)
          .join('\n');
      expect(messages, contains('board=Heltec T096'));
      expect(messages, contains('components=application applicationOnly=true'));
      expect(messages, contains('stage=discover_bootloader'));
      expect(messages, isNot(contains('Bluetooth DFU native_error:')));
      expect(messages, isNot(contains('stage=recover_bootloader')));
      expect(messages, contains('bootloaderAddress=EB:9D:56:B2:48:49'));
      expect(messages, contains('stage=validating'));
      expect(messages, contains('version verification still required'));
      expect(messages, contains('Bluetooth DFU progress=1 '));
      expect(messages, contains('Bluetooth DFU progress=10 '));
      expect(messages, isNot(contains('Bluetooth DFU progress=11 ')));
      expect(messages, isNot(contains('Bluetooth DFU failed:')));
      expect(messages, isNot(contains('T096_companion.zip')));
      expect(messages, isNot(contains('companion-dfu-test-')));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      expect(connector.preserveUpdateScreenOnDisconnect, isFalse);
    },
  );

  testWidgets('opaque iOS identity retains the native application handoff', (
    tester,
  ) async {
    final connector = _CompanionConnector(board: 'Heltec T096')
      ..address = 'ios-peripheral-uuid';
    addTearDown(connector.dispose);
    var transfers = 0;
    final recovery = NrfDfuRecovery(
      scan: (addresses, _) async {
        expect(addresses, ['ios-peripheral-uuid']);
        return [];
      },
      transfer: (address, _, force, _) async {
        expect(address, 'ios-peripheral-uuid');
        expect(force, isFalse);
        transfers++;
      },
    );
    await _loadDfuScreen(tester, connector, recovery);
    await _tapDfu(tester, 'Update over Bluetooth');
    await tester.tap(find.text('Update'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(connector.events, ['stop scan', 'disconnect/true']);
    expect(transfers, 1);
    expect(
      tester.widget<UpdateStatusCard>(find.byType(UpdateStatusCard)).isError,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  for (final failureCase in [
    (percent: 0, code: '8'),
    (percent: 37, code: '8'),
    (percent: 80, code: '8'),
    (percent: 37, code: 'DO_NOT_EXPORT_PRIVATE_CODE'),
    (percent: 37, code: '999999999999999999999999999999999999'),
  ]) {
    final percent = failureCase.percent;
    testWidgets(
      'DFU export records failure stage without secrets at $percent percent (${failureCase.code})',
      (tester) async {
        final log = _captureDfuLog();
        final connector = _CompanionConnector(board: 'Heltec T096');
        addTearDown(connector.dispose);
        const privateDetails = 'DO_NOT_EXPORT_PRIVATE_EXCEPTION_DETAILS';
        final recovery = NrfDfuRecovery(
          scan: (_, _) async => [_t096Bootloader],
          wait: (_) async {},
          transfer: (address, _, _, events) async {
            events.onDeviceConnecting?.call(address);
            events.onEnablingDfuMode?.call(address);
            if (percent > 0) {
              events.onProgressChanged?.call(address, percent, 1, 1, 1, 1);
            }
            if (percent == 80) {
              events.onFirmwareValidating?.call(address);
            }
            events.onError?.call(address, 8, 1, privateDetails);
            throw PlatformException(
              code: failureCase.code,
              message: privateDetails,
              details: {
                'privateKey': privateDetails,
                'password': privateDetails,
              },
            );
          },
        );
        await _loadDfuScreen(tester, connector, recovery);
        await _tapDfu(tester, 'Update over Bluetooth');
        await tester.tap(find.text('Update'));
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        final failures = log.entries.where(
          (entry) =>
              entry.tag == 'CompanionDFU' &&
              entry.level == AppDebugLogLevel.error,
        );
        expect(failures, hasLength(1));
        final failure = failures.single.message;
        expect(failure, contains('Bluetooth DFU failed: stage='));
        expect(failure, contains('address=EB:9D:56:B2:48:48'));
        expect(failure, contains('progress=$percent'));
        expect(failure, contains('payloadStarted=${percent > 0}'));
        expect(failure, contains('validating=${percent == 80}'));
        if (percent > 0) {
          // The bounded terminal callback is authoritative, not an arbitrary
          // code carried by a later platform exception.
          const exportedCode = '8';
          expect(
            failure,
            contains('errorType=PlatformException code=$exportedCode'),
          );
          expect(
            failure,
            contains(
              'stage=${percent == 80 ? 'validating' : 'sending_payload'}',
            ),
          );
        }
        final messages = log.entries.map((entry) => entry.message).join('\n');
        expect(messages, isNot(contains(privateDetails)));
        expect(messages, isNot(contains('DO_NOT_EXPORT_PRIVATE_CODE')));
        expect(
          messages,
          isNot(contains('999999999999999999999999999999999999')),
        );
        expect(messages, isNot(contains('privateKey')));
        expect(messages, isNot(contains('password')));
        expect(messages, isNot(contains('companion-dfu-test-')));
        expect(
          tester
              .widget<UpdateStatusCard>(find.byType(UpdateStatusCard))
              .isError,
          isTrue,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

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
      expect(calls, 0);
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
      expect(calls, 1);
      expect(
        connector.events.where((s) => s == 'disconnect/true'),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed authenticated handoff keeps recovery without native writes',
    (tester) async {
      final connector = _CompanionConnector(board: 'Heltec T096')
        ..dfuHandoffError = 'Control write failed';
      addTearDown(connector.dispose);
      final store = _MemoryRecoveryStore();
      final recovery = NrfDfuRecovery(
        scan: (_, _) async => fail('Must not scan after failed handoff'),
        transfer: (_, _, _, _) async => fail('Must not flash'),
      );
      await _loadDfuScreen(tester, connector, recovery, store: store);
      await _tapDfu(tester, 'Update over Bluetooth');
      await tester.tap(find.text('Update'));
      await tester.pumpAndSettle();
      expect(connector.events, ['stop scan', 'enter DFU']);
      expect(connector.connected, isTrue);
      expect(store.record, isNotNull);
      expect(store.active, isFalse);
      expect(
        tester.widget<UpdateStatusCard>(find.byType(UpdateStatusCard)).isError,
        isTrue,
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
              home: CompanionUpdateScreen(
                recoveryStore: _MemoryRecoveryStore(),
              ),
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
        child: MaterialApp(
          home: CompanionUpdateScreen(recoveryStore: _MemoryRecoveryStore()),
        ),
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
          home: CompanionUpdateScreen(
            pickFirmware: () async => picked,
            recoveryStore: _MemoryRecoveryStore(),
          ),
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
          child: MaterialApp(
            home: CompanionUpdateScreen(recoveryStore: _MemoryRecoveryStore()),
          ),
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
