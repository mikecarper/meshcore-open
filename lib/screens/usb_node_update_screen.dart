import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../connector/meshcore_connector.dart';
import '../services/usb_firmware_catalog.dart';
import '../services/usb_flash_transport.dart';
import '../services/usb_node_backup.dart';
import '../services/usb_node_update_service.dart';
import '../utils/platform_info.dart';

/// The native Android USB workflow, independent of browser serial support.
class UsbNodeUpdateScreen extends StatefulWidget {
  const UsbNodeUpdateScreen({super.key, this.service, this.nativeUsbSupported});
  final UsbNodeUpdateService? service;

  /// Capability injection for mocked transports; normal navigation uses OS detection.
  final bool? nativeUsbSupported;

  @override
  State<UsbNodeUpdateScreen> createState() => _UsbNodeUpdateScreenState();
}

class _UsbNodeUpdateScreenState extends State<UsbNodeUpdateScreen> {
  late final UsbNodeUpdateService _service;
  List<UsbFlashDevice> _devices = [];
  UsbFlashDevice? _selected;
  String? _filename;
  Uint8List? _firmware;
  Uint8List? _migrationZip;
  Uint8List? _usbSetZip;
  String? _uiError;
  bool _working = false;
  bool _makeBackup = true;
  bool get _busy => _working || _service.busy;
  bool get _nativeSupported =>
      widget.nativeUsbSupported ?? PlatformInfo.isAndroid;
  String _deviceKey(UsbFlashDevice device) =>
      '${device.deviceName}:${device.portNumber}';

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? UsbNodeUpdateService();
    _service.addListener(_changed);
    if (_nativeSupported) _refresh();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _service.removeListener(_changed);
    if (widget.service == null && !_service.busy) _service.dispose();
    super.dispose();
  }

  Future<void> _action(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _working = true;
      _uiError = null;
    });
    try {
      await action();
    } catch (_) {
      // File parsing/platform failures must not disclose private JSON/USB data.
      if (mounted) {
        _uiError =
            'The selected file or USB operation could not be '
            'validated. Nothing further was written. Check the file and device.';
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _refresh() => _action(() async {
    final devices = await _service.transport.listDevices();
    if (!mounted) return;
    setState(() {
      _devices = devices;
      final prior = _selected;
      _selected = prior == null
          ? null
          : devices
                .where(
                  (d) =>
                      _deviceKey(d) == _deviceKey(prior) &&
                      d.vendorId == prior.vendorId &&
                      d.productId == prior.productId &&
                      (prior.serialNumber == null ||
                          d.serialNumber == prior.serialNumber),
                )
                .firstOrNull;
    });
  });

  Future<Uint8List?> _pickBytes(List<String> extensions) async {
    final file = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(label: 'Firmware / archive', extensions: extensions),
      ],
    );
    if (file == null) return null;
    final length = await file.length();
    if (length <= 0 || length > UsbFirmwareCatalog.maxArtifactBytes) {
      throw const FormatException('The selected file is empty or too large.');
    }
    return file.readAsBytes();
  }

  Future<void> _pickFirmware() => _action(() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Application firmware', extensions: ['bin', 'zip']),
      ],
    );
    if (file == null) return;
    if (await file.length() > UsbFirmwareCatalog.maxArtifactBytes) {
      throw const FormatException('Firmware is too large.');
    }
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    setState(() {
      _filename = file.name;
      _firmware = bytes;
    });
  });

  Future<void> _downloadFirmware() => _action(() async {
    final choices = await _service.catalog.listKeymind();
    if (!mounted) return;
    final selected = await showDialog<UsbFirmwareDownload>(
      context: context,
      builder: (context) => _FirmwarePicker(choices: choices),
    );
    if (selected == null) return;
    final bytes = await _service.catalog.download(
      selected.url,
      expectedSha256: selected.sha256Hex,
      expectedBytes: selected.bytes,
    );
    if (!mounted) return;
    setState(() {
      _filename = selected.name;
      _firmware = bytes;
    });
  });

  Future<void> _downloadUrl() => _action(() async {
    final input = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Application firmware URL'),
        content: TextField(
          controller: input,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'HTTPS .bin or .zip URL',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, input.text),
            child: const Text('Download'),
          ),
        ],
      ),
    );
    input.dispose();
    if (url == null) return;
    final uri = Uri.parse(url.trim());
    if (uri.pathSegments.isEmpty) {
      throw const FormatException('Missing firmware filename.');
    }
    final name = UsbNodeUpdateService.safeName(uri.pathSegments.last);
    if (!RegExp(r'\.(bin|zip)$', caseSensitive: false).hasMatch(name)) {
      throw const FormatException('Use an application BIN or serial DFU ZIP.');
    }
    final bytes = await _service.catalog.download(uri);
    if (mounted) {
      setState(() {
        _filename = name;
        _firmware = bytes;
      });
    }
  });

  Future<bool> _confirm(UsbUpdateQuestion question) async {
    if (!mounted) return false;
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => _UpdateConfirmation(question: question),
        ) ??
        false;
  }

  Future<UsbFlashDevice?> _reselect(
    UsbFlashDevice original,
    List<UsbFlashDevice> candidates,
  ) async {
    if (!mounted) return null;
    final choice = await showDialog<UsbFlashDevice>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Select the same physical node'),
        content: SizedBox(
          width: 520,
          height: 300,
          child: Column(
            children: [
              const Text(
                'USB identity could not be matched automatically. '
                'Select the original node only. ESP32 chip MAC is checked '
                'again before writes. Cancel if uncertain.',
              ),
              Expanded(
                child: ListView(
                  children: [
                    for (final device in candidates)
                      ListTile(
                        title: Text(device.displayName),
                        subtitle: Text(
                          device.serialNumber ?? 'Serial unavailable',
                        ),
                        onTap: () => Navigator.pop(context, device),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (choice == null) return null;
    if (!await _confirm(
      const UsbUpdateQuestion(
        'Confirm the original physical node',
        'A USB name is not proof of board identity. I have selected the same '
            'physical radio that I started this update on.',
        token: 'same-physical-node',
      ),
    )) {
      return null;
    }
    return choice;
  }

  Future<void> _disconnectCompanion() async {
    // Stop normal messaging before the exclusive raw flashing session.
    await context.read<MeshCoreConnector>().disconnect(manual: true);
  }

  Future<void> _update() => _action(() async {
    final device = _selected;
    if (device == null || _firmware == null || _filename == null) return;
    await _disconnectCompanion();
    await _service.update(
      device,
      _filename!,
      _firmware!,
      confirm: _confirm,
      reselect: _reselect,
      createBackup: _makeBackup,
      localMigrationZip: _migrationZip,
      localUsbSetZip: _usbSetZip,
    );
  });

  Future<void> _backupOnly() => _action(() async {
    final device = _selected;
    if (device == null) return;
    await _disconnectCompanion();
    await _service.backupOnly(device);
  });

  Future<void> _restore() => _action(() async {
    final device = _selected;
    if (device == null) return;
    final bytes = await _pickBytes(['json']);
    if (bytes == null) return;
    final document = jsonDecode(utf8.decode(bytes));
    if (document is! Map<String, dynamic>) {
      throw const FormatException('Invalid backup JSON.');
    }
    final archive = UsbNodeBackupArchive.fromJson(document);
    if (!mounted) return;
    final newHardware = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore destination'),
        content: const Text(
          'Are you restoring the original node, or moving '
          'the backup to different hardware?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Original node'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Different hardware'),
          ),
        ],
      ),
    );
    if (newHardware == null || !mounted) return;
    final replaceIdentity = await showDialog<bool>(
      context: context,
      builder: (context) => UsbRestoreIdentityDialog(newHardware: newHardware),
    );
    if (replaceIdentity == null) return;
    await _disconnectCompanion();
    await _service.restoreBackup(
      device,
      archive,
      confirm: _confirm,
      newHardware: newHardware,
      replaceIdentity: replaceIdentity,
    );
  });

  @override
  Widget build(BuildContext context) {
    final enabled = _nativeSupported && !_busy;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Update over USB')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (!_nativeSupported)
                const Text(
                  'Native USB flashing currently requires the Android '
                  'APK. Windows/Linux can use meshfirmware scripts.',
                ),
              const Text(
                'Use a data cable and stable power. This updater writes '
                'applications, not bootloaders or merged install images. '
                'CH340, CP210x, FTDI and native USB use Android drivers.',
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                // Compatible with the legacy Flutter 3.32.8 build profile.
                // ignore: deprecated_member_use
                value: _selected == null ? null : _deviceKey(_selected!),
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'USB node'),
                items: [
                  for (final device in _devices)
                    DropdownMenuItem(
                      value: _deviceKey(device),
                      child: Text(
                        device.displayName,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: enabled
                    ? (key) => setState(() {
                        _selected = _devices.firstWhere(
                          (d) => _deviceKey(d) == key,
                        );
                      })
                    : null,
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: enabled ? _refresh : null,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh USB devices'),
                ),
              ),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: enabled ? _pickFirmware : null,
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Custom application file'),
                  ),
                  OutlinedButton.icon(
                    onPressed: enabled ? _downloadFirmware : null,
                    icon: const Icon(Icons.download),
                    label: const Text('Keymind releases'),
                  ),
                  OutlinedButton.icon(
                    onPressed: enabled ? _downloadUrl : null,
                    icon: const Icon(Icons.link),
                    label: const Text('Firmware URL'),
                  ),
                ],
              ),
              if (_filename != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(_filename!),
                ),
              CheckboxListTile(
                value: _makeBackup,
                onChanged: enabled
                    ? (v) => setState(() => _makeBackup = v!)
                    : null,
                title: const Text('Create and verify a backup first'),
                subtitle: const Text(
                  'Includes private identity/channel secrets '
                  'when exposed. Stored in private app files. Cannot run in DFU.',
                ),
                contentPadding: EdgeInsets.zero,
              ),
              ExpansionTile(
                title: const Text('Offline migration packages (optional)'),
                children: [
                  const Text(
                    'Normally downloaded automatically. The Full ZIP '
                    'must match the selected image exactly; all local ZIPs '
                    'receive the same integrity and profile checks.',
                  ),
                  TextButton(
                    onPressed: enabled
                        ? () => _action(() async {
                            final bytes = await _pickBytes(['zip']);
                            if (bytes != null && mounted) {
                              setState(() => _migrationZip = bytes);
                            }
                          })
                        : null,
                    child: Text(
                      _migrationZip == null
                          ? 'Choose exact Full migration ZIP'
                          : 'Full migration ZIP selected',
                    ),
                  ),
                  TextButton(
                    onPressed: enabled
                        ? () => _action(() async {
                            final bytes = await _pickBytes(['zip']);
                            if (bytes != null && mounted) {
                              setState(() => _usbSetZip = bytes);
                            }
                          })
                        : null,
                    child: Text(
                      _usbSetZip == null
                          ? 'Choose USB bridge set ZIP'
                          : 'USB bridge set selected',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: enabled && _selected != null && _firmware != null
                    ? _update
                    : null,
                icon: const Icon(Icons.system_update_alt),
                label: const Text('Backup, check and update'),
              ),
              Wrap(
                spacing: 12,
                children: [
                  TextButton(
                    onPressed: enabled && _selected != null
                        ? _backupOnly
                        : null,
                    child: const Text('Backup only'),
                  ),
                  TextButton(
                    onPressed: enabled && _selected != null ? _restore : null,
                    child: const Text('Restore backup'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(_service.stage, key: const Key('usb-update-stage')),
              if (_busy)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: LinearProgressIndicator(value: _service.progress),
                ),
              if (_uiError != null || _service.error != null)
                Text(
                  _uiError ?? _service.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (_service.backupPath != null) ...[
                const SizedBox(height: 12),
                SelectableText('Private backup: ${_service.backupPath}'),
                TextButton.icon(
                  onPressed: !_busy
                      ? () async {
                          await SharePlus.instance.share(
                            ShareParams(
                              files: [XFile(_service.backupPath!)],
                              text:
                                  'Private MeshCore configuration backup. Keep secure.',
                            ),
                          );
                        }
                      : null,
                  icon: const Icon(Icons.share),
                  label: const Text('Export private backup'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _UpdateConfirmation extends StatefulWidget {
  const _UpdateConfirmation({required this.question});
  final UsbUpdateQuestion question;
  @override
  State<_UpdateConfirmation> createState() => _UpdateConfirmationState();
}

/// Separates cancelling restore from an explicit settings-only migration.
class UsbRestoreIdentityDialog extends StatelessWidget {
  const UsbRestoreIdentityDialog({super.key, required this.newHardware});
  final bool newHardware;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Restore identity'),
    content: Text(
      newHardware
          ? 'Keep the destination node’s own identity when moving settings, '
                'or separately authorize importing the backup’s private key.'
          : 'Keep the original node’s matching identity. If it was erased or '
                'changed, separately authorize importing the backup’s private key.',
    ),
    actions: [
      TextButton(
        autofocus: true,
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel restore'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: const Text('Keep node identity'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, true),
        child: const Text('Import backup identity'),
      ),
    ],
  );
}

class _UpdateConfirmationState extends State<_UpdateConfirmation> {
  String _text = '';
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.question.title),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.question.message),
          if (widget.question.token != null) ...[
            const SizedBox(height: 12),
            SelectableText('Type exactly: ${widget.question.token}'),
            TextField(
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (value) => setState(() => _text = value),
              onSubmitted: (_) {}, // Enter never accepts an override.
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        autofocus: widget.question.token == null,
        onPressed: () => Navigator.pop(context, false),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed:
            widget.question.token == null || _text == widget.question.token
            ? () => Navigator.pop(context, true)
            : null,
        child: const Text('Continue'),
      ),
    ],
  );
}

class _FirmwarePicker extends StatefulWidget {
  const _FirmwarePicker({required this.choices});
  final List<UsbFirmwareDownload> choices;
  @override
  State<_FirmwarePicker> createState() => _FirmwarePickerState();
}

class _FirmwarePickerState extends State<_FirmwarePicker> {
  String _filter = '';
  @override
  Widget build(BuildContext context) {
    final choices = widget.choices
        .where(
          (item) => item.name.toLowerCase().contains(_filter.toLowerCase()),
        )
        .toList();
    return AlertDialog(
      title: const Text('Select exact board and role'),
      content: SizedBox(
        width: 600,
        height: MediaQuery.sizeOf(context).height * .6,
        child: Column(
          children: [
            TextField(
              decoration: const InputDecoration(labelText: 'Filter filename'),
              onChanged: (value) => setState(() => _filter = value),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: choices.length,
                itemBuilder: (context, index) {
                  final item = choices[index];
                  return ListTile(
                    title: Text(item.name),
                    subtitle: Text(item.release),
                    onTap: () => Navigator.pop(context, item),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
