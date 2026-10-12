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
    expect(
      select([const DfuAdvertisement(original, 'T096_DFU', [])]),
      original,
    );
    expect(select([const DfuAdvertisement(original, 'AdaDFU', [])]), original);
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
      () => select([advert, const DfuAdvertisement(original, 'T096_DFU', [])]),
      throwsStateError,
    );
    expect(select([advert, advert]), bootloader);
  });

  test(
    'unknown boards require both a DFU name and service at the known address',
    () {
      String? select(List<String> services) => selectDfuBootloader(
        [DfuAdvertisement(original, 'BOARD_DFU', services)],
        originalAddress: original,
        board: 'Unknown board',
      );
      expect(select([]), isNull);
      expect(select([legacyDfuServiceUuid]), original);
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
          scan: (_, _) async => [DfuAdvertisement(address, 'T096_DFU', [])],
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
}
