import 'dart:io';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_uuids.dart';
import 'package:meshcore_open/services/dfu_gatt_discovery.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

const dfuUuid = '00001530-1212-efde-1523-785feabcd123';
const controlUuid = '00001531-1212-efde-1523-785feabcd123';
BluetoothService service(String uuid) => BluetoothService.fromProto(
  BmBluetoothService(
    remoteId: const DeviceIdentifier('CF:A8:18:36:DE:8B'),
    serviceUuid: Guid(uuid),
    primaryServiceUuid: null,
    characteristics: [],
  ),
);

class _Characteristic extends BluetoothCharacteristic {
  _Characteristic(
    String service,
    String characteristic, {
    bool write = false,
    bool withoutResponse = false,
    bool readable = false,
    bool notify = false,
    this.readValue = const [],
    String? device,
  }) : _properties = CharacteristicProperties(
         write: write,
         writeWithoutResponse: withoutResponse,
         read: readable,
         notify: notify,
       ),
       super(
         remoteId: DeviceIdentifier(device ?? 'CF:A8:18:36:DE:8B'),
         serviceUuid: Guid(service),
         characteristicUuid: Guid(characteristic),
       );
  final CharacteristicProperties _properties;
  final List<int> readValue;
  @override
  CharacteristicProperties get properties => _properties;
  @override
  Future<List<int>> read({int timeout = 15}) async => readValue;
}

class _HandoffControl extends _Characteristic {
  _HandoffControl({bool withoutResponse = false})
    : super(
        dfuUuid,
        controlUuid,
        write: !withoutResponse,
        withoutResponse: withoutResponse,
      );

  final steps = <String>[];
  bool notificationsEnabled = true;
  bool current = true;
  bool disconnected = false;
  Object? notifyError, writeError;
  void Function()? afterNotify;

  @override
  Future<bool> setNotifyValue(
    bool notify, {
    int timeout = 15,
    bool forceIndications = false,
  }) async {
    expect(notify, isTrue);
    expect(timeout, 8);
    steps.add('notify');
    if (notifyError != null) throw notifyError!;
    afterNotify?.call();
    return notificationsEnabled;
  }

  @override
  Future<void> write(
    List<int> value, {
    bool withoutResponse = false,
    bool allowLongWrite = false,
    int timeout = 15,
  }) async {
    expect(value, [0x01, 0x04]);
    expect(withoutResponse, !properties.write);
    expect(allowLongWrite, isFalse);
    expect(timeout, 8);
    steps.add('write');
    if (writeError != null) throw writeError!;
  }

  Future<void> handoff() => enterLegacyApplicationDfu(
    control: this,
    isCurrentCompanion: () => current,
    isDisconnected: () => disconnected,
    beforeWrite: () => steps.add('suppress reconnect'),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final invalid in [
    '',
    'NUS',
    'revision',
    'name',
    'packet',
    'other radio',
  ]) {
    test(
      'fresh bootloader GATT proof ${invalid.isEmpty ? 'succeeds' : 'rejects $invalid'}',
      () async {
        final dfu = service(dfuUuid)
          ..characteristics.addAll([
            _Characteristic(dfuUuid, controlUuid, write: true, notify: true),
            _Characteristic(
              dfuUuid,
              '00001532-1212-efde-1523-785feabcd123',
              withoutResponse: invalid != 'packet',
            ),
            _Characteristic(
              dfuUuid,
              '00001534-1212-efde-1523-785feabcd123',
              readable: true,
              readValue: invalid == 'revision' ? [1, 0] : [8, 0],
            ),
          ]);
        final gap = service('1800')
          ..characteristics.add(
            _Characteristic(
              '1800',
              '2a00',
              readable: true,
              readValue:
                  (invalid == 'name' ? 'T114_DFU' : 'T096_DFU').codeUnits,
            ),
          );
        final actual = await inspectLegacyBootloaderServices(
          [dfu, gap, if (invalid == 'NUS') service(MeshCoreUuids.service)],
          address: invalid == 'other radio'
              ? 'AA:BB:CC:DD:EE:FF'
              : 'CF:A8:18:36:DE:8B',
          board: 'Heltec T096',
        );
        expect(actual, invalid.isEmpty ? 'T096_DFU' : isNull);
      },
    );
  }
  for (final withoutResponse in [false, true]) {
    test(
      'handoff subscribes then writes only the application opcode ($withoutResponse)',
      () async {
        final control = _HandoffControl(withoutResponse: withoutResponse);
        await control.handoff();
        expect(control.steps, ['notify', 'suppress reconnect', 'write']);
      },
    );
  }
  test(
    'handoff refuses a changed Companion before or after subscribe',
    () async {
      final before = _HandoffControl()..current = false;
      await expectLater(before.handoff(), throwsStateError);
      expect(before.steps, isEmpty);
      final after = _HandoffControl();
      after.afterNotify = () => after.current = false;
      await expectLater(after.handoff(), throwsStateError);
      expect(after.steps, ['notify']);
    },
  );
  for (final returnsFalse in [false, true]) {
    test('failed DFU subscription never writes ($returnsFalse)', () async {
      final control = _HandoffControl();
      if (returnsFalse) {
        control.notificationsEnabled = false;
      } else {
        control.notifyError = StateError('CCCD failed');
      }
      await expectLater(control.handoff(), throwsStateError);
      expect(control.steps, ['notify']);
    });
  }
  for (final disconnected in [false, true]) {
    test(
      'write failure continues only after reset disconnected the link ($disconnected)',
      () async {
        final control = _HandoffControl()
          ..writeError = StateError('Write failed')
          ..disconnected = disconnected;
        if (disconnected) {
          await control.handoff();
        } else {
          await expectLater(control.handoff(), throwsStateError);
        }
        expect(control.steps, ['notify', 'suppress reconnect', 'write']);
      },
    );
  }
  test(
    'missing reset ACK permits discovery despite stale connected state',
    () async {
      final control = _HandoffControl()
        ..writeError = FlutterBluePlusException(
          ErrorPlatform.fbp,
          'writeCharacteristic',
          FbpErrorCode.timeout.index,
          'Timed out after 8s',
        );
      await control.handoff();
      expect(control.steps, ['notify', 'suppress reconnect', 'write']);
    },
  );
  for (final platform in [ErrorPlatform.android, ErrorPlatform.fbp]) {
    test(
      'native write rejection or other operation timeout is not a reset ACK ($platform)',
      () async {
        final control = _HandoffControl()
          ..writeError = FlutterBluePlusException(
            platform,
            platform == ErrorPlatform.fbp
                ? 'setNotifyValue'
                : 'writeCharacteristic',
            1,
            'Rejected',
          );
        await expectLater(
          control.handoff(),
          throwsA(isA<FlutterBluePlusException>()),
        );
      },
    );
  }
  for (final code in [8, 22, 62, 133, 147]) {
    test(
      'Android reset status $code permits only fresh bootloader discovery',
      () async {
        final control = _HandoffControl()
          ..writeError = FlutterBluePlusException(
            ErrorPlatform.android,
            'writeCharacteristic',
            code,
            'Link lost',
          );
        await control.handoff();
        expect(control.steps, ['notify', 'suppress reconnect', 'write']);
        final changed = _HandoffControl()
          ..writeError = FlutterBluePlusException(
            ErrorPlatform.android,
            'writeCharacteristic',
            code,
            'Link lost',
          );
        changed.afterNotify = () => changed.current = false;
        await expectLater(changed.handoff(), throwsStateError);
        expect(changed.steps, ['notify']);
      },
    );
  }
  for (final code in [5, 15, 128, 137]) {
    test(
      'Android authentication/write rejection $code is not reset proof',
      () async {
        final control = _HandoffControl()
          ..writeError = FlutterBluePlusException(
            ErrorPlatform.android,
            'writeCharacteristic',
            code,
            'Rejected',
          );
        await expectLater(
          control.handoff(),
          throwsA(isA<FlutterBluePlusException>()),
        );
      },
    );
  }
  test('NUS or read-only/wrong controls do not prove application DFU', () {
    final nus = service(MeshCoreUuids.service)
      ..characteristics.add(
        _Characteristic(MeshCoreUuids.service, controlUuid, write: true),
      );
    final readonly = service(dfuUuid)
      ..characteristics.add(_Characteristic(dfuUuid, controlUuid));
    final wrong = service(dfuUuid)
      ..characteristics.add(_Characteristic(dfuUuid, '1532', write: true));
    final wrongService = service(dfuUuid)
      ..characteristics.add(
        _Characteristic(MeshCoreUuids.service, controlUuid, write: true),
      );
    final otherRadio = service(dfuUuid)
      ..characteristics.add(
        _Characteristic(
          dfuUuid,
          controlUuid,
          write: true,
          device: 'AA:BB:CC:DD:EE:FF',
        ),
      );
    for (final candidate in [nus, readonly, wrong, wrongService, otherRadio]) {
      expect(supportsLegacyApplicationDfu([candidate]), isFalse);
    }
    expect(supportsLegacyApplicationDfu([]), isFalse);
  });
  for (final withoutResponse in [false, true]) {
    test(
      'actual DFU control accepts ${withoutResponse ? 'writeWithoutResponse' : 'write'}',
      () {
        final dfu = service(dfuUuid)
          ..characteristics.add(
            _Characteristic(
              dfuUuid,
              controlUuid,
              write: !withoutResponse,
              withoutResponse: withoutResponse,
            ),
          );
        expect(
          supportsLegacyApplicationDfu([service(MeshCoreUuids.service), dfu]),
          isTrue,
        );
      },
    );
  }
  test(
    'connector capability is connection-gated and clears on disconnect',
    () async {
      SharedPreferences.setMockInitialValues({});
      PrefsManager.reset();
      await PrefsManager.initialize();
      final connector = MeshCoreConnector();
      addTearDown(connector.dispose);
      expect(connector.supportsNordicCompanionDfu, isFalse);
      await connector.disconnect(manual: false, skipBleDeviceDisconnect: true);
      expect(connector.supportsNordicCompanionDfu, isFalse);
      final source = await File(
        'lib/connector/meshcore_connector.dart',
      ).readAsString();
      expect(
        source,
        matches(
          RegExp(
            r'bool get supportsNordicCompanionDfu\s*=>\s*isConnected\s*&&',
          ),
        ),
      );
      expect(
        source,
        contains(
          '_hasNordicDfuControl = supportsLegacyApplicationDfu(services);',
        ),
      );
    },
  );
  test(
    'Android bootloader cache refreshes once before rediscovering NUS',
    () async {
      final steps = <String>[];
      var calls = 0;
      final nus = service(MeshCoreUuids.service);
      final result = await discoverWithDfuCacheRecovery(
        isAndroid: true,
        discover: () async {
          steps.add('discover');
          return ++calls == 1 ? [service(dfuUuid)] : [nus];
        },
        refreshCache: () async {
          steps.add('refresh');
        },
        wait: (delay) async {
          expect(delay, const Duration(seconds: 1));
          steps.add('wait');
        },
      );
      expect(result, [nus]);
      expect(steps, ['discover', 'refresh', 'wait', 'discover']);
    },
  );

  for (final uuids in <List<String>>[
    [MeshCoreUuids.service],
    [MeshCoreUuids.service, dfuUuid],
    [],
    ['180f'],
  ]) {
    test('does not clear a normal or unrelated GATT cache: $uuids', () async {
      final services = uuids.map(service).toList();
      expect(
        await discoverWithDfuCacheRecovery(
          isAndroid: true,
          discover: () async => services,
          refreshCache: () async => fail('Do not refresh'),
        ),
        services,
      );
    });
  }

  test('non-Android never invokes Android cache refresh', () async {
    final services = [service(dfuUuid)];
    expect(
      await discoverWithDfuCacheRecovery(
        isAndroid: false,
        refreshBeforeDiscovery: true,
        discover: () async => services,
        refreshCache: () async => fail('Android-only'),
      ),
      services,
    );
  });

  test(
    'DFU preflight refreshes even when a cached application has NUS',
    () async {
      final steps = <String>[];
      final current = [service(MeshCoreUuids.service), service(dfuUuid)];
      final result = await discoverWithDfuCacheRecovery(
        isAndroid: true,
        refreshBeforeDiscovery: true,
        refreshCache: () async => steps.add('refresh'),
        wait: (_) async => steps.add('wait'),
        discover: () async {
          steps.add('discover');
          return current;
        },
      );
      expect(result, current);
      expect(steps, ['refresh', 'wait', 'discover']);
      expect(supportsLegacyApplicationDfu(result), isFalse);
    },
  );

  test(
    'failed DFU preflight refresh cannot fall back to stale services',
    () async {
      await expectLater(
        discoverWithDfuCacheRecovery(
          isAndroid: true,
          refreshBeforeDiscovery: true,
          refreshCache: () async => throw StateError('Refresh unavailable'),
          wait: (_) async => fail('Must not continue'),
          discover: () async => fail('Must not reuse the bonded cache'),
        ),
        throwsStateError,
      );
    },
  );

  test('a real bootloader without NUS cannot cause a refresh loop', () async {
    var discovers = 0, refreshes = 0;
    final services = [service(dfuUuid)];
    expect(
      await discoverWithDfuCacheRecovery(
        isAndroid: true,
        discover: () async {
          discovers++;
          return services;
        },
        refreshCache: () async {
          refreshes++;
        },
        wait: (_) async {},
      ),
      services,
    );
    expect(discovers, 2);
    expect(refreshes, 1);
  });

  test(
    'failed refresh propagates without rediscovering or changing a bond',
    () async {
      var discovers = 0;
      await expectLater(
        discoverWithDfuCacheRecovery(
          isAndroid: true,
          discover: () async {
            discovers++;
            return [service(dfuUuid)];
          },
          refreshCache: () async => throw StateError('Refresh unavailable'),
          wait: (_) async => fail('Must not continue'),
        ),
        throwsStateError,
      );
      expect(discovers, 1);
    },
  );
}
