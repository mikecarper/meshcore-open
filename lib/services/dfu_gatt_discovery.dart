import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../connector/meshcore_uuids.dart';
import 'companion_board_catalog.dart';

/// Prove the connected application's legacy buttonless handoff control is
/// writable. A Nordic board name or advertised DFU UUID alone is insufficient.
bool supportsLegacyApplicationDfu(Iterable<BluetoothService> services) =>
    legacyApplicationDfuControl(services) != null;

BluetoothCharacteristic? legacyApplicationDfuControl(
  Iterable<BluetoothService> services,
) {
  for (final service in services) {
    if (service.uuid.str.toLowerCase() !=
        '00001530-1212-efde-1523-785feabcd123') {
      continue;
    }
    for (final control in service.characteristics) {
      if (control.remoteId == service.remoteId &&
          control.serviceUuid == service.uuid &&
          control.uuid.str.toLowerCase() ==
              '00001531-1212-efde-1523-785feabcd123' &&
          (control.properties.write ||
              control.properties.writeWithoutResponse)) {
        return control;
      }
    }
  }
  return null;
}

/// Send only the legacy application-to-bootloader opcode on the established
/// Companion connection. Completion is not proof of DFU mode: a fresh scan of
/// the exact radio is still required before the native payload transfer.
Future<void> enterLegacyApplicationDfu({
  required BluetoothCharacteristic control,
  required bool Function() isCurrentCompanion,
  required bool Function() isDisconnected,
  required void Function() beforeWrite,
}) async {
  void requireCurrent() {
    if (!isCurrentCompanion()) {
      throw StateError('Companion changed before Bluetooth DFU handoff.');
    }
  }

  requireCurrent();
  if (!await control.setNotifyValue(true, timeout: 8)) {
    throw StateError('Could not enable the Bluetooth DFU control response.');
  }
  requireCurrent();
  beforeWrite();
  try {
    await control.write(
      const [0x01, 0x04],
      withoutResponse: !control.properties.write,
      timeout: 8,
    );
  } catch (error) {
    // Reset can beat the ATT write response while Android still reports the
    // old link as connected until its supervision timeout. This one bounded
    // write timeout or Android link-loss status may continue to disconnect +
    // exact bootloader discovery;
    // it must never be interpreted as success or authorize a blind transfer.
    final lostResetResponse =
        error is FlutterBluePlusException &&
        error.function == 'writeCharacteristic' &&
        ((error.platform == ErrorPlatform.fbp &&
                error.code == FbpErrorCode.timeout.index) ||
            (error.platform == ErrorPlatform.android &&
                const [8, 22, 62, 133, 147].contains(error.code))) &&
        isCurrentCompanion();
    if (!isDisconnected() && !lostResetResponse) rethrow;
  }
}

/// A bonded bootloader may not appear in a discovery scan. A fresh GATT read
/// may prove it instead, but application mode and cached names are never proof.
Future<String?> inspectLegacyBootloaderServices(
  List<BluetoothService> services, {
  required String address,
  required String board,
}) async {
  if (services.any(
    (s) =>
        s.remoteId.str.toUpperCase() != address.toUpperCase() ||
        s.uuid.str.toLowerCase() == MeshCoreUuids.service,
  )) {
    return null;
  }
  final control = legacyApplicationDfuControl(services);
  if (control == null || !control.properties.notify) return null;
  BluetoothCharacteristic? find(String service, String uuid) {
    for (final s in services.where((s) => s.uuid == Guid(service))) {
      for (final c in s.characteristics) {
        if (c.remoteId == s.remoteId &&
            c.serviceUuid == s.uuid &&
            c.uuid == Guid(uuid)) {
          return c;
        }
      }
    }
    return null;
  }

  const dfu = '00001530-1212-efde-1523-785feabcd123';
  final packet = find(dfu, '00001532-1212-efde-1523-785feabcd123');
  final revision = find(dfu, '00001534-1212-efde-1523-785feabcd123');
  final name = find('1800', '2a00');
  if (packet?.properties.writeWithoutResponse != true ||
      revision?.properties.read != true ||
      name?.properties.read != true) {
    return null;
  }
  final version = await revision!.read(timeout: 8);
  // Adafruit Legacy bootloader revision 0.8, not buttonless application 0.1.
  if (version.length != 2 || version[0] != 8 || version[1] != 0) return null;
  final bytes = await name!.read(timeout: 8);
  if (bytes.isEmpty ||
      bytes.length > 40 ||
      bytes.any((b) => b < 32 || b > 126)) {
    return null;
  }
  final actualName = String.fromCharCodes(bytes).toUpperCase();
  final names = CompanionBoardCatalog.lookup(board)?.dfuNames ?? const [];
  return names.contains(actualName) ? actualName : null;
}

/// An Android bond can survive DFU while its cached GATT database still
/// describes the bootloader. Refresh services, not the bond or radio settings.
Future<List<BluetoothService>> discoverWithDfuCacheRecovery({
  required bool isAndroid,
  required Future<List<BluetoothService>> Function() discover,
  required Future<void> Function() refreshCache,
  bool refreshBeforeDiscovery = false,
  Future<void> Function(Duration)? wait,
  void Function()? onRefresh,
}) async {
  if (isAndroid && refreshBeforeDiscovery) {
    // A replacement application may retain NUS while moving DFU handles.
    // Checking only for NUS cannot detect that stale bonded database.
    onRefresh?.call();
    await refreshCache();
    await (wait ?? Future<void>.delayed)(const Duration(seconds: 1));
    return discover();
  }
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
