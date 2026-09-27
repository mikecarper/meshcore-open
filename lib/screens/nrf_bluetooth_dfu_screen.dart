import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:nordic_dfu/nordic_dfu.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../models/contact.dart';
import '../services/nrf_dfu_package.dart';
import '../services/repeater_command_service.dart';
import '../widgets/update_status_card.dart';

class NrfBluetoothDfuScreen extends StatefulWidget {
  const NrfBluetoothDfuScreen({super.key, required this.repeater});

  final Contact repeater;

  @override
  State<NrfBluetoothDfuScreen> createState() => _NrfBluetoothDfuScreenState();
}

class _NrfBluetoothDfuScreenState extends State<NrfBluetoothDfuScreen> {
  late final RepeaterCommandService _commands;
  String? _packagePath;
  String? _packageName;
  NrfDfuPackage? _package;
  String? _address;
  String _status = 'Choose a board-matched Nordic DFU ZIP.';
  int? _progress;
  bool _busy = false;
  bool _completed = false;

  @override
  void initState() {
    super.initState();
    _commands = RepeaterCommandService(context.read<MeshCoreConnector>());
  }

  @override
  void dispose() {
    _commands.dispose();
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
      if (mounted) setState(() => _status = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadPackage(XFile file) async {
    final bytes = await file.readAsBytes();
    final package = NrfDfuPackage.inspect(Uint8List.fromList(bytes));
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
      _packageName = file.name;
      _package = package;
      _address = null;
      _progress = null;
      _completed = false;
      _status =
          '${file.name}: ${package.components.join(', ')} '
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
    final address = _address;
    final path = _packagePath;
    if (address == null || path == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: const Text('Update over Bluetooth?'),
        content: Text(
          'Send $_packageName to $address for ${widget.repeater.name}. '
          'The ZIP must match this exact board and bootloader. '
          'Keep the phone close and do not remove radio power.',
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
        _status = 'Connecting to the radio DFU service…';
        _progress = 0;
      });
      await NordicDfu().startDfu(
        address,
        path,
        name: widget.repeater.name,
        androidParameters: const AndroidParameters(
          startAsForegroundService: true,
          packetReceiptNotificationsEnabled: true,
          // API 22 often observes the buttonless disconnect before the Nordic
          // bootloader has begun advertising. Give it time to re-enumerate.
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
      if (!mounted) return;
      setState(() {
        _completed = true;
        _progress = 100;
        _status =
            'Nordic DFU completed. Wait for the radio to restart, '
            'then reconnect and check its version.';
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
