import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'companion_board_catalog.dart';
import 'companion_image_validator.dart';
import 'companion_firmware_validation.dart';

/// Public identity and a board-validated ZIP only. Never stores credentials,
/// radio private keys, raw CLI replies, or external file-picker paths.
class NrfDfuRecoveryRecord {
  const NrfDfuRecoveryRecord({
    required this.path,
    required this.originalAddress,
    required this.board,
    required this.publicKey,
    required this.filename,
    required this.applicationOnly,
    required this.expiresAt,
    required this.nativeMayBeActive,
    this.verifiedBootloaderAddress,
    this.provenance,
  });

  final String path, originalAddress, board, publicKey, filename;
  final String? verifiedBootloaderAddress;
  final bool applicationOnly, nativeMayBeActive;
  final DateTime expiresAt;
  final CompanionFirmwareProvenance? provenance;

  // System-component updates must not be blindly replayed after interruption.
  bool get canRetry => applicationOnly && !nativeMayBeActive;
}

class NrfDfuRecoveryStore {
  NrfDfuRecoveryStore({
    Future<Directory> Function()? directory,
    DateTime Function()? now,
  }) : _directory = directory ?? getApplicationSupportDirectory,
       _now = now ?? DateTime.now;

  final Future<Directory> Function() _directory;
  final DateTime Function() _now;
  static const _lifetime = Duration(hours: 24);
  static final _address = RegExp(r'^[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}$');
  // CoreBluetooth exposes a per-phone UUID instead of the hardware MAC.
  // Retain it for the native iOS handoff; never invent a MAC/+1 from it.
  static final _iosIdentifier = RegExp(
    r'^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$',
  );
  static final _key = RegExp(r'^[0-9A-Fa-f]{64}$');
  static final _hash = RegExp(r'^[0-9a-f]{64}$');

  Future<Directory> _root() async =>
      Directory('${(await _directory()).path}/dfu-recovery');

  void _validateIdentity(String board, String address, String key) {
    final spec = CompanionBoardCatalog.lookup(board);
    if (spec?.family != CompanionChipFamily.nrf52 ||
        spec!.dfuNames.isEmpty ||
        board.length > 120 ||
        !_key.hasMatch(key) ||
        !(_address.hasMatch(address) || _iosIdentifier.hasMatch(address))) {
      throw const FormatException(
        'Recovery identity is not a verified Nordic board.',
      );
    }
  }

  Future<NrfDfuRecoveryRecord> save({
    required String sourcePath,
    required String originalAddress,
    required String board,
    required String publicKey,
    required String filename,
    required bool applicationOnly,
    String? verifiedBootloaderAddress,
    CompanionFirmwareProvenance? provenance,
  }) async {
    if (await hasUnconfirmedNativeTransfer()) {
      throw StateError(
        'A saved native Bluetooth update has not confirmed termination.',
      );
    }
    _validateIdentity(board, originalAddress, publicKey);
    if (verifiedBootloaderAddress != null &&
        !_address.hasMatch(verifiedBootloaderAddress)) {
      throw const FormatException('Invalid verified bootloader address.');
    }
    if (filename.isEmpty ||
        filename.length > 240 ||
        filename.contains('/') ||
        filename.contains('\\') ||
        filename.codeUnits.any((c) => c < 32 || c > 126)) {
      throw const FormatException('Invalid recovery firmware filename.');
    }
    final source = File(sourcePath);
    final length = await source.length();
    if (length < 256 || length > 0x1000000) {
      throw const FormatException('Invalid recovery ZIP size.');
    }
    final bytes = await source.readAsBytes();
    final package = await CompanionFirmwareValidation.inspectNordic(
      bytes,
      board: board,
      provenance: provenance,
    );
    final actualApplicationOnly =
        package.components.length == 1 &&
        package.components.single == 'application';
    if (actualApplicationOnly != applicationOnly) {
      throw const FormatException('Recovery component classification changed.');
    }
    final root = await _root();
    if (await FileSystemEntity.type(root.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FileSystemException(
        'Recovery storage must not be a symlink.',
      );
    }
    await root.create(recursive: true);
    // The path is fixed under app-private support storage, never taken from
    // serialized metadata. Atomic metadata replacement invalidates torn copies.
    final zip = File('${root.path}/recovery.zip');
    if (await FileSystemEntity.type(zip.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FileSystemException(
        'Recovery firmware must not be a symlink.',
      );
    }
    await zip.writeAsBytes(bytes, flush: true);
    final created = _now().toUtc();
    final data = <String, Object?>{
      'schema': 1,
      'board': board,
      'originalAddress': originalAddress.toUpperCase(),
      'publicKey': publicKey.toLowerCase(),
      'filename': filename,
      'applicationOnly': applicationOnly,
      'verifiedBootloaderAddress': verifiedBootloaderAddress?.toUpperCase(),
      'sha256': package.sha256,
      'size': bytes.length,
      'createdAt': created.toIso8601String(),
      'expiresAt': created.add(_lifetime).toIso8601String(),
      'nativeMayBeActive': false,
      'provenance': provenance == null
          ? null
          : {
              'boardId': provenance.boardId,
              'sha256': provenance.sha256,
              'profile': provenance.profile,
            },
    };
    await _writeMetadata(root, data);
    return _record(root, data);
  }

  Future<void> _writeMetadata(Directory root, Map<String, Object?> data) async {
    final temporary = File('${root.path}/record.json.new');
    final target = File('${root.path}/record.json');
    for (final file in [temporary, target]) {
      if (await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const FileSystemException(
          'Recovery metadata must not be a symlink.',
        );
      }
    }
    await temporary.writeAsString(jsonEncode(data), flush: true);
    await temporary.rename(target.path);
  }

  NrfDfuRecoveryRecord _record(Directory root, Map<String, Object?> data) =>
      NrfDfuRecoveryRecord(
        path: '${root.path}/recovery.zip',
        originalAddress: data['originalAddress'] as String,
        board: data['board'] as String,
        publicKey: data['publicKey'] as String,
        filename: data['filename'] as String,
        applicationOnly: data['applicationOnly'] as bool,
        verifiedBootloaderAddress: data['verifiedBootloaderAddress'] as String?,
        expiresAt: DateTime.parse(data['expiresAt'] as String),
        nativeMayBeActive: data['nativeMayBeActive'] as bool,
        provenance: _provenance(data['provenance']),
      );

  CompanionFirmwareProvenance? _provenance(Object? value) {
    if (value == null) return null;
    if (value is! Map ||
        value['boardId'] is! String ||
        value['sha256'] is! String ||
        value['profile'] is! String) {
      throw const FormatException('Invalid recovery package provenance.');
    }
    return CompanionFirmwareProvenance(
      boardId: value['boardId'] as String,
      sha256: value['sha256'] as String,
      profile: value['profile'] as String,
    );
  }

  Future<Map<String, Object?>?> _readVerified(Directory root) async {
    final metadata = File('${root.path}/record.json');
    final zip = File('${root.path}/recovery.zip');
    if (await FileSystemEntity.type(root.path, followLinks: false) ==
            FileSystemEntityType.link ||
        await FileSystemEntity.type(metadata.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await FileSystemEntity.type(zip.path, followLinks: false) !=
            FileSystemEntityType.file) {
      return null;
    }
    if (await metadata.length() > 4096) return null;
    final decoded = jsonDecode(await metadata.readAsString());
    if (decoded is! Map<String, dynamic>) return null;
    final data = Map<String, Object?>.from(decoded);
    if (data['schema'] != 1 ||
        data['board'] is! String ||
        data['originalAddress'] is! String ||
        data['publicKey'] is! String ||
        data['filename'] is! String ||
        data['applicationOnly'] is! bool ||
        data['nativeMayBeActive'] is! bool ||
        data['createdAt'] is! String ||
        data['expiresAt'] is! String ||
        data['size'] is! int ||
        data['sha256'] is! String ||
        (data['verifiedBootloaderAddress'] != null &&
            data['verifiedBootloaderAddress'] is! String)) {
      return null;
    }
    _validateIdentity(
      data['board'] as String,
      data['originalAddress'] as String,
      data['publicKey'] as String,
    );
    final now = _now().toUtc();
    final created = DateTime.parse(data['createdAt'] as String).toUtc();
    final expires = DateTime.parse(data['expiresAt'] as String).toUtc();
    if (created.isAfter(now.add(const Duration(minutes: 5))) ||
        (!expires.isAfter(now) && data['nativeMayBeActive'] != true) ||
        expires.difference(created) != _lifetime ||
        !_hash.hasMatch(data['sha256'] as String)) {
      return null;
    }
    final verified = data['verifiedBootloaderAddress'] as String?;
    if (verified != null && !_address.hasMatch(verified)) return null;
    final filename = data['filename'] as String;
    if (filename.isEmpty ||
        filename.length > 240 ||
        filename.contains('/') ||
        filename.contains('\\') ||
        filename.codeUnits.any((c) => c < 32 || c > 126)) {
      return null;
    }
    final size = await zip.length();
    if (size < 256 || size > 0x1000000 || size != data['size']) return null;
    final bytes = await zip.readAsBytes();
    final package = await CompanionFirmwareValidation.inspectNordic(
      bytes,
      board: data['board'] as String,
      provenance: _provenance(data['provenance']),
    );
    if (package.sha256 != data['sha256']) return null;
    if ((package.components.length == 1 &&
            package.components.single == 'application') !=
        data['applicationOnly']) {
      return null;
    }
    return data;
  }

  Future<NrfDfuRecoveryRecord?> load() async {
    final root = await _root();
    try {
      final data = await _readVerified(root);
      if (data != null) return _record(root, data);
    } on FormatException {
      // Invalid/expired/torn metadata is never used for a firmware write.
    } on FileSystemException {
      // OS cleanup of support/cache files means recovery is unavailable.
    }
    return null;
  }

  /// A corrupt/expired ZIP must not turn an unknown native-service lifetime
  /// into permission to start another service after the Flutter app restarts.
  Future<bool> hasUnconfirmedNativeTransfer() async {
    final root = await _root();
    final lease = File('${root.path}/native.json');
    final leaseType = await FileSystemEntity.type(
      lease.path,
      followLinks: false,
    );
    if (leaseType != FileSystemEntityType.notFound) return true;
    final metadata = File('${root.path}/record.json');
    final rootType = await FileSystemEntity.type(root.path, followLinks: false);
    if (rootType == FileSystemEntityType.link) return true;
    final type = await FileSystemEntity.type(metadata.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return false;
    if (type != FileSystemEntityType.file) return true;
    try {
      if (await metadata.length() > 4096) return true;
      final decoded = jsonDecode(await metadata.readAsString());
      // A torn record could have been written immediately before native start.
      if (decoded is! Map || decoded['nativeMayBeActive'] is! bool) return true;
      return decoded['nativeMayBeActive'] as bool;
    } on FormatException {
      return true;
    } on FileSystemException {
      return true;
    }
  }

  Future<void> _mark(bool active) async {
    final root = await _root();
    final data = await _readVerified(root);
    if (data == null) {
      throw StateError('Verified recovery record is unavailable.');
    }
    data['nativeMayBeActive'] = active;
    await _writeMetadata(root, data);
  }

  Future<void> markTransferActive() => _mark(true);

  /// Caller must have proof of a native terminal result, not just abort dispatch.
  Future<void> markTransferSettled() => _mark(false);

  /// Dedicated repeater/system workflows share the same durable native guard
  /// without pretending their system ZIP is a Companion application package.
  Future<void> markExternalTransferActive({
    required String address,
    required String board,
    required String publicKey,
  }) async {
    _validateIdentity(board, address, publicKey);
    if (await hasUnconfirmedNativeTransfer()) {
      throw StateError(
        'Another native Bluetooth update has not confirmed termination.',
      );
    }
    final root = await _root();
    if (await FileSystemEntity.type(root.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FileSystemException(
        'Native recovery storage must not be a symlink.',
      );
    }
    await root.create(recursive: true);
    final temporary = File('${root.path}/native.json.new');
    final target = File('${root.path}/native.json');
    for (final file in [temporary, target]) {
      if (await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const FileSystemException(
          'Native recovery guard must not be a symlink.',
        );
      }
    }
    await temporary.writeAsString(
      jsonEncode({
        'schema': 1,
        'originalAddress': address.toUpperCase(),
        'board': board,
        'publicKey': publicKey.toLowerCase(),
        'startedAt': _now().toUtc().toIso8601String(),
      }),
      flush: true,
    );
    await temporary.rename(target.path);
  }

  /// Call only once this workflow's native terminal result is confirmed.
  Future<void> markExternalTransferSettled() async {
    final root = await _root();
    if (await FileSystemEntity.type(root.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FileSystemException(
        'Native recovery storage must not be a symlink.',
      );
    }
    for (final name in ['native.json', 'native.json.new']) {
      final file = File('${root.path}/$name');
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        await file.delete();
      }
    }
  }

  /// Recovery from an interrupted app process requires OS-level proof, not a
  /// user checkbox, expiry, or merely dispatching an abort request.
  Future<bool> confirmNativeStopped({
    required Future<bool> Function() verifyStopped,
  }) async {
    try {
      if (!await verifyStopped()) return false;
    } catch (_) {
      return false;
    }
    final root = await _root();
    if (await FileSystemEntity.type(root.path, followLinks: false) ==
        FileSystemEntityType.link) {
      return false;
    }
    final metadata = File('${root.path}/record.json');
    final type = await FileSystemEntity.type(metadata.path, followLinks: false);
    if (type != FileSystemEntityType.notFound) {
      if (type != FileSystemEntityType.file || await metadata.length() > 4096) {
        return false;
      }
      try {
        final decoded = jsonDecode(await metadata.readAsString());
        if (decoded is! Map<String, dynamic>) return false;
        final data = Map<String, Object?>.from(decoded);
        data['nativeMayBeActive'] = false;
        await _writeMetadata(root, data);
      } on FormatException {
        return false;
      } on FileSystemException {
        return false;
      }
    }
    await markExternalTransferSettled();
    return true;
  }

  Future<void> clear({bool nativeTerminationConfirmed = false}) async {
    if (!nativeTerminationConfirmed && await hasUnconfirmedNativeTransfer()) {
      throw StateError(
        'Cannot discard an unconfirmed native Bluetooth update.',
      );
    }
    final root = await _root();
    if (await FileSystemEntity.type(root.path, followLinks: false) ==
        FileSystemEntityType.link) {
      return;
    }
    // Explicit files only. No recursive deletion or serialized external path.
    for (final name in [
      'record.json',
      'record.json.new',
      'recovery.zip',
      'native.json',
      'native.json.new',
    ]) {
      final file = File('${root.path}/$name');
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        await file.delete();
      }
    }
  }
}
