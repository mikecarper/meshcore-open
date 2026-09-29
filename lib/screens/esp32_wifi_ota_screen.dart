import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../models/contact.dart';
import '../services/esp32_partition_catalog.dart';
import '../services/esp32_wifi_ota_service.dart';
import '../services/esp32_partition_migration_package.dart';
import '../services/esp32_migration_decision.dart';
import '../services/github_mota_release_service.dart';
import '../services/local_mota_builder.dart';
import '../services/repeater_command_service.dart';
import '../services/update_battery_note.dart';
import '../widgets/update_status_card.dart';

class Esp32WifiOtaScreen extends StatefulWidget {
  const Esp32WifiOtaScreen({
    super.key,
    required this.repeater,
    this.commandService,
    this.pickApplication,
    this.pickMigration,
  });

  final Contact repeater;
  final RepeaterCommandService? commandService;
  final Future<XFile?> Function()? pickApplication;
  final Future<XFile?> Function()? pickMigration;

  @override
  State<Esp32WifiOtaScreen> createState() => _Esp32WifiOtaScreenState();
}

class _Esp32WifiOtaScreenState extends State<Esp32WifiOtaScreen> {
  static const _platform = MethodChannel('com.meshcore.meshcore_open/settings');

  late final RepeaterCommandService _commands;
  final _wifi = Esp32WifiOtaService();
  final _releases = GitHubMotaReleaseService();
  Uint8List? _image;
  String? _filename;
  Uri? _url;
  Esp32WifiOtaProbe? _probe;
  String? _reportedBoard;
  String? _versionBefore;
  Esp32PartitionAssessment? _partition;
  String _status = 'Choose a non-merged ESP32 application image.';
  bool _busy = false;
  bool _uploadConfirmed = false;
  Esp32PartitionMigrationPackage? _migrationPackage;
  int _migrationStep = 0;
  bool _migrationStarted = false;

  String get _migrationRole =>
      widget.repeater.type == advTypeRoom ? 'room-server' : 'repeater';

  String get _batteryConfirmationLine {
    final snapshot = context
        .read<MeshCoreConnector>()
        .getRepeaterBatterySnapshot(widget.repeater.publicKeyHex);
    return updateBatteryNote(
      millivolts: snapshot?.millivolts,
      reportedAt: snapshot?.updatedAt,
    );
  }

  @override
  void initState() {
    super.initState();
    _commands =
        widget.commandService ??
        RepeaterCommandService(context.read<MeshCoreConnector>());
  }

  @override
  void dispose() {
    _commands.dispose();
    _wifi.dispose();
    _releases.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() task) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await task();
    } catch (error) {
      if (mounted) setState(() => _status = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chooseImage() => _run(() async {
    const group = XTypeGroup(label: 'ESP32 application', extensions: ['bin']);
    final file = widget.pickApplication == null
        ? await openFile(acceptedTypeGroups: [group])
        : await widget.pickApplication!();
    if (file == null) return;
    final bytes = await file.readAsBytes();
    Esp32WifiOtaService.validateImage(file.name, bytes);
    if (!mounted) return;
    setState(() {
      _image = bytes;
      _filename = file.name;
      _partition = null;
      _url = null;
      _probe = null;
      _migrationStarted = false;
      _migrationPackage = null;
      _migrationStep = 0;
      _uploadConfirmed = false;
      _status =
          'Selected ${file.name} (${(bytes.length / 1024).round()} KB). '
          'Check its board name before starting.';
    });
  });

  Future<void> _chooseMigrationBundle({bool fromDownloads = false}) =>
      _run(() async {
        XFile? file;
        if (fromDownloads) {
          final directory = Directory('/sdcard/Download');
          if (!await directory.exists()) {
            throw StateError('Downloads is unavailable on this phone.');
          }
          final candidates = <File>[];
          await for (final entry in directory.list(followLinks: false)) {
            if (entry is File &&
                entry.path.toLowerCase().endsWith('-migration.zip')) {
              candidates.add(entry);
            }
          }
          candidates.sort((a, b) => a.path.compareTo(b.path));
          if (candidates.isEmpty) {
            throw StateError('No migration ZIP was found in Downloads.');
          }
          if (candidates.length > 30) {
            throw StateError('Too many migration ZIPs in Downloads.');
          }
          if (!mounted) return;
          final selected = await showDialog<File>(
            context: context,
            builder: (dialogContext) => SimpleDialog(
              title: const Text('Choose board package'),
              children: [
                for (final candidate in candidates)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(dialogContext, candidate),
                    child: Text(candidate.uri.pathSegments.last),
                  ),
              ],
            ),
          );
          if (selected == null) return;
          file = XFile(selected.path);
        } else {
          file = widget.pickMigration == null
              ? await openFile(
                  acceptedTypeGroups: const [
                    XTypeGroup(
                      label: 'ESP32 migration bundle',
                      extensions: ['zip'],
                    ),
                  ],
                )
              : await widget.pickMigration!();
        }
        if (file == null || !mounted) return;
        if (await file.length() > 32 * 1024 * 1024) {
          throw const FormatException('Migration ZIP is too large.');
        }
        final package = Esp32PartitionMigrationPackage.load(
          await file.readAsBytes(),
        );
        _setMigrationPackage(package, source: 'Local ZIP');
      });

  void _setMigrationPackage(
    Esp32PartitionMigrationPackage package, {
    required String source,
  }) {
    if (package.role != _migrationRole) {
      throw StateError(
        'This ${package.role} migration ZIP cannot update a '
        '$_migrationRole radio.',
      );
    }
    if (!mounted) return;
    setState(() {
      _migrationPackage = package;
      _migrationStep = 0;
      _migrationStarted = false;
      _image = null;
      _filename = null;
      _partition = null;
      _url = null;
      _probe = null;
      _status =
          '$source: ${package.board} ${package.version} ${package.role} '
          'migration bundle. '
          'This is for target ${package.target}; confirm the radio board '
          'before checking the upgrade.';
    });
  }

  Future<void> _findMigrationBundleOnGitHub() => _run(() async {
    final assets = await _releases.findPartitionMigrationBundles();
    if (assets.isEmpty) {
      throw StateError(
        'No ESP32 migration ZIP is published in recent GitHub releases. '
        'Choose an exact-board bundle from Downloads instead.',
      );
    }
    final board = await _commands.sendCommand(
      widget.repeater,
      'board',
      retries: 2,
      minimumTimeoutMs: 15000,
    );
    final candidates = assets
        .where(
          (asset) => Esp32MigrationDecision.matchesAsset(
            reportedBoard: board,
            role: _migrationRole,
            assetName: asset.name,
          ),
        )
        .toList();
    if (candidates.length != 1) {
      throw StateError(
        'Expected one published $_migrationRole migration ZIP for $board; '
        'found ${candidates.length}. Choose an exact-board local ZIP if '
        'this board uses a different published name.',
      );
    }
    final package = await _releases.downloadPartitionMigrationBundle(
      candidates.single,
    );
    if (!Esp32MigrationDecision.matchesBoard(
      reportedBoard: board,
      packageBoard: package.board,
      role: package.role,
    )) {
      throw StateError('The published ZIP manifest has a different board.');
    }
    _setMigrationPackage(package, source: 'GitHub SHA-256 verified');
  });

  Future<void> _startMigrationUpdater() => _run(() async {
    final package = _migrationPackage;
    if (package == null) throw StateError('Choose a migration bundle first.');
    final board = await _commands.sendCommand(
      widget.repeater,
      'board',
      retries: 2,
      minimumTimeoutMs: 15000,
    );
    final version = await _commands.sendCommand(
      widget.repeater,
      'ver',
      retries: 2,
      minimumTimeoutMs: 15000,
    );
    // Newer nodes report an exact OTA target. Old Wi-Fi-only firmware may
    // reject this optional command, so check the board name in that case.
    String? status;
    try {
      status = await _commands.sendCommand(
        widget.repeater,
        'ota status',
        retries: 1,
        minimumTimeoutMs: 5000,
      );
    } catch (_) {
      // Legacy builds may not implement the read-only mOTA status command.
    }
    final target = status == null
        ? null
        : RegExp(r'\btarget:([0-9a-fA-F]{8})').firstMatch(status);
    final targetConfirmed = target != null;
    if (targetConfirmed &&
        int.parse(target.group(1)!, radix: 16) != package.targetId) {
      throw StateError('Migration bundle targets a different radio.');
    }
    final currentLayout = await _checkPartitions(
      board,
      version,
      package.application.length,
    );
    final route = Esp32MigrationDecision.choose(
      package: package,
      reportedBoard: board,
      role: _migrationRole,
      currentLayout: currentLayout,
      targetConfirmed: targetConfirmed,
    );
    if (route == Esp32MigrationRoute.normalUpdate) {
      if (!mounted) return;
      setState(() {
        _image = package.application;
        _filename = 'full-application.bin';
        _partition = currentLayout;
        _reportedBoard = board;
        _versionBefore = version;
        _url = null;
        _probe = null;
        _migrationStarted = false;
        _status =
            'The full application already fits this radio. No partition '
            'bridge is needed. Start the normal Wi-Fi updater to install '
            '${package.version}. ${currentLayout.message}';
      });
      return;
    }
    final bridgePartition = await _checkPartitions(
      board,
      version,
      package.bridge.length,
    );
    if (bridgePartition.blocksUpload) {
      throw StateError(
        'The migration bridge cannot fit the reported old layout. '
        'Use a smaller exact-board bridge or a cable installation. '
        '${bridgePartition.message}',
      );
    }
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Step 1: expand partitions?'),
        scrollable: true,
        content: Text(
          'Radio: ${widget.repeater.name}\n'
          'Reported board: $board\n'
          'Package board: ${package.board} (${package.hardwareId})\n'
          'Current firmware: $version\n'
          '${bridgePartition.message}\n'
          'Target: ${package.target}$_batteryConfirmationLine\n\n'
          'This bridge changes the partition table and preserves the node '
          'identity; other settings may need to be recreated. Keep stable '
          'external power connected. A power loss '
          'during the table-sector rewrite can require cable recovery. '
          'Continue only if the exact board matches.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Start step 1'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final reply = await _commands.sendCommand(
      widget.repeater,
      'start ota',
      retries: 2,
      minimumTimeoutMs: 15000,
    );
    final url = Esp32WifiOtaService.parseStartReply(reply);
    if (!mounted) return;
    setState(() {
      _reportedBoard = board;
      _versionBefore = version;
      _url = url;
      _probe = null;
      _migrationStep = 0;
      _migrationStarted = true;
      _status =
          'Connect this phone to the radio\'s MeshCore-OTA Wi-Fi, then '
          'check the connection and upload the bridge.';
    });
  });

  Future<void> _uploadMigrationBridge() => _run(() async {
    final package = _migrationPackage;
    final url = _url;
    final probe = _probe;
    if (package == null || url == null || probe == null) {
      throw StateError('Start and check the old updater first.');
    }
    setState(() => _status = 'Uploading migration bridge from this phone…');
    await _wifi.upload(
      updateUri: url,
      protocol: probe.protocol,
      filename: 'wifi-bridge.bin',
      image: package.bridge,
    );
    if (!mounted) return;
    setState(() {
      _migrationStep = 1;
      _status =
          'Bridge accepted. Keep external power connected while it rewrites '
          'the table. Join ${package.migrationApName} in Wi-Fi settings '
          '(password: ${package.migrationApPassword}), wait for reboot, '
          'then check step 2 readiness.';
    });
  });

  Future<void> _checkMigrationReady() => _run(() async {
    final state = await _wifi.probeMigrationBridge();
    if (!mounted) return;
    setState(() {
      if (state == Esp32MigrationBridgeState.ready) {
        _migrationStep = 2;
        _status =
            'Expanded layout and restored identity confirmed by the bridge. '
            'The final application can now be uploaded.';
      } else {
        _status =
            'Bridge is still migrating. Keep power connected and check again.';
      }
    });
  });

  Future<void> _uploadMigrationApplication() async {
    final package = _migrationPackage;
    if (package == null || _migrationStep != 2) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Step 2: install full application?'),
        scrollable: true,
        content: Text(
          'The bridge confirmed its expanded layout and recovered identity. '
          'Upload ${package.board} ${package.version} into the inactive '
          'partition now. Keep external power connected.'
          '$_batteryConfirmationLine',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Install step 2'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(() async {
      if (await _wifi.probeMigrationBridge() !=
          Esp32MigrationBridgeState.ready) {
        throw StateError('The bridge is not ready for the final image.');
      }
      setState(() => _status = 'Uploading full application from this phone…');
      await _wifi.upload(
        updateUri: Esp32WifiOtaService.migrationBridgeUri,
        protocol: Esp32WifiOtaProtocol.elegant,
        filename: 'full-application.bin',
        image: package.application,
      );
      if (!mounted) return;
      setState(() {
        _migrationStep = 3;
        _status =
            'Full application accepted. Reconnect to the mesh after reboot '
            'and verify the running image.';
      });
    });
  }

  Future<void> _verifyMigration() => _run(() async {
    final package = _migrationPackage;
    if (package == null || _migrationStep != 3) return;
    final reply = await _commands.sendCommand(
      widget.repeater,
      'ota self',
      retries: 2,
      minimumTimeoutMs: 15000,
    );
    final expected = FirmwareImageIdentity.read(
      package.application,
      maxSize: 0x1000000,
    ).bodyHashHex;
    final actual = RegExp(
      r'\bbase_hash=([0-9A-Fa-f]{16})',
    ).firstMatch(reply)?.group(1)?.toUpperCase();
    if (actual != expected) {
      throw StateError(
        'The radio has not confirmed the final image yet. '
        'Expected $expected, received ${actual ?? reply}.',
      );
    }
    if (mounted) {
      setState(
        () => _status =
            'Two-step migration verified: ${package.board} now runs the '
            'exact final image ($expected).',
      );
    }
  });

  Future<Esp32PartitionAssessment> _checkPartitions(
    String board,
    String version,
    int imageBytes,
  ) => Esp32PartitionCatalog.check(
    readStorage: () => _commands.sendCommand(
      widget.repeater,
      'get storage.layout',
      retries: 1,
      minimumTimeoutMs: 5000,
    ),
    board: board,
    version: version,
    role: widget.repeater.type == advTypeRoom ? 'room_server' : 'repeater',
    imageBytes: imageBytes,
  );

  Future<void> _startUpdater() => _run(() async {
    if (_image == null) throw StateError('Choose firmware first.');
    setState(() {
      _url = null;
      _probe = null;
      _partition = null;
      _status = 'Checking radio version and partition capacity...';
    });
    final board = await _commands.sendCommand(
      widget.repeater,
      'board',
      retries: 2,
      minimumTimeoutMs: 15000,
    );
    final version = await _commands.sendCommand(
      widget.repeater,
      'ver',
      retries: 2,
      minimumTimeoutMs: 15000,
    );
    final partition = await _checkPartitions(board, version, _image!.length);
    if (!mounted) return;
    setState(() {
      _partition = partition;
      _reportedBoard = board;
      _versionBefore = version;
    });
    if (partition.blocksUpload) {
      setState(
        () => _status =
            'Normal update stopped. Review the partition details below.',
      );
      return;
    }
    final reply = await _commands.sendCommand(
      widget.repeater,
      'start ota',
      retries: 2,
      minimumTimeoutMs: 15000,
    );
    final url = Esp32WifiOtaService.parseStartReply(reply);
    if (!mounted) return;
    setState(() {
      _url = url;
      _probe = null;
      _migrationStarted = false;
      _reportedBoard = board;
      _versionBefore = version;
      _status =
          'Updater started at $url. If it is 192.168.4.1, connect '
          'this phone to MeshCore-OTA in Wi-Fi settings, then tap Check connection.';
    });
  });

  Future<void> _checkConnection() => _run(() async {
    final url = _url;
    if (url == null) throw StateError('Start the radio updater first.');
    final probe = await _wifi.probe(url);
    if (!mounted) return;
    setState(() {
      _probe = probe;
      _status =
          'Connected to ${probe.identity} at $url. '
          'Confirm that the selected image matches ${widget.repeater.name}.';
    });
  });

  Future<void> _upload() async {
    final image = _image;
    final filename = _filename;
    final url = _url;
    final probe = _probe;
    if (image == null ||
        filename == null ||
        url == null ||
        probe == null ||
        _partition == null ||
        _partition!.blocksUpload) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Install ESP32 firmware?'),
        scrollable: true,
        content: Text(
          'Send $filename to ${probe.identity} at ${url.host}. '
          'The radio reports board $_reportedBoard and currently runs '
          '$_versionBefore. '
          '${_partition!.message}\n\n'
          'The radio will write its OTA partition and reboot. '
          'Use only an image built for ${widget.repeater.name}; '
          'do not remove power.$_batteryConfirmationLine',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Upload and reboot'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(() async {
      setState(() => _status = 'Uploading $filename from this phone…');
      await _wifi.upload(
        updateUri: url,
        protocol: probe.protocol,
        filename: filename,
        image: image,
      );
      if (!mounted) return;
      setState(() {
        _uploadConfirmed = true;
        _status =
            'Upload accepted. The radio is rebooting; verify its '
            'running version before another update.';
      });
    });
  }

  Future<void> _verifyRestart() => _run(() async {
    final response = await _commands.sendCommand(
      widget.repeater,
      'ver',
      retries: 2,
      minimumTimeoutMs: 15000,
    );
    if (mounted) {
      setState(
        () => _status = response == _versionBefore
            ? 'Radio replied after reboot, but still reports $response. '
                  'The new version is not confirmed.'
            : 'Radio replied after reboot: $response '
                  '(previously $_versionBefore).',
      );
    }
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Wi-Fi update')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              widget.repeater.name,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            UpdateStatusCard(message: _status, busy: _busy),
            if (_partition != null) ...[
              const SizedBox(height: 12),
              Text(_partition!.message),
            ],
            const SizedBox(height: 16),
            const Text(
              'Use an ESP32 application .bin for this exact board, '
              'not a merged image. Keep the radio powered during the update.',
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _busy ? null : _chooseImage,
              icon: const Icon(Icons.file_open),
              label: const Text('Choose application .bin'),
            ),
            FilledButton(
              onPressed: _busy || _image == null ? null : _startUpdater,
              child: const Text('Start updater on radio'),
            ),
            if (_url != null && !_migrationStarted) ...[
              const SizedBox(height: 8),
              Text('Update address: $_url'),
              if (_url!.host == '192.168.4.1')
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => _platform.invokeMethod<void>('openWifiSettings'),
                  child: const Text('Open Wi-Fi settings'),
                ),
              OutlinedButton(
                onPressed: _busy ? null : _checkConnection,
                child: const Text('Check connection to radio'),
              ),
            ],
            if (_probe != null && !_migrationStarted)
              FilledButton.icon(
                onPressed: _busy || (_partition?.blocksUpload ?? true)
                    ? null
                    : _upload,
                icon: const Icon(Icons.system_update_alt),
                label: const Text('Upload and reboot'),
              ),
            if (_uploadConfirmed)
              OutlinedButton(
                onPressed: _busy ? null : _verifyRestart,
                child: const Text('Verify radio restarted'),
              ),
            const Divider(height: 32),
            ExpansionTile(
              key: ValueKey(_partition?.action),
              initiallyExpanded:
                  _partition?.action == Esp32PartitionAction.expand,
              tilePadding: EdgeInsets.zero,
              title: const Text('Partition upgrade'),
              subtitle: const Text('Check whether this upgrade needs a bridge'),
              children: [
                const SizedBox(height: 6),
                const Text(
                  'The app checks the installed layout first. If the full '
                  'image fits, use the normal updater. Otherwise, a supported '
                  'exact-board ZIP supplies a bridge and final application. '
                  'Unsupported boards still need a cable migration. Never upload '
                  'a merged .bin through Wi-Fi.',
                ),
                OutlinedButton(
                  onPressed: _busy ? null : _chooseMigrationBundle,
                  child: const Text('Choose migration ZIP'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : _findMigrationBundleOnGitHub,
                  child: const Text('Find migration ZIP on GitHub'),
                ),
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => _chooseMigrationBundle(fromDownloads: true),
                  child: const Text('Find migration ZIP in Downloads'),
                ),
                if (_migrationPackage != null) ...[
                  Text(
                    '${_migrationPackage!.board} · ${_migrationPackage!.version} · '
                    '${_migrationPackage!.flashBytes ~/ 0x100000} MB flash',
                  ),
                  if (_migrationStarted || _migrationStep > 0)
                    Text(
                      'Bridge Wi-Fi after step 1: '
                      '${_migrationPackage!.migrationApName} - '
                      'password ${_migrationPackage!.migrationApPassword} '
                      '(from ZIP instructions)',
                    ),
                  FilledButton(
                    onPressed: _busy ? null : _startMigrationUpdater,
                    child: const Text('Check this upgrade'),
                  ),
                  if (_migrationStarted &&
                      _url != null &&
                      _migrationStep == 0) ...[
                    OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => _platform.invokeMethod<void>(
                              'openWifiSettings',
                            ),
                      child: const Text('Open Wi-Fi settings'),
                    ),
                    OutlinedButton(
                      onPressed: _busy ? null : _checkConnection,
                      child: const Text('Check old updater connection'),
                    ),
                    FilledButton(
                      onPressed: _busy || _probe == null
                          ? null
                          : _uploadMigrationBridge,
                      child: const Text('Step 1: upload bridge'),
                    ),
                  ],
                  if (_migrationStep >= 1) ...[
                    OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => _platform.invokeMethod<void>(
                              'openWifiSettings',
                            ),
                      child: const Text('Join bridge Wi-Fi'),
                    ),
                    OutlinedButton(
                      onPressed: _busy ? null : _checkMigrationReady,
                      child: const Text('Check expanded layout and identity'),
                    ),
                  ],
                  if (_migrationStep == 0 &&
                      _partition?.action != Esp32PartitionAction.fits)
                    OutlinedButton(
                      onPressed: _busy ? null : _checkMigrationReady,
                      child: const Text('Resume step 2 on a ready bridge'),
                    ),
                  if (_migrationStep == 2)
                    FilledButton(
                      onPressed: _busy ? null : _uploadMigrationApplication,
                      child: const Text('Step 2: upload final application'),
                    ),
                  if (_migrationStep == 3)
                    OutlinedButton(
                      onPressed: _busy ? null : _verifyMigration,
                      child: const Text('Verify final image on radio'),
                    ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
