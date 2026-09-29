import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nordic_dfu/nordic_dfu.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../models/contact.dart';
import '../services/github_mota_release_service.dart';
import '../services/nrf_dfu_package.dart';
import '../services/rak_bootloader_migration.dart';
import '../services/repeater_command_service.dart';
import '../widgets/update_status_card.dart';

class NrfBluetoothDfuScreen extends StatefulWidget {
  const NrfBluetoothDfuScreen({
    super.key,
    required this.repeater,
    this.commandService,
  });

  final Contact repeater;
  final RepeaterCommandService? commandService;

  @override
  State<NrfBluetoothDfuScreen> createState() => _NrfBluetoothDfuScreenState();
}

class _NrfBluetoothDfuScreenState extends State<NrfBluetoothDfuScreen> {
  late final RepeaterCommandService _commands;
  final GitHubMotaReleaseService _releases = GitHubMotaReleaseService();
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

  @override
  void initState() {
    super.initState();
    final connector = context.read<MeshCoreConnector>();
    _commands = widget.commandService ?? RepeaterCommandService(connector);
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
    _releases.dispose();
    final path = _packagePath;
    if (path != null) {
      unawaited(File(path).delete().catchError((_) => File(path)));
    }
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(() => _status = _errorMessage(error));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
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

  Future<bool> _bridgeIsAdvertising(String address) async {
    if (FlutterBluePlus.isScanningNow) return false;
    final seen = Completer<void>();
    final subscription = FlutterBluePlus.onScanResults.listen((results) {
      if (!seen.isCompleted &&
          results.any(
            (result) => result.device.remoteId.str.toUpperCase() == address,
          )) {
        seen.complete();
      }
    }, onError: (Object _) {});
    try {
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 8),
        androidScanMode: AndroidScanMode.lowLatency,
      );
      await seen.future.timeout(const Duration(seconds: 8));
      return true;
    } catch (_) {
      return false;
    } finally {
      await subscription.cancel();
      if (FlutterBluePlus.isScanningNow) await FlutterBluePlus.stopScan();
    }
  }

  Future<void> _loadPackage(XFile file) async {
    final bytes = await file.readAsBytes();
    await _loadPackageBytes(file.name, Uint8List.fromList(bytes));
    _rakPlan = null;
    _rakFiles = null;
    _bridgeInstalled = false;
  }

  Future<void> _loadPackageBytes(
    String name,
    Uint8List bytes, {
    bool keepAddress = false,
  }) async {
    final package = NrfDfuPackage.inspect(bytes);
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
      if (!keepAddress) _address = null;
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
      _progress = null;
      _completed = false;
      _status = 'Reading the RAK board and installed bootloader...';
    });
    if (previous != null) {
      unawaited(File(previous).delete().catchError((_) => File(previous)));
    }
    final board = await _commands.sendCommand(
      widget.repeater,
      'board',
      retries: 2,
      minimumTimeoutMs: 15000,
    );
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
    setState(
      () => _status = plan.needsRecovery
          ? 'Installed ${plan.installedName} needs the exact recovery bridge. '
                'Checking the published two-stage update...'
          : 'Installed ${plan.installedName} can use the unified RAK image. '
                'Checking its published update...',
    );
    final files = await _releases.downloadRakBootloaderDfu(plan);
    if (!mounted) return;
    if (plan.needsRecovery) {
      final recoveryName = files.recoveryName;
      final recoveryBytes = files.recoveryBytes;
      if (recoveryName == null || recoveryBytes == null) {
        throw StateError('The matching recovery bridge is unavailable.');
      }
      await _loadPackageBytes(recoveryName, recoveryBytes);
    } else {
      await _loadPackageBytes(files.normalName, files.normalBytes);
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
    final file = await openFile(acceptedTypeGroups: [group]);
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
    final reply = await _commands.sendCommand(
      widget.repeater,
      'start ota',
      retries: 2,
      minimumTimeoutMs: 15000,
    );
    final address = NrfDfuPackage.macFromStartReply(reply);
    if (!mounted) return;
    setState(() {
      _address = address;
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
      setState(() {
        _status = 'Connecting to the radio DFU service...';
        _progress = 0;
      });
      Future<void> transfer(String filePath, {required bool forceDfu}) =>
          NordicDfu().startDfu(
            address!,
            filePath,
            name: widget.repeater.name,
            forceDfu: forceDfu,
            androidParameters: const AndroidParameters(
              startAsForegroundService: true,
              packetReceiptNotificationsEnabled: true,
              rebootTime: 5000,
              numberOfRetries: 5,
            ),
            dfuEventHandler: DfuEventHandler(
              onProgressChanged:
                  (_, percent, speed, avgSpeed, currentPart, partsTotal) {
                    if (mounted) setState(() => _progress = percent);
                  },
              onError: (_, error, errorType, message) {
                if (mounted) {
                  setState(() => _status = 'Bluetooth DFU error: $message');
                }
              },
            ),
          );
      var bridgeAdvertising = false;
      try {
        await transfer(path, forceDfu: _bridgeInstalled);
      } catch (_) {
        if (!needsBridge || (_progress ?? 0) < 95) rethrow;
        bridgeAdvertising = await _bridgeIsAdvertising(
          NrfDfuPackage.bootloaderAddress(address!),
        );
        if (!bridgeAdvertising) rethrow;
      }
      if (needsBridge) {
        _bridgeInstalled = true;
        final bridgeAddress = NrfDfuPackage.bootloaderAddress(address!);
        await _loadPackageBytes(
          _rakFiles!.normalName,
          _rakFiles!.normalBytes,
          keepAddress: true,
        );
        if (!mounted) return;
        setState(() {
          _status =
              'Recovery bridge accepted. Waiting for its DFU restart '
              'before installing the normal RAK bootloader...';
          _progress = 0;
        });
        await Future<void>.delayed(const Duration(seconds: 5));
        // A combined bootloader ZIP may leave the application running after
        // activation. If it does, ask it to enter DFU again. If it was erased,
        // the bridge advertises at the previous Bluetooth address plus one.
        if (bridgeAdvertising) {
          address = bridgeAddress;
          if (mounted) setState(() => _address = bridgeAddress);
        } else {
          try {
            final reply = await _commands.sendCommand(
              widget.repeater,
              'start ota',
              retries: 1,
              minimumTimeoutMs: 8000,
            );
            address = NrfDfuPackage.macFromStartReply(reply);
            if (mounted) setState(() => _address = address);
          } catch (_) {
            address = bridgeAddress;
            if (mounted) setState(() => _address = bridgeAddress);
            if (mounted) {
              setState(
                () => _status =
                    'The application did not answer after recovery. '
                    'Trying the bridge at $bridgeAddress...',
              );
            }
          }
        }
        try {
          await transfer(_packagePath!, forceDfu: true);
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
