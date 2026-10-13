import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../models/contact.dart';
import '../services/github_mota_release_service.dart';
import '../services/companion_board_catalog.dart';
import '../services/companion_firmware_validation.dart';
import '../services/nrf_dfu_package.dart';
import '../services/nrf_dfu_recovery.dart';
import '../services/nrf_dfu_recovery_store.dart';
import '../services/native_dfu_lifetime.dart';
import '../services/rak_bootloader_migration.dart';
import '../services/repeater_command_service.dart';
import '../widgets/update_status_card.dart';

class NrfBluetoothDfuScreen extends StatefulWidget {
  const NrfBluetoothDfuScreen({
    super.key,
    required this.repeater,
    this.commandService,
    this.dfuRecovery,
    this.pickFirmware,
    this.releaseService,
    this.recoveryStore,
  });

  final Contact repeater;
  final RepeaterCommandService? commandService;
  final NrfDfuRecovery? dfuRecovery;
  final Future<XFile?> Function()? pickFirmware;
  final GitHubMotaReleaseService? releaseService;
  final NrfDfuRecoveryStore? recoveryStore;

  @override
  State<NrfBluetoothDfuScreen> createState() => _NrfBluetoothDfuScreenState();
}

class _NrfBluetoothDfuScreenState extends State<NrfBluetoothDfuScreen> {
  late final RepeaterCommandService _commands;
  late final GitHubMotaReleaseService _releases;
  late final NrfDfuRecovery _dfuRecovery;
  late final NrfDfuRecoveryStore _recoveryStore;
  StreamSubscription<Uint8List>? _frameSubscription;
  String? _packagePath;
  String? _packageName;
  NrfDfuPackage? _package;
  String? _address;
  String _status = 'Choose a board-matched Nordic DFU ZIP.';
  int? _progress;
  bool _busy = false;
  bool _completed = false;
  RakBootloaderMigration? _rakPlan;
  RakBootloaderDfuFiles? _rakFiles;
  bool _bridgeInstalled = false;
  bool _operationCancelled = false;
  String? _board;
  String? _systemPackageSha;
  final _verifiedSystemHashes = <String>{};
  bool _bootloaderOnly = false;
  NrfDfuApplicationRole get _applicationRole =>
      widget.repeater.type == advTypeRoom
      ? NrfDfuApplicationRole.roomServer
      : NrfDfuApplicationRole.repeater;

  @override
  void initState() {
    super.initState();
    final connector = context.read<MeshCoreConnector>();
    _commands = widget.commandService ?? RepeaterCommandService(connector);
    _releases = widget.releaseService ?? GitHubMotaReleaseService();
    _dfuRecovery = widget.dfuRecovery ?? NrfDfuRecovery();
    _recoveryStore = widget.recoveryStore ?? NrfDfuRecoveryStore();
    _frameSubscription = connector.receivedFrames.listen(_handleFrame);
  }

  void _handleFrame(Uint8List frame) {
    final reply = parseContactMessageText(frame);
    if (reply == null) return;
    final target = widget.repeater.publicKey;
    if (target.length < 6 || reply.senderPrefix.length != 6) return;
    for (var i = 0; i < 6; i++) {
      if (reply.senderPrefix[i] != target[i]) return;
    }
    _commands.handleResponse(widget.repeater, reply.text);
  }

  @override
  void dispose() {
    _frameSubscription?.cancel();
    if (widget.commandService == null) _commands.dispose();
    if (widget.releaseService == null) _releases.dispose();
    _dfuRecovery.dispose();
    final path = _packagePath;
    if (path != null && _dfuRecovery.nativeTerminationConfirmed) {
      unawaited(File(path).delete().catchError((_) => File(path)));
    }
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    if (_dfuRecovery.isQuarantined) {
      setState(
        () => _status =
            'A native Bluetooth update has not confirmed termination. '
            'No other update can start. Keep the radio powered.',
      );
      return;
    }
    _operationCancelled = false;
    setState(() => _busy = true);
    try {
      if (await _recoveryStore.hasUnconfirmedNativeTransfer()) {
        throw StateError(
          'A saved native Bluetooth update has not confirmed stopping. '
          'Check that the previous update service stopped before starting another.',
        );
      }
      _checkContinue();
      await action();
    } catch (error) {
      if (mounted) {
        setState(() => _status = _errorMessage(error));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _checkContinue() {
    if (!mounted || _operationCancelled) {
      throw StateError('Update cancelled. No further stage was started.');
    }
  }

  Future<void> _cancelUpdate() async {
    _operationCancelled = true;
    await _dfuRecovery.cancel();
    if (mounted) {
      setState(
        () => _status = _dfuRecovery.nativeTerminationConfirmed
            ? 'Update cancelled. The native transfer stopped. No other stage was sent.'
            : 'Cancellation was requested, but native DFU did not confirm stopping. '
                  'Further updates are blocked. Keep the radio powered.',
      );
    }
  }

  Future<void> _checkNativeStopped() async {
    final saved = await _dfuRecovery.recoverQuarantine(
      verifyStopped: () => _recoveryStore.confirmNativeStopped(
        verifyStopped: NativeDfuLifetime.verifyStopped,
      ),
    );
    if (mounted) {
      setState(
        () => _status = saved
            ? 'The previous native Bluetooth updater stopped. Its saved firmware identity is unchanged.'
            : 'Native Bluetooth termination is still unconfirmed. No new update was started.',
      );
    }
  }

  String _errorMessage(Object error) {
    if (error is PlatformException && error.code == '133') {
      return 'Android could not connect to the radio DFU service (GATT 133). '
          'Check that the radio is still advertising, then retry. If this '
          'phone keeps failing, use another phone or the exact-board USB '
          'updater.';
    }
    return error is StateError ? error.message.toString() : '$error';
  }

  Future<String> _readBoard() async {
    final board = await _commands.sendCommand(
      widget.repeater,
      'board',
      retries: 2,
      minimumTimeoutMs: 15000,
    );
    _checkContinue();
    final spec = CompanionBoardCatalog.lookup(board);
    if (spec?.family != CompanionChipFamily.nrf52 || spec!.dfuNames.isEmpty) {
      throw StateError(
        'The selected repeater did not report a supported exact Nordic board.',
      );
    }
    return board;
  }

  Future<void> _loadPackage(XFile file) async {
    final board = await _readBoard();
    final bytes = await file.readAsBytes();
    _checkContinue();
    _board = board;
    await _loadPackageBytes(file.name, Uint8List.fromList(bytes));
    _rakPlan = null;
    _rakFiles = null;
    _bridgeInstalled = false;
    _systemPackageSha = null;
    _verifiedSystemHashes.clear();
  }

  Future<void> _loadPackageBytes(
    String name,
    Uint8List bytes, {
    bool keepAddress = false,
    bool trustedRakSystem = false,
  }) async {
    final package = trustedRakSystem
        ? await CompanionFirmwareValidation.inspectNordicPackage(bytes)
        : await CompanionFirmwareValidation.inspectNordic(
            bytes,
            board: _board ?? '',
            role: _applicationRole,
          );
    _checkContinue();
    if (trustedRakSystem) {
      if (package.components.length != 1 ||
          package.components.single != 'softdevice_bootloader') {
        throw const FormatException(
          'Verified RAK workflow requires an exact system-component ZIP.',
        );
      }
    }
    final directory = await getTemporaryDirectory();
    final copy = File(
      '${directory.path}/meshcore-dfu-${DateTime.now().microsecondsSinceEpoch}.zip',
    );
    await copy.writeAsBytes(bytes, flush: true);
    final previous = _packagePath;
    if (!mounted) {
      await copy.delete();
      return;
    }
    setState(() {
      _packagePath = copy.path;
      _packageName = name;
      _package = package;
      _systemPackageSha = trustedRakSystem ? package.sha256 : null;
      if (!keepAddress) {
        _address = null;
        _bootloaderOnly = false;
      }
      _progress = null;
      _completed = false;
      _status =
          '$name: ${package.components.join(', ')} '
          '(${(package.size / 1024).round()} KB). Confirm the board matches '
          '${widget.repeater.name}.';
    });
    if (previous != null) {
      try {
        await File(previous).delete();
      } catch (_) {
        // The OS can clear old cache files later.
      }
    }
  }

  Future<void> _prepareRakUpdate() => _run(() async {
    final previous = _packagePath;
    setState(() {
      _packagePath = null;
      _packageName = null;
      _package = null;
      _address = null;
      _rakPlan = null;
      _rakFiles = null;
      _bridgeInstalled = false;
      _systemPackageSha = null;
      _progress = null;
      _completed = false;
      _status = 'Reading the RAK board and installed bootloader...';
    });
    if (previous != null) {
      unawaited(File(previous).delete().catchError((_) => File(previous)));
    }
    final board = await _readBoard();
    _board = board;
    final bootloader = await _commands.sendCommand(
      widget.repeater,
      'ota bootloader',
      retries: 2,
      minimumTimeoutMs: 15000,
    );
    final plan = RakBootloaderMigration.fromReplies(
      board: board,
      bootloader: bootloader,
    );
    _checkContinue();
    setState(
      () => _status = plan.needsRecovery
          ? 'Installed ${plan.installedName} needs the exact recovery bridge. '
                'Checking the published two-stage update...'
          : 'Installed ${plan.installedName} can use the unified RAK image. '
                'Checking its published update...',
    );
    final files = await _releases.downloadRakBootloaderDfu(plan);
    _checkContinue();
    final normal = await CompanionFirmwareValidation.inspectNordicPackage(
      files.normalBytes,
    );
    final recovery = files.recoveryBytes == null
        ? null
        : await CompanionFirmwareValidation.inspectNordicPackage(
            files.recoveryBytes!,
          );
    if (normal.components.length != 1 ||
        normal.components.single != 'softdevice_bootloader' ||
        recovery != null &&
            (recovery.components.length != 1 ||
                recovery.components.single != 'softdevice_bootloader')) {
      throw const FormatException(
        'Verified RAK downloads require exact system-component ZIPs.',
      );
    }
    _checkContinue();
    _verifiedSystemHashes.clear();
    _verifiedSystemHashes.addAll([
      normal.sha256,
      if (recovery != null) recovery.sha256,
    ]);
    if (plan.needsRecovery) {
      final recoveryName = files.recoveryName;
      final recoveryBytes = files.recoveryBytes;
      if (recoveryName == null || recoveryBytes == null) {
        throw StateError('The matching recovery bridge is unavailable.');
      }
      await _loadPackageBytes(
        recoveryName,
        recoveryBytes,
        trustedRakSystem: true,
      );
    } else {
      await _loadPackageBytes(
        files.normalName,
        files.normalBytes,
        trustedRakSystem: true,
      );
    }
    if (!mounted) return;
    setState(() {
      _rakPlan = plan;
      _rakFiles = files;
      _bridgeInstalled = false;
      _status = plan.needsRecovery
          ? 'Verified ${plan.installedName}: recovery bridge first, then '
                '${plan.normalProfile} from ${files.tag}. Enable the nearby '
                'radio updater to install both in order.'
          : 'Verified ${plan.installedName}: ${plan.normalProfile} from '
                '${files.tag}. A recovery bridge is not needed. The signed '
                'LoRa bootloader package is available in LoRa OTA when supported.';
    });
  });

  Future<void> _choosePackage() => _run(() async {
    const group = XTypeGroup(label: 'Nordic DFU ZIP', extensions: ['zip']);
    final file = widget.pickFirmware != null
        ? await widget.pickFirmware!()
        : await openFile(acceptedTypeGroups: [group]);
    if (file != null) await _loadPackage(file);
  });

  Future<void> _chooseFromDownloads() => _run(() async {
    final downloads = Directory('/sdcard/Download');
    if (!await downloads.exists()) {
      throw StateError('The Downloads folder is unavailable.');
    }
    final files = <File>[];
    await for (final entry in downloads.list(followLinks: false)) {
      if (entry is File && entry.path.toLowerCase().endsWith('.zip')) {
        files.add(entry);
      }
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    if (files.isEmpty) throw StateError('No DFU ZIP was found in Downloads.');
    if (files.length > 32) {
      throw StateError(
        'Too many ZIP files in Downloads; move older files out.',
      );
    }
    if (!mounted) return;
    final chosen = await showDialog<File>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Choose DFU ZIP'),
        children: files
            .map(
              (file) => SimpleDialogOption(
                onPressed: () => Navigator.pop(dialogContext, file),
                child: Text(file.uri.pathSegments.last),
              ),
            )
            .toList(),
      ),
    );
    if (chosen != null) await _loadPackage(XFile(chosen.path));
  });

  Future<void> _enableRadioDfu() => _run(() async {
    if (_package == null) throw StateError('Choose firmware first.');
    final currentBoard = await _readBoard();
    if (CompanionBoardCatalog.lookup(currentBoard)?.id !=
        CompanionBoardCatalog.lookup(_board)?.id) {
      throw StateError(
        'Repeater board changed. Choose exact-board firmware again.',
      );
    }
    _checkContinue();
    final reply = await _commands.sendCommand(
      widget.repeater,
      'start ota',
      retries: 2,
      minimumTimeoutMs: 15000,
    );
    final address = NrfDfuPackage.macFromStartReply(reply);
    _checkContinue();
    setState(() {
      _address = address;
      _bootloaderOnly = false;
      _status =
          '${widget.repeater.name} is advertising Nordic DFU at '
          '$address. Keep the radio powered and the phone nearby.';
    });
  });

  Future<void> _startDfu() async {
    var address = _address;
    final path = _packagePath;
    if (address == null || path == null) return;
    final needsBridge = _rakPlan?.needsRecovery == true && !_bridgeInstalled;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: Text(
          needsBridge
              ? 'Install RAK recovery and normal bootloader?'
              : 'Update over Bluetooth?',
        ),
        content: Text(
          needsBridge
              ? 'The installed ${_rakPlan!.installedName} needs the verified '
                    '$_packageName bridge first, followed by '
                    '${_rakFiles!.normalName}. These bootloader DFU ZIPs can '
                    'erase the application; it may need reinstalling afterward. '
                    'Keep the phone close and radio powered through both stages.'
              : 'Send $_packageName to $address for ${widget.repeater.name}. '
                    'A bootloader DFU ZIP may erase the application. The ZIP '
                    'must match this exact board and bootloader. Keep the phone '
                    'close and do not remove radio power.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Start Bluetooth update'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(() async {
      _checkContinue();
      final selectedFile = File(path);
      if (await selectedFile.length() > 4 * 1024 * 1024) {
        throw const FormatException(
          'Selected Nordic ZIP exceeds the supported limit.',
        );
      }
      final selectedBytes = await selectedFile.readAsBytes();
      final selected = _systemPackageSha != null
          ? await CompanionFirmwareValidation.inspectNordicPackage(
              selectedBytes,
            )
          : await CompanionFirmwareValidation.inspectNordic(
              selectedBytes,
              board: _board ?? '',
              role: _applicationRole,
            );
      _checkContinue();
      if (selected.sha256 != _package?.sha256) {
        throw const FormatException(
          'Selected firmware changed after inspection.',
        );
      }
      final system =
          selected.components.length != 1 ||
          selected.components.single != 'application';
      if (system) {
        final files = _rakFiles;
        if (_rakPlan == null ||
            files == null ||
            selected.sha256 != _systemPackageSha ||
            !_verifiedSystemHashes.contains(selected.sha256)) {
          throw StateError(
            'System updates require the verified exact-board RAK migration workflow.',
          );
        }
      }
      setState(() {
        _status = 'Connecting to the radio DFU service...';
        _progress = 0;
      });
      Future<void> transfer(
        String filePath, {
        required bool retryBootloader,
      }) async {
        _checkContinue();
        if (_dfuRecovery.isBusy) {
          throw StateError('Another native Bluetooth update is running.');
        }
        // Do not compete with the native updater's bootloader scan. Keep the
        // established Companion link for any later authenticated LoRa stage.
        await context.read<MeshCoreConnector>().stopScan();
        _checkContinue();
        await _recoveryStore.markExternalTransferActive(
          address: address!,
          board: _board ?? '',
          publicKey: widget.repeater.publicKeyHex,
        );
        try {
          await _dfuRecovery.update(
            originalAddress: address!,
            path: filePath,
            board: _board ?? '',
            applicationOnly: !system,
            retryBootloader: retryBootloader,
            onStatus: (status) {
              if (mounted && !_operationCancelled) {
                setState(() => _status = status);
              }
            },
            onProgress: (percent) {
              if (mounted && !_operationCancelled) {
                setState(() => _progress = percent);
              }
            },
          );
        } finally {
          if (_dfuRecovery.nativeTerminationConfirmed) {
            await _recoveryStore.markExternalTransferSettled();
          }
        }
        _checkContinue();
      }

      // Progress near 100% and a nearby advertisement are not proof that a
      // bootloader accepted a system image. Continue only after native success.
      await transfer(path, retryBootloader: _bootloaderOnly);
      if (needsBridge) {
        _bridgeInstalled = true;
        await _loadPackageBytes(
          _rakFiles!.normalName,
          _rakFiles!.normalBytes,
          keepAddress: true,
          trustedRakSystem: true,
        );
        if (!mounted) return;
        setState(() {
          _status =
              'Recovery bridge accepted. Waiting for its DFU restart '
              'before installing the normal RAK bootloader...';
          _progress = 0;
        });
        await Future<void>.delayed(const Duration(seconds: 5));
        _checkContinue();
        // A combined bootloader ZIP may leave the application running after
        // activation. If it does, ask it to enter DFU again. If it was erased,
        // the bridge advertises at the previous Bluetooth address plus one.
        try {
          final reply = await _commands.sendCommand(
            widget.repeater,
            'start ota',
            retries: 1,
            minimumTimeoutMs: 8000,
          );
          address = NrfDfuPackage.macFromStartReply(reply);
          _checkContinue();
          _bootloaderOnly = false;
          if (mounted) setState(() => _address = address);
        } catch (_) {
          _checkContinue();
          _bootloaderOnly = true;
          // Keep the original authenticated address binding. Shared DFU
          // recovery will require fresh full/short-name and protocol proof
          // at that address or +1 before any system component is sent.
          if (mounted) {
            setState(
              () => _status =
                  'The application did not answer after recovery. '
                  'Looking for this verified bridge before continuing...',
            );
          }
        }
        try {
          await transfer(_packagePath!, retryBootloader: _bootloaderOnly);
        } catch (error) {
          throw StateError(
            'The recovery bridge was sent, but the normal '
            'bootloader did not finish: $error. Keep the radio powered '
            'and retry the normal stage.',
          );
        }
      }
      if (!mounted) return;
      setState(() {
        _completed = true;
        _progress = 100;
        _status = _rakPlan == null
            ? 'Nordic DFU completed. Verify the installed version after '
                  'restart. Reinstall the application if needed.'
            : 'Nordic DFU completed. Check that the installed bootloader is '
                  '${_rakPlan!.model}_DFU and verify its version after '
                  'restart. Reinstall the application if needed.';
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Bluetooth update')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                widget.repeater.name,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              UpdateStatusCard(
                message: _status,
                busy: _busy,
                progress: _progress,
              ),
              if (_busy)
                OutlinedButton.icon(
                  onPressed: _operationCancelled ? null : _cancelUpdate,
                  icon: const Icon(Icons.cancel_outlined),
                  label: const Text('Cancel update'),
                ),
              if (!_busy)
                OutlinedButton.icon(
                  onPressed: _checkNativeStopped,
                  icon: const Icon(Icons.verified_user_outlined),
                  label: const Text('Check stopped Bluetooth updater'),
                ),
              const SizedBox(height: 16),
              const Text(
                'Use a Nordic DFU ZIP for this exact nRF52 board. '
                'Keep the radio powered and nearby.',
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _busy ? null : _prepareRakUpdate,
                icon: const Icon(Icons.auto_fix_high),
                label: const Text('Find the right RAK bootloader update'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy ? null : _choosePackage,
                icon: const Icon(Icons.file_open),
                label: const Text('Choose DFU ZIP'),
              ),
              OutlinedButton(
                onPressed: _busy ? null : _chooseFromDownloads,
                child: const Text('Phone Downloads'),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _busy || _package == null ? null : _enableRadioDfu,
                child: const Text('Enable radio updater'),
              ),
              if (_address != null)
                FilledButton.icon(
                  onPressed: _busy || _completed ? null : _startDfu,
                  icon: const Icon(Icons.bluetooth),
                  label: const Text('Start Bluetooth update'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
