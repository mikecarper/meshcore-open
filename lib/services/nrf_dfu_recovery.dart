import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:nordic_dfu/nordic_dfu.dart';

import 'companion_board_catalog.dart';
import 'dfu_gatt_discovery.dart';
import 'nrf_dfu_package.dart';
import '../utils/platform_info.dart';

const legacyDfuServiceUuid = '00001530-1212-efde-1523-785feabcd123';
const _nusUuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
final _macPattern = RegExp(r'^[0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5}$');

/// Android exposes addresses that can be matched across the application and
/// bootloader. iOS opaque identifiers require the native SDK's handoff.
bool canDiscoverDfuHandoff(String address) => _macPattern.hasMatch(address);

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

bool _isKnownBootloaderName(String name) =>
    CompanionBoardCatalog.specs.any((board) => board.dfuNames.contains(name));

bool _sameBootloaderProfile(String a, String b) => CompanionBoardCatalog.specs
    .any((board) => board.dfuNames.contains(a) && board.dfuNames.contains(b));

_AdvertisementPhase _advertisementPhase(DfuAdvertisement value) {
  if (value.services.contains(_nusUuid)) {
    return _AdvertisementPhase.application;
  }
  final name = value.name.toUpperCase();
  if (value.services.contains(legacyDfuServiceUuid) ||
      name == 'ADADFU' ||
      name.endsWith('_DFU') ||
      _isKnownBootloaderName(name)) {
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
      !_sameBootloaderProfile(oldName, newName);
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
  final names = CompanionBoardCatalog.lookup(board)?.dfuNames;
  return names == null || names.isEmpty ? null : names.first;
}

List<String> dfuCandidateAddresses(
  String original, {
  String? verifiedBootloaderAddress,
}) {
  if (!_macPattern.hasMatch(original)) return [original];
  if (verifiedBootloaderAddress != null &&
      !_macPattern.hasMatch(verifiedBootloaderAddress)) {
    throw const FormatException('Invalid verified Bluetooth DFU address.');
  }
  return {
    original.toUpperCase(),
    NrfDfuPackage.bootloaderAddress(original),
    if (verifiedBootloaderAddress != null)
      verifiedBootloaderAddress.toUpperCase(),
  }.toList();
}

/// An advertised board name is not sufficient to identify a radio. In
/// particular, never pick the first nearby T096_DFU after losing a connection.
String? selectDfuBootloader(
  List<DfuAdvertisement> advertisements, {
  required String originalAddress,
  required String board,
  String? verifiedBootloaderAddress,
}) {
  final candidates = dfuCandidateAddresses(
    originalAddress,
    verifiedBootloaderAddress: verifiedBootloaderAddress,
  ).toSet();
  final names = CompanionBoardCatalog.lookup(board)?.dfuNames ?? const [];
  final matches = <String>{};
  for (final advertisement in advertisements) {
    final address = _macPattern.hasMatch(advertisement.address)
        ? advertisement.address.toUpperCase()
        : advertisement.address;
    if (!candidates.contains(address) || advertisement.isAmbiguous) continue;
    final name = advertisement.name.toUpperCase();
    final services = advertisement.services.map((s) => s.toLowerCase()).toSet();
    // Every board requires fresh protocol evidence and its explicit full or
    // shortened bootloader name. Neither a generic name nor a nearby radio
    // can establish which exact board/address was selected before reboot.
    if (services.contains(_nusUuid) ||
        !services.contains(legacyDfuServiceUuid)) {
      continue;
    }
    if (names.contains(name)) matches.add(address);
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
  // Android 5.1 can surface a failed GATT read as local-host termination (22)
  // after the application/bootloader database changes. The caller still
  // requires no payload, a terminal native result and a fresh exact-radio scan.
  // 4101 is Nordic SERVICE_DISCOVERY_NOT_STARTED, not FILE_ERROR (4098).
  if ([8, 22, 62, 133, 147, 4101].contains(code)) return true;
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
typedef DfuAbort = Future<void> Function();
typedef DfuBondedProbe =
    Future<DfuAdvertisement?> Function(String address, String board);

class DfuStoppedException extends StateError {
  DfuStoppedException(String reason, {required this.nativeTerminationConfirmed})
    : super(
        nativeTerminationConfirmed
            ? '$reason Native DFU stopped. No automatic firmware retry was sent.'
            : '$reason Native DFU did not confirm termination. Further updates '
                  'are blocked until its terminal result arrives. Keep the radio powered.',
      );

  final bool nativeTerminationConfirmed;
}

class _TransferResult {
  const _TransferResult([this.error, this.stack]);
  final Object? error;
  final StackTrace? stack;
}

class _ActiveTransfer {
  final terminal = Completer<_TransferResult>();
  final stopped = Completer<_TransferResult>();
  Timer? idleTimer;
  Timer? overallTimer;
  Future<void>? stopping;
  String? stopReason;
  bool quarantined = false;

  void cancelTimers() {
    idleTimer?.cancel();
    overallTimer?.cancel();
  }
}

/// Shared by legacy and modern builds. Owns one update at a time and only
/// automatically reconnects before any reported payload/validation progress.
class NrfDfuRecovery {
  NrfDfuRecovery({
    DfuTransfer? transfer,
    DfuScan? scan,
    DfuWait? wait,
    DfuAbort? abort,
    DfuBondedProbe? bondedProbe,
    this.idleTimeout = const Duration(seconds: 60),
    this.overallTimeout = const Duration(minutes: 10),
    this.abortTimeout = const Duration(seconds: 10),
  }) : _transfer = transfer,
       _scan = scan ?? _freshScan,
       _bondedProbe = bondedProbe ?? _freshBondedProbe,
       _wait = wait ?? Future<void>.delayed,
       _abort =
           abort ??
           (() async {
             await NordicDfu().abortDfu();
           }) {
    if (idleTimeout <= Duration.zero ||
        overallTimeout <= Duration.zero ||
        abortTimeout <= Duration.zero) {
      throw ArgumentError('DFU deadlines must be positive.');
    }
  }

  final DfuTransfer? _transfer;
  final DfuScan _scan;
  final DfuBondedProbe _bondedProbe;
  final DfuWait _wait;
  final DfuAbort _abort;
  final Duration idleTimeout, overallTimeout, abortTimeout;
  static NrfDfuRecovery? _owner;
  _ActiveTransfer? _active;
  bool _busy = false, _closed = false;
  bool _cancelRequested = false;
  bool _verificationHeld = false;

  bool get isBusy => _busy || _owner != null;
  bool get isQuarantined => _owner?._active?.quarantined ?? false;
  bool get nativeTerminationConfirmed =>
      _active == null || _active!.terminal.isCompleted;

  void _terminal(_ActiveTransfer active, _TransferResult result) {
    if (active.terminal.isCompleted) return;
    active.terminal.complete(result);
    active.cancelTimers();
    if (active.quarantined &&
        identical(_owner, this) &&
        identical(_active, active) &&
        !_verificationHeld) {
      _owner = null;
    }
  }

  void _activity() {
    final active = _active;
    if (active == null ||
        active.terminal.isCompleted ||
        active.stopReason != null) {
      return;
    }
    active.idleTimer?.cancel();
    active.idleTimer = Timer(idleTimeout, () {
      unawaited(
        _stopTransfer(active, 'Bluetooth DFU stopped reporting activity.'),
      );
    });
  }

  Future<void> _stopTransfer(_ActiveTransfer active, String reason) =>
      active.stopping ??= _stopAndConfirm(active, reason);

  Future<void> _stopAndConfirm(_ActiveTransfer active, String reason) async {
    active.stopReason = reason;
    active.cancelTimers();
    // An abort command acknowledgement only confirms dispatch. The native
    // terminal callback/Future must also arrive before another updater starts.
    final limit = Completer<void>();
    final timer = Timer(abortTimeout, () => limit.complete());
    try {
      final abort = Future<void>.sync(_abort).catchError((Object _) {});
      await Future.any<void>([
        active.terminal.future.then((_) {}),
        abort.then((_) => active.terminal.future.then((_) {})),
        limit.future,
      ]);
    } finally {
      timer.cancel();
    }
    final confirmed = active.terminal.isCompleted;
    active.quarantined = !confirmed;
    if (!active.stopped.isCompleted) {
      active.stopped.complete(
        _TransferResult(
          DfuStoppedException(reason, nativeTerminationConfirmed: confirmed),
          StackTrace.current,
        ),
      );
    }
  }

  Future<void> cancel() async {
    _cancelRequested = true;
    final active = _active;
    if (active != null && !active.terminal.isCompleted) {
      await _stopTransfer(active, 'Bluetooth DFU was cancelled.');
    }
  }

  /// A lost Flutter callback can leave a service quarantined even after the
  /// OS stopped it. Only independent native-service proof can release it.
  Future<bool> recoverQuarantine({
    required Future<bool> Function() verifyStopped,
  }) async {
    final owner = _owner;
    final active = owner?._active;
    if (owner != null &&
        (active == null || !active.quarantined || owner._verificationHeld)) {
      return false;
    }
    // Hold coordination through the caller's proof and persistent-flag update.
    // Otherwise a new service could start between the OS check and disk write.
    if (owner == null) _owner = this;
    final verifierOwner = owner ?? this;
    verifierOwner._verificationHeld = true;
    bool verified;
    try {
      verified = await verifyStopped();
    } catch (_) {
      verified = false;
    } finally {
      verifierOwner._verificationHeld = false;
    }
    if (owner == null) {
      if (!identical(_owner, this)) return false;
      _owner = null;
      return verified;
    }
    if (!verified) {
      if (active?.terminal.isCompleted == true && identical(_owner, owner)) {
        _owner = null;
      }
      return false;
    }
    if (!identical(_owner, owner) ||
        !identical(owner._active, active) ||
        active == null ||
        !active.quarantined) {
      return false;
    }
    owner._terminal(
      active,
      _TransferResult(
        DfuStoppedException(
          'OS confirmed the native Bluetooth updater stopped.',
          nativeTerminationConfirmed: true,
        ),
        StackTrace.current,
      ),
    );
    owner._active = null;
    _owner = null;
    return true;
  }

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
        // Native payload restart retries are disabled. Its separate initial
        // GATT reconnection policy still supports normal buttonless handoff;
        // our only extra retry below requires fresh identity and no payload.
        rebootTime: 5000,
        numberOfRetries: 0,
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

  static Future<DfuAdvertisement?> _freshBondedProbe(
    String address,
    String board,
  ) async {
    if (!PlatformInfo.isAndroid || !canDiscoverDfuHandoff(address)) return null;
    final bonded = await FlutterBluePlus.bondedDevices;
    final matches = bonded.where(
      (d) => d.remoteId.str.toUpperCase() == address.toUpperCase(),
    );
    if (matches.length != 1) return null;
    final device = matches.single;
    // Never take over a connection owned by the Companion or another route.
    if (device.isConnected) return null;
    try {
      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 12),
        mtu: null,
      );
      final services = await discoverWithDfuCacheRecovery(
        isAndroid: true,
        refreshBeforeDiscovery: true,
        discover: () =>
            device.discoverServices(subscribeToServicesChanged: false),
        refreshCache: device.clearGattCache,
      );
      final name = await inspectLegacyBootloaderServices(
        services,
        address: address,
        board: board,
      );
      return name == null
          ? null
          : DfuAdvertisement(address, name, [legacyDfuServiceUuid]);
    } finally {
      // No native update may start while the read-only probe owns this link.
      await device.disconnect(queue: false);
    }
  }

  void _guard() {
    if (_closed) {
      throw StateError('Updater closed. No further DFU attempt was started.');
    }
    if (_cancelRequested) {
      throw DfuStoppedException(
        'Bluetooth DFU was cancelled.',
        nativeTerminationConfirmed: nativeTerminationConfirmed,
      );
    }
  }

  Future<String> update({
    required String originalAddress,
    required String path,
    required String board,
    required bool applicationOnly,
    String? verifiedBootloaderAddress,
    bool retryBootloader = false,
    bool allowBondedBootloaderProbe = false,
    void Function(String)? onStatus,
    void Function(int)? onProgress,
    void Function(String)? onBootloader,
  }) async {
    if (!_busy && nativeTerminationConfirmed) _cancelRequested = false;
    _guard();
    if (_busy || _owner != null) {
      throw StateError(
        isQuarantined
            ? 'A previous native Bluetooth update has not confirmed termination. '
                  'No additional firmware was sent.'
            : 'A Bluetooth firmware update is already running.',
      );
    }
    if (CompanionBoardCatalog.lookup(board)?.dfuNames.isEmpty ?? true) {
      throw StateError(
        'This exact board has no verified Bluetooth DFU profile.',
      );
    }
    // Validate independently established addresses before any scan or write.
    final candidates = dfuCandidateAddresses(
      originalAddress,
      verifiedBootloaderAddress: verifiedBootloaderAddress,
    );
    _busy = true;
    _owner = this;
    final deadline = DateTime.now().add(overallTimeout);
    var payloadStarted = false, validating = false;
    int? errorType;
    void status(String text) {
      _activity();
      if (!_closed && !_cancelRequested && _active?.stopReason == null) {
        onStatus?.call(text);
      }
    }

    DfuEventHandler handler(_ActiveTransfer active) {
      bool current() =>
          identical(_active, active) && !active.terminal.isCompleted;
      void activity(String _) {
        if (current()) _activity();
      }

      return DfuEventHandler(
        onDeviceConnecting: (_) {
          if (current()) status('Connecting to the radio DFU service...');
        },
        onEnablingDfuMode: (_) {
          if (current()) {
            status('Asking the Companion to enter Bluetooth OTA mode...');
          }
        },
        onDfuProcessStarted: (_) {
          if (!current()) return;
          // The first bytes can be written before the first >0% callback.
          payloadStarted = true;
          status('Bluetooth DFU connected. Sending firmware...');
        },
        onDfuProcessStarting: activity,
        onDeviceConnected: activity,
        onDeviceDisconnecting: activity,
        onDeviceDisconnected: activity,
        onFirmwareValidating: (_) {
          if (!current()) return;
          validating = true;
          status('Validating firmware on the radio...');
        },
        onProgressChanged: (_, percent, speed, average, part, total) {
          if (!current()) return;
          _activity();
          if (percent > 0) payloadStarted = true;
          if (!_closed && !_cancelRequested && _active?.stopReason == null) {
            onProgress?.call(percent);
          }
        },
        onError: (_, code, type, message) {
          if (!current()) return;
          errorType = type;
          status('Bluetooth DFU error (code=$code, type=$type): $message');
          _terminal(
            active,
            _TransferResult(
              PlatformException(code: '$code', message: message),
              StackTrace.current,
            ),
          );
        },
        onDfuCompleted: (_) {
          _terminal(active, const _TransferResult());
        },
        onDfuAborted: (_) {
          _terminal(
            active,
            _TransferResult(
              DfuStoppedException(
                'Native Bluetooth DFU aborted.',
                nativeTerminationConfirmed: true,
              ),
              StackTrace.current,
            ),
          );
        },
      );
    }

    Future<String?> discover(Duration timeout) async {
      final observations = await _scan(candidates, timeout);
      _guard();
      var address = selectDfuBootloader(
        observations,
        originalAddress: originalAddress,
        board: board,
        verifiedBootloaderAddress: verifiedBootloaderAddress,
      );
      if (address == null && allowBondedBootloaderProbe) {
        _guard();
        status('Checking this bonded radio bootloader directly...');
        final proof = await _bondedProbe(originalAddress, board);
        _guard();
        // A probe can only certify the original paired radio, never a nearby
        // alternative or a vendor-name-only match.
        if (proof != null &&
            proof.address.toUpperCase() == originalAddress.toUpperCase()) {
          address = selectDfuBootloader(
            [proof],
            originalAddress: originalAddress,
            board: board,
          );
        }
      }
      if (address != null) onBootloader?.call(address);
      return address;
    }

    Future<void> transfer(String address, bool forceBootloader) async {
      _guard();
      final active = _ActiveTransfer();
      _active = active;
      final events = handler(active);
      _activity();
      final remaining = deadline.difference(DateTime.now());
      active.overallTimer = Timer(
        remaining.isNegative ? Duration.zero : remaining,
        () => unawaited(
          _stopTransfer(
            active,
            'Bluetooth DFU reached its overall time limit.',
          ),
        ),
      );
      // Handle late completion/errors even after the caller has been returned
      // a quarantined timeout. A hung method Future never becomes permission
      // for a second native service to write the same radio concurrently.
      unawaited(
        Future<void>.sync(
          () => _transfer != null
              ? _transfer(address, path, forceBootloader, events)
              : _nativeTransfer(
                  address,
                  path,
                  forceBootloader,
                  events,
                  applicationOnly,
                ),
        ).then(
          (_) => _terminal(active, const _TransferResult()),
          onError: (Object error, StackTrace stack) =>
              _terminal(active, _TransferResult(error, stack)),
        ),
      );
      try {
        var result = await Future.any([
          active.terminal.future,
          active.stopped.future,
        ]);
        if (active.stopReason != null) {
          await active.stopping;
          result = await active.stopped.future;
        }
        if (result.error != null) {
          Error.throwWithStackTrace(
            result.error!,
            result.stack ?? StackTrace.current,
          );
        }
      } finally {
        active.cancelTimers();
        if (active.terminal.isCompleted && identical(_active, active)) {
          _active = null;
        }
      }
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
      if (nativeTerminationConfirmed && identical(_owner, this)) {
        _owner = null;
      }
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
    unawaited(cancel());
  }
}
