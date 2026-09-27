import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nordic_dfu/nordic_dfu.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../services/esp32_wifi_ota_service.dart';
import '../services/github_mota_release_service.dart';
import '../services/local_mota_builder.dart';
import '../services/nrf_dfu_package.dart';
import '../widgets/mesh_ui.dart';
import '../widgets/update_status_card.dart';

class CompanionUpdateScreen extends StatefulWidget {
  const CompanionUpdateScreen({super.key});

  @override
  State<CompanionUpdateScreen> createState() => _CompanionUpdateScreenState();
}

class _CompanionUpdateScreenState extends State<CompanionUpdateScreen> {
  static const _settings = MethodChannel('com.meshcore.meshcore_open/settings');
  final _wifi = Esp32WifiOtaService();
  final _releases = GitHubMotaReleaseService();
  final _scrollController = ScrollController();
  MeshCoreConnector? _dfuConnector;
  String? _board;
  String? _version;
  String? _filename;
  String? _dfuPath;
  String? _dfuAddress;
  NrfDfuPackage? _dfu;
  Uint8List? _espImage;
  FirmwareImageIdentity? _imageIdentity;
  Uri? _updateUri;
  Esp32WifiOtaProbe? _probe;
  String _status = 'Reading the connected Companion…';
  bool _busy = false;
  int? _progress;
  bool _isError = false;
  String? _errorDetails;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _readDevice());
  }

  @override
  void dispose() {
    _dfuConnector?.setPreserveUpdateScreenOnDisconnect(false);
    _wifi.dispose();
    _releases.dispose();
    _scrollController.dispose();
    final path = _dfuPath;
    if (path != null && !_busy) {
      File(path).delete().catchError((_) => File(path));
    }
    super.dispose();
  }

  Future<void> _run(
    Future<void> Function() action, {
    String? failureMessage,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _isError = false;
      _errorDetails = null;
      _progress = null;
    });
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(() {
          _isError = true;
          _progress = null;
          if (error is StateError) {
            _status = error.message.toString();
          } else if (error is FormatException) {
            _status = error.message;
          } else if (error is SocketException) {
            _status =
                'Could not connect. Check the phone connection and try again.';
          } else {
            _status =
                failureMessage ??
                'Could not complete this step. Check the connection and try again.';
            _errorDetails = '$error';
          }
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _readDevice() => _run(() async {
    final connector = context.read<MeshCoreConnector>();
    if (!connector.isConnected) {
      throw StateError('Connect to a Companion first.');
    }
    String board;
    String version;
    try {
      board = await connector.executeLocalCliCommand('board');
      version = await connector.executeLocalCliCommand('version');
    } catch (_) {
      board = connector.manufacturerName ?? 'Unknown board';
      version = connector.firmwareVersionString ?? 'Unknown firmware';
    }
    if (!mounted) return;
    setState(() {
      _board = board;
      _version = version;
      _status = 'Choose firmware built for this exact board.';
    });
  });

  Future<void> _chooseFirmware() => _run(() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Companion firmware', extensions: ['zip', 'bin']),
      ],
    );
    if (file == null) return;
    if (await file.length() > 16 * 1024 * 1024) {
      throw const FormatException('Firmware file is too large.');
    }
    await _loadFirmware(file.name, await file.readAsBytes());
  });

  Future<void> _chooseFromDownloads() => _run(() async {
    final directory = Directory('/sdcard/Download');
    if (!await directory.exists()) {
      throw StateError('Phone Downloads is unavailable.');
    }
    final files = <File>[];
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is File &&
          (entry.path.toLowerCase().endsWith('.zip') ||
              entry.path.toLowerCase().endsWith('.bin'))) {
        files.add(entry);
      }
    }
    if (files.isEmpty) {
      throw StateError('No firmware ZIP or .bin in Downloads.');
    }
    if (files.length > 40) {
      throw StateError('Too many firmware files in Downloads.');
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    if (!mounted) return;
    final chosen = await showDialog<File>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Choose downloaded firmware'),
        children: [
          for (final candidate in files)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, candidate),
              child: Text(candidate.uri.pathSegments.last),
            ),
        ],
      ),
    );
    if (chosen == null) return;
    final length = await chosen.length();
    if (length > 16 * 1024 * 1024) {
      throw const FormatException('Firmware file is too large.');
    }
    await _loadFirmware(
      chosen.uri.pathSegments.last,
      await chosen.readAsBytes(),
    );
  });

  Future<void> _findOnGitHub() => _run(() async {
    setState(() => _status = 'Checking GitHub for board-matched firmware...');
    final board = _board;
    if (board == null) throw StateError('Read the Companion board first.');
    final assets = await _releases.findCompanionAssets(board);
    if (assets.isEmpty) {
      throw StateError(
        'No exact-board Companion BLE update is published in the latest GitHub releases. Choose a local file instead.',
      );
    }
    final newer = assets
        .where(
          (asset) =>
              GitHubMotaReleaseService.isCompanionReleaseNewer(
                _version ?? '',
                asset.name,
              ) !=
              false,
        )
        .toList();
    if (newer.isEmpty) {
      throw StateError(
        'Your installed firmware is newer than the latest board-matched '
        'GitHub release. No downgrade was selected.',
      );
    }
    if (!mounted) return;
    final chosen = await showDialog<GitHubReleaseAsset>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Board-matched GitHub releases'),
        children: [
          for (final asset in newer)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, asset),
              child: Text(asset.name),
            ),
        ],
      ),
    );
    if (chosen == null) return;
    if (mounted) {
      setState(() => _status = 'Downloading and verifying ${chosen.name}…');
    }
    await _loadFirmware(
      chosen.name,
      await _releases.downloadCompanionAsset(chosen),
    );
  });

  Future<void> _loadFirmware(String name, List<int> bytes) async {
    if (name.toLowerCase().endsWith('.zip')) {
      final package = NrfDfuPackage.inspect(Uint8List.fromList(bytes));
      final directory = await getTemporaryDirectory();
      final copy = File(
        '${directory.path}/meshcore-companion-dfu-${DateTime.now().microsecondsSinceEpoch}.zip',
      );
      await copy.writeAsBytes(bytes, flush: true);
      final previous = _dfuPath;
      if (!mounted) {
        await copy.delete();
        return;
      }
      setState(() {
        _filename = name;
        _dfuPath = copy.path;
        _dfu = package;
        _espImage = null;
        _imageIdentity = null;
        _status =
            'Nordic package: ${package.components.join(', ')}. '
            'Confirm it matches $_board and its bootloader.';
      });
      if (previous != null) {
        try {
          await File(previous).delete();
        } catch (_) {
          /* cache cleanup */
        }
      }
    } else {
      final image = Uint8List.fromList(bytes);
      Esp32WifiOtaService.validateImage(name, image);
      FirmwareImageIdentity? identity;
      try {
        identity = FirmwareImageIdentity.read(image, maxSize: 0x1000000);
      } catch (_) {
        // Older ESP32 builds have no EndF trailer; the board check remains manual.
      }
      if (!mounted) return;
      setState(() {
        _filename = name;
        _espImage = image;
        _imageIdentity = identity;
        _dfu = null;
        _updateUri = null;
        _probe = null;
        _status =
            'ESP32 image selected. '
            'Confirm ${identity?.hardwareId ?? name} matches $_board.';
      });
    }
  }

  String get _batteryNote {
    final mv = context.read<MeshCoreConnector>().batteryMillivolts;
    return mv != null && mv > 0
        ? '\nLast reported battery: ${(mv / 1000).toStringAsFixed(2)} V.'
        : '';
  }

  Future<bool> _confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          scrollable: true,
          title: Text(title),
          content: Text('$message$_batteryNote'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Update'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _startBluetoothDfu() async {
    final path = _dfuPath;
    final package = _dfu;
    if (path == null || package == null) return;
    final connector = context.read<MeshCoreConnector>();
    final retryBootloader = !connector.isConnected && _dfuAddress != null;
    if (!retryBootloader &&
        (connector.activeTransport != MeshCoreTransportType.bluetooth ||
            !connector.isConnected)) {
      setState(
        () => _status =
            'Connect directly to the Companion over Bluetooth for DFU.',
      );
      return;
    }
    final address = retryBootloader ? _dfuAddress! : connector.deviceIdLabel;
    final bootMessage = retryBootloader
        ? 'The bootloader must still be advertising. Keep it powered.'
        : 'The Companion will disconnect and reboot. Keep it powered.';
    if (!await _confirm(
      retryBootloader ? 'Retry bootloader?' : 'Update Companion?',
      'Send $_filename to $_board at $address. '
      'The ZIP must match this exact board and bootloader. '
      '$bootMessage',
    )) {
      return;
    }
    if (!mounted) return;
    _dfuAddress = address;
    connector.setPreserveUpdateScreenOnDisconnect(true);
    _dfuConnector = connector;
    await _run(
      () async {
        setState(() {
          _status = retryBootloader
              ? 'Retrying the nearby DFU bootloader…'
              : 'Releasing Companion Bluetooth for Nordic DFU…';
          _progress = 0;
        });
        if (retryBootloader) {
          await Future<void>.delayed(const Duration(seconds: 5));
        } else {
          await connector.disconnect(manual: true);
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        Future<void> transfer({required bool forceBootloader}) async {
          await NordicDfu().startDfu(
            address,
            path,
            name: _board,
            forceDfu: forceBootloader,
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
        }

        try {
          await transfer(forceBootloader: retryBootloader);
        } on PlatformException catch (error) {
          if (retryBootloader || (error.code != '62' && error.code != '4101')) {
            rethrow;
          }
          if (mounted) {
            setState(() {
              _status =
                  'Android lost the bootloader connection. Retrying once…';
              _progress = 0;
            });
          }
          await Future<void>.delayed(const Duration(seconds: 5));
          await transfer(forceBootloader: true);
        }
        if (mounted) {
          setState(() {
            _progress = 100;
            _status =
                'Bluetooth update finished. Reconnect to the Companion and check its version.';
          });
        }
      },
      failureMessage:
          'The Bluetooth update did not finish. Keep the radio powered and nearby, then retry the bootloader.',
    );
  }

  Future<void> _startWifi() => _run(() async {
    if (_espImage == null) {
      throw StateError('Choose an ESP32 application first.');
    }
    final connector = context.read<MeshCoreConnector>();
    final reply = await connector.executeLocalCliCommand('start ota ap');
    if (reply.toLowerCase().contains('select wifi transport')) {
      throw StateError(
        'This Companion boots in exclusive Bluetooth mode. '
        'Switch it to Wi-Fi transport and reboot before Wi-Fi OTA; '
        'use Nordic DFU if this is an nRF52 board.',
      );
    }
    final uri = Esp32WifiOtaService.parseStartReply(reply);
    if (!mounted) return;
    setState(() {
      _updateUri = uri;
      _probe = null;
      _status =
          'Updater started at $uri. Join MeshCore-OTA in phone Wi-Fi settings, '
          'then return and check the connection.';
    });
  });

  Future<void> _probeWifi() => _run(() async {
    final uri = _updateUri;
    if (uri == null) throw StateError('Start the Companion updater first.');
    final probe = await _wifi.probe(uri);
    if (!mounted) return;
    setState(() {
      _probe = probe;
      _status = 'Connected to ${probe.identity}. Confirm the board and upload.';
    });
  });

  Future<void> _uploadWifi() async {
    final image = _espImage;
    final uri = _updateUri;
    final probe = _probe;
    if (image == null || uri == null || probe == null) return;
    if (!await _confirm(
      'Update Companion over Wi-Fi?',
      'Upload $_filename (${(image.length / 1024).round()} KB) to '
          '${probe.identity} for $_board. '
          'Image hardware: ${_imageIdentity?.hardwareId ?? 'unmarked / confirm manually'}. '
          'The Companion will reboot. Keep it powered.',
    )) {
      return;
    }
    if (!mounted) return;
    await _run(() async {
      setState(() => _status = 'Uploading firmware from this phone…');
      await _wifi.upload(
        updateUri: uri,
        protocol: probe.protocol,
        filename: _filename ?? 'companion.bin',
        image: image,
      );
      if (mounted) {
        setState(
          () => _status =
              'Upload accepted. Reconnect to the Companion and verify its version.',
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('Companion update')),
      body: SafeArea(
        child: ListView(
          controller: _scrollController,
          padding: const EdgeInsets.all(16),
          children: [
            MeshCard(
              margin: EdgeInsets.zero,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.router_outlined,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _board ?? 'Reading board...',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Refresh Companion details',
                        onPressed: _busy ? null : _readDevice,
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                  if (_version != null)
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: const Text('Installed firmware'),
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: SelectableText(_version!),
                        ),
                        const SizedBox(height: 8),
                      ],
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            UpdateStatusCard(
              message: _status,
              busy: _busy,
              progress: _progress,
              isError: _isError,
              details: _errorDetails,
            ),
            if (_filename != null) ...[
              const SizedBox(height: 16),
              MeshCard(
                margin: EdgeInsets.zero,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Selected firmware',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 6),
                    SelectableText(
                      _filename!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (_dfu != null)
              FilledButton.icon(
                onPressed: _busy ? null : _startBluetoothDfu,
                icon: const Icon(Icons.bluetooth),
                label: Text(
                  !context.read<MeshCoreConnector>().isConnected &&
                          _dfuAddress != null
                      ? 'Retry bootloader'
                      : 'Update over Bluetooth',
                ),
              ),
            if (_espImage != null) ...[
              FilledButton.icon(
                onPressed: _busy ? null : _startWifi,
                icon: const Icon(Icons.wifi),
                label: const Text('Start Wi-Fi updater'),
              ),
              if (_updateUri != null) ...[
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => _settings.invokeMethod<void>('openWifiSettings'),
                  child: const Text('Open Wi-Fi settings'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : _probeWifi,
                  child: const Text('Check Wi-Fi connection'),
                ),
              ],
              if (_probe != null)
                FilledButton(
                  onPressed: _busy ? null : _uploadWifi,
                  child: const Text('Upload firmware'),
                ),
            ],
            const SizedBox(height: 16),
            if (_filename == null)
              FilledButton.icon(
                onPressed: _busy || _board == null ? null : _findOnGitHub,
                icon: const Icon(Icons.cloud_download_outlined),
                label: const Text('Find updates on GitHub'),
              )
            else
              OutlinedButton.icon(
                onPressed: _busy || _board == null ? null : _findOnGitHub,
                icon: const Icon(Icons.cloud_download_outlined),
                label: const Text('Find updates on GitHub'),
              ),
            const SizedBox(height: 8),
            MeshCard(
              margin: EdgeInsets.zero,
              padding: EdgeInsets.zero,
              child: ExpansionTile(
                title: Text(
                  _filename == null
                      ? 'Use a firmware file'
                      : 'Choose another file',
                ),
                subtitle: const Text('Nordic ZIP or ESP32 .bin'),
                childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _chooseFromDownloads,
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('Phone Downloads'),
                    ),
                  ),
                  const SizedBox(height: 4),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton.icon(
                      onPressed: _busy ? null : _chooseFirmware,
                      icon: const Icon(Icons.folder_open),
                      label: const Text('Browse files'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
