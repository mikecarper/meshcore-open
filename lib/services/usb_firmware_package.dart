import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;

/// A fail-closed validation result, safe to display without device secrets.
class UsbFirmwareValidationException implements Exception {
  const UsbFirmwareValidationException(this.message, {this.code});
  final String message;
  final String? code;
  @override
  String toString() => message;
}

Never usbReject(String message, {String? code}) =>
    throw UsbFirmwareValidationException(message, code: code);

String usbSha256(List<int> bytes) => crypto.sha256.convert(bytes).toString();

bool usbBytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}

int usbUint16(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes).getUint16(offset, Endian.little);
int usbUint32(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes).getUint32(offset, Endian.little);

/// Python/zlib compatible CRC32; NVS and OTA use an explicit FFFFFFFF seed.
int usbCrc32(List<int> bytes, [int seed = 0]) {
  var crc = seed ^ 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc >>> 1) ^ ((crc & 1) != 0 ? 0xedb88320 : 0);
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

class UsbEspImageHeader {
  const UsbEspImageHeader(this.chip, this.flashBytes);
  final int chip;
  final int flashBytes;

  static UsbEspImageHeader parse(Uint8List image) {
    if (image.length < 32 ||
        image[0] != 0xe9 ||
        image[1] < 1 ||
        image[1] > 16 ||
        image[2] > 3 ||
        image[23] > 1 ||
        image[3] >> 4 > 7) {
      usbReject('A valid ESP32 application-only BIN is required.');
    }
    return UsbEspImageHeader(usbUint16(image, 12), 1 << (20 + (image[3] >> 4)));
  }
}

class UsbEndfIdentity {
  const UsbEndfIdentity(this.version, this.targetId, this.hardwareId);
  final int version;
  final int targetId;
  final String hardwareId;

  static UsbEndfIdentity? inspect(Uint8List image) {
    if (image.length < 56 ||
        !usbBytesEqual(
          image.sublist(image.length - 56, image.length - 52),
          ascii.encode('EndF'),
        )) {
      return null;
    }
    final trailer = Uint8List.sublistView(image, image.length - 56);
    if (usbUint32(trailer, 4) != image.length - 56 ||
        !usbBytesEqual(
          trailer.sublist(8, 16),
          crypto.sha256
              .convert(image.sublist(0, image.length - 56))
              .bytes
              .sublist(0, 8),
        )) {
      usbReject('MeshCore EndF firmware identity checksum failed.');
    }
    final version = usbUint32(trailer, 16);
    final target = usbUint32(trailer, 20);
    var end = 56;
    while (end > 24 && trailer[end - 1] == 0) {
      end--;
    }
    final hardware = _ascii(trailer.sublist(24, end));
    if (version == 0 ||
        target == 0 ||
        !RegExp(r'^[A-Za-z0-9_-]{1,32}$').hasMatch(hardware)) {
      usbReject('MeshCore EndF hardware identity is invalid.');
    }
    return UsbEndfIdentity(version, target, hardware);
  }
}

class UsbFirmwareRelease {
  const UsbFirmwareRelease(this.version, this.sourceCommit);
  final String version;
  final String sourceCommit;
  static UsbFirmwareRelease? fromFilename(String name) {
    final match = RegExp(
      r'(?:^|[-_])(v\d+(?:\.\d+){2,3}-[A-Za-z0-9][A-Za-z0-9._-]*?)-([0-9a-f]{8,40})\.bin$',
    ).firstMatch(name);
    return match == null ? null : UsbFirmwareRelease(match[1]!, match[2]!);
  }

  static int numericVersion(String version) {
    final match = RegExp(r'^v(\d+(?:\.\d+){2,3})(?:-|$)').firstMatch(version);
    if (match == null) usbReject('Migration firmware version is invalid.');
    final numbers = match[1]!.split('.').map(int.parse).toList();
    while (numbers.length < 4) {
      numbers.add(0);
    }
    if (numbers.any((n) => n > 255)) {
      usbReject('Migration firmware version exceeds the EndF range.');
    }
    return (numbers[0] << 24) |
        (numbers[1] << 16) |
        (numbers[2] << 8) |
        numbers[3];
  }
}

/// Immutable ESP application image. ZIP/UF2/merged images are not treated as
/// application-only BINs. An absent EndF is allowed for ordinary updates only.
class UsbFirmwareImage {
  UsbFirmwareImage._(
    this.name,
    this.bytes,
    this.header,
    this.endf,
    this.release,
    this.sha256,
  );
  factory UsbFirmwareImage.fromBytes(String name, Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > UsbVerifiedPackage.maxArchiveBytes) {
      usbReject('The selected firmware is empty or too large.');
    }
    if (!name.toLowerCase().endsWith('.bin') ||
        name.toLowerCase().endsWith('-merged.bin')) {
      usbReject(
        'Select an application-only ESP32 BIN, not a merged flash image.',
      );
    }
    final frozen = Uint8List.fromList(bytes).asUnmodifiableView();
    final header = UsbEspImageHeader.parse(frozen);
    final endf = UsbEndfIdentity.inspect(frozen);
    _verifyEspSegments(frozen, endf != null);
    return UsbFirmwareImage._(
      name,
      frozen,
      header,
      endf,
      UsbFirmwareRelease.fromFilename(name),
      usbSha256(frozen),
    );
  }
  final String name;
  final Uint8List bytes;
  final UsbEspImageHeader header;
  final UsbEndfIdentity? endf;
  final UsbFirmwareRelease? release;
  final String sha256;
  int get chip => header.chip;
  int get declaredFlashBytes => header.flashBytes;
}

void _verifyEspSegments(Uint8List image, bool hasEndf) {
  var cursor = 24;
  var checksum = 0xef;
  for (var segment = 0; segment < image[1]; segment++) {
    if (cursor + 8 > image.length) {
      usbReject('ESP32 image segment is truncated.');
    }
    final length = usbUint32(image, cursor + 4);
    cursor += 8;
    if (length > 16 * 1024 * 1024 || cursor + length > image.length) {
      usbReject('ESP32 image segment geometry is invalid.');
    }
    for (var i = cursor; i < cursor + length; i++) {
      checksum ^= image[i];
    }
    cursor += length;
  }
  final checksumOffset = ((cursor ~/ 16) + 1) * 16 - 1;
  if (checksumOffset >= image.length || image[checksumOffset] != checksum) {
    usbReject('ESP32 application checksum failed.');
  }
  for (var i = cursor; i < checksumOffset; i++) {
    if (image[i] != 0) usbReject('ESP32 image padding is malformed.');
  }
  cursor = checksumOffset + 1;
  if (image[23] == 1) {
    if (cursor + 32 > image.length ||
        !usbBytesEqual(
          image.sublist(cursor, cursor + 32),
          crypto.sha256.convert(image.sublist(0, cursor)).bytes,
        )) {
      usbReject('ESP32 application appended SHA-256 failed.');
    }
    cursor += 32;
  }
  if (cursor != image.length - (hasEndf ? 56 : 0)) {
    usbReject(
      'ESP32 BIN contains trailing or merged data, not one application.',
    );
  }
}

/// Verified utility archive. Only flat reviewed names are accepted. ZIP64,
/// encrypted, multi-disk, links and duplicate entries are refused before
/// inflation. Deflate output is bounded before allocation grows unbounded.
class UsbVerifiedPackage {
  UsbVerifiedPackage._(this.manifest, this.files, this.sha256);
  static const maxArchiveBytes = 32 * 1024 * 1024;
  static const maxMetadataBytes = 1024 * 1024;
  final Map<String, dynamic> manifest;
  final Map<String, Uint8List> files;
  final String sha256;

  factory UsbVerifiedPackage.fromZip(Uint8List zip, {bool usbOnly = false}) {
    final files = checkedZipEntries(zip);
    if (files.length < 4) usbReject('Migration archive inventory is invalid.');
    final rawManifest = files['manifest.json'];
    if (rawManifest == null || rawManifest.length > maxMetadataBytes) {
      usbReject('Migration archive has no usable manifest.');
    }
    final manifest = usbStrictJson(rawManifest);
    if (manifest is! Map<String, dynamic> || manifest['files'] is! Map) {
      usbReject('Migration manifest file inventory is invalid.');
    }
    final inventory = manifest['files'] as Map;
    if (!_sameKeys(files.keys.toSet(), {
      ...inventory.keys,
      'manifest.json',
      'SHA256SUMS.txt',
    })) {
      usbReject('Migration archive and manifest inventories differ.');
    }
    for (final entry in inventory.entries) {
      final record = entry.value;
      final bytes = files[entry.key];
      if (record is! Map ||
          bytes == null ||
          record['bytes'] is! int ||
          record['bytes'] != bytes.length ||
          record['sha256'] != usbSha256(bytes)) {
        usbReject('Migration file size or SHA-256 verification failed.');
      }
    }
    final required = usbOnly
        ? {'README.md'}
        : {
            'wifi-bridge.bin',
            'target-partitions.bin',
            'full-application.bin',
            'capabilities.json',
          };
    if (!inventory.keys.toSet().containsAll(required)) {
      usbReject(
        'Migration archive is missing required application/bridge metadata.',
      );
    }
    final sumsBytes = files['SHA256SUMS.txt'];
    if (sumsBytes == null || sumsBytes.length > maxMetadataBytes) {
      usbReject('Migration checksum inventory is invalid.');
    }
    final sums = <String, String>{};
    for (final line in const LineSplitter().convert(_ascii(sumsBytes))) {
      final match = RegExp(
        r'^([0-9a-f]{64})  ([A-Za-z0-9_.-]+)$',
      ).firstMatch(line);
      if (match == null || sums.containsKey(match[2])) {
        usbReject('Migration archive checksum inventory is invalid.');
      }
      sums[match[2]!] = match[1]!;
    }
    if (!_sameKeys(
          sums.keys.toSet(),
          files.keys.where((name) => name != 'SHA256SUMS.txt').toSet(),
        ) ||
        sums.entries.any(
          (entry) => usbSha256(files[entry.key]!) != entry.value,
        )) {
      usbReject('Migration checksum inventory does not match its files.');
    }
    return UsbVerifiedPackage._(
      Map<String, dynamic>.unmodifiable(manifest),
      Map<String, Uint8List>.unmodifiable(files),
      usbSha256(zip),
    );
  }
}

bool _sameKeys(Set<Object?> a, Set<Object?> b) =>
    a.length == b.length && a.containsAll(b);

String _ascii(List<int> bytes) {
  if (bytes.any((byte) => byte > 127)) {
    usbReject('Metadata contains invalid ASCII.');
  }
  return String.fromCharCodes(bytes);
}

Map<String, Uint8List> checkedZipEntries(
  Uint8List zip, {
  int maxArchiveBytes = UsbVerifiedPackage.maxArchiveBytes,
  int maxExpandedBytes = UsbVerifiedPackage.maxArchiveBytes,
  int maxEntries = 32,
}) {
  if (maxArchiveBytes <= 0 ||
      maxExpandedBytes <= 0 ||
      maxEntries <= 0 ||
      zip.length < 22 ||
      zip.length > maxArchiveBytes) {
    usbReject('Migration archive size is invalid.');
  }
  var eocd = -1;
  for (var i = zip.length - 22; i >= 0 && i >= zip.length - 65557; i--) {
    if (usbUint32(zip, i) == 0x06054b50 &&
        i + 22 + usbUint16(zip, i + 20) == zip.length) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0 ||
      usbUint16(zip, eocd + 4) != 0 ||
      usbUint16(zip, eocd + 6) != 0) {
    usbReject('Multi-disk or incomplete migration ZIP is unsupported.');
  }
  final count = usbUint16(zip, eocd + 10);
  final centralSize = usbUint32(zip, eocd + 12);
  final centralStart = usbUint32(zip, eocd + 16);
  if (count < 1 ||
      count > maxEntries ||
      count != usbUint16(zip, eocd + 8) ||
      centralStart + centralSize != eocd) {
    usbReject('Migration archive inventory is invalid.');
  }
  final result = <String, Uint8List>{};
  final ranges = <(int, int)>[];
  var cursor = centralStart;
  var expandedTotal = 0;
  try {
    for (var index = 0; index < count; index++) {
      if (cursor + 46 > eocd || usbUint32(zip, cursor) != 0x02014b50) {
        usbReject('Migration ZIP central directory is invalid.');
      }
      final flags = usbUint16(zip, cursor + 8);
      final method = usbUint16(zip, cursor + 10);
      final crc = usbUint32(zip, cursor + 16);
      final compressed = usbUint32(zip, cursor + 20);
      final expanded = usbUint32(zip, cursor + 24);
      final nameLength = usbUint16(zip, cursor + 28);
      final extraLength = usbUint16(zip, cursor + 30);
      final commentLength = usbUint16(zip, cursor + 32);
      final mode = usbUint32(zip, cursor + 38) >> 16;
      final local = usbUint32(zip, cursor + 42);
      final next = cursor + 46 + nameLength + extraLength + commentLength;
      if (next > eocd ||
          nameLength == 0 ||
          nameLength > 100 ||
          flags & ~0x0808 != 0 ||
          (method != 0 && method != 8) ||
          usbUint16(zip, cursor + 34) != 0 ||
          (mode & 0xf000) == 0xa000 ||
          expanded <= 0 ||
          expanded > maxExpandedBytes ||
          compressed > maxArchiveBytes ||
          local + 30 > centralStart) {
        usbReject('Migration ZIP has unsafe or unsupported entries.');
      }
      expandedTotal += expanded;
      if (expandedTotal > maxExpandedBytes) {
        usbReject('Migration archive expanded size exceeds its limit.');
      }
      final nameBytes = zip.sublist(cursor + 46, cursor + 46 + nameLength);
      final name = _ascii(nameBytes);
      if (!RegExp(r'^[A-Za-z0-9_.-]{1,100}$').hasMatch(name) ||
          name == '.' ||
          name == '..' ||
          result.containsKey(name)) {
        usbReject('Migration ZIP has unsafe paths or duplicate names.');
      }
      if (usbUint32(zip, local) != 0x04034b50 ||
          usbUint16(zip, local + 6) != flags ||
          usbUint16(zip, local + 8) != method ||
          usbUint16(zip, local + 26) != nameLength) {
        usbReject('Migration ZIP local and central headers differ.');
      }
      final start = local + 30 + nameLength + usbUint16(zip, local + 28);
      final end = start + compressed;
      if (end > centralStart ||
          !usbBytesEqual(
            zip.sublist(local + 30, local + 30 + nameLength),
            nameBytes,
          ) ||
          ranges.any((r) => local < r.$2 && end > r.$1)) {
        usbReject('Migration ZIP data ranges are invalid or overlapping.');
      }
      if ((flags & 8) == 0 &&
          (usbUint32(zip, local + 14) != crc ||
              usbUint32(zip, local + 18) != compressed ||
              usbUint32(zip, local + 22) != expanded)) {
        usbReject('Migration ZIP local sizes/checksum differ.');
      }
      ranges.add((local, end));
      final compressedBytes = Uint8List.sublistView(zip, start, end);
      final bytes = method == 0
          ? Uint8List.fromList(compressedBytes)
          : Inflate(
              compressedBytes,
              output: _BoundedInflateOutput(expanded),
            ).getBytes();
      if (bytes.length != expanded || usbCrc32(bytes) != crc) {
        usbReject('Migration ZIP entry CRC or size verification failed.');
      }
      result[name] = bytes.asUnmodifiableView();
      cursor = next;
    }
    if (cursor != eocd) {
      usbReject('Migration ZIP inventory has trailing entries.');
    }
  } on UsbFirmwareValidationException {
    rethrow;
  } catch (_) {
    usbReject('Migration archive integrity verification failed.');
  }
  return result;
}

/// Use the exported Dart inflater with a hard output ceiling. archive 4.3's
/// native decodeStream collects all chunks before handing them to an output
/// sink, so merely checking its output after decoding is not memory-bounded.
class _BoundedInflateOutput extends OutputMemoryStream {
  _BoundedInflateOutput(this.limit) : super(size: limit);
  final int limit;
  void _check(int additional) {
    if (additional < 0 || length + additional > limit) {
      usbReject('Migration ZIP inflation exceeded its declared size.');
    }
  }

  @override
  void writeByte(int value) {
    _check(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _check(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _check(stream.length);
    super.writeStream(stream);
  }

  @override
  void writeBackReference(int distance, int count) {
    _check(count);
    super.writeBackReference(distance, count);
  }
}

/// JSON decoding with duplicate-key and depth checks (jsonDecode alone loses
/// duplicate fields before a reviver can examine them).
dynamic usbStrictJson(Uint8List bytes) {
  if (bytes.length > UsbVerifiedPackage.maxMetadataBytes) {
    usbReject('Migration JSON exceeds its permitted size.');
  }
  try {
    return _UniqueJsonParser(utf8.decode(bytes)).parse();
  } on UsbFirmwareValidationException {
    rethrow;
  } catch (_) {
    usbReject('Invalid partition expansion JSON metadata.');
  }
}

class _UniqueJsonParser {
  _UniqueJsonParser(this.source);
  final String source;
  var cursor = 0;
  dynamic parse() {
    final value = _value(0);
    _space();
    if (cursor != source.length) {
      usbReject('Invalid migration JSON trailing data.');
    }
    return value;
  }

  void _space() {
    while (cursor < source.length &&
        const [' ', '\r', '\n', '\t'].contains(source[cursor])) {
      cursor++;
    }
  }

  dynamic _value(int depth) {
    _space();
    if (depth > 64 || cursor >= source.length) {
      usbReject('Invalid migration JSON.');
    }
    final c = source[cursor];
    if (c == '"') return _string();
    if (c == '{') {
      cursor++;
      final map = <String, dynamic>{};
      _space();
      if (_eat('}')) return map;
      while (true) {
        _space();
        final key = _string();
        if (map.containsKey(key)) {
          usbReject('Duplicate key in migration metadata.');
        }
        _space();
        if (!_eat(':')) usbReject('Invalid migration JSON object.');
        map[key] = _value(depth + 1);
        _space();
        if (_eat('}')) return map;
        if (!_eat(',')) usbReject('Invalid migration JSON object.');
      }
    }
    if (c == '[') {
      cursor++;
      final list = <dynamic>[];
      _space();
      if (_eat(']')) return list;
      while (true) {
        list.add(_value(depth + 1));
        _space();
        if (_eat(']')) return list;
        if (!_eat(',')) usbReject('Invalid migration JSON array.');
      }
    }
    for (final literal in ['true', 'false', 'null']) {
      if (source.startsWith(literal, cursor)) {
        cursor += literal.length;
        return jsonDecode(literal);
      }
    }
    final number = RegExp(
      r'-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?',
    ).matchAsPrefix(source, cursor);
    if (number == null) usbReject('Invalid migration JSON value.');
    cursor = number.end;
    final value = jsonDecode(number[0]!);
    if (value is double && !value.isFinite) {
      usbReject('Invalid migration JSON number.');
    }
    return value;
  }

  bool _eat(String value) {
    if (cursor < source.length && source[cursor] == value) {
      cursor++;
      return true;
    }
    return false;
  }

  String _string() {
    if (cursor >= source.length || source[cursor] != '"') {
      usbReject('Invalid migration JSON string.');
    }
    final start = cursor++;
    var escaped = false;
    while (cursor < source.length) {
      final c = source[cursor++];
      if (c == '"' && !escaped) {
        return jsonDecode(source.substring(start, cursor)) as String;
      }
      escaped = c == '\\' && !escaped;
    }
    usbReject('Unterminated migration JSON string.');
  }
}
