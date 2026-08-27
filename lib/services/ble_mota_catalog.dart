import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:file_selector/file_selector.dart';

const int bleMotaSeederReadMax = 192;
const int bleMotaDescriptorSize = 38;

const int _headerSize = 8;
const int _fixedManifestSize = 197;
const int _signedManifestSize = 129;
const List<int> _containerMagic = <int>[0x6D, 0x4F, 0x54, 0x41];
const List<int> _containerTrailer = <int>[0x76, 0x6B, 0x34, 0x39, 0x36];
const int _hashAlgorithmSha256 = 0x12;
const int _flagFull = 0x01;
const int _flagSigned = 0x02;
const int _flagBootloader = 0x04;
const int _knownFlags = _flagFull | _flagSigned | _flagBootloader;
const int _codecFull = 0;
const int _codecDetoolsSequential = 1;
const int _codecDetoolsInPlace = 2;

const int _requestOpCount = 0x01;
const int _requestOpDescribe = 0x02;
const int _requestOpRead = 0x03;
const int _statusOk = 0;
const int _statusError = 1;

class BleMotaFormatException implements Exception {
  final String message;

  const BleMotaFormatException(this.message);

  @override
  String toString() => message;
}

class BleMotaFile {
  final XFile source;
  final String name;
  final int size;
  final int flags;
  final int targetId;
  final int firmwareVersion;
  final int imageSize;
  final int payloadSize;
  final int blockSizeLog2;
  final int blockCount;
  final int codecId;
  final int leavesOffset;
  final int payloadOffset;
  final String hardwareId;
  final Uint8List _descriptor;
  final List<List<_ByteRange>> _payloadCoverage;
  final List<int> _payloadCoveredByBlock;

  int readRequests = 0;
  int bytesServed = 0;
  int payloadReadRequests = 0;
  int uniquePayloadBytesServed = 0;
  int payloadBlocksServed = 0;
  DateTime? firstPayloadReadAt;
  DateTime? lastPayloadReadAt;

  BleMotaFile._({
    required this.source,
    required this.name,
    required this.size,
    required this.flags,
    required this.targetId,
    required this.firmwareVersion,
    required this.imageSize,
    required this.payloadSize,
    required this.blockSizeLog2,
    required this.blockCount,
    required this.codecId,
    required this.leavesOffset,
    required this.payloadOffset,
    required this.hardwareId,
    required Uint8List descriptor,
  }) : _descriptor = descriptor,
       _payloadCoverage = List<List<_ByteRange>>.generate(
         blockCount,
         (_) => <_ByteRange>[],
       ),
       _payloadCoveredByBlock = List<int>.filled(blockCount, 0);

  bool get isFull => (flags & _flagFull) != 0;
  bool get isSigned => (flags & _flagSigned) != 0;
  bool get isBootloader => (flags & _flagBootloader) != 0;

  String get manifestId => _hex(_descriptor.sublist(0, 4));

  String get versionLabel {
    return '${(firmwareVersion >> 24) & 0xFF}.'
        '${(firmwareVersion >> 16) & 0xFF}.'
        '${(firmwareVersion >> 8) & 0xFF}.'
        '${firmwareVersion & 0xFF}';
  }

  String get codecLabel {
    return switch (codecId) {
      _codecFull => 'full',
      _codecDetoolsSequential => 'detools sequential',
      _codecDetoolsInPlace => 'detools in-place',
      _ => 'codec $codecId',
    };
  }

  Uint8List get descriptor => Uint8List.fromList(_descriptor);

  double get sentProgress =>
      blockCount == 0 ? 0 : (payloadBlocksServed / blockCount).clamp(0.0, 1.0);

  double? get payloadBytesPerSecond {
    final first = firstPayloadReadAt;
    final last = lastPayloadReadAt;
    if (first == null || last == null || uniquePayloadBytesServed == 0) {
      return null;
    }
    final seconds = last.difference(first).inMilliseconds / 1000;
    if (seconds <= 0) return null;
    return uniquePayloadBytesServed / seconds;
  }

  static Future<BleMotaFile> load(XFile source) async {
    final size = await source.length();
    if (size > 0xFFFFFFFF) {
      throw const BleMotaFormatException(
        'Container is too large for the mOTA protocol',
      );
    }
    if (size < _headerSize + _fixedManifestSize + _containerTrailer.length) {
      throw const BleMotaFormatException('Container is too short');
    }

    final header = await _readExact(source, 0, _headerSize);
    if (!_bytesEqual(header.sublist(0, 4), _containerMagic)) {
      throw const BleMotaFormatException('Bad mOTA magic');
    }
    final declaredSize = ByteData.sublistView(
      header,
    ).getUint32(4, Endian.little);
    if (declaredSize != size) {
      throw BleMotaFormatException(
        'Declared size $declaredSize does not match file size $size',
      );
    }

    final trailer = await _readExact(
      source,
      size - _containerTrailer.length,
      _containerTrailer.length,
    );
    if (!_bytesEqual(trailer, _containerTrailer)) {
      throw const BleMotaFormatException('Bad mOTA trailer');
    }

    final manifest = await _readExact(source, _headerSize, _fixedManifestSize);
    final manifestData = ByteData.sublistView(manifest);
    final formatVersion = manifest[0];
    final flags = manifest[1];
    if (formatVersion == 2) {
      if ((flags & _flagBootloader) != 0 || (flags & ~_knownFlags) != 0) {
        throw const BleMotaFormatException(
          'Application manifest has invalid flags',
        );
      }
    } else if (formatVersion == 3) {
      if (flags != _knownFlags) {
        throw const BleMotaFormatException(
          'Bootloader manifest must be full and signed',
        );
      }
    } else {
      throw BleMotaFormatException(
        'Unsupported mOTA format version $formatVersion',
      );
    }
    if (manifest[2] != _hashAlgorithmSha256) {
      throw BleMotaFormatException(
        'Unsupported hash algorithm 0x${manifest[2].toRadixString(16)}',
      );
    }

    final targetId = manifestData.getUint32(3, Endian.little);
    final firmwareVersion = manifestData.getUint32(7, Endian.little);
    final imageSize = manifestData.getUint32(11, Endian.little);
    final payloadSize = manifestData.getUint32(15, Endian.little);
    final blockSizeLog2 = manifest[19];
    final codecId = manifest[56];
    final isFull = (flags & _flagFull) != 0;
    final isSigned = (flags & _flagSigned) != 0;
    final isBootloader = (flags & _flagBootloader) != 0;

    if (payloadSize == 0 || blockSizeLog2 == 0 || blockSizeLog2 > 24) {
      throw const BleMotaFormatException('Invalid mOTA block geometry');
    }
    if (imageSize == 0) {
      throw const BleMotaFormatException('Image size cannot be zero');
    }
    if (isFull) {
      if (codecId != _codecFull || imageSize != payloadSize) {
        throw const BleMotaFormatException(
          'Full image has inconsistent codec or size',
        );
      }
    } else if (codecId != _codecDetoolsSequential &&
        codecId != _codecDetoolsInPlace) {
      throw const BleMotaFormatException('Delta image has an invalid codec');
    }

    final blockSize = 1 << blockSizeLog2;
    final blockCount = (payloadSize + blockSize - 1) ~/ blockSize;
    if (blockCount == 0 || blockCount > 0xFFFF) {
      throw const BleMotaFormatException('mOTA block count is out of range');
    }
    final leavesOffset = _headerSize + _fixedManifestSize;
    final payloadOffset = leavesOffset + blockCount * 4;
    final expectedSize = payloadOffset + payloadSize + _containerTrailer.length;
    if (expectedSize != size) {
      throw BleMotaFormatException(
        'Container geometry expects $expectedSize bytes, found $size',
      );
    }

    final baseHash = manifest.sublist(89, 97);
    if (isFull && !_allBytes(baseHash, 0)) {
      throw const BleMotaFormatException('Full image base hash must be zero');
    }
    if (!isFull && _allBytes(baseHash, 0)) {
      throw const BleMotaFormatException('Delta image has no base hash');
    }
    if (!_allBytes(manifest.sublist(193, 197), 0xFF)) {
      throw const BleMotaFormatException(
        'Distributed mOTA approval field is not erased',
      );
    }

    if (isBootloader &&
        (firmwareVersion == 0 ||
            codecId != _codecFull ||
            imageSize != 0xA000 ||
            payloadSize != 0xA000 ||
            blockSizeLog2 != 10 ||
            blockCount != 40)) {
      throw const BleMotaFormatException(
        'Bootloader container geometry is invalid',
      );
    }

    if (isSigned) {
      final publicKey = SimplePublicKey(
        manifest.sublist(97, 129),
        type: KeyPairType.ed25519,
      );
      final signature = Signature(
        manifest.sublist(129, 193),
        publicKey: publicKey,
      );
      final valid = await Ed25519().verify(
        manifest.sublist(0, _signedManifestSize),
        signature: signature,
      );
      if (!valid) {
        throw const BleMotaFormatException('Ed25519 signature is invalid');
      }
    } else if (!_allBytes(manifest.sublist(97, 193), 0)) {
      throw const BleMotaFormatException(
        'Unsigned mOTA has non-zero signer data',
      );
    }

    final storedLeaves = await _readExact(source, leavesOffset, blockCount * 4);
    final computedLeaves = <Uint8List>[];
    for (var index = 0; index < blockCount; index++) {
      final offset = payloadOffset + index * blockSize;
      final remaining = payloadSize - index * blockSize;
      final length = remaining < blockSize ? remaining : blockSize;
      final block = await _readExact(source, offset, length);
      final digest = crypto.sha256.convert(block).bytes;
      final leaf = Uint8List.fromList(digest.sublist(0, 4));
      final stored = storedLeaves.sublist(index * 4, index * 4 + 4);
      if (!_bytesEqual(leaf, stored)) {
        throw BleMotaFormatException(
          'Payload block $index does not match its mOTA leaf',
        );
      }
      computedLeaves.add(leaf);
    }

    final computedRoot = _merkleRoot(computedLeaves);
    if (!_bytesEqual(computedRoot, manifest.sublist(20, 24))) {
      throw const BleMotaFormatException('Merkle root does not match payload');
    }

    if (isFull) {
      final imageDigest = await crypto.sha256
          .bind(source.openRead(payloadOffset, payloadOffset + payloadSize))
          .first;
      if (!_bytesEqual(imageDigest.bytes, manifest.sublist(24, 56))) {
        throw const BleMotaFormatException(
          'Full image hash does not match payload',
        );
      }
    }

    final descriptor = Uint8List(bleMotaDescriptorSize);
    final descriptorData = ByteData.sublistView(descriptor);
    descriptor.setRange(0, 4, manifest, 20);
    descriptorData.setUint32(4, targetId, Endian.little);
    descriptorData.setUint32(8, firmwareVersion, Endian.little);
    descriptor[12] = codecId;
    descriptor[13] = flags;
    descriptorData.setUint32(14, size, Endian.little);
    descriptorData.setUint32(18, leavesOffset, Endian.little);
    descriptorData.setUint32(22, blockCount, Endian.little);
    descriptorData.setUint32(26, payloadOffset, Endian.little);
    descriptorData.setUint32(30, payloadSize, Endian.little);
    descriptor[34] = blockSizeLog2;

    return BleMotaFile._(
      source: source,
      name: source.name,
      size: size,
      flags: flags,
      targetId: targetId,
      firmwareVersion: firmwareVersion,
      imageSize: imageSize,
      payloadSize: payloadSize,
      blockSizeLog2: blockSizeLog2,
      blockCount: blockCount,
      codecId: codecId,
      leavesOffset: leavesOffset,
      payloadOffset: payloadOffset,
      hardwareId: _readHardwareId(manifest.sublist(57, 89)),
      descriptor: descriptor,
    );
  }

  Future<Uint8List> read(int offset, int length) async {
    if (offset < 0 || length < 0 || offset + length > size) {
      throw const BleMotaFormatException('Read is outside the mOTA container');
    }
    final currentSize = await source.length();
    if (currentSize != size) {
      throw const BleMotaFormatException(
        'mOTA file changed after it was validated',
      );
    }
    final result = await _readExact(source, offset, length);
    _recordSuccessfulRead(offset, length);
    return result;
  }

  void resetTransferMetrics() {
    readRequests = 0;
    bytesServed = 0;
    payloadReadRequests = 0;
    uniquePayloadBytesServed = 0;
    payloadBlocksServed = 0;
    firstPayloadReadAt = null;
    lastPayloadReadAt = null;
    for (var index = 0; index < _payloadCoverage.length; index++) {
      _payloadCoverage[index].clear();
      _payloadCoveredByBlock[index] = 0;
    }
  }

  void _recordSuccessfulRead(int offset, int length) {
    readRequests++;
    bytesServed += length;
    if (length == 0) return;

    final readStart = math.max(offset, payloadOffset);
    final readEnd = math.min(offset + length, payloadOffset + payloadSize);
    if (readStart >= readEnd) return;

    payloadReadRequests++;
    final now = DateTime.now();
    firstPayloadReadAt ??= now;
    lastPayloadReadAt = now;

    final blockSize = 1 << blockSizeLog2;
    final firstBlock = (readStart - payloadOffset) ~/ blockSize;
    final lastBlock = (readEnd - payloadOffset - 1) ~/ blockSize;
    for (var block = firstBlock; block <= lastBlock; block++) {
      final absoluteBlockStart = payloadOffset + block * blockSize;
      final blockLength = math.min(blockSize, payloadSize - block * blockSize);
      final localStart =
          math.max(readStart, absoluteBlockStart) - absoluteBlockStart;
      final localEnd =
          math.min(readEnd, absoluteBlockStart + blockLength) -
          absoluteBlockStart;
      final oldCovered = _payloadCoveredByBlock[block];
      final newCovered = _addCoveredRange(
        _payloadCoverage[block],
        localStart,
        localEnd,
      );
      _payloadCoveredByBlock[block] = newCovered;
      uniquePayloadBytesServed += newCovered - oldCovered;
      if (oldCovered < blockLength && newCovered == blockLength) {
        payloadBlocksServed++;
      }
    }
  }
}

class BleMotaCatalog {
  final List<BleMotaFile> files;
  int requestsHandled = 0;
  int bytesServed = 0;
  DateTime? lastRequestAt;
  String? lastRequestDescription;

  BleMotaCatalog._(List<BleMotaFile> files)
    : files = List<BleMotaFile>.unmodifiable(files);

  int get readRequests => files.fold(0, (sum, file) => sum + file.readRequests);
  int get payloadReadRequests =>
      files.fold(0, (sum, file) => sum + file.payloadReadRequests);
  int get uniquePayloadBytesServed =>
      files.fold(0, (sum, file) => sum + file.uniquePayloadBytesServed);

  void resetTransferMetrics() {
    requestsHandled = 0;
    bytesServed = 0;
    lastRequestAt = null;
    lastRequestDescription = null;
    for (final file in files) {
      file.resetTransferMetrics();
    }
  }

  static Future<BleMotaCatalog> load(
    List<XFile> sources, {
    void Function(int completed, int total)? onProgress,
  }) async {
    if (sources.isEmpty) {
      throw const BleMotaFormatException('Choose at least one .mota file');
    }
    if (sources.length > 255) {
      throw const BleMotaFormatException(
        'Bluetooth mOTA catalogs are limited to 255 files',
      );
    }

    final loaded = <BleMotaFile>[];
    final manifestIds = <String>{};
    for (var index = 0; index < sources.length; index++) {
      final source = sources[index];
      late final BleMotaFile file;
      try {
        file = await BleMotaFile.load(source);
      } on BleMotaFormatException catch (error) {
        throw BleMotaFormatException('${source.name}: ${error.message}');
      } on Exception catch (error) {
        throw BleMotaFormatException('${source.name}: $error');
      }
      if (!manifestIds.add(file.manifestId)) {
        throw BleMotaFormatException(
          '${source.name}: duplicate manifest ID ${file.manifestId}',
        );
      }
      loaded.add(file);
      onProgress?.call(index + 1, sources.length);
    }
    return BleMotaCatalog._(loaded);
  }

  Future<Uint8List?> handleRequest(Uint8List frame) async {
    if (frame.length < 4 || frame[0] != 0x4D || frame[1] != 0x53) {
      return null;
    }
    final operation = frame[2];
    final args = frame.sublist(3, frame.length - 1);
    if (frame.last != _xor(args, seed: operation)) {
      return null;
    }

    var status = _statusError;
    var payload = Uint8List(0);
    var description = 'invalid op 0x${operation.toRadixString(16)}';
    if (operation == _requestOpCount && args.isEmpty) {
      status = _statusOk;
      payload = Uint8List.fromList([files.length]);
      description = 'count ${files.length}';
    } else if (operation == _requestOpDescribe && args.length == 1) {
      final index = args[0];
      description = 'describe $index';
      if (index < files.length) {
        status = _statusOk;
        payload = files[index].descriptor;
      }
    } else if (operation == _requestOpRead && args.length == 7) {
      final index = args[0];
      final data = ByteData.sublistView(args);
      final offset = data.getUint32(1, Endian.little);
      final length = data.getUint16(5, Endian.little);
      description = 'read $index at $offset for $length';
      if (index < files.length && length <= bleMotaSeederReadMax) {
        try {
          payload = await files[index].read(offset, length);
          status = _statusOk;
        } on Exception {
          payload = Uint8List(0);
        }
      }
    }

    final response = BytesBuilder(copy: false)
      ..add(const <int>[0x6D, 0x73])
      ..add(<int>[operation, status])
      ..add(payload);
    final withoutChecksum = response.toBytes();
    final result = Uint8List(withoutChecksum.length + 1)
      ..setRange(0, withoutChecksum.length, withoutChecksum)
      ..last = _xor(withoutChecksum);

    requestsHandled++;
    if (status == _statusOk && operation == _requestOpRead) {
      bytesServed += payload.length;
    }
    lastRequestAt = DateTime.now();
    lastRequestDescription = description;
    return result;
  }
}

Future<Uint8List> _readExact(XFile source, int offset, int length) async {
  if (offset < 0 || length < 0) {
    throw const BleMotaFormatException('Invalid file read range');
  }
  final builder = BytesBuilder(copy: false);
  await for (final chunk in source.openRead(offset, offset + length)) {
    builder.add(chunk);
  }
  final result = builder.toBytes();
  if (result.length != length) {
    throw BleMotaFormatException(
      'Short read at $offset: expected $length bytes, got ${result.length}',
    );
  }
  return result;
}

Uint8List _merkleRoot(List<Uint8List> leaves) {
  if (leaves.isEmpty) {
    throw const BleMotaFormatException('mOTA payload has no leaves');
  }
  var level = leaves.map(Uint8List.fromList).toList(growable: false);
  while (level.length > 1) {
    final next = <Uint8List>[];
    for (var index = 0; index < level.length; index += 2) {
      if (index + 1 == level.length) {
        next.add(level[index]);
        continue;
      }
      final pair = Uint8List(8)
        ..setRange(0, 4, level[index])
        ..setRange(4, 8, level[index + 1]);
      next.add(
        Uint8List.fromList(crypto.sha256.convert(pair).bytes.sublist(0, 4)),
      );
    }
    level = next;
  }
  return level.single;
}

String _readHardwareId(List<int> bytes) {
  final nul = bytes.indexOf(0);
  final value = bytes.sublist(0, nul < 0 ? bytes.length : nul);
  if (value.any((byte) => byte < 0x20 || byte > 0x7E)) {
    throw const BleMotaFormatException('Hardware ID is not printable ASCII');
  }
  return ascii.decode(value);
}

bool _bytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

bool _allBytes(List<int> bytes, int expected) {
  for (final byte in bytes) {
    if (byte != expected) return false;
  }
  return true;
}

int _xor(Iterable<int> bytes, {int seed = 0}) {
  var result = seed;
  for (final byte in bytes) {
    result ^= byte;
  }
  return result;
}

String _hex(Iterable<int> bytes) {
  return bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();
}

class _ByteRange {
  final int start;
  final int end;

  const _ByteRange(this.start, this.end);
}

int _addCoveredRange(List<_ByteRange> ranges, int start, int end) {
  if (start >= end) {
    return ranges.fold(0, (sum, range) => sum + range.end - range.start);
  }
  ranges.add(_ByteRange(start, end));
  ranges.sort((left, right) => left.start.compareTo(right.start));
  final merged = <_ByteRange>[];
  for (final range in ranges) {
    if (merged.isEmpty || range.start > merged.last.end) {
      merged.add(range);
      continue;
    }
    final previous = merged.removeLast();
    merged.add(_ByteRange(previous.start, math.max(previous.end, range.end)));
  }
  ranges
    ..clear()
    ..addAll(merged);
  return ranges.fold(0, (sum, range) => sum + range.end - range.start);
}
