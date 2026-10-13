import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../services/companion_firmware_inspector.dart';
import '../services/companion_board_catalog.dart';
import '../services/companion_image_validator.dart';
import '../services/companion_firmware_validation.dart';
import '../services/companion_target_catalog.dart';
import '../services/esp32_partition_catalog.dart';
import '../services/esp32_wifi_ota_service.dart';
import '../services/github_mota_release_service.dart';
import '../services/local_mota_builder.dart';
import '../services/nrf_dfu_package.dart';
import '../services/nrf_dfu_recovery.dart';
import '../services/nrf_dfu_recovery_store.dart';
import '../services/native_dfu_lifetime.dart';
import '../services/usb_firmware_package.dart';
import '../utils/app_logger.dart';
import '../widgets/mesh_ui.dart';
import '../widgets/update_status_card.dart';
import 'usb_node_update_screen.dart';

String _dfuExportCode(String? value) {
  if (value == null || !RegExp(r'^[0-9]{1,5}$').hasMatch(value)) {
    return 'unavailable';
  }
  final code = int.parse(value);
  return code <= 0xFFFF ? '$code' : 'unavailable';
}

class CompanionUpdateScreen extends StatefulWidget {
  const CompanionUpdateScreen({
    super.key,
    this.pickFirmware,
    this.dfuRecovery,
    this.recoveryStore,
    this.releases,
  });

  final Future<XFile?> Function()? pickFirmware;
  final NrfDfuRecovery? dfuRecovery;
  final NrfDfuRecoveryStore? recoveryStore;
  final GitHubMotaReleaseService? releases;

  @override
  State<CompanionUpdateScreen> createState() => _CompanionUpdateScreenState();
}

class _CompanionUpdateScreenState extends State<CompanionUpdateScreen> {
  static const _settings = MethodChannel('com.meshcore.meshcore_open/settings');
  final _wifi = Esp32WifiOtaService();
  late final GitHubMotaReleaseService _releases;
  final _scrollController = ScrollController();
  MeshCoreConnector? _dfuConnector;
  String? _board;
  String? _reportedBoard;
  bool _boardManuallyConfirmed = false;
  String? _version;
  String? _filename;
  String? _dfuPath;
  String? _dfuAddress;
  String? _dfuBootloaderAddress;
  String? _companionKey;
  String? _companionAddress;
  late final NrfDfuRecovery _dfuRecovery;
  late final NrfDfuRecoveryStore _recoveryStore;
  NrfDfuRecoveryRecord? _recoveryRecord;
  CompanionFirmwareProvenance? _provenance;
  bool _nativeUnconfirmed = false;
  bool _ownsPersistedTransfer = false;
  NrfDfuPackage? _dfu;
  Uint8List? _espImage;
  FirmwareImageIdentity? _imageIdentity;
  Uri? _updateUri;
  Esp32WifiOtaProbe? _probe;
  Esp32WifiOtaBinding? _wifiBinding;
  Esp32PartitionAssessment? _partition;
  String _status = 'Reading the connected Companion…';
  bool _busy = false;
  int? _progress;
  bool _isError = false;
  String? _errorDetails;

  String? get _expectedExtension =>
      CompanionFirmwareInspector.updateExtensionForBoard(_board);

  String? get _selectedProfile {
    if (_provenance != null) return _provenance!.profile;
    final spec = CompanionBoardCatalog.lookup(_board);
    final target =
        _dfu?.applicationIdentity?.targetId ?? _imageIdentity?.targetId;
    return spec == null || target == null
        ? null
        : CompanionTargetCatalog.profileFor(target, spec);
  }

  String get _firmwareHint {
    final spec = CompanionBoardCatalog.lookup(_board);
    if (spec != null && !spec.supportsWirelessUpdate) {
      return spec.family == CompanionChipFamily.rp2040
          ? 'RP2040 firmware - wired USB only; no Bluetooth or Wi-Fi OTA'
          : 'ESP32 .bin - wired USB only; this board has no Wi-Fi OTA';
    }
    return switch (_expectedExtension) {
      'zip' => 'Nordic DFU .zip - Bluetooth update',
      'bin' => 'ESP32 application .bin - Wi-Fi update; full/erase needs USB',
      _ => 'Nordic DFU .zip or ESP32 application .bin',
    };
  }

  @override
  void initState() {
    super.initState();
    _releases = widget.releases ?? GitHubMotaReleaseService();
    _dfuRecovery = widget.dfuRecovery ?? NrfDfuRecovery();
    _recoveryStore = widget.recoveryStore ?? NrfDfuRecoveryStore();
    WidgetsBinding.instance.addPostFrameCallback((_) => _readDevice());
  }

  @override
  void dispose() {
    _dfuRecovery.dispose();
    _dfuConnector?.setPreserveUpdateScreenOnDisconnect(false);
    _wifi.dispose();
    _releases.dispose();
    _scrollController.dispose();
    final path = _dfuPath;
    if (path != null && !_busy && path != _recoveryRecord?.path) {
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
          } else if (error is UsbFirmwareValidationException) {
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
    if (_ownsPersistedTransfer && _dfuRecovery.nativeTerminationConfirmed) {
      await _recoveryStore.markTransferSettled();
      _ownsPersistedTransfer = false;
    }
    _nativeUnconfirmed = await _recoveryStore.hasUnconfirmedNativeTransfer();
    final saved = await _recoveryStore.load();
    if (_nativeUnconfirmed) {
      throw StateError(
        'A previous native Bluetooth update has not confirmed termination. Keep the radio powered. No new transfer will start; do not erase recovery data.',
      );
    }
    if (saved != null && !connector.isConnected) {
      final bytes = await File(saved.path).readAsBytes();
      final package = await CompanionFirmwareValidation.inspectNordic(
        bytes,
        board: saved.board,
        provenance: saved.provenance,
      );
      if (!mounted) return;
      setState(() {
        _recoveryRecord = saved;
        _board = saved.board;
        _companionKey = saved.publicKey;
        _companionAddress = saved.originalAddress;
        _dfuAddress = saved.originalAddress;
        _dfuBootloaderAddress = saved.verifiedBootloaderAddress;
        _dfuPath = saved.path;
        _filename = saved.filename;
        _dfu = package;
        _provenance = saved.provenance;
        _status =
            'Verified update restored for ${saved.board}. Retry only while this radio bootloader is advertising, or reconnect to verify its version.';
      });
      return;
    }
    if (!connector.isConnected) {
      throw StateError('Connect to a Companion first.');
    }
    final identity = connector.selfPublicKeyHex;
    final address = connector.deviceIdLabel;
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
    if (!connector.isConnected ||
        connector.selfPublicKeyHex != identity ||
        connector.deviceIdLabel != address) {
      throw StateError(
        'Companion changed while reading device info. Reopen the updater.',
      );
    }
    final previous = _dfuPath;
    setState(() {
      _recoveryRecord = saved;
      _board = board;
      _reportedBoard = board;
      _boardManuallyConfirmed = false;
      _companionKey = identity;
      _companionAddress = address;
      _version = version;
      _partition = null;
      _filename = null;
      _dfuPath = null;
      _dfuAddress = null;
      _dfuBootloaderAddress = null;
      _dfu = null;
      _espImage = null;
      _imageIdentity = null;
      _updateUri = null;
      _probe = null;
      _wifiBinding = null;
      _status = 'Choose firmware built for this exact board. $_firmwareHint.';
    });
    if (previous != null && previous != _recoveryRecord?.path) {
      try {
        await File(previous).delete();
      } catch (_) {
        /* cache cleanup */
      }
    }
  });

  Future<void> _correctBoardIdentity() => _run(() async {
    final connector = context.read<MeshCoreConnector>();
    if (!connector.isConnected ||
        _nativeUnconfirmed ||
        _recoveryRecord != null ||
        _dfuRecovery.isBusy) {
      throw StateError(
        'Finish or verify the saved update before changing the expected hardware.',
      );
    }
    final identity = connector.selfPublicKeyHex;
    final address = connector.deviceIdLabel;
    if (!connector.supportsNordicCompanionDfu) {
      setState(() => _busy = false);
      final useUsb = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          scrollable: true,
          title: const Text('Recover incorrect firmware'),
          content: const Text(
            'The installed firmware supplies the reported board name. If it is '
            'wrong, use the model printed on the hardware to choose its USB '
            'recovery image. This connected firmware has no verified Bluetooth '
            'DFU service. Wi-Fi cannot correct a conflicting image identity.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Close'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Open USB installer'),
            ),
          ],
        ),
      );
      if (useUsb == true && mounted) {
        await Navigator.push<void>(
          context,
          MaterialPageRoute(builder: (_) => const UsbNodeUpdateScreen()),
        );
      }
      return;
    }
    await connector.refreshNordicDfuService();
    if (!mounted) return;
    // No work is running while the modal waits for the user's selection.
    setState(() => _busy = false);
    final candidates = CompanionBoardCatalog.specs
        .where(
          (spec) =>
              spec.family == CompanionChipFamily.nrf52 &&
              spec.dfuNames.isNotEmpty &&
              spec.nrfApplicationAddress != null &&
              spec.nrfApplicationMaxSize != null &&
              spec.nrfSoftdeviceIds.isNotEmpty &&
              spec.hardwareIds.isNotEmpty &&
              spec.assetPrefixes.isNotEmpty,
        )
        .toList();
    CompanionBoardSpec? selected;
    var confirmed = false;
    final chosen = await showDialog<CompanionBoardSpec>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, updateDialog) => AlertDialog(
          scrollable: true,
          title: const Text('Recover incorrect firmware'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Firmware reports: ${_reportedBoard ?? _board}'),
              const SizedBox(height: 12),
              const Text(
                'Choose the physical model from its label or verified '
                'bootloader information. File integrity, bootloader layout '
                'and same-radio checks still apply.',
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<CompanionBoardSpec>(
                // Flutter 3.32 (API 22 build) predates initialValue.
                // ignore: deprecated_member_use
                value: selected,
                isExpanded: true,
                menuMaxHeight: 280,
                decoration: const InputDecoration(labelText: 'Physical board'),
                items: [
                  for (final spec in candidates)
                    DropdownMenuItem(
                      value: spec,
                      child: Text(spec.aliases.first),
                    ),
                ],
                onChanged: (value) => updateDialog(() {
                  selected = value;
                  confirmed = false;
                }),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('I checked the physical board model'),
                value: confirmed,
                onChanged: selected == null
                    ? null
                    : (value) => updateDialog(() => confirmed = value == true),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: confirmed
                  ? () => Navigator.pop(dialogContext, selected)
                  : null,
              child: const Text('Use selected board'),
            ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    if (!connector.isConnected ||
        connector.selfPublicKeyHex != identity ||
        connector.deviceIdLabel != address) {
      throw StateError('Companion changed during hardware confirmation.');
    }
    final previous = _dfuPath;
    setState(() {
      _board = chosen.aliases.first;
      _boardManuallyConfirmed = true;
      _filename = null;
      _dfuPath = null;
      _dfuAddress = null;
      _dfuBootloaderAddress = null;
      _dfu = null;
      _provenance = null;
      _espImage = null;
      _imageIdentity = null;
      _wifiBinding = null;
      _partition = null;
      _updateUri = null;
      _probe = null;
      _status =
          'Hardware selected by you: $_board. Choose its firmware again. '
          'The installed version will not hide recovery releases.';
    });
    if (previous != null) {
      try {
        await File(previous).delete();
      } catch (_) {
        /* cache cleanup */
      }
    }
  });

  Future<void> _chooseFirmware() => _run(() async {
    final extension = _expectedExtension;
    final file = widget.pickFirmware != null
        ? await widget.pickFirmware!()
        : await openFile(
            acceptedTypeGroups: [
              XTypeGroup(
                label: 'Companion firmware',
                extensions: extension == null ? ['zip', 'bin'] : [extension],
              ),
            ],
          );
    if (file == null) return;
    if (await file.length() > 16 * 1024 * 1024) {
      throw const FormatException('Firmware file is too large.');
    }
    await _loadFirmware(file.name, await file.readAsBytes());
  });

  Future<void> _chooseFromDownloads() => _run(() async {
    final extension = _expectedExtension;
    final directory = Directory('/sdcard/Download');
    if (!await directory.exists()) {
      throw StateError('Phone Downloads is unavailable.');
    }
    final files = <File>[];
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is File &&
          (extension == null
              ? entry.path.toLowerCase().endsWith('.zip') ||
                    entry.path.toLowerCase().endsWith('.bin')
              : entry.path.toLowerCase().endsWith('.$extension'))) {
        files.add(entry);
      }
    }
    if (files.isEmpty) {
      throw StateError('No matching $_firmwareHint file in Downloads.');
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

  Future<void> _findOnGitHub({
    bool includeOlderVersions = false,
  }) => _run(() async {
    setState(() => _status = 'Checking GitHub for board-matched firmware...');
    final board = _board;
    if (board == null) throw StateError('Read the Companion board first.');
    if (!(CompanionBoardCatalog.lookup(board)?.supportsWirelessUpdate ??
        false)) {
      throw StateError(
        'This board has no supported wireless updater. Use its exact-board wired USB installer.',
      );
    }
    final assets = await _releases.findCompanionAssets(
      board,
      extension: _expectedExtension,
      includeOlderVersions: includeOlderVersions,
    );
    if (assets.isEmpty) {
      throw StateError(
        'No verified exact-board Full Companion update is published in these GitHub releases. Choose a reviewed BLE file only if you intend to remove Full features, or use an exact-board wired installer.',
      );
    }
    int? order(GitHubReleaseAsset asset) =>
        GitHubMotaReleaseService.compareCompanionRelease(
          _version ?? '',
          asset.name,
        );
    final eligible = assets
        .where(
          (asset) =>
              includeOlderVersions ||
              _boardManuallyConfirmed ||
              (order(asset) ?? 1) >= 0,
        )
        .toList();
    if (eligible.isEmpty) {
      throw StateError(
        'Your installed firmware is newer than the latest board-matched '
        'GitHub release. No downgrade was selected. '
        'Use Choose another version to review older firmware.',
      );
    }
    if (!mounted) return;
    final chosen = await showDialog<GitHubReleaseAsset>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Board-matched GitHub releases'),
        children: [
          for (final asset in eligible)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, asset),
              child: Text(
                (order(asset) ?? 1) < 0
                    ? '${asset.name}\nOlder version - downgrade'
                    : order(asset) == 0
                    ? '${asset.name}\nSame version - reinstall'
                    : asset.name,
              ),
            ),
        ],
      ),
    );
    if (chosen == null) return;
    if ((order(chosen) ?? 1) <= 0) {
      if (!mounted) return;
      final downgrade = order(chosen)! < 0;
      final reinstall = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          scrollable: true,
          title: Text(
            downgrade ? 'Downgrade firmware?' : 'Reinstall this version?',
          ),
          content: Text(
            downgrade
                ? 'This release is older than the reported installed firmware. '
                      'Older firmware may remove features or be unable to read newer '
                      'settings. This changes the application only; it does not '
                      'downgrade the bootloader or shrink partitions. Board, file '
                      'integrity and same-radio checks still apply.\n\n${chosen.name}'
                : 'This release has the same numeric version as the installed '
                      'firmware. The build or features may differ. Board, file integrity '
                      'and same-radio checks still apply.\n\n${chosen.name}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(downgrade ? 'Downgrade' : 'Reinstall'),
            ),
          ],
        ),
      );
      if (reinstall != true) {
        if (mounted) {
          setState(
            () => _status = downgrade
                ? 'Downgrade cancelled.'
                : 'Reinstall cancelled.',
          );
        }
        return;
      }
    }
    if (mounted) {
      setState(() => _status = 'Downloading and verifying ${chosen.name}...');
    }
    final download = await _releases.downloadCompanionFirmware(
      chosen,
      board: board,
    );
    await _loadFirmware(
      chosen.name,
      download.bytes,
      provenance: download.provenance,
    );
  });

  Future<void> _loadFirmware(
    String name,
    List<int> bytes, {
    CompanionFirmwareProvenance? provenance,
  }) async {
    if (_nativeUnconfirmed || _dfuRecovery.isQuarantined) {
      throw StateError(
        'The previous native update has not confirmed termination. No new firmware can be selected.',
      );
    }
    final spec = CompanionBoardCatalog.lookup(_board);
    if (spec == null || !spec.supportsWirelessUpdate) {
      throw const FormatException(
        'This exact board has no supported wireless update path. Use its wired installer.',
      );
    }
    final lower = name.toLowerCase();
    final extension = lower.endsWith('.zip')
        ? 'zip'
        : lower.endsWith('.bin')
        ? 'bin'
        : null;
    if (extension == null ||
        (_expectedExtension != null && extension != _expectedExtension)) {
      throw FormatException('This board needs $_firmwareHint.');
    }
    if (extension == 'zip') {
      if (mounted) {
        setState(
          () => _status = 'Verifying board, firmware role and checksums...',
        );
      }
      final package = await CompanionFirmwareValidation.inspectNordic(
        Uint8List.fromList(bytes),
        board: _board!,
        provenance: provenance,
      );
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
        _provenance = provenance;
        _espImage = null;
        _imageIdentity = null;
        _partition = null;
        _updateUri = null;
        _probe = null;
        _status =
            'Nordic package: ${package.components.join(', ')}. '
            'Confirm it matches $_board and its bootloader.';
      });
      if (previous != null && previous != _recoveryRecord?.path) {
        try {
          await File(previous).delete();
        } catch (_) {
          /* cache cleanup */
        }
      }
    } else {
      final image = Uint8List.fromList(bytes);
      final layout = CompanionFirmwareInspector.inspectEsp32(image);
      if (layout == Esp32FirmwareLayout.fullFlash) {
        if (!mounted) return;
        final previous = _dfuPath;
        setState(() {
          _filename = name;
          _dfuPath = null;
          _dfu = null;
          _espImage = null;
          _imageIdentity = null;
          _partition = null;
          _updateUri = null;
          _probe = null;
          _isError = true;
          _status =
              'This .bin is a full/erase ESP32 image. It may replace '
              'partitions and device settings. It cannot be sent through '
              'phone Wi-Fi OTA; use an exact-board wired installer.';
        });
        if (previous != null && previous != _recoveryRecord?.path) {
          try {
            await File(previous).delete();
          } catch (_) {
            /* cache cleanup */
          }
        }
        return;
      }
      if (lower.contains('merged') ||
          lower.contains('cleaninstall') ||
          lower.contains('factory')) {
        throw const FormatException(
          'The filename says full/erase, but the bytes look like an '
          'application update. Verify this file before installing it.',
        );
      }
      final verified = await CompanionFirmwareValidation.inspectEsp32(
        name,
        image,
        board: _board!,
        provenance: provenance,
      );
      final endf = verified.endf;
      if (endf == null) {
        throw const FormatException(
          'The device-bound Wi-Fi updater requires a marked EndF application image. Use a marked exact-board release or wired installer.',
        );
      }
      final identity = FirmwareImageIdentity(
        targetId: endf.targetId,
        firmwareVersion: endf.version,
        hardwareId: endf.hardwareId,
        bodyHash: Uint8List.fromList(
          verified.bytes.sublist(
            verified.bytes.length - 48,
            verified.bytes.length - 40,
          ),
        ),
      );
      if (!mounted) return;
      final previous = _dfuPath;
      setState(() {
        _filename = name;
        _dfuPath = null;
        _espImage = verified.bytes;
        _imageIdentity = identity;
        _provenance = provenance;
        _partition = null;
        _dfu = null;
        _updateUri = null;
        _probe = null;
        _status =
            'ESP32 image selected. '
            'Verified ${identity.hardwareId} matches $_board.';
      });
      if (previous != null && previous != _recoveryRecord?.path) {
        try {
          await File(previous).delete();
        } catch (_) {
          /* cache cleanup */
        }
      }
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
    if (_nativeUnconfirmed ||
        _dfuRecovery.isBusy ||
        _dfuRecovery.isQuarantined) {
      setState(
        () => _status =
            'The previous native Bluetooth update has not settled. No overlapping transfer will start.',
      );
      return;
    }
    if (!retryBootloader && !connector.supportsNordicCompanionDfu) {
      setState(
        () => _status =
            'This Companion does not expose a writable Nordic DFU control service. Use an exact-board USB update; no Bluetooth handoff was attempted.',
      );
      return;
    }
    if (!retryBootloader &&
        (connector.activeTransport != MeshCoreTransportType.bluetooth ||
            !connector.isConnected)) {
      setState(
        () => _status =
            'Connect directly to the Companion over Bluetooth for DFU.',
      );
      return;
    }
    if (!retryBootloader &&
        (connector.selfPublicKeyHex != _companionKey ||
            connector.deviceIdLabel != _companionAddress)) {
      setState(
        () => _status =
            'The Companion changed. Read its device info and choose matching firmware again.',
      );
      return;
    }
    final address = retryBootloader ? _dfuAddress! : connector.deviceIdLabel;
    final directHandoff = canDiscoverDfuHandoff(address);
    final bootMessage = retryBootloader
        ? 'The bootloader must still be advertising. Keep it powered.'
        : 'The Companion will disconnect and reboot. Keep it powered.';
    if (!await _confirm(
      retryBootloader ? 'Retry bootloader?' : 'Update Companion?',
      'Send $_filename to $_board at $address. '
      '${retryBootloader && _dfuBootloaderAddress != null ? 'Last discovered bootloader: $_dfuBootloaderAddress. It will be checked again. ' : ''}'
      'The ZIP must match this exact board and bootloader. '
      '${_boardManuallyConfirmed ? 'You selected the physical hardware as $_board; the installed firmware reports $_reportedBoard. ' : ''}'
      '${_selectedProfile == 'ble' ? 'This is BLE-only firmware and may remove Full Companion features. ' : ''}'
      '$bootMessage',
    )) {
      return;
    }
    if (!mounted) return;
    if ((retryBootloader && connector.isConnected) ||
        (!retryBootloader &&
            (!connector.isConnected ||
                connector.activeTransport != MeshCoreTransportType.bluetooth ||
                !connector.supportsNordicCompanionDfu ||
                connector.selfPublicKeyHex != _companionKey ||
                connector.deviceIdLabel != address))) {
      setState(
        () => _status =
            'Connection changed during confirmation. Reopen the updater.',
      );
      return;
    }
    _dfuAddress = address;
    connector.setPreserveUpdateScreenOnDisconnect(true);
    _dfuConnector = connector;
    final applicationOnly =
        package.components.length == 1 &&
        package.components.single == 'application';
    appLogger.info(
      'Bluetooth DFU confirmed: board=$_board address=$address '
      'components=${package.components.join(',')} '
      'applicationOnly=$applicationOnly retryBootloader=$retryBootloader',
      tag: 'CompanionDFU',
      noNotify: true,
    );
    await _run(
      () async {
        var phase = 'release_companion';
        var progress = 0;
        var lastProgressBucket = -1;
        var payloadStarted = false;
        var validating = false;
        var nativeCode = 'unavailable';
        var nativeErrorType = 'unavailable';
        setState(() {
          _status = retryBootloader
              ? 'Finding this radio Bluetooth OTA bootloader...'
              : 'Releasing Companion Bluetooth for Nordic DFU...';
          _progress = 0;
        });
        try {
          appLogger.info(
            'Bluetooth DFU stage=$phase address=$address',
            tag: 'CompanionDFU',
            noNotify: true,
          );
          // Do not let the normal Companion scanner compete with the native
          // DFU service. Manual disconnect also disables auto-reconnection.
          await connector.stopScan();
          if (!retryBootloader) await connector.refreshNordicDfuService();
          if (!mounted) return;
          if ((retryBootloader && connector.isConnected) ||
              (!retryBootloader &&
                  (!connector.isConnected ||
                      !connector.supportsNordicCompanionDfu ||
                      connector.deviceIdLabel != address ||
                      connector.selfPublicKeyHex != _companionKey))) {
            throw StateError('Connection changed. Reopen the updater.');
          }
          if (!retryBootloader) {
            _recoveryRecord = await _recoveryStore.save(
              sourcePath: path,
              originalAddress: address,
              board: _board!,
              publicKey: _companionKey!,
              filename: _filename!,
              applicationOnly: applicationOnly,
              provenance: _provenance,
              verifiedBootloaderAddress: _dfuBootloaderAddress,
            );
            _dfuPath = _recoveryRecord!.path;
            if (directHandoff) {
              setState(
                () => _status =
                    'Asking the Companion to enter Bluetooth OTA mode...',
              );
              await connector.enterNordicDfu();
            }
            if (connector.isConnected &&
                (connector.deviceIdLabel != address ||
                    connector.selfPublicKeyHex != _companionKey)) {
              throw StateError(
                'Companion changed during Bluetooth DFU handoff.',
              );
            }
            await connector.disconnect(manual: true);
          }
          phase = 'connection_released';
          appLogger.info(
            'Bluetooth DFU stage=$phase address=$address',
            tag: 'CompanionDFU',
            noNotify: true,
          );
          await Future<void>.delayed(const Duration(seconds: 2));
          if (!mounted) return;
          await _recoveryStore.markTransferActive();
          _ownsPersistedTransfer = true;
          _nativeUnconfirmed = true;
          final completedAddress = await _dfuRecovery.update(
            originalAddress: address,
            path: _dfuPath!,
            board: _board ?? '',
            applicationOnly: applicationOnly,
            // Android uses the authenticated link followed by an exact-address
            // scan. Opaque iOS identifiers retain the native SDK's handoff.
            retryBootloader: retryBootloader || directHandoff,
            allowBondedBootloaderProbe: directHandoff,
            verifiedBootloaderAddress:
                _recoveryRecord?.verifiedBootloaderAddress,
            onStatus: (message) {
              // Native error strings are not trusted export metadata: they may
              // contain paths or other private details. Keep the prior stage
              // and extract only bounded numeric fields from a known header.
              if (message.startsWith('Bluetooth DFU error')) {
                final header = RegExp(
                  r'^Bluetooth DFU error \((?:code=)?([0-9]{1,5})(?:[, ]+type[= ]([123]))?\):',
                ).firstMatch(message);
                nativeCode = _dfuExportCode(header?.group(1));
                nativeErrorType = header?.group(2) ?? 'unavailable';
                appLogger.warn(
                  'Bluetooth DFU native_error: code=$nativeCode '
                  'errorType=$nativeErrorType stage=$phase address=$address '
                  'progress=$progress payloadStarted=$payloadStarted '
                  'validating=$validating',
                  tag: 'CompanionDFU',
                  noNotify: true,
                );
              } else {
                phase = switch (message) {
                  'Looking for this radio Bluetooth OTA bootloader...' =>
                    'discover_bootloader',
                  'Checking this bonded radio bootloader directly...' =>
                    'probe_bonded_bootloader',
                  'Connecting to the radio DFU service...' => 'connecting_dfu',
                  'Asking the Companion to enter Bluetooth OTA mode...' =>
                    'enabling_dfu',
                  'Bluetooth DFU connected. Sending firmware...' =>
                    'dfu_connected',
                  'Validating firmware on the radio...' => 'validating',
                  'Bluetooth handoff timed out. Looking for the actual bootloader before retrying...' =>
                    'recover_bootloader',
                  _
                      when message.startsWith(
                        'Found this radio bootloader. Reconnecting at ',
                      ) =>
                    'reconnect_bootloader',
                  _ => 'native_status_unknown',
                };
                if (phase == 'validating') validating = true;
                if (phase == 'dfu_connected') payloadStarted = true;
                appLogger.info(
                  'Bluetooth DFU stage=$phase address=$address '
                  'progress=$progress payloadStarted=$payloadStarted '
                  'validating=$validating',
                  tag: 'CompanionDFU',
                  noNotify: true,
                );
              }
              if (mounted) setState(() => _status = message);
            },
            onProgress: (percent) {
              final hadPayload = payloadStarted;
              progress = percent;
              if (percent > 0) {
                payloadStarted = true;
                phase = 'sending_payload';
              }
              // Keep the exported log useful without recording every packet.
              final bucket = percent ~/ 10;
              if (bucket != lastProgressBucket ||
                  (!hadPayload && payloadStarted)) {
                lastProgressBucket = bucket;
                appLogger.info(
                  'Bluetooth DFU progress=$percent address=$address '
                  'payloadStarted=$payloadStarted',
                  tag: 'CompanionDFU',
                  noNotify: true,
                );
              }
              if (mounted) setState(() => _progress = percent);
            },
            onBootloader: (found) {
              appLogger.info(
                'Bluetooth DFU bootloader selected: '
                'originalAddress=$address bootloaderAddress=$found',
                tag: 'CompanionDFU',
                noNotify: true,
              );
              if (mounted) setState(() => _dfuBootloaderAddress = found);
            },
          );
          appLogger.info(
            'Bluetooth DFU transfer complete: originalAddress=$address '
            'bootloaderAddress=$completedAddress; '
            'Companion reconnection and version verification still required',
            tag: 'CompanionDFU',
            noNotify: true,
          );
          if (mounted) {
            setState(() {
              _progress = 100;
              _status =
                  'Bluetooth update finished. Reconnect to the Companion and check its version.';
            });
          }
        } catch (error) {
          // Do not export arbitrary exception details, file paths, firmware
          // bytes, or identity keys. Native status callbacks identify the stage.
          final code = error is PlatformException
              ? _dfuExportCode(error.code)
              : nativeCode;
          appLogger.error(
            'Bluetooth DFU failed: stage=$phase address=$address '
            'progress=$progress payloadStarted=$payloadStarted '
            'validating=$validating errorType=${error.runtimeType} code=$code '
            'nativeErrorType=$nativeErrorType',
            tag: 'CompanionDFU',
            noNotify: true,
          );
          rethrow;
        } finally {
          if (_nativeUnconfirmed && _dfuRecovery.nativeTerminationConfirmed) {
            await _recoveryStore.markTransferSettled();
            _nativeUnconfirmed = false;
            _ownsPersistedTransfer = false;
          }
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
    void checkSameCompanion() {
      if (!connector.isConnected ||
          connector.selfPublicKeyHex != _companionKey ||
          connector.deviceIdLabel != _companionAddress) {
        throw StateError(
          'The Companion changed. Read its details again before Wi-Fi OTA.',
        );
      }
    }

    if (!connector.isConnected ||
        connector.selfPublicKeyHex != _companionKey ||
        connector.deviceIdLabel != _companionAddress) {
      throw StateError(
        'The Companion changed. Read its details again before starting Wi-Fi OTA.',
      );
    }
    setState(() {
      _updateUri = null;
      _probe = null;
      _partition = null;
      _status = 'Checking Companion partition capacity...';
    });
    final partition = await Esp32PartitionCatalog.check(
      readStorage: () => connector.executeLocalCliCommand('get storage.layout'),
      board: _board ?? '',
      version: _version ?? '',
      role: 'companion_radio',
      imageBytes: _espImage!.length,
    );
    if (!mounted) return;
    setState(() => _partition = partition);
    if (partition.blocksUpload) {
      throw StateError(
        'This image cannot be installed into the current Companion OTA layout. '
        'Review the partition details below.',
      );
    }
    final binding = Esp32WifiOtaBinding.parse(
      await connector.executeLocalCliCommand('get ota.identity'),
      board: _board!,
    );
    checkSameCompanion();
    if (_espImage!.length > binding.slot) {
      throw StateError(
        'The firmware exceeds the measured inactive OTA partition. Use a verified partition migration or wired installer.',
      );
    }
    final reply = await connector.executeLocalCliCommand('start ota ap');
    checkSameCompanion();
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
      _wifiBinding = binding;
      _probe = null;
      _status =
          'Updater started at $uri. Join MeshCore-OTA in phone Wi-Fi settings, '
          'then return and check the connection.';
    });
  });

  Future<void> _verifyBluetooth() => _run(() async {
    final saved = _recoveryRecord;
    final connector = context.read<MeshCoreConnector>();
    final verifyingAddress = connector.deviceIdLabel;
    if (saved == null ||
        !connector.isConnected ||
        connector.selfPublicKeyHex.toLowerCase() != saved.publicKey) {
      throw StateError(
        'Reconnect to the same Companion before verifying the update.',
      );
    }
    final package = await CompanionFirmwareValidation.inspectNordic(
      await File(saved.path).readAsBytes(),
      board: saved.board,
      provenance: saved.provenance,
    );
    final board = await connector.executeLocalCliCommand('board');
    final version = await connector.executeLocalCliCommand('version');
    final expectedBase = package.applicationBaseHash;
    if (expectedBase != null) {
      final actual = await connector.executeLocalCliCommand('ota self');
      final base = RegExp(
        r'\bbase_hash=([0-9a-fA-F]{16})\b',
      ).firstMatch(actual)?.group(1)?.toLowerCase();
      if (base != expectedBase) {
        throw StateError(
          'The Companion has not confirmed the selected firmware body hash. Recovery was retained.',
        );
      }
    }
    final expected = RegExp(
      r'v([0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?)([^/]*?)\.zip$',
    ).firstMatch(saved.filename);
    if (expected == null && expectedBase == null) {
      throw StateError(
        'This local filename has no verifiable release version. Check the running firmware using its exact-board wired tools; the recovery record was retained.',
      );
    }
    final versionToken = RegExp(
      r'v([0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?)(?=[^0-9.]|$)',
    ).firstMatch(version);
    final expectedHash = RegExp(
      r'-([0-9a-f]{8})(?:-|$)',
    ).firstMatch(expected?.group(2) ?? '')?.group(1);
    if (!connector.isConnected ||
        connector.deviceIdLabel != verifyingAddress ||
        connector.selfPublicKeyHex.toLowerCase() != saved.publicKey ||
        CompanionBoardCatalog.lookup(board)?.id !=
            CompanionBoardCatalog.lookup(saved.board)?.id ||
        (expectedBase == null &&
            (versionToken?.group(1) != expected?.group(1) ||
                (expectedHash != null && !version.contains(expectedHash))))) {
      throw StateError(
        'The selected Companion has not confirmed the expected firmware version. Recovery was retained.',
      );
    }
    await _recoveryStore.clear();
    if (!mounted) return;
    setState(() {
      _recoveryRecord = null;
      _dfuAddress = null;
      _dfuPath = null;
      _dfu = null;
      _filename = null;
      _version = version;
      _status =
          'The same Companion reconnected and confirmed $version. Update verified.';
    });
  });

  Future<void> _cancelDfu() async {
    setState(
      () => _status =
          'Cancelling Bluetooth DFU and waiting for native termination...',
    );
    await _dfuRecovery.cancel();
  }

  Future<void> _checkNativeStopped() => _run(() async {
    final stopped = await _dfuRecovery.recoverQuarantine(
      verifyStopped: () => _recoveryStore.confirmNativeStopped(
        verifyStopped: NativeDfuLifetime.verifyStopped,
      ),
    );
    _nativeUnconfirmed = await _recoveryStore.hasUnconfirmedNativeTransfer();
    if (!stopped || _nativeUnconfirmed) {
      throw StateError(
        'The OS has not confirmed the native updater stopped. No retry was started.',
      );
    }
    setState(
      () => _status =
          'The OS confirmed the old updater is stopped. Refresh Companion details to restore the verified recovery file.',
    );
  });

  Future<void> _probeWifi() => _run(() async {
    final uri = _updateUri;
    if (uri == null) throw StateError('Start the Companion updater first.');
    final binding = _wifiBinding;
    if (binding == null) {
      throw StateError('Read the authenticated OTA identity first.');
    }
    final probe = await _wifi.probe(uri, binding: binding);
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
    if (image == null ||
        uri == null ||
        probe == null ||
        _partition == null ||
        _partition!.blocksUpload) {
      return;
    }
    if (!await _confirm(
      'Update Companion over Wi-Fi?',
      'Upload $_filename (${(image.length / 1024).round()} KB) to '
          '${probe.identity} for $_board. '
          'Image hardware: ${_imageIdentity?.hardwareId ?? 'unmarked / confirm manually'}. '
          '${_partition!.message}\n\n'
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
        binding: probe.binding,
        provenance: _provenance,
      );
      if (mounted) {
        setState(
          () => _status =
              'Upload accepted. Reconnect to the Companion and verify its version.',
        );
      }
    });
  }

  String get _partitionMessage {
    if (_partition?.action == Esp32PartitionAction.expand) {
      return 'This image exceeds the Companion OTA slot '
          '(${_partition!.slotBytes! ~/ 1024} KB). '
          'Companion partition migration is not available on this screen. '
          'Use a smaller exact-board image or cable migration. '
          '${_partition!.source == Esp32PartitionSource.releaseCatalog ? 'Capacity is a release-version estimate, not a live measurement.' : 'Capacity was read from the radio.'}';
    }
    return _partition?.message ?? '';
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
                        if (_boardManuallyConfirmed)
                          Text(
                            'Firmware reports: $_reportedBoard. Hardware selected by you: $_board.',
                          ),
                        TextButton(
                          onPressed: _busy || _nativeUnconfirmed
                              ? null
                              : _correctBoardIdentity,
                          child: const Text('Wrong board reported?'),
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
            if (_busy && _dfuRecovery.isBusy)
              OutlinedButton.icon(
                onPressed: _cancelDfu,
                icon: const Icon(Icons.cancel_outlined),
                label: const Text('Cancel Bluetooth update'),
              ),
            if (!_busy && _nativeUnconfirmed)
              OutlinedButton(
                onPressed: _checkNativeStopped,
                child: const Text('Check stopped Bluetooth updater'),
              ),
            if (!_busy && _recoveryRecord != null)
              OutlinedButton.icon(
                onPressed: _nativeUnconfirmed ? null : _verifyBluetooth,
                icon: const Icon(Icons.verified_outlined),
                label: const Text('Verify reconnected Companion'),
              ),
            if (_partition != null) ...[
              const SizedBox(height: 12),
              Text(_partitionMessage),
            ],
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
                  !context.watch<MeshCoreConnector>().isConnected &&
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
                  onPressed: _busy || (_partition?.blocksUpload ?? true)
                      ? null
                      : _uploadWifi,
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
                subtitle: Text(_firmwareHint),
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
            TextButton.icon(
              onPressed: _busy || _board == null
                  ? null
                  : () => _findOnGitHub(includeOlderVersions: true),
              icon: const Icon(Icons.history),
              label: const Text('Choose another version'),
            ),
          ],
        ),
      ),
    ),
  );
}
