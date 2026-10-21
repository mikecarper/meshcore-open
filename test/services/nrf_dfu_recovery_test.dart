import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/nrf_dfu_recovery.dart';
import 'package:nordic_dfu/nordic_dfu.dart';

const original = 'EB:9D:56:B2:48:48';
const bootloader = 'EB:9D:56:B2:48:49';
const advert = DfuAdvertisement(bootloader, 'T096_DFU', [legacyDfuServiceUuid]);
const nus = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';

Future<String> update(
  NrfDfuRecovery recovery, {
  bool applicationOnly = true,
  bool retryBootloader = false,
  String address = original,
}) => recovery.update(
  originalAddress: address,
  path: '/test/companion.zip',
  board: 'Heltec T096',
  applicationOnly: applicationOnly,
  retryBootloader: retryBootloader,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final profile in [
    ('Heltec MeshTower V2 SD', 'TOWER_V2', 'HT-n5262'),
    ('RAK WisMesh Tag', 'RTAG_DFU', 'WisMesh Tag'),
    ('Heltec MeshPocket', 'MESH_POC', 'Mesh Pocket'),
    ('ProMicro DIY', 'PROM_DFU', 'ProMicro NRF52840'),
    ('ThinkNode M3', 'TNM3_DFU', 'ThinkNode-M3'),
    ('Keepteen LT1', 'KEEPTEEN', 'LT1'),
    ('RAK4631 + W25Q16', '4631_W25', 'RAK4631 + W25Q16'),
  ]) {
    test('verified supported profile remains available: ${profile.$1}', () {
      expect(
        selectDfuBootloader(
          [
            DfuAdvertisement(original, profile.$2, [legacyDfuServiceUuid]),
          ],
          originalAddress: original,
          board: profile.$1,
        ),
        original,
      );
      expect(
        matchesDfuBootloaderIdentity(
          board: profile.$1,
          name: profile.$2,
          model: profile.$3,
          revision: [8, 0],
        ),
        isTrue,
      );
      expect(
        matchesDfuBootloaderIdentity(
          board: profile.$1,
          name: profile.$2,
          model: 'Another board',
          revision: [8, 0],
        ),
        isFalse,
      );
    });
  }
  test('an unrelated factory address requires this radio known address', () {
    const factory = 'C3:C6:A8:FC:AD:A6';
    const custom = 'D2:90:05:46:31:01';
    const value = DfuAdvertisement(factory, '4631_DFU', [legacyDfuServiceUuid]);
    expect(
      selectDfuBootloader([value], originalAddress: custom, board: 'RAK 4631'),
      isNull,
    );
    expect(
      selectDfuBootloader(
        [value],
        originalAddress: custom,
        board: 'RAK 4631',
        knownBootloaderAddress: factory.toLowerCase(),
      ),
      factory,
    );
    expect(() => knownDfuAddress(' not-an-address '), throwsFormatException);
  });

  test('bootloader profile requires the actual model and revision 0.8', () {
    bool match(String model, List<int> revision, {String name = '4631_DFU'}) =>
        matchesDfuBootloaderIdentity(
          board: 'RAK 4631',
          name: name,
          model: model,
          revision: revision,
        );
    expect(match('RAK4631', [8, 0]), isTrue);
    expect(match('RAK3401', [8, 0]), isFalse);
    expect(match('RAK4631', [1, 0]), isFalse);
    expect(match('RAK4631', [8]), isFalse);
    expect(match('RAK4631', [8, 0], name: 'RAK4631_OTA'), isFalse);
    expect(match('RAK4631', [8, 0], name: 'ADADFU'), isTrue);
  });

  test(
    'generic stock name needs a known address, DFU service and actual profile',
    () {
      const unbound = 'C3:C6:A8:FC:AD:A6';
      String? select(String address, List<String> services) =>
          selectDfuBootloader(
            [DfuAdvertisement(address, 'AdaDFU', services)],
            originalAddress: original,
            board: 'Heltec T096',
            allowAddressChange: true,
          );
      expect(select(original, [legacyDfuServiceUuid]), original);
      expect(select(bootloader, [legacyDfuServiceUuid]), bootloader);
      expect(select(original, []), isNull);
      expect(select(unbound, [legacyDfuServiceUuid]), isNull);
      expect(
        matchesDfuBootloaderIdentity(
          board: 'Heltec T096',
          name: 'AdaDFU',
          model: 'RAK4631',
          revision: [8, 0],
        ),
        isFalse,
      );
    },
  );

  test(
    'unsupported board stops before discovery and gives a clear error',
    () async {
      final recovery = NrfDfuRecovery(
        scan: (_, _) async => fail('Do not scan an unsupported model'),
        transfer: (_, _, _, _) async => fail('No unverified board transfer'),
      );
      await expectLater(
        recovery.update(
          originalAddress: original,
          path: '/test/app.zip',
          board: 'Unknown board',
          applicationOnly: true,
        ),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'factory-address recovery probes before its sole forced transfer',
    () async {
      const factory = 'C3:C6:A8:FC:AD:A6';
      const custom = 'D2:90:05:46:31:01';
      final steps = <String>[];
      final recovery = NrfDfuRecovery(
        scan: (addresses, _) async {
          expect(addresses, contains(factory));
          return []; // Retained peer whitelist hides it from discovery.
        },
        wait: (_) async {},
        probe: (address, board) async {
          steps.add('probe:$address');
          expect(board, 'RAK 4631');
          return true;
        },
        transfer: (address, _, force, _) async {
          steps.add('transfer:$address:$force');
        },
      );
      expect(
        await recovery.update(
          originalAddress: custom,
          path: '/test/app.zip',
          board: 'RAK 4631',
          applicationOnly: true,
          retryBootloader: true,
          knownBootloaderAddress: factory,
        ),
        factory,
      );
      expect(steps, ['probe:$factory', 'transfer:$factory:true']);
    },
  );

  test('failed actual GATT identity never starts a native transfer', () async {
    var transfers = 0;
    final recovery = NrfDfuRecovery(
      scan: (_, _) async => [advert],
      probe: (_, _) async => false,
      transfer: (_, _, _, _) async {
        transfers++;
      },
    );
    await expectLater(
      update(recovery, retryBootloader: true),
      throwsStateError,
    );
    expect(transfers, 0);
  });

  test(
    'a custom-address handoff discovers its factory updater automatically',
    () async {
      const custom = 'D2:90:05:46:31:01';
      const factory = 'C3:C6:A8:FC:AD:A6';
      final steps = <String>[];
      var scans = 0;
      final recovery = NrfDfuRecovery(
        scan: (_, _) async => ++scans == 1
            ? []
            : [
                const DfuAdvertisement(factory, '4631_DFU', [
                  legacyDfuServiceUuid,
                ]),
              ],
        wait: (_) async {},
        probe: (address, _) async {
          steps.add('probe:$address');
          return true;
        },
        transfer: (address, _, force, events) async {
          steps.add('transfer:$address:$force');
          if (!force) {
            events.onEnablingDfuMode?.call(address);
            throw PlatformException(code: '8');
          }
        },
      );
      expect(
        await recovery.update(
          originalAddress: custom,
          path: '/test/app.zip',
          board: 'RAK 4631',
          applicationOnly: true,
        ),
        factory,
      );
      expect(steps, [
        'transfer:$custom:false',
        'probe:$factory',
        'transfer:$factory:true',
      ]);
    },
  );

  test(
    'multiple factory updaters require an explicit current-candidate choice',
    () async {
      const second = 'C3:C6:A8:FC:AD:A6';
      final steps = <String>[];
      final recovery = NrfDfuRecovery(
        scan: (_, _) async => [
          advert,
          const DfuAdvertisement(second, 'T096_DFU', [legacyDfuServiceUuid]),
        ],
        probe: (address, _) async {
          steps.add('probe:$address');
          return true;
        },
        transfer: (address, _, _, _) async {
          steps.add('transfer:$address');
        },
      );
      expect(
        await recovery.update(
          originalAddress: original,
          path: '/test/app.zip',
          board: 'Heltec T096',
          applicationOnly: true,
          retryBootloader: true,
          chooseBootloader: (candidates) async {
            expect(candidates.map((c) => c.address), [bootloader, second]);
            steps.add('choose');
            return second;
          },
        ),
        second,
      );
      expect(steps, ['choose', 'probe:$second', 'transfer:$second']);
    },
  );

  for (final choice in <String?>[null, 'AA:BB:CC:DD:EE:FF']) {
    test(
      'cancelled or invented choice cannot authorize firmware: $choice',
      () async {
        final recovery = NrfDfuRecovery(
          scan: (_, _) async => [
            advert,
            const DfuAdvertisement(original, 'T096_DFU', [
              legacyDfuServiceUuid,
            ]),
          ],
          probe: (_, _) async => fail('No selected candidate to probe'),
          transfer: (_, _, _, _) async =>
              fail('No firmware after cancelled or invalid choice'),
        );
        await expectLater(
          recovery.update(
            originalAddress: original,
            path: '/test/app.zip',
            board: 'Heltec T096',
            applicationOnly: true,
            retryBootloader: true,
            chooseBootloader: (_) async => choice,
          ),
          throwsStateError,
        );
      },
    );
  }

  test(
    'ambiguous candidates are rejected before any GATT probe or transfer',
    () async {
      final recovery = NrfDfuRecovery(
        scan: (_, _) async => [
          advert,
          const DfuAdvertisement(original, 'T096_DFU', [legacyDfuServiceUuid]),
        ],
        probe: (_, _) async => fail('Do not probe an ambiguous handoff'),
        transfer: (_, _, _, _) async =>
            fail('Do not transfer to an ambiguous handoff'),
      );
      await expectLater(
        update(recovery, retryBootloader: true),
        throwsStateError,
      );
    },
  );

  for (final applicationOnly in [true, false]) {
    test(
      'native DFU retains bonds only for applicationOnly=$applicationOnly',
      () async {
        const method = MethodChannel('dev.steenbakker.nordic_dfu/method');
        const event = MethodChannel('dev.steenbakker.nordic_dfu/event');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        var calls = 0;
        messenger.setMockMethodCallHandler(event, (_) async => null);
        messenger.setMockMethodCallHandler(method, (call) async {
          expect(call.method, 'startDfu');
          final args = call.arguments as Map;
          expect(args['keepBond'], applicationOnly);
          expect(args['numberOfRetries'], 2);
          expect(args['packetReceiptNotificationsEnabled'], isTrue);
          expect(args['address'], original);
          expect(args['forceDfu'], isFalse);
          calls++;
          return original;
        });
        addTearDown(() async {
          await NordicDfu().dispose();
          messenger.setMockMethodCallHandler(method, null);
          messenger.setMockMethodCallHandler(event, null);
        });
        final recovery = NrfDfuRecovery(
          probe: (_, _) async => true,
          scan: (_, _) async => [],
        );
        expect(
          await update(recovery, applicationOnly: applicationOnly),
          original,
        );
        expect(calls, 1);
      },
    );
  }
  test(
    'candidate addresses preserve identity and wrap only the last octet',
    () {
      expect(dfuCandidateAddresses(original.toLowerCase()), [
        original,
        bootloader,
      ]);
      expect(dfuCandidateAddresses('EB:9D:56:B2:48:FF'), [
        'EB:9D:56:B2:48:FF',
        'EB:9D:56:B2:48:00',
      ]);
      expect(dfuCandidateAddresses('ios-uuid'), ['ios-uuid']);
      expect(dfuBootloaderName('Heltec T096'), 'T096_DFU');
      expect(dfuBootloaderName('RAK 4631'), '4631_DFU');
    },
  );

  test('matches fresh board and address, never just a nearby board name', () {
    String? select(List<DfuAdvertisement> values) => selectDfuBootloader(
      values,
      originalAddress: original.toLowerCase(),
      board: 'Heltec T096',
    );
    expect(select([advert]), bootloader);
    expect(select([const DfuAdvertisement(original, 'T096_DFU', [])]), isNull);
    expect(select([const DfuAdvertisement(original, 'AdaDFU', [])]), isNull);
    expect(
      select([const DfuAdvertisement('AA:BB:CC:DD:EE:01', 'T096_DFU', [])]),
      isNull,
    );
    expect(
      select([
        const DfuAdvertisement(original, 'T096_DFU', [nus]),
      ]),
      isNull,
    );
    expect(
      select([
        const DfuAdvertisement(original, 'T096_OTA', [legacyDfuServiceUuid]),
      ]),
      isNull,
    );
    expect(select([const DfuAdvertisement(original, '4631_DFU', [])]), isNull);
    expect(
      select([
        const DfuAdvertisement(original, '', [legacyDfuServiceUuid]),
      ]),
      isNull,
    );
    expect(
      () => select([
        advert,
        const DfuAdvertisement(original, 'T096_DFU', [legacyDfuServiceUuid]),
      ]),
      throwsStateError,
    );
    expect(select([advert, advert]), bootloader);
  });

  test(
    'an initial connection failure cannot select an unrelated factory radio',
    () async {
      const factory = 'C3:C6:A8:FC:AD:A6';
      final transfers = <String>[];
      var scans = 0;
      final recovery = NrfDfuRecovery(
        scan: (_, _) async => ++scans == 1
            ? []
            : [
                const DfuAdvertisement(factory, 'T096_DFU', [
                  legacyDfuServiceUuid,
                ]),
              ],
        wait: (_) async {},
        probe: (_, _) async =>
            fail('No handoff authorized another factory address'),
        transfer: (address, _, _, _) async {
          transfers.add(address);
          throw PlatformException(code: '133');
        },
      );
      await expectLater(update(recovery), throwsStateError);
      expect(transfers, [original]);
    },
  );

  test(
    'unknown boards are not identified by a generic DFU name and service',
    () {
      String? select(List<String> services) => selectDfuBootloader(
        [DfuAdvertisement(original, 'BOARD_DFU', services)],
        originalAddress: original,
        board: 'Unknown board',
      );
      expect(select([]), isNull);
      expect(select([legacyDfuServiceUuid]), isNull);
    },
  );

  test('recognizes GATT timeouts but not ZIP or remote protocol failures', () {
    for (final code in ['8', '62', '133', '147']) {
      expect(isDfuConnectionFailure(PlatformException(code: code)), isTrue);
    }
    for (final message in [
      'GATT CONN TIMEOUT',
      'GATT_CONN_TIMEOUT',
      'GATT CONNECTION TIMEOUT',
      'GATT ERROR (133)',
    ]) {
      expect(
        isDfuConnectionFailure(
          PlatformException(code: 'native', message: message),
        ),
        isTrue,
      );
    }
    expect(
      isDfuConnectionFailure(
        PlatformException(code: '4101', message: 'File error'),
      ),
      isFalse,
    );
    expect(
      isDfuConnectionFailure(PlatformException(code: '8'), errorType: 3),
      isFalse,
    );
    expect(isDfuConnectionFailure(StateError('GATT CONN TIMEOUT')), isFalse);
  });

  test(
    'timeout performs one fresh scan and retries the actual changed address',
    () async {
      final calls = <String>[];
      final scans = <Duration>[];
      final waits = <Duration>[];
      final recovery = NrfDfuRecovery(
        probe: (_, _) async => true,
        scan: (addresses, timeout) async {
          expect(addresses, [original, bootloader]);
          scans.add(timeout);
          return scans.length == 1 ? [] : [advert];
        },
        wait: (duration) async {
          waits.add(duration);
        },
        transfer: (address, path, force, events) async {
          expect(path, '/test/companion.zip');
          calls.add('$address/$force');
          if (calls.length == 1) {
            events.onError?.call(address, 8, 2, 'GATT CONN TIMEOUT');
            throw PlatformException(code: '8', message: 'GATT CONN TIMEOUT');
          }
        },
      );
      expect(await update(recovery), bootloader);
      expect(calls, ['$original/false', '$bootloader/true']);
      expect(scans, [const Duration(seconds: 2), const Duration(seconds: 8)]);
      expect(waits, [const Duration(seconds: 2)]);
    },
  );

  for (final address in [original, bootloader]) {
    test(
      'already manual OTA at $address connects directly without app handoff',
      () async {
        var calls = 0;
        final recovery = NrfDfuRecovery(
          probe: (_, _) async => true,
          scan: (_, _) async => [
            DfuAdvertisement(address, 'T096_DFU', [legacyDfuServiceUuid]),
          ],
          transfer: (found, _, force, _) async {
            calls++;
            expect(found, address);
            expect(force, isTrue);
          },
        );
        expect(await update(recovery), address);
        expect(calls, 1);
      },
    );
  }

  test(
    'missing bootloader gives manual-entry instructions, no blind retry',
    () async {
      var calls = 0, scans = 0;
      final recovery = NrfDfuRecovery(
        probe: (_, _) async => true,
        scan: (_, _) async {
          scans++;
          return [];
        },
        wait: (_) async {},
        transfer: (_, _, _, _) async {
          calls++;
          throw PlatformException(code: '8');
        },
      );
      await expectLater(
        update(recovery),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'instructions',
            allOf(
              contains('T096_DFU'),
              contains('Retry bootloader'),
              contains('Do not erase'),
            ),
          ),
        ),
      );
      expect(calls, 1);
      expect(scans, 2);
    },
  );

  test(
    'explicit retry scans again and does not retrigger the application',
    () async {
      var calls = 0;
      final recovery = NrfDfuRecovery(
        probe: (_, _) async => true,
        scan: (_, timeout) async {
          expect(timeout, const Duration(seconds: 8));
          return [advert];
        },
        transfer: (address, _, force, _) async {
          calls++;
          expect(address, bootloader);
          expect(force, isTrue);
        },
      );
      expect(await update(recovery, retryBootloader: true), bootloader);
      expect(calls, 1);
      final absent = NrfDfuRecovery(
        probe: (_, _) async => true,
        scan: (_, _) async => [],
        transfer: (_, _, _, _) async => fail('No proven bootloader'),
      );
      await expectLater(
        update(absent, retryBootloader: true),
        throwsStateError,
      );
    },
  );

  for (final reason in [
    'progress',
    'validation',
    'system image',
    'file',
    'remote rejection',
    'explicit retry',
    'iOS',
  ]) {
    test('does not add another attempt after $reason', () async {
      var calls = 0, scans = 0;
      final recovery = NrfDfuRecovery(
        probe: (_, _) async => true,
        scan: (_, _) async {
          scans++;
          return reason == 'explicit retry' ? [advert] : [];
        },
        wait: (_) async => fail('Must not retry'),
        transfer: (address, _, _, events) async {
          calls++;
          if (reason == 'progress') {
            events.onProgressChanged?.call(address, 1, 0, 0, 1, 1);
          }
          if (reason == 'validation') {
            events.onFirmwareValidating?.call(address);
          }
          if (reason == 'remote rejection') {
            events.onError?.call(address, 8, 3, 'Rejected');
          }
          throw PlatformException(code: reason == 'file' ? '4101' : '8');
        },
      );
      await expectLater(
        update(
          recovery,
          applicationOnly: reason != 'system image',
          retryBootloader: reason == 'explicit retry',
          address: reason == 'iOS' ? 'ios-uuid' : original,
        ),
        throwsA(isA<PlatformException>()),
      );
      expect(calls, 1);
      expect(scans, 1);
    });
  }

  test('second connection failure is surfaced without a retry loop', () async {
    var calls = 0, scans = 0;
    final recovery = NrfDfuRecovery(
      probe: (_, _) async => true,
      scan: (_, _) async {
        scans++;
        return scans == 1 ? [] : [advert];
      },
      wait: (_) async {},
      transfer: (_, _, _, _) async {
        calls++;
        throw PlatformException(code: '8');
      },
    );
    await expectLater(update(recovery), throwsA(isA<PlatformException>()));
    expect(calls, 2);
    expect(scans, 2);
  });

  test('one update at a time and disposal prevents another attempt', () async {
    final scanned = Completer<List<DfuAdvertisement>>();
    var calls = 0;
    final recovery = NrfDfuRecovery(
      probe: (_, _) async => true,
      scan: (_, _) => scanned.future,
      transfer: (_, _, _, _) async {
        calls++;
      },
    );
    final pending = update(recovery);
    await expectLater(update(recovery), throwsStateError);
    recovery.dispose();
    final failed = expectLater(pending, throwsStateError);
    scanned.complete([advert]);
    await failed;
    expect(calls, 0);
    await expectLater(update(recovery), throwsStateError);
  });

  test(
    'closing during GATT cleanup prevents recovery scan and transfer',
    () async {
      final waiting = Completer<void>();
      final entered = Completer<void>();
      var calls = 0, scans = 0;
      final recovery = NrfDfuRecovery(
        probe: (_, _) async => true,
        scan: (_, _) async {
          scans++;
          return [];
        },
        wait: (_) {
          entered.complete();
          return waiting.future;
        },
        transfer: (_, _, _, _) async {
          calls++;
          throw PlatformException(code: '8');
        },
      );
      final pending = update(recovery);
      await entered.future;
      recovery.dispose();
      final failed = expectLater(pending, throwsStateError);
      waiting.complete();
      await failed;
      expect(calls, 1);
      expect(scans, 1);
    },
  );

  test('iOS manual retry uses its unchanged native identifier', () async {
    final recovery = NrfDfuRecovery(
      probe: (_, _) async => true,
      scan: (_, _) async => [],
      transfer: (address, _, force, _) async {
        expect(address, 'ios-uuid');
        expect(force, isTrue);
      },
    );
    expect(
      await update(recovery, retryBootloader: true, address: 'ios-uuid'),
      'ios-uuid',
    );
  });
}
