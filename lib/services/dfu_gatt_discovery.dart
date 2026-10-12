import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../connector/meshcore_uuids.dart';

/// An Android bond can survive DFU while its cached GATT database still
/// describes the bootloader. Refresh services, not the bond or radio settings.
Future<List<BluetoothService>> discoverWithDfuCacheRecovery({
  required bool isAndroid,
  required Future<List<BluetoothService>> Function() discover,
  required Future<void> Function() refreshCache,
  Future<void> Function(Duration)? wait,
  void Function()? onRefresh,
}) async {
  final services = await discover();
  final uuids = services.map((s) => s.uuid.str.toLowerCase()).toSet();
  if (!isAndroid ||
      uuids.contains(MeshCoreUuids.service) ||
      !uuids.contains('00001530-1212-efde-1523-785feabcd123')) {
    return services;
  }
  onRefresh?.call();
  await refreshCache();
  await (wait ?? Future<void>.delayed)(const Duration(seconds: 1));
  // At most one refresh per connection. A radio really still in DFU will
  // remain without NUS, and the connector's normal check will reject it.
  return discover();
}
