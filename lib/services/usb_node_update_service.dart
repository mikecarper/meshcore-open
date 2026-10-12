import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'usb_esp_flash_engine.dart';
import 'usb_firmware_catalog.dart';
import 'usb_firmware_package.dart';
import 'usb_flash_transport.dart';
import 'usb_node_backup.dart';
import 'usb_nrf_dfu.dart';
import 'usb_partition_expansion.dart';

class UsbUpdateQuestion {
  const UsbUpdateQuestion(this.title, this.message, {this.token});
  final String title;
  final String message;
  final String? token;
}

typedef UsbUpdateConfirm = Future<bool> Function(UsbUpdateQuestion question);
typedef UsbUpdateReselect =
    Future<UsbFlashDevice?> Function(
      UsbFlashDevice original,
      List<UsbFlashDevice> candidates,
    );

class UsbUpdateCancelled implements Exception {
  const UsbUpdateCancelled();
  @override
  String toString() => 'Update cancelled before the next write.';
}

/// Native Android updater. No automatic chip erase or manual table upload.
/// Confirmation callbacks default to denial in the UI. Device snapshots stay
/// in memory; backups are private app files and journals contain public data.
class UsbNodeUpdateService extends ChangeNotifier {
  UsbNodeUpdateService({
    UsbFlashTransport? transport,
    UsbFirmwareCatalog? catalog,
    Future<Directory> Function()? directory,
    UsbEspFlashEngine? esp,
    UsbNodeBackupService? backupService,
  }) : transport = transport ?? UsbFlashTransport(),
       catalog = catalog ?? UsbFirmwareCatalog(),
       _directory = directory ?? getApplicationSupportDirectory {
    this.esp = esp ?? UsbEspFlashEngine(this.transport);
    backup = backupService ?? UsbNodeBackupService(this.transport);
  }

  final UsbFlashTransport transport;
  final UsbFirmwareCatalog catalog;
  final Future<Directory> Function() _directory;
  late final UsbEspFlashEngine esp;
  late final UsbNodeBackupService backup;
  bool busy = false;
  String stage = 'Choose a USB node and an application firmware file.';
  double? progress;
  String? backupPath;
  String? error;
  bool succeeded = false;
  UsbFlashDevice? connectedDevice;

  @override
  void dispose() {
    catalog.dispose();
    super.dispose();
  }

  void _state(String message, [double? fraction]) {
    stage = message;
    progress = fraction;
    notifyListeners();
  }

  Future<Directory> _root() async {
    final root = Directory('${(await _directory()).path}/usb-updater');
    await root.create(recursive: true);
    return root;
  }

  static String safeName(String name) => name
      .split(RegExp(r'[/\\]'))
      .last
      .replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '-');

  Future<File> _artifact(String name, Uint8List bytes) async {
    final root = await _root();
    final directory = Directory('${root.path}/artifacts/${usbSha256(bytes)}');
    await directory.create(recursive: true);
    final file = File('${directory.path}/${safeName(name)}');
    if (await file.exists()) {
      if (usbSha256(await file.readAsBytes()) != usbSha256(bytes)) {
        throw StateError('Cached firmware changed; no write is allowed.');
      }
    } else {
      await file.writeAsBytes(bytes, flush: true);
    }
    return file;
  }

  Future<void> _saveBackup(UsbNodeBackupArchive archive) async {
    archive.verify();
    final root = await _root();
    final directory = Directory('${root.path}/backups');
    await directory.create(recursive: true);
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    final file = File(
      '${directory.path}/mc.config_backup.${safeName(archive.deviceName)}.$stamp.json',
    );
    await file.writeAsString(jsonEncode(archive.toJson()), flush: true);
    UsbNodeBackupArchive.fromJson(
      Map<String, dynamic>.from(jsonDecode(await file.readAsString()) as Map),
    ).verify();
    backupPath = file.path;
  }

  Future<void> backupOnly(UsbFlashDevice device) async {
    if (busy) throw StateError('A USB operation is already running.');
    busy = true;
    error = null;
    succeeded = false;
    try {
      await transport.setKeepAwake(true);
      _state('Creating a private logical USB backup…');
      final identified = await transport.readIdentity(device);
      final archive = await backup.capture(
        identified,
        isDfu: identified.isNrfDfu,
      );
      await _saveBackup(archive);
      _state(
        archive.isComplete
            ? 'Backup saved and verified.'
            : 'Partial backup saved. Missing fields are listed in the archive.',
        1,
      );
      succeeded = archive.isComplete;
    } catch (failure) {
      error = _safeError(failure);
      _state('Backup could not be completed.');
    } finally {
      await _cleanup();
    }
  }

  Future<void> restoreBackup(
    UsbFlashDevice device,
    UsbNodeBackupArchive archive, {
    required UsbUpdateConfirm confirm,
    bool newHardware = false,
    bool replaceIdentity = false,
  }) async {
    if (busy) throw StateError('A USB operation is already running.');
    archive.verify();
    await _require(
      confirm,
      UsbUpdateQuestion(
        'Restore node settings?',
        'The archive contains private configuration. Restore only to the '
            'selected node. Firmware and bootloader versions are never restored. '
            '${newHardware ? 'This is a different hardware platform.' : ''}',
        token: newHardware ? 'restore-to-new-hardware' : null,
      ),
    );
    if (replaceIdentity) {
      await _require(
        confirm,
        const UsbUpdateQuestion(
          'Import the backup’s private identity?',
          'Importing the old private key makes this node impersonate the old '
              'node. Do not operate both on the mesh with the same identity. '
              'Cancel stops the restore.',
          token: 'replace-private-identity',
        ),
      );
    }
    busy = true;
    error = null;
    succeeded = false;
    try {
      await transport.setKeepAwake(true);
      _state('Restoring verified node configuration…');
      await backup.restore(
        await transport.readIdentity(device),
        archive,
        newHardware: newHardware,
        replaceIdentity: replaceIdentity,
        onProgress: (fraction, message) => _state(message, fraction),
      );
      succeeded = true;
      _state('Configuration restore completed and verified.', 1);
    } catch (failure) {
      error = _safeError(failure);
      _state('Configuration restore did not complete.');
    } finally {
      await _cleanup();
    }
  }

  Future<void> update(
    UsbFlashDevice device,
    String filename,
    Uint8List bytes, {
    required UsbUpdateConfirm confirm,
    UsbUpdateReselect? reselect,
    bool createBackup = true,
    Uint8List? localMigrationZip,
    Uint8List? localUsbSetZip,
  }) async {
    if (busy) throw StateError('A USB operation is already running.');
    // Parse all supplied firmware before requesting any USB reset.
    final isNrf = filename.toLowerCase().endsWith('.zip');
    final nrf = isNrf ? UsbNrfDfuPackage.fromBytes(filename, bytes) : null;
    final image = isNrf ? null : UsbFirmwareImage.fromBytes(filename, bytes);
    busy = true;
    succeeded = false;
    error = null;
    backupPath = null;
    UsbNodeInfo? before;
    var identity = device;
    try {
      await transport.setKeepAwake(true);
      _state('Checking the selected USB endpoint…');
      identity = await transport.readIdentity(device);
      connectedDevice = identity;
      if (createBackup) {
        _state('Creating and verifying a private backup before flashing…');
        try {
          final archive = await backup.capture(
            identity,
            isDfu: identity.isNrfDfu,
          );
          await _saveBackup(archive);
          if (!archive.isComplete) {
            await _require(
              confirm,
              const UsbUpdateQuestion(
                'Continue without a complete backup?',
                'A partial archive was saved, but not every private identity '
                    'or configuration field could be read. This is a write-only '
                    'update; no chip erase will be performed.',
              ),
            );
          }
        } on UsbUpdateCancelled {
          rethrow;
        } catch (_) {
          await _require(
            confirm,
            UsbUpdateQuestion(
              'Continue without a usable backup?',
              identity.isNrfDfu
                  ? 'Backup cannot be done in DFU mode: the bootloader does '
                        'not expose the MeshCore configuration API.'
                  : 'The running firmware did not provide a usable logical '
                        'USB backup. Continue the write-only update without it?',
            ),
          );
        }
      }
      if (!identity.isNrfDfu) {
        try {
          before = await backup.inspect(identity);
        } catch (_) {
          // Unknown board is an explicit one-time confirmation, not a guess.
        }
      }
      await _require(
        confirm,
        const UsbUpdateQuestion(
          'Prepare this node for an update?',
          'The backup step is finished. The selected node may reboot into '
              'its bootloader so its real chip and flash layout can be checked. '
              'No firmware will be erased or written yet.',
        ),
      );
      await _confirmBoard(
        confirm,
        before?.hardwareModel,
        image?.endf?.hardwareId ?? nrf?.hardwareId,
      );
      if (nrf != null) {
        await _updateNrf(identity, nrf, before, confirm, reselect);
      } else {
        await _updateEsp(
          identity,
          image!,
          before,
          confirm,
          reselect,
          localMigrationZip,
          localUsbSetZip,
        );
      }
      succeeded = true;
      _state(
        'Firmware writes verified; running application and version checked.',
        1,
      );
    } on UsbUpdateCancelled catch (failure) {
      error = failure.toString();
      _state('Update cancelled.');
    } catch (failure) {
      error = _safeError(failure);
      _state('Update stopped. Do not guess a different node or firmware.');
    } finally {
      // Closing never asserts reset lines, especially during restoration.
      await _cleanup();
    }
  }

  static String _safeError(Object failure) {
    if (failure is UsbBackupUnavailable) return failure.message;
    if (failure is UsbFlashReenumerationRequired) return failure.message;
    if (failure is FormatException) return failure.message;
    if (failure is UsbFirmwareValidationException) return failure.message;
    if (failure is StateError) return failure.message;
    if (failure is TimeoutException) {
      return failure.message ?? 'The node did not answer before the timeout.';
    }
    // Do not put raw USB responses or private backup contents in the UI/log.
    return 'USB operation failed (${failure.runtimeType}). Check permissions, '
        'the data cable and the selected node before retrying.';
  }

  Future<void> _cleanup() async {
    try {
      await esp.close();
    } catch (_) {
      /* Never reset during cleanup. */
    }
    try {
      await transport.close();
    } catch (_) {
      /* Keep the original error. */
    }
    try {
      await transport.setKeepAwake(false);
    } catch (_) {
      /* Best effort. */
    }
    busy = false;
    notifyListeners();
  }

  static Future<void> _require(
    UsbUpdateConfirm confirm,
    UsbUpdateQuestion question,
  ) async {
    if (!await confirm(question)) throw const UsbUpdateCancelled();
  }

  static String _board(String? value) {
    final normalized = (value ?? '').toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]'),
      '',
    );
    const aliases = {
      't1000e': ['seeedtrackert1000e', 'sensecapt1000e', 't1000e'],
      'rak4631': ['rak4631', 'rak4630', 'rakwisblock4631'],
      'heltecv4': ['heltecv4', 'heltecv42v43', 'heltecv4repeater'],
      'heltecv3': ['heltecv3', 'heltecv3repeater'],
      'xiaonrf52': ['seeedxiaonrf52840', 'xiaonrf52'],
      'xiaos3wio': ['xiaos3wio', 'seeedxiaoesp32s3wio'],
    };
    for (final entry in aliases.entries) {
      if (entry.value.contains(normalized)) return entry.key;
    }
    return normalized;
  }

  static Future<void> _confirmBoard(
    UsbUpdateConfirm confirm,
    String? connected,
    String? target,
  ) async {
    final oldBoard = _board(connected);
    final newBoard = _board(target);
    if (oldBoard.isNotEmpty && newBoard.isNotEmpty && oldBoard == newBoard) {
      return;
    }
    final token =
        '${oldBoard.isEmpty ? 'unknown' : oldBoard}-to-'
        '${newBoard.isEmpty ? 'unknown' : newBoard}';
    await _require(
      confirm,
      UsbUpdateQuestion(
        'One-time board override',
        'Connected board: ${connected ?? 'unknown'}. Firmware board: '
            '${target ?? 'unknown'}. Board compatibility could not be proven. '
            'Confirm the physical board before continuing. This does not bypass '
            'chip, capacity, package integrity or migration checks.',
        token: token,
      ),
    );
  }

  Future<UsbFlashDevice> _reconnect(
    UsbFlashDevice original,
    UsbUpdateReselect? reselect, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    try {
      return await transport.reacquire(original, timeout: timeout);
    } catch (_) {
      if (reselect == null) rethrow;
      final candidate = await reselect(original, await transport.listDevices());
      if (candidate == null) throw const UsbUpdateCancelled();
      return transport.readIdentity(candidate);
    }
  }

  Future<void> _verifyApplication(
    UsbFlashDevice original,
    UsbNodeInfo? before,
    String? expectedVersion,
    UsbUpdateReselect? reselect,
  ) async {
    _state('Waiting for the running application and verifying its identity…');
    final watch = Stopwatch()..start();
    Object? lastFailure;
    while (watch.elapsed < const Duration(seconds: 30)) {
      try {
        final device = await _reconnect(
          original,
          reselect,
          timeout: const Duration(seconds: 3),
        );
        final info = await backup.inspect(device);
        if (before?.publicKey.isNotEmpty == true &&
            info.publicKey != before!.publicKey) {
          throw StateError('The running node identity changed after flashing.');
        }
        final version = info.firmwareVersion;
        if (version == null || version.isEmpty) {
          throw StateError(
            'The application did not report its firmware version.',
          );
        }
        final numeric = RegExp(r'\d+\.\d+\.\d+(?:\.\d+)?');
        final wanted = expectedVersion == null
            ? null
            : numeric.firstMatch(expectedVersion)?.group(0);
        if (wanted != null && numeric.firstMatch(version)?.group(0) != wanted) {
          throw StateError(
            'The application reported a different firmware version.',
          );
        }
        connectedDevice = device;
        return;
      } on UsbUpdateCancelled {
        rethrow;
      } catch (failure) {
        if (failure is StateError &&
            failure.message.contains('identity changed')) {
          rethrow;
        }
        lastFailure = failure;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    throw StateError(
      'Flash transfer completed but application verification did not pass: '
      '${lastFailure == null ? 'no response' : _safeError(lastFailure)}',
    );
  }

  Future<void> _updateNrf(
    UsbFlashDevice device,
    UsbNrfDfuPackage package,
    UsbNodeInfo? before,
    UsbUpdateConfirm confirm,
    UsbUpdateReselect? reselect,
  ) async {
    if (device.vendorId == 0x303a) {
      throw StateError('An Espressif USB device cannot receive an nRF52 ZIP.');
    }
    await _require(
      confirm,
      UsbUpdateQuestion(
        'Write nRF52 application?',
        '${package.name}\nApplication-only serial DFU; no bootloader or '
            'SoftDevice is installed. Keep the USB connection and power stable.',
      ),
    );
    var dfuDevice = device;
    if (!device.isNrfDfu) {
      _state('Requesting DFU with an explicit 1200-baud touch…');
      await transport.open(device);
      final identified = transport.activeDevice ?? device;
      try {
        await transport.touch1200();
      } finally {
        await transport.close();
      }
      dfuDevice = await _reconnect(identified, reselect);
    }
    await transport.open(dfuDevice);
    final selected = transport.activeDevice ?? dfuDevice;
    await UsbNrfDfuUpdater(transport).flash(
      package,
      expectedDevice: selected,
      onProgress: (fraction, message) => _state(message, fraction),
    );
    await transport.close();
    final expected =
        package.firmwareVersion ??
        RegExp(r'v\d+\.\d+\.\d+(?:\.\d+)?').firstMatch(package.name)?.group(0);
    await _verifyApplication(selected, before, expected, reselect);
  }

  Future<Map<String, Uint8List?>> _snapshot(UsbEspChipInfo chip) async {
    final table = await esp.readFlash(0x8000, 0x1000);
    final parts = UsbPartitionExpansion.parseTable(table, chip.flashBytes);
    final nvss = parts.where((p) => p.type == 1 && p.subtype == 2).toList();
    final otas = parts.where((p) => p.type == 1 && p.subtype == 0).toList();
    if (nvss.length > 1 || otas.length > 1) {
      throw StateError('The device has ambiguous NVS or OTA partitions.');
    }
    if (otas.isNotEmpty && otas.single.size < 0x2000) {
      throw StateError('The OTA metadata partition is too small.');
    }
    return {
      'table': table,
      'nvs': nvss.isEmpty
          ? null
          : await esp.readFlash(nvss.single.offset, nvss.single.size),
      'ota': otas.isEmpty
          ? null
          : await esp.readFlash(otas.single.offset, 0x2000),
    };
  }

  Future<void> _writeJson(File file, Map<String, dynamic> json) async {
    final partial = File('${file.path}.partial');
    await partial.writeAsString(jsonEncode(json), flush: true);
    await partial.rename(file.path);
  }

  Future<Uint8List> _readRecoveryArtifact(
    Directory root,
    Object? path,
    Object? checksum,
  ) async {
    if (path is! String ||
        checksum is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(checksum)) {
      throw StateError('Recovery artifact path or checksum is invalid.');
    }
    final base = await Directory(
      '${root.path}/artifacts',
    ).resolveSymbolicLinks();
    final file = File(path);
    final resolved = await file.resolveSymbolicLinks();
    if (!resolved
            .replaceAll('\\', '/')
            .startsWith('${base.replaceAll('\\', '/')}/') ||
        await file.length() > UsbFirmwareCatalog.maxArtifactBytes) {
      throw StateError(
        'Recovery artifact is outside the private cache or too large.',
      );
    }
    final bytes = await file.readAsBytes();
    if (usbSha256(bytes) != checksum) {
      throw StateError('Recovery artifact changed; no write is permitted.');
    }
    return bytes;
  }

  Future<void> _updateEsp(
    UsbFlashDevice device,
    UsbFirmwareImage image,
    UsbNodeInfo? before,
    UsbUpdateConfirm confirm,
    UsbUpdateReselect? reselect,
    Uint8List? localMigrationZip,
    Uint8List? localUsbSetZip,
  ) async {
    _state('Reading actual ESP32 chip, capacity and partition state…');
    UsbEspChipInfo chip;
    try {
      chip = await esp.connect(device);
    } on UsbFlashReenumerationRequired catch (failure) {
      if (reselect == null) rethrow;
      final chosen = await reselect(
        failure.original,
        await transport.listDevices(),
      );
      if (chosen == null) throw const UsbUpdateCancelled();
      device = await transport.readIdentity(chosen);
      chip = await esp.connect(device, reset: false);
    }
    device = esp.connectedDevice ?? device;
    if (chip.chip != image.chip) {
      throw StateError('The ESP32 image targets a different chip family.');
    }
    final root = await _root();
    final journalDirectory = Directory('${root.path}/recovery/${chip.mac}');
    await journalDirectory.create(recursive: true);
    final journalFile = File('${journalDirectory.path}/plan.json');
    Map<String, dynamic>? journal;
    if (await journalFile.exists()) {
      final decoded = jsonDecode(await journalFile.readAsString());
      if (decoded is! Map<String, dynamic>) {
        throw StateError('The saved USB recovery record is invalid.');
      }
      if (decoded['format'] != 'meshcore-open-usb-migration-v1' ||
          decoded['started'] is! bool ||
          decoded['completed'] is! bool) {
        throw StateError('The saved USB recovery record format is invalid.');
      }
      if (decoded['started'] == true && decoded['completed'] != true) {
        journal = decoded;
        if (journal['mac'] != chip.mac ||
            journal['chip'] != chip.chip ||
            journal['flashBytes'] != chip.flashBytes ||
            journal['firmwareSha256'] != image.sha256) {
          throw StateError(
            'A migration is pending. Select its original exact '
            'firmware on the original node before doing another update.',
          );
        }
        if (journal['originalPublicKey'] is String &&
            (journal['originalPublicKey'] as String).isNotEmpty) {
          final originalKey = journal['originalPublicKey'] as String;
          if (!RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(originalKey)) {
            throw StateError('The recovery record public identity is invalid.');
          }
          if (before != null && before.publicKey != originalKey) {
            throw StateError(
              'The node identity differs from the original '
              'recovery record. Restore the original identity before retrying.',
            );
          }
          before = UsbNodeInfo(
            publicKey: originalKey,
            role: before?.role ?? 'unknown',
            hardwareModel: before?.hardwareModel,
            firmwareVersion: before?.firmwareVersion,
          );
        }
      }
    }
    final snapshot = await _snapshot(chip);
    final savedFirmware = await _artifact(image.name, image.bytes);
    final originalTable = journal == null
        ? snapshot['table']!
        : Uint8List.fromList(base64Decode(journal['sourceTable'] as String));
    final originalOta = journal == null
        ? snapshot['ota']
        : Uint8List.fromList(base64Decode(journal['sourceOtadata'] as String));
    if (journal != null &&
        (usbSha256(originalTable) != journal['sourceTableSha256'] ||
            originalOta == null ||
            usbSha256(originalOta) != journal['sourceOtadataSha256'])) {
      throw StateError('Saved recovery layout or OTA metadata changed.');
    }
    // No private NVS is persisted in recovery records. This reconstruction is
    // allowed only for a previously validated, MAC+image-bound started plan.
    // Real live NVS completion is always required below before final writes.
    final analysis = UsbPartitionExpansion.analyze(
      image: image,
      table: originalTable,
      flashBytes: chip.flashBytes,
      chip: chip.chip,
      otadata: originalOta,
      nvs: journal == null
          ? snapshot['nvs']
          : Uint8List.fromList(List.filled(0x5000, 0xff)),
    );
    var appOffsets = analysis.appOffsets;
    if (analysis.needed) {
      _state('Qualifying the exact Full package and pinned USB bridge…');
      if (journal == null &&
          localMigrationZip == null &&
          analysis.packageUrl == null) {
        throw StateError(
          'Cannot determine the exact firmware release. Choose '
          'its matching Full migration ZIP under Offline migration packages.',
        );
      }
      final packageZip = journal == null
          ? localMigrationZip ??
                await catalog.download(Uri.parse(analysis.packageUrl!))
          : await _readRecoveryArtifact(
              root,
              journal['packagePath'],
              journal['packageSha256'],
            );
      Uint8List? usbSet = journal == null
          ? localUsbSetZip
          : (journal['usbSetPath'] == null
                ? null
                : await _readRecoveryArtifact(
                    root,
                    journal['usbSetPath'],
                    journal['usbSetSha256'],
                  ));
      if (journal != null &&
          (usbSha256(packageZip) != journal['packageSha256'] ||
              (usbSet != null &&
                  usbSha256(usbSet) != journal['usbSetSha256']) ||
              usbSha256(originalTable) != journal['sourceTableSha256'])) {
        throw StateError('Recovery artifacts changed; no write is permitted.');
      }
      UsbPartitionPlan plan;
      try {
        plan = UsbPartitionExpansion.createPlan(
          analysis: analysis,
          packageZip: packageZip,
          usbSetZip: usbSet,
          requirePinnedUsbSet: journal == null
              ? localUsbSetZip == null
              : journal['usbSetPinned'] != false,
        );
      } on UsbFirmwareValidationException catch (failure) {
        if (journal != null ||
            usbSet != null ||
            failure.code != 'usb_bridge_missing') {
          rethrow;
        }
        // Only an already qualified legacy Full package may fetch the separate
        // pinned utility set. Malformed embedded metadata never falls back.
        usbSet = await catalog.download(
          Uri.parse(UsbPartitionExpansion.pinnedUsbSetUrl),
          expectedSha256: UsbPartitionExpansion.pinnedUsbSetSha256,
        );
        plan = UsbPartitionExpansion.createPlan(
          analysis: analysis,
          packageZip: packageZip,
          usbSetZip: usbSet,
          requirePinnedUsbSet: true,
        );
      }
      plan.verifyArtifacts();
      final currentHash = usbSha256(snapshot['table']!);
      if (journal != null &&
          currentHash != plan.sourceTableSha256 &&
          currentHash != plan.targetTableSha256) {
        throw StateError('Pending migration layout changed unexpectedly.');
      }
      await _require(
        confirm,
        UsbUpdateQuestion(
          'Expand partitions and update?',
          '${plan.board}: the current app slots are too small. The verified '
              'USB bridge preserves identity and supported configuration, then '
              'returns to USB. No full-chip erase is performed. Keep stable '
              'power: partition-table replacement is NOT power-loss atomic; '
              'power loss can still require physical recovery.',
        ),
      );
      if (usbSha256(await savedFirmware.readAsBytes()) != image.sha256) {
        throw StateError(
          'The selected final firmware changed before bridge '
          'execution. No partition migration was started.',
        );
      }
      if (journal == null) {
        final packageFile = await _artifact('full-migration.zip', packageZip);
        final usbFile = usbSet == null
            ? null
            : await _artifact('usb-bridges.zip', usbSet);
        journal = {
          'format': 'meshcore-open-usb-migration-v1',
          'mac': chip.mac,
          'chip': chip.chip,
          'flashBytes': chip.flashBytes,
          'firmwareSha256': image.sha256,
          'firmwarePath': savedFirmware.path,
          'packagePath': packageFile.path,
          'packageSha256': usbSha256(packageZip),
          'usbSetPath': usbFile?.path,
          'usbSetSha256': usbSet == null ? null : usbSha256(usbSet),
          'usbSetPinned': localUsbSetZip == null,
          'originalPublicKey': before?.publicKey,
          'sourceTable': base64Encode(originalTable),
          'sourceTableSha256': usbSha256(originalTable),
          'sourceOtadata': base64Encode(originalOta!),
          'sourceOtadataSha256': usbSha256(originalOta),
          'started': true,
          'completed': false,
        };
        // Durable recovery record BEFORE the first bridge write.
        await _writeJson(journalFile, journal);
      }
      if (currentHash == plan.sourceTableSha256) {
        _state('Writing the verified USB bridge, inactive slot first…');
        // A partially run bridge may have changed the active source slot.
        // Use LIVE OTA selection for this retry, not the original journal's.
        final parts = UsbPartitionExpansion.parseTable(
          snapshot['table']!,
          chip.flashBytes,
        );
        final liveActive = UsbPartitionExpansion.activeOtaOffset(
          parts,
          snapshot['ota']!,
        );
        final liveSlots = parts
            .where((p) => p.type == 0)
            .map((p) => p.offset)
            .toList();
        final bridgeOffsets = [
          ...liveSlots.where((p) => p != liveActive),
          liveActive,
        ];
        for (final offset in bridgeOffsets) {
          plan.verifyArtifacts();
          if (usbSha256(await savedFirmware.readAsBytes()) != image.sha256) {
            throw StateError(
              'The final firmware changed during bridge preparation.',
            );
          }
          await esp.writeFlash(offset, plan.bridge, expectedMac: chip.mac);
        }
        await esp.runApplication(migrationBridge: true);
        await esp.close();
        await _waitForMigration(device, chip, plan, reselect);
      }
      final completed = await _snapshot(chip);
      if (completed['nvs'] == null || completed['ota'] == null) {
        throw StateError('Migration restoration proof is incomplete.');
      }
      final recovery = UsbPartitionExpansion.verifyRecovery(
        plan: plan,
        table: completed['table']!,
        nvs: completed['nvs']!,
        otadata: completed['ota']!,
      );
      appOffsets = recovery.appOffsets;
      // Only mark complete after the selected final application verifies.
    } else {
      if (journal != null) {
        throw StateError(
          'A pending migration cannot use the ordinary fit path.',
        );
      }
      await _require(
        confirm,
        UsbUpdateQuestion(
          'Write application firmware?',
          '${image.name}\nChip: ${chip.name}; MAC: ${chip.mac}; '
              'capacity: ${chip.flashBytes ~/ (1024 * 1024)} MiB. '
              'The image fits the verified layout. Write-only update, no chip erase.',
        ),
      );
    }
    _state('Writing final firmware, active app slot last…');
    for (var index = 0; index < appOffsets.length; index++) {
      final current = await savedFirmware.readAsBytes();
      if (usbSha256(current) != image.sha256) {
        throw StateError('The selected firmware changed before writing.');
      }
      await esp.writeFlash(appOffsets[index], current, expectedMac: chip.mac);
      _state(
        'Verified application slot ${index + 1}/${appOffsets.length}.',
        (index + 1) / appOffsets.length,
      );
    }
    await esp.runApplication();
    await esp.close();
    final packed = image.endf?.version;
    final version =
        image.release?.version ??
        (packed == null
            ? null
            : [
                packed >> 24 & 255,
                packed >> 16 & 255,
                packed >> 8 & 255,
                if (packed & 255 != 0) packed & 255,
              ].join('.'));
    await _verifyApplication(device, before, version, reselect);
    if (journal != null) {
      journal['completed'] = true;
      await _writeJson(journalFile, journal);
    }
  }

  Future<void> _waitForMigration(
    UsbFlashDevice original,
    UsbEspChipInfo chip,
    UsbPartitionPlan plan,
    UsbUpdateReselect? reselect,
  ) async {
    _state('Bridge is restoring settings. Keep power and USB connected…');
    if (plan.uartCompletionStatus) {
      await transport.open(original);
      await transport.purge();
      var buffer = '';
      final watch = Stopwatch()..start();
      var settled = false;
      try {
        while (watch.elapsed < const Duration(seconds: 180)) {
          final bytes = await transport.read();
          buffer += utf8.decode(bytes, allowMalformed: true);
          if (buffer.length > 65536) {
            throw StateError('USB bridge status exceeded its bounded size.');
          }
          while (buffer.contains('\n')) {
            final newline = buffer.indexOf('\n');
            final line = buffer.substring(0, newline).trimRight();
            buffer = buffer.substring(newline + 1);
            const prefix = 'MESHCORE_USB_MIGRATION_STATE ';
            if (!line.startsWith(prefix)) continue;
            try {
              final state = usbStrictJson(
                Uint8List.fromList(utf8.encode(line.substring(prefix.length))),
              );
              if (state is Map &&
                  state['format'] == 'meshcore-usb-partition-migration-v1' &&
                  state['device_mac'] is String &&
                  state['settled'] == true &&
                  state['restored'] is bool) {
                if (UsbEspChipInfo.normalizeMac(
                      state['device_mac'] as String,
                    ) !=
                    chip.mac) {
                  throw StateError(
                    'The settled USB bridge belongs to a different chip.',
                  );
                }
                settled = true;
              }
            } on FormatException {
              // A split status line is not evidence; wait for a complete one.
            }
          }
          if (settled) break;
        }
      } finally {
        await transport.close();
      }
      if (!settled) {
        throw StateError(
          'No matching-MAC settled status. No host reset was issued.',
        );
      }
      final recovered = await esp.connect(original);
      if (recovered.mac != chip.mac ||
          recovered.chip != chip.chip ||
          recovered.flashBytes != chip.flashBytes) {
        throw StateError('The USB migration returned a different chip.');
      }
      return;
    }
    final watch = Stopwatch()..start();
    while (watch.elapsed < const Duration(seconds: 180)) {
      try {
        final endpoint = await transport.reacquire(
          original,
          timeout: const Duration(seconds: 2),
        );
        // Never DTR/RTS-reset a native bridge that may still be restoring.
        final recovered = await esp.connect(endpoint, reset: false);
        if (recovered.mac != chip.mac ||
            recovered.chip != chip.chip ||
            recovered.flashBytes != chip.flashBytes) {
          throw StateError('The USB migration returned a different chip.');
        }
        return;
      } on StateError catch (failure) {
        if (failure.message.contains('different chip')) rethrow;
        await esp.close();
      } catch (_) {
        await esp.close();
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    // No explicit reselect is attempted while the helper might still be active.
    throw TimeoutException(
      'The USB bridge did not return with passive ROM '
      'proof. No host reset or final firmware write was attempted.',
    );
  }
}
