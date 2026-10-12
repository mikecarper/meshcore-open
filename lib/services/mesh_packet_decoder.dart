import 'dart:convert';
import 'dart:typed_data';

String packetHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

Uint8List packetHexBytes(String text) {
  final value = text
      .trim()
      .replaceAll(RegExp(r'0x', caseSensitive: false), '')
      .replaceAll(RegExp(r'[\s:,_-]'), '')
      .replaceAll(RegExp(r'''^["']|["',;]$'''), '');
  if (value.isEmpty ||
      value.length.isOdd ||
      !RegExp(r'^[0-9a-f]+$', caseSensitive: false).hasMatch(value)) {
    throw const FormatException('Enter complete hexadecimal bytes.');
  }
  return Uint8List.fromList([
    for (var i = 0; i < value.length; i += 2)
      int.parse(value.substring(i, i + 2), radix: 16),
  ]);
}

/// Accept analyzer/MQTT JSON, quoted raw fields, and one hex packet per line.
/// Input is bounded before parsing, including when used without a radio.
List<Uint8List> packetInputBytes(String input) {
  if (input.length > 32768) {
    throw const FormatException('Input exceeds 32 KiB. Import fewer packets.');
  }
  final text = input
      .trim()
      .replaceAll(RegExp(r'^```(?:text|json)?\s*'), '')
      .replaceAll(RegExp(r'```\s*$'), '');
  final candidates = <String>[];
  void collect(Object? value, [int depth = 0]) {
    if (depth > 8) return;
    if (value is List) {
      for (final item in value.take(100)) {
        collect(item, depth + 1);
      }
    } else if (value is Map) {
      for (final key in [
        'raw',
        'raw_hex',
        'raw_data',
        'packet',
        'data',
        'packets',
        'payload',
      ]) {
        if (value.containsKey(key)) {
          final item = value[key];
          if (item is String) {
            candidates.add(item);
          } else {
            collect(item, depth + 1);
          }
        }
      }
    }
  }

  try {
    collect(jsonDecode(text));
  } on FormatException {
    /* Not JSON. */
  }
  if (candidates.isEmpty) {
    final fields = RegExp(
      r'''["'](?:raw|data|raw_hex)["']\s*:\s*["']([^"']+)["']''',
    );
    candidates.addAll(fields.allMatches(text).map((m) => m[1]!));
  }
  if (candidates.isEmpty) {
    final lines = text
        .split(RegExp(r'\r?\n'))
        .where((s) => s.trim().isNotEmpty)
        .toList();
    bool complete(String line) {
      try {
        final bytes = packetHexBytes(line);
        if ([
          'TTB1',
          'TVB1',
          'IVB1',
          'MGR1',
        ].contains(packetAscii(bytes, 0, 4))) {
          return true;
        }
        decodeMeshPacket(bytes);
        return true;
      } on FormatException {
        return false;
      }
    }

    if (lines.length > 1 && lines.every(complete)) candidates.addAll(lines);
  }
  if (candidates.isEmpty) {
    // Wrapped hex is one value unless every line is itself a complete packet.
    try {
      packetHexBytes(text);
      candidates.add(text);
    } on FormatException {
      candidates.addAll(text.split(RegExp(r'\r?\n')));
    }
  }
  final unique = <String, Uint8List>{};
  if (candidates.length > 100) {
    throw const FormatException('Import at most 100 packets at a time.');
  }
  for (final candidate in candidates) {
    try {
      final bytes = packetHexBytes(candidate);
      if (bytes.length >= 2 && bytes.length <= 512) {
        unique[packetHex(bytes)] = bytes;
      }
    } on FormatException {
      /* Ignore command lines and JSON wrappers. */
    }
  }
  if (unique.isEmpty) {
    throw const FormatException('No complete packet hex found.');
  }
  return unique.values.toList();
}

class DecodedMeshPacket {
  const DecodedMeshPacket({
    required this.header,
    required this.pathWidth,
    required this.path,
    required this.payload,
    required this.transport,
  });
  final int header;
  final int pathWidth;
  final Uint8List path;
  final Uint8List payload;
  final Uint8List transport;
  int get version => (header >> 6) + 1;
  int get payloadType => (header >> 2) & 15;
  int get hops => path.length ~/ pathWidth;
  String get route =>
      ['Transport flood', 'Flood', 'Direct', 'Transport direct'][header & 3];
  String get typeName =>
      const {
        0: 'Request',
        1: 'Response',
        2: 'Direct text',
        3: 'Acknowledgement',
        4: 'Advertisement',
        5: 'Channel text',
        6: 'Group data',
        7: 'Anonymous request',
        8: 'Path',
        9: 'Trace',
        10: 'Multipart',
        11: 'Control',
        15: 'Raw custom',
      }[payloadType] ??
      'Unknown ($payloadType)';
  String get pathText => path.isEmpty
      ? 'Direct / no hops'
      : [
          for (var i = 0; i < path.length; i += pathWidth)
            packetHex(path.sublist(i, i + pathWidth)),
        ].join(', ');
}

DecodedMeshPacket decodeMeshPacket(Uint8List bytes) {
  if (bytes.length < 2 || bytes.length > 512) {
    throw const FormatException(
      'Packet header is missing or packet is too large.',
    );
  }
  final route = bytes[0] & 3;
  final pathOffset = route == 0 || route == 3 ? 5 : 1;
  if (pathOffset >= bytes.length) {
    throw const FormatException('Transport header is truncated.');
  }
  final width = (bytes[pathOffset] >> 6) + 1;
  final length = (bytes[pathOffset] & 63) * width;
  final payloadOffset = pathOffset + 1 + length;
  if (width > 3 || length > 64 || payloadOffset >= bytes.length) {
    throw const FormatException(
      'Invalid path width, hop count, or truncated payload.',
    );
  }
  return DecodedMeshPacket(
    header: bytes[0],
    pathWidth: width,
    path: bytes.sublist(pathOffset + 1, payloadOffset),
    payload: bytes.sublist(payloadOffset),
    transport: bytes.sublist(1, pathOffset),
  );
}

int packetUint16(List<int> bytes, int at) => bytes[at] | bytes[at + 1] << 8;
int packetUint32(List<int> bytes, int at) =>
    bytes[at] | bytes[at + 1] << 8 | bytes[at + 2] << 16 | bytes[at + 3] << 24;
String packetAscii(List<int> bytes, int at, int length) =>
    String.fromCharCodes(bytes.skip(at).take(length));
int packetBits(List<int> bytes, int byteOffset, int bitOffset, int width) {
  var result = 0;
  for (var i = 0; i < width; i++) {
    final bit = byteOffset * 8 + bitOffset + i;
    result = (result << 1) | ((bytes[bit ~/ 8] >> (7 - bit % 8)) & 1);
  }
  return result;
}
