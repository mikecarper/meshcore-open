import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'mesh_packet_decoder.dart';

class TelemetrySample {
  const TelemetrySample(this.epoch, this.status, this.value, this.raw);
  final int epoch;
  final String status;
  final String value;
  final String raw;
  String get utc => DateTime.fromMillisecondsSinceEpoch(
    epoch * 1000,
    isUtc: true,
  ).toIso8601String();
}

class DecodedTelemetry {
  const DecodedTelemetry({
    required this.kind,
    required this.interval,
    required this.samples,
    this.source,
    this.channel,
    this.packet,
    this.warnings = const [],
  });
  final String kind;
  final int interval;
  final String? source;
  final int? channel;
  final DecodedMeshPacket? packet;
  final List<TelemetrySample> samples;
  final List<String> warnings;
  String get csv => [
    'timestamp_utc,type,source,channel,status,value,raw_code',
    for (final row in samples)
      [
        row.utc,
        kind,
        source ?? '',
        channel?.toString() ?? '',
        row.status,
        row.value,
        row.raw,
      ].map((s) => '"${s.replaceAll('"', '""')}"').join(','),
  ].join('\n');
}

DecodedTelemetry decodeTelemetry(String input) {
  if (input.length > 32768) {
    throw const FormatException('Input exceeds 32 KiB.');
  }
  List<Uint8List>? packets;
  try {
    packets = packetInputBytes(input);
  } on FormatException {
    /* CLI Base64 instead. */
  }
  final decoded = <DecodedTelemetry>[];
  if (packets != null) {
    for (final bytes in packets) {
      final magic = packetAscii(bytes, 0, 4);
      if (['TTB1', 'TVB1', 'IVB1'].contains(magic)) {
        decoded.add(_binary(bytes, null));
      } else {
        final packet = decodeMeshPacket(bytes);
        if (packet.payloadType != 15 || packet.version != 1) {
          throw const FormatException(
            'Expected a version 1 RAW_CUSTOM telemetry packet.',
          );
        }
        decoded.add(_binary(packet.payload, packet));
      }
    }
  } else {
    final lines = input
        .trim()
        .split(RegExp(r'\r?\n'))
        .map((s) => s.trim())
        .where(
          (s) => s.isNotEmpty && !s.startsWith('get ') && !s.startsWith('```'),
        );
    for (var line in lines) {
      line = line.replaceFirst(RegExp(r'^>\s*'), '');
      if (!RegExp(
        r'^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$',
      ).hasMatch(line)) {
        throw const FormatException(
          'Copy complete padded CLI Base64 replies or raw packet hex.',
        );
      }
      final bytes = base64Decode(line);
      if (base64Encode(bytes) != line) {
        throw const FormatException('Noncanonical Base64 reply.');
      }
      decoded.add(_cli(bytes));
    }
  }
  if (decoded.isEmpty) {
    throw const FormatException('Paste telemetry data first.');
  }
  final first = decoded.first;
  final rows = <int, TelemetrySample>{};
  final warnings = <String>{};
  for (final item in decoded) {
    if (item.kind != first.kind ||
        item.source != first.source ||
        item.channel != first.channel ||
        item.interval != first.interval) {
      throw const FormatException(
        'Pages must have the same type, source, channel, and interval.',
      );
    }
    warnings.addAll(item.warnings);
    for (final row in item.samples) {
      final old = rows[row.epoch];
      if (old != null && (old.value != row.value || old.status != row.status)) {
        throw const FormatException(
          'Conflicting samples at the same timestamp.',
        );
      }
      rows[row.epoch] = row;
      if (rows.length > 4096) {
        throw const FormatException(
          'Import at most 4096 telemetry samples at a time.',
        );
      }
    }
  }
  return DecodedTelemetry(
    kind: first.kind,
    source: first.source,
    channel: first.channel,
    interval: first.interval,
    packet: decoded.length == 1 ? first.packet : null,
    samples: rows.values.toList()..sort((a, b) => a.epoch.compareTo(b.epoch)),
    warnings: warnings.toList(),
  );
}

TelemetrySample _valueSample(
  int epoch,
  int code,
  String kind, {
  int? tempStatus,
}) {
  if (kind == 'Temperature') {
    final status =
        tempStatus ??
        (code == 0
            ? 0
            : code == 1
            ? 2
            : code == 2
            ? 3
            : code <= 130
            ? 1
            : 4);
    final value = tempStatus == null ? code - 53 : code - 50;
    return TelemetrySample(
      epoch,
      [
        'Missing',
        'Value',
        'Below range',
        'Above range',
        'Reserved code',
      ][status],
      status == 1
          ? '$value C'
          : status == 2
          ? '< -50 C'
          : status == 3
          ? '> 77 C'
          : '',
      tempStatus == null ? '$code' : '$tempStatus / $code',
    );
  }
  final external = kind == 'I2C voltage';
  final status = code == 0
      ? 'Missing'
      : !external && code == 1
      ? 'Below range'
      : !external && code == 255
      ? 'Above range'
      : 'Value';
  final mv = external ? code * 20 : 1880 + (code - 2) * 10;
  return TelemetrySample(
    epoch,
    status,
    status == 'Value'
        ? '${(mv / 1000).toStringAsFixed(2)} V'
        : status == 'Below range'
        ? '< 1.88 V'
        : status == 'Above range'
        ? '> 4.40 V'
        : '',
    '$code',
  );
}

DecodedTelemetry _binary(Uint8List bytes, DecodedMeshPacket? packet) {
  final magic = packetAscii(bytes, 0, 4);
  if (!['TTB1', 'TVB1', 'IVB1'].contains(magic)) {
    throw const FormatException('No TTB1, TVB1, or IVB1 snapshot found.');
  }
  final external = magic == 'IVB1';
  final header = external ? 20 : 19;
  if (bytes.length < header) {
    throw const FormatException('Telemetry header is truncated.');
  }
  final count = bytes[header - 1];
  final interval = packetUint16(bytes, 16);
  if (count < 1 || count > (external ? 64 : 165) || interval == 0) {
    throw const FormatException('Invalid telemetry sample count or interval.');
  }
  final length = header + (external ? (count * 15 + 7) ~/ 8 : count);
  if (bytes.length < length) {
    throw const FormatException('Telemetry samples are truncated.');
  }
  if (external && bytes[18] == 0) {
    throw const FormatException('I2C channel cannot be zero.');
  }
  final kind = magic == 'TTB1'
      ? 'Temperature'
      : external
      ? 'I2C voltage'
      : 'Battery voltage';
  final epoch = packetUint32(bytes, 12);
  return DecodedTelemetry(
    kind: kind,
    interval: interval,
    source: packetHex(bytes.sublist(4, 12)),
    channel: external ? bytes[18] : null,
    packet: packet,
    warnings: [
      if (bytes.length > length)
        '${bytes.length - length} trailing bytes ignored.',
    ],
    samples: [
      for (var i = 0; i < count; i++)
        _valueSample(
          epoch + i * interval * 60,
          external ? packetBits(bytes, header, i * 15, 15) : bytes[header + i],
          kind,
        ),
    ],
  );
}

DecodedTelemetry _cli(Uint8List bytes) {
  if (bytes.length < 7) {
    throw const FormatException('CLI telemetry header is truncated.');
  }
  final type = bytes[0];
  final count = bytes[6];
  final interval = bytes[5];
  if (interval == 0 || count == 0 || count > (type == 0x13 ? 24 : 48)) {
    throw const FormatException('Invalid CLI sample count or interval.');
  }
  final epoch = packetUint32(bytes, 1);
  if (type == 0x13) return _gps(bytes, epoch, interval, count);
  final kind = type == 0x11
      ? 'Temperature'
      : type == 0x12
      ? 'Battery voltage'
      : type == 0x14
      ? 'I2C voltage'
      : null;
  if (kind == null) {
    throw const FormatException('Unsupported CLI telemetry type.');
  }
  final statusLength = (count * 2 + 7) ~/ 8;
  final expected = type == 0x11
      ? 7 + statusLength + (count * 7 + 7) ~/ 8
      : type == 0x14
      ? 8 + (count * 15 + 7) ~/ 8
      : 7 + count;
  if (bytes.length != expected) {
    throw const FormatException(
      'CLI sample count does not match payload length.',
    );
  }
  if (type == 0x14 && bytes[7] == 0) {
    throw const FormatException('I2C channel cannot be zero.');
  }
  return DecodedTelemetry(
    kind: kind,
    interval: interval,
    channel: type == 0x14 ? bytes[7] : null,
    samples: [
      for (var i = 0; i < count; i++)
        _valueSample(
          epoch + i * interval * 60,
          type == 0x11
              ? packetBits(bytes, 7 + statusLength, i * 7, 7)
              : type == 0x14
              ? packetBits(bytes, 8, i * 15, 15)
              : bytes[7 + i],
          kind,
          tempStatus: type == 0x11 ? packetBits(bytes, 7, i * 2, 2) : null,
        ),
    ],
  );
}

DecodedTelemetry _gps(Uint8List bytes, int epoch, int interval, int count) {
  if (bytes.length != 17 + (count * 28 + 7) ~/ 8) {
    throw const FormatException('GPS payload length is invalid.');
  }
  int signed32(int at) {
    final v = packetUint32(bytes, at);
    return v > 0x7fffffff ? v - 0x100000000 : v;
  }

  int signed14(int v) => v & 0x2000 != 0 ? v - 0x4000 : v;
  var lat = signed32(7) / 1e7;
  var lon = signed32(11) / 1e7;
  final origin = bytes[15];
  if (origin != 255 && origin >= count) {
    throw const FormatException('GPS origin is outside page.');
  }
  final warnings = <String>[
    if (bytes[16] & 1 != 0)
      'GPS differentials were clipped; subsequent positions may be inaccurate.',
    if (bytes[16] & 254 != 0) 'GPS flags contain unknown bits.',
    if (origin != 255)
      'Zero differentials after the origin are ambiguous, not proof of a fix.',
    if (lat.abs() > 90 || lon.abs() > 180)
      'GPS origin is outside valid coordinate ranges.',
  ];
  final rows = <TelemetrySample>[];
  for (var i = 0; i < count; i++) {
    final n = signed14(packetBits(bytes, 17, i * 28, 14));
    final e = signed14(packetBits(bytes, 17, i * 28 + 14, 14));
    var status = 'No fix';
    var value = '';
    if (origin != 255 && i >= origin) {
      if (i == origin) {
        status = 'Origin fix';
        if (n != 0 || e != 0) {
          warnings.add('GPS origin has a non-zero differential.');
        }
      } else if (n == 0 && e == 0) {
        status = 'Unchanged / no fix';
      } else {
        lat += n * 10 / 111320;
        final scale = 111320 * math.cos(lat * math.pi / 180);
        if (scale.abs() > 0.001) lon += e * 10 / scale;
        status =
            bytes[16] & 1 != 0 && [n, e].any((v) => v == -8192 || v == 8191)
            ? 'Fix (clipped delta)'
            : 'Fix';
      }
      if (status != 'Unchanged / no fix') {
        value = '${lat.toStringAsFixed(7)}, ${lon.toStringAsFixed(7)}';
      }
    } else if (n != 0 || e != 0) {
      warnings.add('A no-fix row contains a non-zero differential.');
    }
    rows.add(
      TelemetrySample(
        epoch + i * interval * 60,
        status,
        value,
        '${n * 10} m N / ${e * 10} m E',
      ),
    );
  }
  return DecodedTelemetry(
    kind: 'GPS',
    interval: interval,
    samples: rows,
    warnings: warnings.toSet().toList(),
  );
}
