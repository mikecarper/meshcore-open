import 'dart:math' as math;
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:file_selector/file_selector.dart';

import 'ble_mota_catalog.dart';

/// Builds a signed application package entirely on the phone. The caller owns
/// the signing seed and must clear its byte buffer after this method returns.
/// Neither the seed nor the resulting package is written to disk here.
class LocalMotaBuilder {
  static const int _manifestSize = 197;
  static const int _blockSize = 1024;
  static const int _segmentSize = 4096;

  /// Matches the key files produced by motatool: 32 raw seed bytes or 64 hex
  /// characters (with optional surrounding whitespace). The caller must
  /// clear both the selected file buffer and the returned seed after use.
  static Uint8List parseSigningSeed(Uint8List contents) {
    if (contents.length == 32) return Uint8List.fromList(contents);
    if (contents.length > 128) {
      throw const FormatException('Signing key file is too large.');
    }
    final text = utf8.decode(contents, allowMalformed: false).trim();
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(text)) {
      throw const FormatException(
        'Signing key must contain 32 raw bytes or 64 hex characters.',
      );
    }
    return Uint8List.fromList(<int>[
      for (var index = 0; index < 64; index += 2)
        int.parse(text.substring(index, index + 2), radix: 16),
    ]);
  }

  /// External SD/QSPI targets can install a full image without a base image.
  /// This costs more LoRa airtime but is useful when the exact running build
  /// cannot be recovered. Internal-flash targets must use an in-place delta.
  Future<BleMotaFile> buildFullForTarget({
    required Uint8List updatedImage,
    required Uint8List signingSeed,
    required int targetId,
  }) async {
    if (signingSeed.length != 32) {
      throw const FormatException(
        'The signing key must be a 32-byte Ed25519 seed.',
      );
    }
    final next = FirmwareImageIdentity.read(updatedImage);
    if (next.targetId != targetId || next.firmwareVersion == 0) {
      throw StateError('The new firmware does not match this target.');
    }
    final bytes = await _package(
      payload: updatedImage,
      image: updatedImage,
      baseHash: Uint8List(8),
      identity: next,
      signingSeed: signingSeed,
      full: true,
    );
    final name =
        '${next.hardwareId}_${next.targetId.toRadixString(16).padLeft(8, '0')}'
        '_v${next.versionLabel}_full.mota';
    return BleMotaFile.load(XFile.fromData(bytes, name: name, path: name));
  }

  Future<BleMotaFile> buildForTarget({
    required Uint8List installedImage,
    required Uint8List updatedImage,
    required Uint8List signingSeed,
    required int targetId,
    required String targetBaseHash,
    int? inplaceMemory,
    bool allowFull = true,
  }) async {
    if (signingSeed.length != 32) {
      throw const FormatException(
        'The signing key must be a 32-byte Ed25519 seed.',
      );
    }
    final old = FirmwareImageIdentity.read(installedImage);
    final next = FirmwareImageIdentity.read(updatedImage);
    if (old.targetId != targetId || next.targetId != targetId) {
      throw StateError('The firmware images do not match this target ID.');
    }
    if (old.hardwareId != next.hardwareId) {
      throw StateError('The old and new images have different hardware IDs.');
    }
    if (old.bodyHashHex != targetBaseHash.toUpperCase()) {
      throw StateError(
        'The selected old image is not the target\'s running image: '
        '${old.bodyHashHex} != ${targetBaseHash.toUpperCase()}.',
      );
    }
    if (next.firmwareVersion == 0 ||
        next.firmwareVersion <= old.firmwareVersion) {
      throw StateError(
        'The new firmware version must be greater than the installed version.',
      );
    }

    final minimum = math.max(
      _roundUp(installedImage.length, _segmentSize) + 2 * _segmentSize,
      _roundUp(updatedImage.length, _segmentSize),
    );
    final authenticatedPair =
        old.nrf52Layout != null && next.nrf52Layout != null;
    if (authenticatedPair &&
        old.nrf52Layout!.appBase != next.nrf52Layout!.appBase) {
      throw StateError(
        'The firmware images use different SoftDevice application addresses.',
      );
    }
    final memory = inplaceMemory ?? (authenticatedPair ? minimum : 0x98000);
    var fullFallback =
        inplaceMemory == null &&
        !authenticatedPair &&
        memory < minimum &&
        allowFull;
    if (memory <= 0 ||
        memory % _segmentSize != 0 ||
        (memory < minimum && !fullFallback)) {
      throw StateError(
        'The in-place workspace is too small or not page aligned. '
        'Both images need valid layout records for automatic sizing beyond the legacy limit.',
      );
    }
    final layout = old.nrf52Layout;
    if (layout != null && updatedImage.length > layout.applicationSpan) {
      throw StateError(
        'The update exceeds the running image\'s authenticated application workspace.',
      );
    }
    if (layout != null && memory > layout.workspaceSpan) {
      if (inplaceMemory != null || !allowFull) {
        throw StateError(
          'The selected workspace exceeds the running image\'s authenticated layout.',
        );
      }
      // A full image on an allowed external store does not need the delta's
      // extra relocation pages. Preserve that existing fallback near the limit.
      fullFallback = true;
    }
    final delta = fullFallback
        ? null
        : _encodeInPlace(installedImage, updatedImage, memory);
    final useDelta = delta != null && delta.length < updatedImage.length;
    if (!useDelta && !allowFull) {
      throw StateError(
        'A safe in-place delta is not smaller than the full image; this '
        'target cannot stage a full image in internal flash.',
      );
    }
    final payload = useDelta ? delta : updatedImage;
    final bytes = await _package(
      payload: payload,
      image: updatedImage,
      baseHash: useDelta ? old.bodyHash : Uint8List(8),
      identity: next,
      signingSeed: signingSeed,
      full: !useDelta,
    );
    if (useDelta && !(layout?.externalBacked ?? false)) {
      final span =
          layout?.workspaceSpan ?? (inplaceMemory == null ? 0xad000 : null);
      if (span != null &&
          memory + _roundUp(bytes.length, _segmentSize) > span) {
        final flashLength = _roundUp(
          math.max(_segmentSize, bytes.length - 65536),
          _segmentSize,
        );
        final ramLength = bytes.length - flashLength;
        if (layout?.hybridRam != true ||
            memory + flashLength > span ||
            ramLength <= 0 ||
            ramLength > 65536) {
          throw StateError(
            'The signed update container does not fit beside the in-place workspace.',
          );
        }
      }
    }
    final name =
        '${next.hardwareId}_${next.targetId.toRadixString(16).padLeft(8, '0')}'
        '_v${next.versionLabel}_${useDelta ? 'ipdelta' : 'full'}.mota';
    return BleMotaFile.load(XFile.fromData(bytes, name: name, path: name));
  }

  static Future<Uint8List> _package({
    required Uint8List payload,
    required Uint8List image,
    required Uint8List baseHash,
    required FirmwareImageIdentity identity,
    required Uint8List signingSeed,
    required bool full,
  }) async {
    final leaves = <Uint8List>[];
    for (var offset = 0; offset < payload.length; offset += _blockSize) {
      leaves.add(
        Uint8List.fromList(
          crypto.sha256
              .convert(
                payload.sublist(
                  offset,
                  math.min(offset + _blockSize, payload.length),
                ),
              )
              .bytes
              .sublist(0, 4),
        ),
      );
    }
    if (leaves.isEmpty || leaves.length > 0xFFFF) {
      throw StateError('The update payload has an unsupported block count.');
    }

    final manifest = Uint8List(_manifestSize);
    final fields = ByteData.sublistView(manifest);
    manifest[0] = 2;
    manifest[1] = full ? 0x03 : 0x02; // signed full or signed delta
    manifest[2] = 0x12; // SHA-256
    fields.setUint32(3, identity.targetId, Endian.little);
    fields.setUint32(7, identity.firmwareVersion, Endian.little);
    fields.setUint32(11, image.length, Endian.little);
    fields.setUint32(15, payload.length, Endian.little);
    manifest[19] = 10; // 1024-byte blocks
    manifest.setRange(20, 24, _merkleRoot(leaves));
    manifest.setRange(24, 56, crypto.sha256.convert(image).bytes);
    manifest[56] = full ? 0 : 2; // raw full or detools in-place
    manifest.setRange(
      57,
      57 + identity.hardwareId.length,
      identity.hardwareId.codeUnits,
    );
    manifest.setRange(89, 97, baseHash);

    final ed25519 = Ed25519();
    final keyPair = await ed25519.newKeyPairFromSeed(signingSeed);
    final publicKey = await keyPair.extractPublicKey();
    manifest.setRange(97, 129, publicKey.bytes);
    final signature = await ed25519.sign(
      manifest.sublist(0, 129),
      keyPair: keyPair,
    );
    manifest.setRange(129, 193, signature.bytes);
    manifest.fillRange(193, 197, 0xFF);

    final total = 8 + _manifestSize + leaves.length * 4 + payload.length + 5;
    final header = Uint8List(8);
    header.setRange(0, 4, 'mOTA'.codeUnits);
    ByteData.sublistView(header).setUint32(4, total, Endian.little);
    final container = BytesBuilder(copy: false)
      ..add(header)
      ..add(manifest);
    for (final leaf in leaves) {
      container.add(leaf);
    }
    container
      ..add(payload)
      ..add('vk496'.codeUnits);
    return container.toBytes();
  }

  /// A detools in-place CRLE stream. Each 4 KiB target segment uses the
  /// same-offset bytes of the authenticated base image as its diff reference.
  /// CRLE collapses unchanged byte runs; a package that is not smaller than a
  /// full image is never selected by [buildForTarget].
  static Uint8List _encodeInPlace(
    Uint8List from,
    Uint8List to,
    int memorySize,
  ) {
    final roundedBase = _roundUp(from.length, _segmentSize);
    final shift = math.max(memorySize - roundedBase, 2 * _segmentSize);
    final body = BytesBuilder(copy: false);
    for (var offset = 0; offset < to.length; offset += _segmentSize) {
      final size = math.min(_segmentSize, to.length - offset);
      final referenceStart = math.max(offset + _segmentSize, shift);
      final diffLength = math.min(size, math.max(0, from.length - offset));
      body.add(_signedSize(0)); // no data-format patch
      if (diffLength > 0) {
        final seek = shift + offset - referenceStart;
        if (seek > 0) {
          body
            ..add(_signedSize(0))
            ..add(_signedSize(0))
            ..add(_signedSize(seek));
        }
        final differences = Uint8List(diffLength);
        for (var i = 0; i < diffLength; i++) {
          differences[i] = (to[offset + i] - from[offset + i]) & 0xFF;
        }
        body
          ..add(_signedSize(diffLength))
          ..add(differences);
      } else {
        body.add(_signedSize(0));
      }
      final extraLength = size - diffLength;
      body.add(_signedSize(extraLength));
      if (extraLength > 0) {
        body.add(to.sublist(offset + diffLength, offset + size));
      }
      body.add(_signedSize(0));
    }

    final patch = BytesBuilder(copy: false)
      ..addByte(0x12) // in-place + CRLE
      ..add(_signedSize(memorySize))
      ..add(_signedSize(_segmentSize))
      ..add(_signedSize(shift))
      ..add(_signedSize(from.length))
      ..add(_signedSize(to.length))
      ..add(_crle(body.toBytes()));
    return patch.toBytes();
  }

  static Uint8List _signedSize(int value) {
    var remaining = value.abs();
    var first = (remaining & 0x3F) | (value < 0 ? 0x40 : 0);
    remaining >>= 6;
    final bytes = <int>[];
    while (remaining != 0) {
      bytes.add(first | 0x80);
      first = remaining & 0x7F;
      remaining >>= 7;
    }
    bytes.add(first);
    return Uint8List.fromList(bytes);
  }

  static Uint8List _crle(Uint8List data) {
    final encoded = BytesBuilder(copy: false);
    var offset = 0;
    while (offset < data.length) {
      var runStart = offset;
      var runLength = 0;
      while (runStart < data.length) {
        runLength = 1;
        while (runStart + runLength < data.length &&
            data[runStart + runLength] == data[runStart]) {
          runLength++;
        }
        if (runLength >= 6) break;
        runStart += runLength;
      }
      if (runStart > offset) {
        encoded
          ..addByte(0)
          ..add(_unsignedSize(runStart - offset))
          ..add(data.sublist(offset, runStart));
        offset = runStart;
      } else {
        encoded
          ..addByte(1)
          ..add(_unsignedSize(runLength))
          ..addByte(data[offset]);
        offset += runLength;
      }
    }
    return encoded.toBytes();
  }

  static Uint8List _unsignedSize(int value) {
    var remaining = value;
    final bytes = <int>[];
    do {
      var byte = remaining & 0x7F;
      remaining >>= 7;
      if (remaining != 0) byte |= 0x80;
      bytes.add(byte);
    } while (remaining != 0);
    return Uint8List.fromList(bytes);
  }

  static Uint8List _merkleRoot(List<Uint8List> leaves) {
    var level = leaves;
    while (level.length > 1) {
      final next = <Uint8List>[];
      for (var index = 0; index < level.length; index += 2) {
        if (index + 1 == level.length) {
          next.add(level[index]);
        } else {
          next.add(
            Uint8List.fromList(
              crypto.sha256
                  .convert(<int>[...level[index], ...level[index + 1]])
                  .bytes
                  .sublist(0, 4),
            ),
          );
        }
      }
      level = next;
    }
    return level.single;
  }

  static int _roundUp(int value, int multiple) =>
      (value + multiple - 1) ~/ multiple * multiple;
}

class FirmwareImageIdentity {
  final int targetId;
  final int firmwareVersion;
  final String hardwareId;
  final Uint8List bodyHash;
  final Nrf52OtaLayout? nrf52Layout;

  const FirmwareImageIdentity({
    required this.targetId,
    required this.firmwareVersion,
    required this.hardwareId,
    required this.bodyHash,
    this.nrf52Layout,
  });

  String get bodyHashHex => bodyHash
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();

  String get versionLabel =>
      '${firmwareVersion >> 24}.${(firmwareVersion >> 16) & 0xFF}.'
      '${(firmwareVersion >> 8) & 0xFF}.${firmwareVersion & 0xFF}';

  static FirmwareImageIdentity read(Uint8List bytes, {int maxSize = 0x100000}) {
    if (bytes.length <= 56 || bytes.length > maxSize) {
      throw const FormatException('Firmware image has no EndF trailer.');
    }
    final trailer = bytes.sublist(bytes.length - 56);
    if (String.fromCharCodes(trailer.sublist(0, 4)) != 'EndF') {
      throw const FormatException('Firmware image has no EndF trailer.');
    }
    final fields = ByteData.sublistView(trailer);
    final bodyLength = fields.getUint32(4, Endian.little);
    if (bodyLength != bytes.length - 56) {
      throw const FormatException('Firmware EndF body length is invalid.');
    }
    final hash = Uint8List.fromList(
      crypto.sha256.convert(bytes.sublist(0, bodyLength)).bytes.sublist(0, 8),
    );
    for (var i = 0; i < 8; i++) {
      if (hash[i] != trailer[8 + i]) {
        throw const FormatException('Firmware EndF body hash is invalid.');
      }
    }
    final hardwareBytes = trailer.sublist(24, 56);
    final end = hardwareBytes.indexOf(0);
    final hardware = String.fromCharCodes(
      hardwareBytes.sublist(0, end < 0 ? 32 : end),
    );
    if (hardware.isEmpty || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(hardware)) {
      throw const FormatException('Firmware EndF hardware ID is invalid.');
    }
    return FirmwareImageIdentity(
      targetId: fields.getUint32(20, Endian.little),
      firmwareVersion: fields.getUint32(16, Endian.little),
      hardwareId: hardware,
      bodyHash: hash,
      // The record is inside the body whose hash was checked above.
      nrf52Layout: Nrf52OtaLayout._read(bytes),
    );
  }
}

/// Version-1 mOTALay1 geometry, authenticated by the enclosing EndF body hash.
/// Mirrors OTAFIX/motatool's layout contract; unknown geometry fails closed.
class Nrf52OtaLayout {
  const Nrf52OtaLayout._(
    this.appBase,
    this.linkedEnd,
    this.stageCeiling,
    this.flags,
  );
  final int appBase, linkedEnd, stageCeiling, flags;
  bool get externalBacked => flags & 5 != 0;
  bool get hybridRam => flags & 0x10 != 0;
  int get applicationSpan => (flags & 8 != 0 ? linkedEnd : 0xed000) - appBase;
  int get workspaceSpan =>
      externalBacked ? applicationSpan : stageCeiling - appBase;

  static Nrf52OtaLayout? _read(Uint8List image) {
    if (image.length < 80) return null;
    final start = image.length - 80;
    final record = ByteData.sublistView(image, start, start + 24);
    if (String.fromCharCodes(image.sublist(start, start + 8)) != 'mOTALay1') {
      return null;
    }
    final flags = record.getUint8(9);
    final base = record.getUint32(12, Endian.little);
    final end = record.getUint32(16, Endian.little);
    final ceiling = record.getUint32(20, Endian.little);
    final sd = flags & 1 != 0, fs = flags & 2 != 0, qspi = flags & 4 != 0;
    final scratch = flags & 8 != 0,
        hybrid = flags & 0x10 != 0,
        auto = flags & 0x20 != 0;
    final external = sd || qspi;
    if (record.getUint8(8) != 1 ||
        record.getUint16(10, Endian.little) != 24 ||
        !const [0x26000, 0x27000].contains(base) ||
        !const [0xd4000, 0xe0000, 0xed000].contains(end) ||
        !const [0xd4000, 0xed000].contains(ceiling) ||
        base >= end ||
        flags & ~0x3f != 0 ||
        (sd && qspi) ||
        (external && fs) ||
        (auto && (external || fs)) ||
        (hybrid && (external || fs || end != 0xed000 || ceiling != 0xed000)) ||
        (scratch ? !qspi || sd || end != 0xe0000 : end == 0xe0000) ||
        ceiling != (external || !fs ? 0xed000 : 0xd4000) ||
        image.length > math.min(end, ceiling) - base) {
      throw const FormatException(
        'Firmware has an invalid authenticated nRF52 layout.',
      );
    }
    return Nrf52OtaLayout._(base, end, ceiling, flags);
  }
}
