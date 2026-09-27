import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../connector/meshcore_connector.dart';
import '../models/contact.dart';
import '../services/remote_private_key_backup.dart';
import '../widgets/update_status_card.dart';

class RemoteKeyBackupScreen extends StatefulWidget {
  const RemoteKeyBackupScreen({super.key, required this.target});

  final Contact target;

  @override
  State<RemoteKeyBackupScreen> createState() => _RemoteKeyBackupScreenState();
}

class _RemoteKeyBackupScreenState extends State<RemoteKeyBackupScreen> {
  bool _busy = false;
  bool? _supported;
  String _status = 'Checking Companion backup support…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkSupport());
  }

  Future<void> _checkSupport() async {
    try {
      final reply = await context
          .read<MeshCoreConnector>()
          .executeLocalCliCommand('get key.backup.transport');
      if (!mounted) return;
      setState(() {
        _supported = reply.trim() == 'ephemeral-routed-v1';
        _status = _supported!
            ? 'Ready to create an encrypted backup.'
            : 'Update the connected Companion first: this firmware can retain private-key replies in its message queue.';
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _supported = false;
          _status =
              'This Companion cannot safely deliver remote private-key backups yet.';
        });
      }
    }
  }

  Future<String?> _askPassphrase() async {
    final first = TextEditingController();
    final second = TextEditingController();
    final form = GlobalKey<FormState>();
    try {
      return await showDialog<String>(
        context: context,
        builder: (dialogContext) => Dialog(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Form(
              key: form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Protect your backup',
                    style: Theme.of(dialogContext).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'The reply travels end-to-end encrypted over LoRa. '
                    'Keep the backup file and passphrase separately.',
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: first,
                    textInputAction: TextInputAction.next,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'Backup passphrase',
                    ),
                    validator: (value) => (value?.length ?? 0) < 12
                        ? 'Use at least 12 characters'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: second,
                    textInputAction: TextInputAction.done,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'Confirm passphrase',
                    ),
                    validator: (value) =>
                        value != first.text ? 'Passphrases do not match' : null,
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () {
                          if (form.currentState?.validate() ?? false) {
                            Navigator.pop(dialogContext, first.text);
                          }
                        },
                        child: const Text('Request backup'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    } finally {
      first.clear();
      second.clear();
      first.dispose();
      second.dispose();
    }
  }

  Future<void> _backup() async {
    if (_busy) return;
    final passphrase = await _askPassphrase();
    if (passphrase == null || !mounted) return;
    setState(() {
      _busy = true;
      _status = 'Requesting encrypted reply from ${widget.target.name}…';
    });
    File? temporaryFile;
    Uint8List? privateKey;
    try {
      final connector = context.read<MeshCoreConnector>();
      privateKey = await connector.requestRemotePrivateKeyBackup(widget.target);
      if (mounted) setState(() => _status = 'Encrypting backup on this phone…');
      final encrypted = await RemotePrivateKeyBackup.encrypt(
        privateKey: privateKey,
        publicKey: widget.target.publicKey,
        passphrase: passphrase,
      );
      privateKey.fillRange(0, privateKey.length, 0);
      privateKey = null;
      final filename =
          'meshcore-${widget.target.publicKeyHex.substring(0, 8).toLowerCase()}-identity-'
          '${DateTime.now().toUtc().microsecondsSinceEpoch}.mckey.json';
      if (Platform.isAndroid) {
        File? downloadsFile;
        try {
          final downloads = Directory('/sdcard/Download');
          if (await downloads.exists()) {
            downloadsFile = File('${downloads.path}/$filename');
            await downloadsFile.writeAsBytes(encrypted, flush: true);
            if (mounted) {
              setState(
                () => _status =
                    'Encrypted backup saved in phone Downloads as $filename. '
                    'Keep the passphrase separately.',
              );
            }
            return;
          }
        } on FileSystemException {
          try {
            await downloadsFile?.delete();
          } catch (_) {
            // Best effort: the failed write may already have been removed.
          }
          // Scoped-storage Android versions use the share sheet instead.
        }
      }
      final directory = await getTemporaryDirectory();
      temporaryFile = File('${directory.path}/$filename');
      await temporaryFile.writeAsBytes(encrypted, flush: true);
      final result = await SharePlus.instance.share(
        ShareParams(
          subject: 'MeshCore encrypted identity backup',
          text:
              'Encrypted backup for ${widget.target.name}. Keep the passphrase separately.',
          files: [XFile(temporaryFile.path)],
        ),
      );
      if (mounted) {
        setState(
          () => _status = result.status == ShareResultStatus.success
              ? 'Encrypted backup shared. Verify that it is saved in a place you control.'
              : 'Share was cancelled; no backup was saved by this app.',
        );
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _status = error is TimeoutException
              ? 'No reply. This target may need firmware with admin backup support.'
              : 'Backup failed: $error',
        );
      }
    } finally {
      privateKey?.fillRange(0, privateKey.length, 0);
      if (temporaryFile != null) {
        try {
          await temporaryFile.delete();
        } catch (_) {
          // The system can later clear a stale encrypted cache file.
        }
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('Identity backup')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              widget.target.name,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            UpdateStatusCard(
              message: _status,
              busy: _busy || _supported == null,
              isError: _supported == false,
            ),
            const SizedBox(height: 16),
            const Text(
              'Admin access is required. Your backup is encrypted on this phone '
              'with a passphrase. Keep the file and passphrase separately.',
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _busy || _supported != true ? null : _backup,
              icon: const Icon(Icons.lock_outline),
              label: const Text('Create encrypted backup'),
            ),
            const SizedBox(height: 16),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Target public key'),
              children: [SelectableText(widget.target.publicKeyHex)],
            ),
          ],
        ),
      ),
    ),
  );
}
