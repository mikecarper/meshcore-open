import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_uuids.dart';
import 'package:meshcore_open/services/dfu_gatt_discovery.dart';

const dfuUuid = '00001530-1212-efde-1523-785feabcd123';
BluetoothService service(String uuid) => BluetoothService.fromProto(
  BmBluetoothService(
    remoteId: const DeviceIdentifier('CF:A8:18:36:DE:8B'),
    serviceUuid: Guid(uuid),
    primaryServiceUuid: null,
    characteristics: [],
  ),
);

void main() {
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
        discover: () async => services,
        refreshCache: () async => fail('Android-only'),
      ),
      services,
    );
  });

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
