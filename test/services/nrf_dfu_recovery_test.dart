import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/companion_board_catalog.dart';
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
  bool allowBondedBootloaderProbe = false,
  String address = original,
  String board = 'Heltec T096',
}) => recovery.update(
  originalAddress: address,
  path: '/test/companion.zip',
  board: board,
  applicationOnly: applicationOnly,
  retryBootloader: retryBootloader,
  allowBondedBootloaderProbe: allowBondedBootloaderProbe,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final evidence in ['same radio', 'another radio', 'none']) {
    test(
      'bonded probe requires fresh bootloader evidence for $evidence',
      () async {
        var probes = 0, transfers = 0;
        final recovery = NrfDfuRecovery(
          scan: (_, _) async => [],
          bondedProbe: (address, board) async {
            expect(address, original);
            expect(board, 'Heltec T096');
            probes++;
            return evidence == 'none'
                ? null
                : DfuAdvertisement(
                    evidence == 'same radio' ? original : bootloader,
                    'T096_DFU',
                    [legacyDfuServiceUuid],
                  );
          },
          transfer: (address, _, force, _) async {
            expect(address, original);
            expect(force, isTrue);
            transfers++;
          },
        );
        final future = update(
          recovery,
          retryBootloader: true,
          allowBondedBootloaderProbe: true,
        );
        if (evidence == 'same radio') {
          expect(await future, original);
        } else {
          await expectLater(future, throwsStateError);
        }
        expect(probes, 1);
        expect(transfers, evidence == 'same radio' ? 1 : 0);
      },
    );
  }
  test(
    'ordinary discovery does not probe a bonded radio without opt-in',
    () async {
      final recovery = NrfDfuRecovery(
        scan: (_, _) async => [advert],
        bondedProbe: (_, _) async => fail('No probe'),
        transfer: (_, _, _, _) async {},
      );
      expect(await update(recovery), bootloader);
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
          expect(args['numberOfRetries'], 0);
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
        final recovery = NrfDfuRecovery(scan: (_, _) async => []);
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
      select([
        const DfuAdvertisement(original, 'AdaDFU', [legacyDfuServiceUuid]),
      ]),
      isNull,
    );
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
    'unknown boards cannot authorize an arbitrary DFU name at the known address',
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

  test(
    'Tower full and shortened names require its known address and DFU UUID',
    () {
      for (final board in [
        'Heltec Tower V2',
        'Heltec MeshTower V2 SD',
        'Heltec Mesh Tower V2',
        'MeshTower V2',
        'tower_v2',
        'Heltec_tower_v2_sdcard',
        'Heltec_mesh_tower_v2_sdcard',
        'mesh_tower_v2_sdcard',
        'tower_v2_sdcard',
      ]) {
        expect(dfuBootloaderName(board), 'TOWER_V2_OTA');
        for (final address in [original, bootloader]) {
          for (final name in ['TOWER_V2_OTA', 'TOWER_V2']) {
            expect(
              selectDfuBootloader(
                [
                  DfuAdvertisement(address, name, [legacyDfuServiceUuid]),
                ],
                originalAddress: original,
                board: board,
              ),
              address,
            );
          }
        }
      }
    },
  );

  test(
    'Tower refuses wrong identity, arbitrary OTA, missing DFU and any NUS',
    () {
      for (final candidate in [
        const DfuAdvertisement('AA:BB:CC:DD:EE:01', 'TOWER_V2', [
          legacyDfuServiceUuid,
        ]),
        const DfuAdvertisement(original, 'TOWER_V2_OTA', []),
        const DfuAdvertisement(original, 'TOWER_V2', ['180f']),
        const DfuAdvertisement(original, 'TOWER_V2', [
          legacyDfuServiceUuid,
          nus,
        ]),
        const DfuAdvertisement(original, 'TOWER_V2_OTA', [
          legacyDfuServiceUuid,
          nus,
        ]),
        const DfuAdvertisement(original, 'T114_DFU', [legacyDfuServiceUuid]),
        const DfuAdvertisement(original, 'OTHER_OTA', [legacyDfuServiceUuid]),
        const DfuAdvertisement(original, 'AdaDFU', [legacyDfuServiceUuid]),
        const DfuAdvertisement(original, 'TOWER', [legacyDfuServiceUuid]),
      ]) {
        expect(
          selectDfuBootloader(
            [candidate],
            originalAddress: original,
            board: 'Heltec Tower V2',
          ),
          isNull,
        );
      }
      for (final board in ['Heltec T114', 'Unknown board', 'Heltec Tower V3']) {
        expect(
          selectDfuBootloader(
            [
              const DfuAdvertisement(original, 'TOWER_V2', [
                legacyDfuServiceUuid,
              ]),
            ],
            originalAddress: original,
            board: board,
          ),
          isNull,
        );
      }
      expect(
        () => selectDfuBootloader(
          [
            const DfuAdvertisement(original, 'TOWER_V2', [
              legacyDfuServiceUuid,
            ]),
            const DfuAdvertisement(bootloader, 'TOWER_V2_OTA', [
              legacyDfuServiceUuid,
            ]),
          ],
          originalAddress: original,
          board: 'Heltec Tower V2',
        ),
        throwsStateError,
      );
    },
  );

  group('fresh advertisement reducer', () {
    String? select(DfuAdvertisement value, String board) =>
        selectDfuBootloader([value], originalAddress: original, board: board);

    for (final entry in {
      'Heltec T096': 'T096_DFU',
      'Heltec T114': 'T114_DFU',
      'Heltec Tower V2': 'TOWER_V2',
    }.entries) {
      test('${entry.key} NUS to DFU at the same MAC drops historical NUS', () {
        final application = reduceDfuAdvertisement(
          null,
          const DfuAdvertisement(original, 'MeshCore-radio', [
            nus,
            legacyDfuServiceUuid,
          ]),
        );
        final boot = reduceDfuAdvertisement(
          application,
          DfuAdvertisement(original.toLowerCase(), entry.value, [
            legacyDfuServiceUuid.toUpperCase(),
          ]),
        );
        expect(boot.services, [legacyDfuServiceUuid]);
        expect(boot.isAmbiguous, isFalse);
        expect(select(boot, entry.key), original);
      });

      test(
        '${entry.key} name-only phase transition fails closed until fresh UUID',
        () {
          final ambiguous = reduceDfuAdvertisement(
            const DfuAdvertisement(original, 'MeshCore-radio', [nus]),
            DfuAdvertisement(original, entry.value, []),
          );
          expect(ambiguous.services, isEmpty);
          expect(ambiguous.isAmbiguous, isTrue);
          expect(select(ambiguous, entry.key), isNull);
          final stillAmbiguous = reduceDfuAdvertisement(
            ambiguous,
            DfuAdvertisement(original, entry.value, []),
          );
          expect(select(stillAmbiguous, entry.key), isNull);
          final proven = reduceDfuAdvertisement(
            stillAmbiguous,
            const DfuAdvertisement(original, '', [legacyDfuServiceUuid]),
          );
          expect(proven.name, entry.value);
          expect(proven.isAmbiguous, isFalse);
          expect(select(proven, entry.key), original);
        },
      );

      test(
        '${entry.key} service-only DFU followed by scan-response name joins safely',
        () {
          final unnamed = reduceDfuAdvertisement(
            const DfuAdvertisement(original, 'MeshCore-radio', [nus]),
            const DfuAdvertisement(original, '', [legacyDfuServiceUuid]),
          );
          expect(unnamed.name, isEmpty);
          expect(select(unnamed, entry.key), isNull);
          final named = reduceDfuAdvertisement(
            unnamed,
            DfuAdvertisement(original, entry.value, []),
          );
          expect(named.services, [legacyDfuServiceUuid]);
          expect(select(named, entry.key), original);
        },
      );
    }

    test(
      'Tower empty responses and short/full names retain same-phase proof',
      () {
        var observed = reduceDfuAdvertisement(
          null,
          const DfuAdvertisement(original, 'TOWER_V2', [legacyDfuServiceUuid]),
        );
        for (final response in [
          const DfuAdvertisement(original, '', []),
          const DfuAdvertisement(original, 'TOWER_V2_OTA', []),
          const DfuAdvertisement(original, '', [legacyDfuServiceUuid]),
          const DfuAdvertisement(original, 'TOWER_V2', []),
        ]) {
          observed = reduceDfuAdvertisement(observed, response);
          expect(observed.services, [legacyDfuServiceUuid]);
          expect(select(observed, 'Heltec Tower V2'), original);
        }
      },
    );

    test(
      'fresh NUS replaces DFU proof and refuses application reappearance',
      () {
        var observed = reduceDfuAdvertisement(
          const DfuAdvertisement(original, 'T114_DFU', [legacyDfuServiceUuid]),
          const DfuAdvertisement(original, '', [nus]),
        );
        expect(observed.name, isEmpty);
        expect(observed.services, [nus]);
        observed = reduceDfuAdvertisement(
          observed,
          const DfuAdvertisement(original, 'T114_DFU', []),
        );
        expect(observed.isAmbiguous, isTrue);
        expect(select(observed, 'Heltec T114'), isNull);
      },
    );

    test('a conflicting bootloader name needs new service proof', () {
      final observed = reduceDfuAdvertisement(
        const DfuAdvertisement(original, 'T096_DFU', [legacyDfuServiceUuid]),
        const DfuAdvertisement(original, 'T114_DFU', []),
      );
      expect(observed.isAmbiguous, isTrue);
      expect(select(observed, 'Heltec T096'), isNull);
      expect(select(observed, 'Heltec T114'), isNull);
    });

    test(
      'no DFU UUID is borrowed from another address or unrelated services',
      () {
        final otherAddress = reduceDfuAdvertisement(
          const DfuAdvertisement(original, 'TOWER_V2', [legacyDfuServiceUuid]),
          const DfuAdvertisement('AA:BB:CC:DD:EE:01', 'TOWER_V2', []),
        );
        expect(otherAddress.services, isEmpty);
        expect(select(otherAddress, 'Heltec Tower V2'), isNull);
        final unrelated = reduceDfuAdvertisement(
          const DfuAdvertisement(original, '', ['180f']),
          const DfuAdvertisement(original, 'T114_DFU', []),
        );
        expect(unrelated.isAmbiguous, isTrue);
        expect(select(unrelated, 'Heltec T114'), isNull);
      },
    );
  });

  test(
    'every catalog full/short DFU name joins fresh same-profile service proof',
    () {
      for (final board in CompanionBoardCatalog.specs.where(
        (s) => s.dfuNames.isNotEmpty,
      )) {
        for (final name in board.dfuNames) {
          var observation = reduceDfuAdvertisement(
            null,
            const DfuAdvertisement(original, '', [legacyDfuServiceUuid]),
          );
          observation = reduceDfuAdvertisement(
            observation,
            DfuAdvertisement(original, name, []),
          );
          expect(
            selectDfuBootloader(
              [observation],
              originalAddress: original,
              board: board.aliases.first,
            ),
            original,
            reason: '${board.id}/$name',
          );
          for (final nextName in board.dfuNames) {
            final next = reduceDfuAdvertisement(
              observation,
              DfuAdvertisement(original, nextName, []),
            );
            expect(
              selectDfuBootloader(
                [next],
                originalAddress: original,
                board: board.aliases.first,
              ),
              original,
              reason: '${board.id}/$name->$nextName',
            );
          }
        }
      }
    },
  );

  for (final entry in {
    'Heltec T114': 'T114_DFU',
    'Heltec Tower V2': 'TOWER_V2',
  }.entries) {
    test(
      '${entry.key} timeout recovery uses fresh proven bootloader',
      () async {
        var scans = 0, calls = 0;
        final recovery = NrfDfuRecovery(
          scan: (_, _) async {
            if (++scans == 1) return [];
            final observed = reduceDfuAdvertisement(
              const DfuAdvertisement(original, 'MeshCore-radio', [nus]),
              DfuAdvertisement(original, entry.value, [legacyDfuServiceUuid]),
            );
            return [observed];
          },
          wait: (_) async {},
          transfer: (address, _, force, _) async {
            calls++;
            expect(address, original);
            if (calls == 1) {
              expect(force, isFalse);
              throw PlatformException(code: '8', message: 'GATT CONN TIMEOUT');
            }
            expect(force, isTrue);
          },
        );
        expect(await update(recovery, board: entry.key), original);
        expect(calls, 2);
        expect(scans, 2);
      },
    );
  }

  test('recognizes GATT timeouts but not ZIP or remote protocol failures', () {
    for (final code in ['8', '22', '62', '133', '147', '4101']) {
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
        PlatformException(code: '4098', message: 'File error'),
      ),
      isFalse,
    );
    expect(
      isDfuConnectionFailure(PlatformException(code: '8'), errorType: 3),
      isFalse,
    );
    expect(
      isDfuConnectionFailure(PlatformException(code: '22'), errorType: 3),
      isFalse,
    );
    expect(isDfuConnectionFailure(StateError('GATT CONN TIMEOUT')), isFalse);
  });

  for (final errorCode in [8, 22, 4101]) {
    test(
      'connection error $errorCode scans and retries the actual changed address',
      () async {
        final calls = <String>[];
        final statuses = <String>[];
        final scans = <Duration>[];
        final waits = <Duration>[];
        final recovery = NrfDfuRecovery(
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
              events.onError?.call(
                address,
                errorCode,
                2,
                'GATT connection failed',
              );
              throw PlatformException(
                code: '$errorCode',
                message: 'GATT connection failed',
              );
            }
          },
        );
        expect(
          await recovery.update(
            originalAddress: original,
            path: '/test/companion.zip',
            board: 'Heltec T096',
            applicationOnly: true,
            onStatus: statuses.add,
          ),
          bootloader,
        );
        expect(
          statuses,
          contains(
            'Bluetooth DFU error (code=$errorCode, type=2): GATT connection failed',
          ),
        );
        expect(calls, ['$original/false', '$bootloader/true']);
        expect(scans, [const Duration(seconds: 2), const Duration(seconds: 8)]);
        expect(waits, [const Duration(seconds: 2)]);
      },
    );
  }

  for (final address in [original, bootloader]) {
    test(
      'already manual OTA at $address connects directly without app handoff',
      () async {
        var calls = 0;
        final recovery = NrfDfuRecovery(
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
    'possible first bytes',
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
          if (reason == 'possible first bytes') {
            events.onDfuProcessStarted?.call(address);
          }
          if (reason == 'validation') {
            events.onFirmwareValidating?.call(address);
          }
          if (reason == 'remote rejection') {
            events.onError?.call(address, 8, 3, 'Rejected');
          }
          throw PlatformException(code: reason == 'file' ? '4098' : '8');
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

  test(
    'verified factory address is explicit, never inferred from nearby names',
    () {
      const factory = 'CC:01:02:03:04:05';
      const device = DfuAdvertisement(factory, 'T096_DFU', [
        legacyDfuServiceUuid,
      ]);
      expect(
        selectDfuBootloader(
          [device],
          originalAddress: original,
          board: 'Heltec T096',
        ),
        isNull,
      );
      expect(
        selectDfuBootloader(
          [device],
          originalAddress: original,
          board: 'Heltec T096',
          verifiedBootloaderAddress: factory,
        ),
        factory,
      );
      expect(
        () => dfuCandidateAddresses(
          original,
          verifiedBootloaderAddress: 'invalid',
        ),
        throwsFormatException,
      );
      expect(
        dfuCandidateAddresses(original, verifiedBootloaderAddress: original),
        [original, bootloader],
      );
    },
  );

  test('unknown board never starts a scan or transfer', () async {
    final recovery = NrfDfuRecovery(
      scan: (_, _) async => fail('Unknown board must not scan'),
      transfer: (_, _, _, _) async => fail('Unknown board must not write'),
    );
    await expectLater(
      update(recovery, board: 'Custom nRF52 board'),
      throwsStateError,
    );
  });

  test(
    'separate updater instances cannot overlap even during discovery',
    () async {
      final scanned = Completer<List<DfuAdvertisement>>();
      final first = NrfDfuRecovery(
        scan: (_, _) => scanned.future,
        transfer: (_, _, _, _) async {},
      );
      final second = NrfDfuRecovery(
        scan: (_, _) async => [],
        transfer: (_, _, _, _) async {},
      );
      final pending = update(first);
      await expectLater(update(second), throwsStateError);
      scanned.complete([]);
      await pending;
      expect(await update(second), original);
    },
  );

  test('cancel before transfer never asks native to write or abort', () async {
    final scanned = Completer<List<DfuAdvertisement>>();
    final recovery = NrfDfuRecovery(
      scan: (_, _) => scanned.future,
      transfer: (_, _, _, _) async => fail('Cancelled before transfer'),
      abort: () async => fail('No active native transfer'),
    );
    final pending = update(recovery);
    final failed = expectLater(pending, throwsStateError);
    await recovery.cancel();
    scanned.complete([]);
    await failed;
    expect(recovery.nativeTerminationConfirmed, isTrue);
    expect(recovery.isQuarantined, isFalse);
  });

  testWidgets(
    'hung native Future is aborted, quarantine prevents any second service',
    (tester) async {
      final native = Completer<void>();
      var writes = 0, aborts = 0;
      DfuEventHandler? callbacks;
      final recovery = NrfDfuRecovery(
        scan: (_, _) async => [],
        transfer: (_, _, _, events) {
          writes++;
          callbacks = events;
          return native.future;
        },
        abort: () async {
          aborts++;
        },
      );
      final pending = update(recovery);
      final failed = expectLater(
        pending,
        throwsA(
          isA<DfuStoppedException>().having(
            (e) => e.nativeTerminationConfirmed,
            'no terminal confirmation',
            isFalse,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 60));
      await tester.pump(const Duration(seconds: 10));
      await failed;
      expect(aborts, 1);
      expect(writes, 1);
      expect(recovery.isQuarantined, isTrue);
      expect(recovery.nativeTerminationConfirmed, isFalse);
      final other = NrfDfuRecovery(
        scan: (_, _) async => [],
        transfer: (_, _, _, _) async =>
            fail('Quarantined service must own native DFU'),
      );
      await expectLater(update(other), throwsStateError);
      // A late true terminal event is proof that the OS service finally stopped.
      callbacks!.onDfuAborted?.call(original);
      await tester.pump();
      expect(recovery.isQuarantined, isFalse);
      expect(recovery.nativeTerminationConfirmed, isTrue);
      native.complete();
      await tester.pump();
      other.dispose();
    },
  );

  testWidgets(
    'abort acknowledgement plus true terminal Future safely clears ownership',
    (tester) async {
      final native = Completer<void>();
      var writes = 0, aborts = 0;
      final recovery = NrfDfuRecovery(
        scan: (_, _) async => [],
        transfer: (_, _, _, _) {
          writes++;
          return native.future;
        },
        abort: () async {
          aborts++;
          native.completeError(PlatformException(code: 'ABORTED'));
        },
      );
      final pending = update(recovery);
      final failed = expectLater(
        pending,
        throwsA(
          isA<DfuStoppedException>().having(
            (e) => e.nativeTerminationConfirmed,
            'terminal confirmed',
            isTrue,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 60));
      await tester.pump();
      await failed;
      expect(aborts, 1);
      expect(writes, 1);
      expect(recovery.isQuarantined, isFalse);
      expect(recovery.nativeTerminationConfirmed, isTrue);
    },
  );

  testWidgets(
    'payload starts before progress; deadline never automatically retries',
    (tester) async {
      final native = Completer<void>();
      var writes = 0, scans = 0;
      late DfuEventHandler callbacks;
      final recovery = NrfDfuRecovery(
        scan: (_, _) async {
          scans++;
          return [];
        },
        transfer: (address, _, _, events) {
          writes++;
          callbacks = events;
          events.onDfuProcessStarted?.call(address);
          return native.future;
        },
        abort: () async {
          callbacks.onDfuAborted?.call(original);
        },
      );
      final pending = update(recovery);
      final failed = expectLater(pending, throwsA(isA<DfuStoppedException>()));
      await tester.pump();
      await tester.pump(const Duration(seconds: 60));
      await tester.pump();
      await failed;
      expect(scans, 1);
      expect(writes, 1);
      native.complete();
      await tester.pump();
    },
  );

  testWidgets('progress resets inactivity but cannot bypass overall deadline', (
    tester,
  ) async {
    final native = Completer<void>();
    late DfuEventHandler events;
    final recovery = NrfDfuRecovery(
      overallTimeout: const Duration(seconds: 90),
      scan: (_, _) async => [],
      transfer: (_, _, _, e) {
        events = e;
        return native.future;
      },
      abort: () async {
        events.onDfuAborted?.call(original);
      },
    );
    final pending = update(recovery);
    final failed = expectLater(
      pending,
      throwsA(
        isA<DfuStoppedException>().having(
          (e) => e.message,
          'overall limit',
          contains('overall'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 45));
    events.onProgressChanged?.call(original, 10, 0, 0, 1, 1);
    await tester.pump(const Duration(seconds: 45));
    await tester.pump();
    await failed;
    native.complete();
    await tester.pump();
  });

  testWidgets('dispose aborts native and suppresses late callbacks', (
    tester,
  ) async {
    final native = Completer<void>();
    final progress = <int>[];
    late DfuEventHandler events;
    var aborts = 0;
    final recovery = NrfDfuRecovery(
      scan: (_, _) async => [],
      transfer: (_, _, _, e) {
        events = e;
        return native.future;
      },
      abort: () async {
        aborts++;
        events.onDfuAborted?.call(original);
      },
    );
    final pending = recovery.update(
      originalAddress: original,
      path: '/test/file.zip',
      board: 'Heltec T096',
      applicationOnly: true,
      onProgress: progress.add,
    );
    final failed = expectLater(pending, throwsStateError);
    await tester.pump();
    recovery.dispose();
    events.onProgressChanged?.call(original, 75, 0, 0, 1, 1);
    await tester.pump();
    await failed;
    expect(aborts, 1);
    expect(progress, isEmpty);
    expect(recovery.nativeTerminationConfirmed, isTrue);
    native.complete();
    await tester.pump();
  });

  testWidgets(
    'late first-attempt events cannot finish a new recovery attempt',
    (tester) async {
      var writes = 0, scans = 0;
      late DfuEventHandler oldEvents;
      final second = Completer<void>();
      final recovery = NrfDfuRecovery(
        scan: (_, _) async => ++scans == 1 ? [] : [advert],
        wait: (_) async {},
        transfer: (_, _, _, events) {
          writes++;
          if (writes == 1) {
            oldEvents = events;
            return Future.error(PlatformException(code: '8'));
          }
          return second.future;
        },
      );
      var completed = false;
      final pending = update(recovery).then((value) {
        completed = true;
        return value;
      });
      await tester.pump();
      expect(writes, 2);
      oldEvents.onDfuCompleted?.call(original);
      oldEvents.onError?.call(original, 133, 2, 'late');
      await tester.pump();
      expect(completed, isFalse);
      second.complete();
      await tester.pump();
      expect(await pending, bootloader);
    },
  );

  testWidgets('OS proof is required to release a callback-lost quarantine', (
    tester,
  ) async {
    final native = Completer<void>();
    final recovery = NrfDfuRecovery(
      scan: (_, _) async => [],
      transfer: (_, _, _, _) => native.future,
      abort: () async {},
    );
    final pending = update(recovery);
    final failed = expectLater(pending, throwsStateError);
    await tester.pump();
    await tester.pump(const Duration(seconds: 70));
    await failed;
    expect(recovery.isQuarantined, isTrue);
    expect(
      await recovery.recoverQuarantine(verifyStopped: () async => false),
      isFalse,
    );
    expect(
      await recovery.recoverQuarantine(
        verifyStopped: () async => throw StateError('no OS proof'),
      ),
      isFalse,
    );
    expect(recovery.isQuarantined, isTrue);
    expect(
      await recovery.recoverQuarantine(verifyStopped: () async => true),
      isTrue,
    );
    expect(recovery.nativeTerminationConfirmed, isTrue);
    expect(recovery.isQuarantined, isFalse);
    native.complete();
    await tester.pump();
  });

  test(
    'verification itself holds native ownership and refuses active transfers',
    () async {
      final proof = Completer<bool>();
      final recovery = NrfDfuRecovery(
        scan: (_, _) async => [],
        transfer: (_, _, _, _) async {},
      );
      final verifying = recovery.recoverQuarantine(
        verifyStopped: () => proof.future,
      );
      final other = NrfDfuRecovery(
        scan: (_, _) async => [],
        transfer: (_, _, _, _) async {},
      );
      await expectLater(update(other), throwsStateError);
      expect(
        await other.recoverQuarantine(
          verifyStopped: () async => fail('Must not verify another owner'),
        ),
        isFalse,
      );
      proof.complete(true);
      expect(await verifying, isTrue);
      expect(await update(other), original);
    },
  );

  testWidgets(
    'late terminal callback cannot release ownership during OS proof and persistent flag update',
    (tester) async {
      final native = Completer<void>();
      final proof = Completer<bool>();
      final recovery = NrfDfuRecovery(
        scan: (_, _) async => [],
        transfer: (_, _, _, _) => native.future,
        abort: () async {},
      );
      final pending = update(recovery);
      final failed = expectLater(pending, throwsStateError);
      await tester.pump();
      await tester.pump(const Duration(seconds: 70));
      await failed;
      final verifying = recovery.recoverQuarantine(
        verifyStopped: () => proof.future,
      );
      native.complete();
      await tester.pump();
      final scan = Completer<List<DfuAdvertisement>>();
      final other = NrfDfuRecovery(
        scan: (_, _) => scan.future,
        transfer: (_, _, _, _) async {},
      );
      await expectLater(update(other), throwsStateError);
      proof.complete(true);
      expect(await verifying, isTrue);
      final otherPending = update(other);
      scan.complete([]);
      await otherPending;
    },
  );
}
