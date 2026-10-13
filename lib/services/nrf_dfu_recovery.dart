import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:nordic_dfu/nordic_dfu.dart';

import 'companion_firmware_inspector.dart';
import 'nrf_dfu_package.dart';

const legacyDfuServiceUuid = '00001530-1212-efde-1523-785feabcd123';
const _nusUuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
final _macPattern = RegExp(r'^[0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5}$');

class DfuAdvertisement {
  const DfuAdvertisement(
    this.address,
    this.name,
    this.services, {
    this.isAmbiguous = false,
  });
  final String address, name;
  final List<String> services;
  final bool isAmbiguous;
}

enum _AdvertisementPhase { unknown, application, bootloader }

bool _isTowerBootloaderName(String name) =>
    name == 'TOWER_V2_OTA' || name == 'TOWER_V2';

_AdvertisementPhase _advertisementPhase(DfuAdvertisement value) {
  if (value.services.contains(_nusUuid)) {
    return _AdvertisementPhase.application;
  }
  final name = value.name.toUpperCase();
  if (value.services.contains(legacyDfuServiceUuid) ||
      name == 'ADADFU' ||
      name.endsWith('_DFU') ||
      _isTowerBootloaderName(name)) {
    return _AdvertisementPhase.bootloader;
  }
  return name.isEmpty
      ? _AdvertisementPhase.unknown
      : _AdvertisementPhase.application;
}

/// Nonempty service data replaces an earlier database, never unions with it.
/// Empty scan responses retain evidence only within the same radio phase. A
/// name-only phase change needs fresh service data before it can be selected.
DfuAdvertisement reduceDfuAdvertisement(
  DfuAdvertisement? previous,
  DfuAdvertisement observation,
) {
  final address = _macPattern.hasMatch(observation.address)
      ? observation.address.toUpperCase()
      : observation.address;
  final current = DfuAdvertisement(
    address,
    observation.name,
    observation.services.map((s) => s.toLowerCase()).toSet().toList(),
    isAmbiguous: observation.isAmbiguous,
  );
  if (previous == null ||
      previous.address.toUpperCase() != address.toUpperCase()) {
    return current;
  }
  final old = DfuAdvertisement(
    address,
    previous.name,
    previous.services.map((s) => s.toLowerCase()).toSet().toList(),
    isAmbiguous: previous.isAmbiguous,
  );
  final oldPhase = _advertisementPhase(old);
  final newPhase = _advertisementPhase(current);
  if (current.services.isNotEmpty) {
    return DfuAdvertisement(
      address,
      current.name.isNotEmpty
          ? current.name
          : newPhase == oldPhase
          ? old.name
          : '',
      current.services,
      isAmbiguous: current.isAmbiguous,
    );
  }
  if (current.name.isEmpty) return old;
  final oldName = old.name.toUpperCase();
  final newName = current.name.toUpperCase();
  final changedBootloaderName =
      oldPhase == _AdvertisementPhase.bootloader &&
      newPhase == _AdvertisementPhase.bootloader &&
      oldName.isNotEmpty &&
      oldName != newName &&
      !(_isTowerBootloaderName(oldName) && _isTowerBootloaderName(newName));
  final phaseChanged =
      oldPhase != _AdvertisementPhase.unknown && oldPhase != newPhase;
  final unclassifiedServices =
      oldPhase == _AdvertisementPhase.unknown && old.services.isNotEmpty;
  if (phaseChanged || changedBootloaderName || unclassifiedServices) {
    return DfuAdvertisement(address, current.name, [], isAmbiguous: true);
  }
  return DfuAdvertisement(
    address,
    current.name,
    old.services,
    isAmbiguous: old.isAmbiguous || current.isAmbiguous,
  );
}

String? dfuBootloaderName(String board) {
  final value = board.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  if (CompanionFirmwareInspector.isTowerV2Board(board)) return 'TOWER_V2_OTA';
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

List<String> dfuCandidateAddresses(String original) {
  if (!_macPattern.hasMatch(original)) return [original];
  return [original.toUpperCase(), NrfDfuPackage.bootloaderAddress(original)];
}

/// An advertised board name is not sufficient to identify a radio. In
/// particular, never pick the first nearby T096_DFU after losing a connection.
String? selectDfuBootloader(
  List<DfuAdvertisement> advertisements, {
  required String originalAddress,
  required String board,
}) {
  final candidates = dfuCandidateAddresses(originalAddress).toSet();
  final expectedName = dfuBootloaderName(board);
  final matches = <String>{};
  for (final advertisement in advertisements) {
    final address = _macPattern.hasMatch(advertisement.address)
        ? advertisement.address.toUpperCase()
        : advertisement.address;
    if (!candidates.contains(address) || advertisement.isAmbiguous) continue;
    final name = advertisement.name.toUpperCase();
    final services = advertisement.services.map((s) => s.toLowerCase()).toSet();
    // A Companion also exposes the DFU service. NUS or an arbitrary *_OTA
    // name is not proof it has actually reached the bootloader. Tower's known
    // full/short name also requires fresh legacy DFU service evidence.
    if (services.contains(_nusUuid)) continue;
    final knownName = expectedName == 'TOWER_V2_OTA'
        ? _isTowerBootloaderName(name) &&
              services.contains(legacyDfuServiceUuid)
        : name == expectedName || name == 'ADADFU';
    final genericName =
        expectedName == null &&
        name.endsWith('_DFU') &&
        services.contains(legacyDfuServiceUuid);
    if (knownName || genericName) matches.add(address);
  }
  if (matches.length > 1) {
    throw StateError(
      'More than one possible DFU radio was found. No firmware was sent. '
      'Keep only the intended radio in Bluetooth OTA mode, then retry.',
    );
  }
  return matches.singleOrNull;
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

/// Shared by legacy and modern builds. Owns one update at a time and only
/// automatically reconnects before any reported payload/validation progress.
class NrfDfuRecovery {
  NrfDfuRecovery({DfuTransfer? transfer, DfuScan? scan, DfuWait? wait})
    : _transfer = transfer,
      _scan = scan ?? _freshScan,
      _wait = wait ?? Future<void>.delayed;

  final DfuTransfer? _transfer;
  final DfuScan _scan;
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
          if (!addresses.contains(address)) continue;
          seen[address] = reduceDfuAdvertisement(
            seen[address],
            DfuAdvertisement(
              address,
              data.advName,
              data.serviceUuids.map((s) => s.str).toList(),
            ),
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
        withRemoteIds: addresses,
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
    var payloadStarted = false, validating = false;
    int? errorType;
    void status(String text) {
      if (!_closed) onStatus?.call(text);
    }

    final events = DfuEventHandler(
      onDeviceConnecting: (_) =>
          status('Connecting to the radio DFU service...'),
      onEnablingDfuMode: (_) =>
          status('Asking the Companion to enter Bluetooth OTA mode...'),
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
        status('Bluetooth DFU error (code=$code, type=$type): $message');
      },
    );
    Future<String?> discover(Duration timeout) async {
      final observations = await _scan(
        dfuCandidateAddresses(originalAddress),
        timeout,
      );
      _guard();
      final address = selectDfuBootloader(
        observations,
        originalAddress: originalAddress,
        board: board,
      );
      if (address != null) onBootloader?.call(address);
      return address;
    }

    Future<void> transfer(String address, bool forceBootloader) =>
        _transfer != null
        ? _transfer(address, path, forceBootloader, events)
        : _nativeTransfer(
            address,
            path,
            forceBootloader,
            events,
            applicationOnly,
          );

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
    'Do not erase settings to troubleshoot this connection timeout.',
  );

  void dispose() {
    _closed = true;
  }
}
