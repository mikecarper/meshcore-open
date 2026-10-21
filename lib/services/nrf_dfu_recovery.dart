import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:nordic_dfu/nordic_dfu.dart';

import 'nrf_dfu_package.dart';
import '../utils/platform_info.dart';

const legacyDfuServiceUuid = '00001530-1212-efde-1523-785feabcd123';
const _nusUuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
final _macPattern = RegExp(r'^[0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5}$');

class DfuAdvertisement {
  const DfuAdvertisement(this.address, this.name, this.services);
  final String address, name;
  final List<String> services;
}

// Exact aliases offered by the app's maintained board catalog. Names come
// from OTAFIX board.cmake; models come from each matching board.h. Keep
// storage/carrier variants separate even when they share the same nRF52.
const _additionalDfuProfiles =
    <({List<String> boards, List<String> names, List<String> models})>[
      (
        boards: [
          'Heltec Tower V2',
          'Heltec Mesh Tower V2',
          'MeshTower V2',
          'tower_v2',
          'Heltec Tower V2 SD',
          'Heltec MeshTower V2 SD',
          'MeshTower V2 SD',
          'tower_v2_sd',
          'Heltec_tower_v2_sdcard',
          'Heltec_mesh_tower_v2_sdcard',
          'mesh_tower_v2_sdcard',
          'tower_v2_sdcard',
        ],
        names: ['TOWER_V2_OTA', 'TOWER_V2'],
        models: ['HT-n5262'],
      ),
      (
        boards: ['RAK WisMesh Tag', 'WisMesh Tag'],
        names: ['RTAG_DFU'],
        models: ['WisMesh Tag'],
      ),
      (
        boards: ['Heltec MeshPocket', 'Heltec Mesh Pocket', 'Mesh Pocket'],
        names: ['MESH_POCKET_OTA', 'MESH_POC'],
        models: ['Mesh Pocket'],
      ),
      (
        boards: ['RAK4631 + W25Q16', 'RAK4631 W25Q16'],
        names: ['4631_W25Q16_DFU', '4631_W25'],
        models: ['RAK4631 + W25Q16'],
      ),
      (
        boards: ['RAK4631 + RAK15001 Slot C', 'RAK4631 RAK15001 C'],
        names: ['4631_15001C_DFU', '4631_150'],
        models: ['RAK4631 + RAK15001 Slot C'],
      ),
      (
        boards: ['RAK3401 + RAK13302 + W25Q16', 'RAK3401 RAK13302 W25Q16'],
        names: ['3401_W25Q16_DFU', '3401_W25'],
        models: ['RAK3401 + RAK13302 + W25Q16'],
      ),
      (
        boards: ['LilyGo T-Echo Lite', 'T-Echo Lite'],
        names: ['LTEL_DFU'],
        models: ['T-Echo-Lite'],
      ),
      (
        boards: ['LilyGo T-Echo Card', 'T-Echo Card'],
        names: ['LTECARD_DFU', 'LTECARD_'],
        models: ['T-Echo Card'],
      ),
      (
        boards: ['LilyGo T-Impulse-Plus', 'LilyGo T-Impulse Plus'],
        names: ['LTIMP_DFU', 'LTIMP_DF'],
        models: ['T-Impulse Plus'],
      ),
      (
        boards: ['Keepteen LT1'],
        names: ['KEEPTEENLT1_OTA', 'KEEPTEEN'],
        models: ['LT1'],
      ),
      (
        boards: ['Nano G2 Ultra', 'B and Q Nano G2 Ultra'],
        names: ['NANOG2_DFU', 'NANOG2_D'],
        models: ['Nano G2 Ultra'],
      ),
      (
        boards: ['Elecrow ThinkNode-M1', 'ThinkNode M1'],
        names: ['TNM1_DFU'],
        models: ['ThinkNodeM1'],
      ),
      (
        boards: ['Elecrow ThinkNode M3', 'ThinkNode M3'],
        names: ['TNM3_DFU'],
        models: ['ThinkNode-M3'],
      ),
      (
        boards: ['Elecrow ThinkNode M6', 'ThinkNode M6'],
        names: ['TNM6_DFU'],
        models: ['ThinkNodeM6'],
      ),
      (
        boards: ['Meshtiny'],
        names: ['MT001_DFU', 'MT001_DF'],
        models: ['MT001'],
      ),
      (
        boards: ['ProMicro DIY', 'ProMicro NRF52840', 'ProMicro'],
        names: ['PROM_DFU'],
        models: ['ProMicro NRF52840'],
      ),
      (
        boards: ['Seeed SenseCap Solar'],
        names: ['SCAP_DFU'],
        models: ['SenseCAP Solar Node P1'],
      ),
      (
        boards: ['Muzi Base Uno', 'Muzi Base Duo'],
        names: ['MUZIB_DFU', 'MUZIB_DF'],
        models: ['Muzi Base'],
      ),
    ];

String _boardKey(String board) =>
    board.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

({List<String> boards, List<String> names, List<String> models})?
_additionalProfile(String board) {
  final key = _boardKey(board);
  return _additionalDfuProfiles
      .where((profile) => profile.boards.any((name) => _boardKey(name) == key))
      .firstOrNull;
}

List<String> dfuBootloaderNames(String board) {
  final additional = _additionalProfile(board);
  if (additional != null) return additional.names;
  final name = dfuBootloaderName(board);
  if (name == '4631_DFU') {
    return const ['4631_DFU', '4631_AUTO_DFU', '4631_AUT'];
  }
  if (name == '3401_DFU') {
    return const ['3401_DFU', '3401_AUTO_DFU', '3401_AUT'];
  }
  return name == null ? const [] : [name];
}

String? dfuBootloaderName(String board) {
  final additional = _additionalProfile(board);
  if (additional != null) return additional.names.first;
  final value = board.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  if (value.contains('t096')) return 'T096_DFU';
  if (value.contains('t114')) return 'T114_DFU';
  if (value.contains('rak4631') || value.contains('rak4630')) return '4631_DFU';
  if (value.contains('rak3401')) return '3401_DFU';
  if (value.contains('t1000')) return 'T1KE_DFU';
  if (value.contains('xiao') || value.contains('solarxiao')) return 'XIAO_DFU';
  if (value.contains('wio') && value.contains('l1')) return 'WTL1_DFU';
  if (value.contains('techo')) return 'LGTE_DFU';
  if (value.contains('heltec') && value.contains('t1')) return 'T1_DFU';
  return null;
}

String? knownDfuAddress(String value) {
  final address = value.trim().toUpperCase();
  if (address.isEmpty) return null;
  if (!_macPattern.hasMatch(address)) {
    throw const FormatException(
      'Enter the known bootloader Bluetooth address.',
    );
  }
  return address;
}

List<String> dfuCandidateAddresses(
  String original, {
  String? knownBootloaderAddress,
}) {
  if (!_macPattern.hasMatch(original)) return [original];
  return {
    original.toUpperCase(),
    // This is a discovery hint for an unbonded factory-address application,
    // never permission to send firmware without fresh bootloader proof.
    NrfDfuPackage.bootloaderAddress(original),
    if (knownBootloaderAddress != null)
      knownDfuAddress(knownBootloaderAddress)!,
  }.toList();
}

/// An advertised board name is not sufficient to identify a radio. In
/// particular, never pick the first nearby T096_DFU after losing a connection.
List<DfuAdvertisement> dfuBootloaderCandidates(
  List<DfuAdvertisement> advertisements, {
  required String originalAddress,
  required String board,
  String? knownBootloaderAddress,
  bool allowAddressChange = false,
}) {
  final candidates = dfuCandidateAddresses(
    originalAddress,
    knownBootloaderAddress: knownBootloaderAddress,
  ).toSet();
  final expectedNames = dfuBootloaderNames(board);
  final matches = <String, DfuAdvertisement>{};
  for (final advertisement in advertisements) {
    final address = _macPattern.hasMatch(advertisement.address)
        ? advertisement.address.toUpperCase()
        : advertisement.address;
    if (!candidates.contains(address) &&
        !(allowAddressChange && knownBootloaderAddress == null)) {
      continue;
    }
    final name = advertisement.name.toUpperCase();
    final services = advertisement.services.map((s) => s.toLowerCase()).toSet();
    // A Companion also exposes the DFU service. NUS or an *_OTA/application
    // name is not proof it has actually reached the bootloader.
    if (services.contains(_nusUuid) ||
        !services.contains(legacyDfuServiceUuid)) {
      continue;
    }
    final boundGeneric = name == 'ADADFU' && candidates.contains(address);
    if (expectedNames.isNotEmpty &&
        (expectedNames.contains(name) || boundGeneric)) {
      matches[address] = DfuAdvertisement(
        address,
        advertisement.name,
        advertisement.services,
      );
    }
  }
  return matches.values.toList();
}

String? selectDfuBootloader(
  List<DfuAdvertisement> advertisements, {
  required String originalAddress,
  required String board,
  String? knownBootloaderAddress,
  bool allowAddressChange = false,
}) {
  final matches = dfuBootloaderCandidates(
    advertisements,
    originalAddress: originalAddress,
    board: board,
    knownBootloaderAddress: knownBootloaderAddress,
    allowAddressChange: allowAddressChange,
  );
  if (matches.length > 1) {
    throw StateError(
      'More than one possible DFU radio was found. No firmware was sent. '
      'Keep only the intended radio in Bluetooth OTA mode, then retry.',
    );
  }
  return matches.singleOrNull?.address;
}

bool isDfuConnectionFailure(Object error, {int? errorType}) {
  // Nordic remote protocol/validation errors are not reconnect errors.
  if (errorType == 3 || error is! PlatformException) return false;
  final code = int.tryParse(error.code);
  if ([8, 62, 133, 147].contains(code)) return true;
  final message = '${error.message ?? ''} ${error.details ?? ''}'.toUpperCase();
  return message.contains('GATT CONN TIMEOUT') ||
      message.contains('GATT_CONN_TIMEOUT') ||
      message.contains('GATT CONNECTION TIMEOUT') ||
      message.contains('GATT ERROR (133)');
}

typedef DfuTransfer =
    Future<void> Function(
      String address,
      String path,
      bool forceBootloader,
      DfuEventHandler events,
    );
typedef DfuScan =
    Future<List<DfuAdvertisement>> Function(
      List<String> addresses,
      Duration timeout,
    );
typedef DfuWait = Future<void> Function(Duration duration);
typedef DfuBootloaderProbe =
    Future<bool> Function(String address, String board);
typedef DfuBootloaderChoice =
    Future<String?> Function(List<DfuAdvertisement> candidates);

List<String> dfuBootloaderModels(String board) =>
    _additionalProfile(board)?.models ??
    switch (dfuBootloaderName(board)) {
      '4631_DFU' => const ['RAK4631', 'WisBlock RAK4631'],
      '3401_DFU' => const ['RAK3401', 'WisBlock RAK3401'],
      'XIAO_DFU' => const ['XIAO nRF52840', 'XIAO nRF52840 Sense'],
      'T096_DFU' => const ['HT-n5262G'],
      'T114_DFU' => const ['HT-n5262'],
      'T1_DFU' => const ['Mesh Node T1'],
      'T1KE_DFU' => const ['T1000-E'],
      'WTL1_DFU' => const ['Wio Tracker L1'],
      'LGTE_DFU' => const ['T-Echo v1.0'],
      _ => const [],
    };

/// Names and models confirm a profile after the handoff phase or an explicit
/// recovery choice has selected the address. Generic ADADFU remains confined
/// to the known-address candidates, never an unrelated nearby factory address.
bool matchesDfuBootloaderIdentity({
  required String board,
  required String name,
  required String model,
  required List<int> revision,
}) =>
    (dfuBootloaderNames(board).contains(name.toUpperCase()) ||
        name.toUpperCase() == 'ADADFU') &&
    dfuBootloaderModels(board).contains(model) &&
    revision.length == 2 &&
    revision[0] == 8 &&
    revision[1] == 0;

/// Shared by legacy and modern builds. Owns one update at a time and only
/// automatically reconnects before any reported payload/validation progress.
class NrfDfuRecovery {
  NrfDfuRecovery({
    DfuTransfer? transfer,
    DfuScan? scan,
    DfuWait? wait,
    DfuBootloaderProbe? probe,
  }) : _transfer = transfer,
       _scan = scan ?? _freshScan,
       _probe = probe ?? _freshBootloaderProbe,
       _wait = wait ?? Future<void>.delayed;

  final DfuTransfer? _transfer;
  final DfuScan _scan;
  final DfuBootloaderProbe _probe;
  final DfuWait _wait;
  bool _busy = false, _closed = false;

  static Future<void> _nativeTransfer(
    String address,
    String path,
    bool forceBootloader,
    DfuEventHandler events,
    bool applicationOnly,
  ) async {
    await NordicDfu().startDfu(
      address,
      path,
      forceDfu: forceBootloader,
      androidParameters: AndroidParameters(
        startAsForegroundService: true,
        packetReceiptNotificationsEnabled: true,
        // Legacy application DFU can retain the existing phone/radio bond.
        // System-component updates must not promise to preserve its keys.
        keepBond: applicationOnly,
        // SDK retries still support a normal buttonless handoff. The app's
        // extra retry below first proves the actual bootloader address.
        rebootTime: 5000,
        numberOfRetries: 2,
      ),
      dfuEventHandler: events,
    );
  }

  static Future<List<DfuAdvertisement>> _freshScan(
    List<String> addresses,
    Duration timeout,
  ) async {
    // UUID-style iOS identities cannot be converted to an Android MAC +1.
    // Leave the automatic iOS handoff to Nordic's native implementation.
    if (!addresses.every(_macPattern.hasMatch)) return [];
    if (FlutterBluePlus.isScanningNow) {
      throw StateError(
        'Another Bluetooth scan is running. Stop it before retrying DFU.',
      );
    }
    final seen = <String, DfuAdvertisement>{};
    final started = DateTime.now();
    Object? scanError;
    StackTrace? scanStack;
    final subscription = FlutterBluePlus.onScanResults.listen(
      (results) {
        for (final result in results) {
          // Ignore cached advertisements from before this scan.
          if (result.timeStamp.isBefore(started)) continue;
          final data = result.advertisementData;
          final address = result.device.remoteId.str.toUpperCase();
          final previous = seen[address];
          seen[address] = DfuAdvertisement(
            address,
            data.advName.isNotEmpty ? data.advName : previous?.name ?? '',
            // A reboot can replace NUS with DFU at the same address. Do not
            // merge an old application's services into the new bootloader.
            data.serviceUuids.isNotEmpty
                ? data.serviceUuids.map((s) => s.str).toList()
                : data.advName.isEmpty || data.advName == previous?.name
                ? previous?.services ?? []
                : [],
          );
        }
      },
      onError: (Object error, StackTrace stack) {
        scanError = error;
        scanStack = stack;
      },
    );
    var ownsScan = false;
    try {
      ownsScan = true;
      await FlutterBluePlus.startScan(
        // The application may use a custom address while DFU uses its factory
        // identity. Keep the scan bounded and protocol-filtered; the handoff
        // phase and explicit choice below decide which addresses may proceed.
        withServices: [Guid(legacyDfuServiceUuid)],
        timeout: timeout,
        continuousUpdates: true,
        androidScanMode: AndroidScanMode.lowLatency,
      );
      await Future<void>.delayed(timeout);
      if (scanError != null) {
        Error.throwWithStackTrace(scanError!, scanStack!);
      }
      return seen.values.toList();
    } finally {
      await subscription.cancel();
      if (ownsScan && FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }
    }
  }

  static Future<bool> _freshBootloaderProbe(
    String address,
    String board,
  ) async {
    final device = BluetoothDevice.fromId(address);
    if (device.isConnected) {
      throw StateError(
        'The bootloader Bluetooth connection is already in use.',
      );
    }
    var attempted = false;
    try {
      attempted = true;
      await device.connect(
        timeout: const Duration(seconds: 15),
        mtu: null,
        autoConnect: false,
        license: License.nonprofit,
      );
      if (PlatformInfo.isAndroid) {
        // A bonded application can leave cached DFU 0.1 handles behind.
        // Refresh the GATT database without removing the saved bond.
        await device.clearGattCache();
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      final services = await device.discoverServices(
        timeout: 10,
        subscribeToServicesChanged: false,
      );
      if (services.any(
        (s) => s.remoteId != device.remoteId || s.uuid == Guid(_nusUuid),
      )) {
        return false;
      }
      BluetoothCharacteristic? find(String service, String characteristic) {
        for (final s in services.where((s) => s.uuid == Guid(service))) {
          for (final c in s.characteristics) {
            if (c.remoteId == device.remoteId &&
                c.serviceUuid == s.uuid &&
                c.uuid == Guid(characteristic)) {
              return c;
            }
          }
        }
        return null;
      }

      final control = find(
        legacyDfuServiceUuid,
        '00001531-1212-efde-1523-785feabcd123',
      );
      final packet = find(
        legacyDfuServiceUuid,
        '00001532-1212-efde-1523-785feabcd123',
      );
      final revision = find(
        legacyDfuServiceUuid,
        '00001534-1212-efde-1523-785feabcd123',
      );
      final name = find('1800', '2a00');
      final model = find('180a', '2a24');
      if (control?.properties.write != true ||
          control?.properties.notify != true ||
          packet?.properties.writeWithoutResponse != true ||
          revision?.properties.read != true ||
          name?.properties.read != true ||
          model?.properties.read != true) {
        return false;
      }
      Future<String> text(BluetoothCharacteristic c) async {
        final bytes = await c.read(timeout: 8);
        if (bytes.isEmpty ||
            bytes.length > 64 ||
            bytes.any((b) => b < 32 || b > 126)) {
          throw const FormatException('Bootloader identity reply is invalid.');
        }
        return String.fromCharCodes(bytes);
      }

      return matchesDfuBootloaderIdentity(
        board: board,
        name: await text(name!),
        model: await text(model!),
        revision: await revision!.read(timeout: 8),
      );
    } finally {
      // A failed connect can still own a partially established native link.
      if (attempted) await device.disconnect(queue: false);
    }
  }

  /// Read-only discovery. Address changes require a completed handoff attempt
  /// or explicit recovery context from the caller, then a fresh connected
  /// model/revision proof. Multiple matching radios require an explicit choice.
  Future<String?> discoverBootloader({
    required String originalAddress,
    required String board,
    String? knownBootloaderAddress,
    bool allowKnownAddressProbe = false,
    bool allowAddressChange = false,
    DfuBootloaderChoice? chooseBootloader,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    _guard();
    if (dfuBootloaderModels(board).isEmpty) {
      throw UnsupportedError(
        'This board has no verified Bluetooth bootloader model. '
        'Use its supported board-specific updater. No firmware was sent.',
      );
    }
    final observations = await _scan(
      dfuCandidateAddresses(
        originalAddress,
        knownBootloaderAddress: knownBootloaderAddress,
      ),
      timeout,
    );
    _guard();
    final candidates = dfuBootloaderCandidates(
      observations,
      originalAddress: originalAddress,
      board: board,
      knownBootloaderAddress: knownBootloaderAddress,
      allowAddressChange: allowAddressChange,
    );
    String? address;
    if (candidates.length > 1) {
      if (chooseBootloader == null) {
        throw StateError(
          'Several matching radio updaters are nearby. '
          'Keep only the intended radio in update mode, then retry. No firmware was sent.',
        );
      }
      address = await chooseBootloader(List.unmodifiable(candidates));
      _guard();
      if (address == null) {
        throw StateError(
          'Bootloader selection cancelled. No firmware was sent.',
        );
      }
      if (!candidates.any((candidate) => candidate.address == address)) {
        throw StateError(
          'The selected bootloader was not in this fresh discovery. No firmware was sent.',
        );
      }
    } else {
      address = candidates.singleOrNull?.address;
    }
    // A retained peer whitelist can hide the bootloader from an ordinary
    // scan. A separately known address permits a read-only connection proof,
    // never a native transfer directly to an unobserved or guessed address.
    if (address == null &&
        allowKnownAddressProbe &&
        knownBootloaderAddress != null) {
      address = knownDfuAddress(knownBootloaderAddress);
    }
    if (address == null) return null;
    if (!await _probe(address, board)) {
      throw StateError(
        'The selected radio did not confirm the matching bootloader model and revision. No firmware was sent.',
      );
    }
    _guard();
    return address;
  }

  void _guard() {
    if (_closed) {
      throw StateError('Updater closed. No further DFU attempt was started.');
    }
  }

  Future<String> update({
    required String originalAddress,
    required String path,
    required String board,
    required bool applicationOnly,
    String? knownBootloaderAddress,
    DfuBootloaderChoice? chooseBootloader,
    bool retryBootloader = false,
    void Function(String)? onStatus,
    void Function(int)? onProgress,
    void Function(String)? onBootloader,
  }) async {
    _guard();
    if (_busy) {
      throw StateError('A Bluetooth firmware update is already running.');
    }
    _busy = true;
    var payloadStarted = false, validating = false, handoffAttempted = false;
    int? errorType;
    void status(String text) {
      if (!_closed) onStatus?.call(text);
    }

    final events = DfuEventHandler(
      onDeviceConnecting: (_) =>
          status('Connecting to the radio DFU service...'),
      onEnablingDfuMode: (address) {
        if (address.toUpperCase() == originalAddress.toUpperCase()) {
          handoffAttempted = true;
        }
        status('Asking the Companion to enter Bluetooth OTA mode...');
      },
      onDfuProcessStarted: (_) =>
          status('Bluetooth DFU connected. Sending firmware...'),
      onFirmwareValidating: (_) {
        validating = true;
        status('Validating firmware on the radio...');
      },
      onProgressChanged: (_, percent, speed, average, part, total) {
        if (percent > 0) payloadStarted = true;
        if (!_closed) onProgress?.call(percent);
      },
      onError: (_, code, type, message) {
        errorType = type;
        status('Bluetooth DFU error: $message');
      },
    );
    Future<String?> discover(Duration timeout) async {
      final address = await discoverBootloader(
        originalAddress: originalAddress,
        board: board,
        knownBootloaderAddress: knownBootloaderAddress,
        allowKnownAddressProbe: retryBootloader || handoffAttempted,
        allowAddressChange: retryBootloader || handoffAttempted,
        chooseBootloader: chooseBootloader,
        timeout: timeout,
      );
      if (address != null) onBootloader?.call(address);
      return address;
    }

    Future<void> transfer(String address, bool forceBootloader) {
      return _transfer != null
          ? _transfer(address, path, forceBootloader, events)
          : _nativeTransfer(
              address,
              path,
              forceBootloader,
              events,
              applicationOnly,
            );
    }

    try {
      status('Looking for this radio Bluetooth OTA bootloader...');
      // Also supports a radio already placed in BT OTA mode manually.
      final existing = await discover(
        retryBootloader
            ? const Duration(seconds: 8)
            : const Duration(seconds: 2),
      );
      if (retryBootloader &&
          existing == null &&
          _macPattern.hasMatch(originalAddress)) {
        throw _notFound(board);
      }
      var address = existing ?? originalAddress;
      _guard();
      try {
        await transfer(address, retryBootloader || existing != null);
      } catch (error) {
        _guard();
        if (retryBootloader ||
            !_macPattern.hasMatch(originalAddress) ||
            !applicationOnly ||
            payloadStarted ||
            validating ||
            !isDfuConnectionFailure(error, errorType: errorType)) {
          rethrow;
        }
        status(
          'Bluetooth handoff timed out. Looking for the actual bootloader before retrying...',
        );
        // Let the native DFU service release its failed GATT connection.
        await _wait(const Duration(seconds: 2));
        _guard();
        final bootloader = await discover(const Duration(seconds: 8));
        if (bootloader == null) throw _notFound(board);
        address = bootloader;
        errorType = null;
        status('Found this radio bootloader. Reconnecting at $address...');
        _guard();
        // One fresh, address-proven retry. Do not loop or retry a validation,
        // ZIP, SoftDevice, or partially completed system-component update.
        await transfer(address, true);
      }
      _guard();
      return address;
    } finally {
      _busy = false;
    }
  }

  StateError _notFound(String board) => StateError(
    'Could not find this radio Bluetooth OTA bootloader '
    '(${dfuBootloaderName(board) ?? 'DFU'}). No additional firmware attempt was sent. '
    'Keep the radio powered and near the phone. If it is still running Companion '
    'firmware, enter BT OTA mode using the board controls, then tap Retry bootloader. '
    'An older application handoff may need a fixed application installed once. '
    'A custom application Bluetooth address may differ from the bootloader factory address. '
    'Enter a separately known bootloader address from this radio or its administrator; do not guess it. '
    'Do not erase settings to troubleshoot this connection timeout.',
  );

  void dispose() {
    _closed = true;
  }
}
