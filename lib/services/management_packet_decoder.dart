import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart' as pc;

import 'mesh_packet_decoder.dart';

const managementExamplePassword = 'management test password';
const managementExamplePage =
    '4D475231000102030405060708090A0B0C0D0E0F2A00000000F153650501110106040200CDAB3412112233445566778840E2010000900100070700004800700E2850840E2A4EA815011F051F4F00000101000138BD699262E721CD2E9018D9E52A0AF74669C9D56685DEFFD8ABEA3C58';

class ManagementAclEntry {
  const ManagementAclEntry(
    this.index,
    this.fingerprint,
    this.flags,
    this.candidateMatch,
  );
  final int index;
  final String fingerprint;
  final int flags;
  final bool? candidateMatch;
  String get permissions => [
    if (flags & 1 != 0) 'Administrator',
    if (flags & 2 != 0) 'OTA signer',
  ].join(', ');
}

class DecodedManagement {
  const DecodedManagement({
    required this.fields,
    required this.authenticated,
    required this.suppliedPages,
    required this.pageCount,
    required this.acl,
    required this.warnings,
  });
  final Map<String, String> fields;
  final bool authenticated;
  final int suppliedPages;
  final int pageCount;
  final List<ManagementAclEntry> acl;
  final List<String> warnings;
}

/// Matches MeshCore docs/_javascript/management_decoder.js (MGR1 / RFC 5297).
/// No password, candidate key, or report is sent to the network or persisted.
DecodedManagement decodeManagement(
  String input, {
  String password = '',
  String candidate = '',
}) {
  final pages = <int, Uint8List>{};
  DecodedMeshPacket? envelope;
  for (final bytes in packetInputBytes(input)) {
    Uint8List payload;
    if (packetAscii(bytes, 0, 4) == 'MGR1') {
      payload = bytes;
    } else {
      final packet = decodeMeshPacket(bytes);
      if (packet.version != 1 || packet.payloadType != 6) {
        throw const FormatException(
          'Expected a version 1 GroupData management packet.',
        );
      }
      envelope ??= packet;
      payload = packet.payload;
    }
    if (payload.length < 99 || packetAscii(payload, 0, 4) != 'MGR1') {
      throw const FormatException(
        'MGR1 management header is missing or truncated.',
      );
    }
    final index = payload[78], totalPages = payload[79], total = payload[80];
    final start = payload[81], count = payload[82];
    final expectedPages = total == 0 ? 1 : (total + 5) ~/ 6;
    if (total > 36 ||
        totalPages != expectedPages ||
        index >= totalPages ||
        start != index * 6 ||
        start > total ||
        count != (total - start).clamp(0, 6)) {
      throw const FormatException(
        'Invalid management page index or ACL bounds.',
      );
    }
    final canonical = 83 + count * 13 + 16;
    final padded = 3 + ((canonical - 3 + 15) ~/ 16) * 16;
    if (payload.length != canonical &&
        (payload.length != padded ||
            payload.skip(canonical).any((b) => b != 0))) {
      throw const FormatException(
        'Invalid management length or non-zero padding.',
      );
    }
    payload = payload.sublist(0, canonical);
    if (pages.isNotEmpty &&
        (!_equal(payload.sublist(0, 78), pages.values.first.sublist(0, 78)) ||
            payload[79] != pages.values.first[79] ||
            payload[80] != pages.values.first[80])) {
      throw const FormatException(
        'Pages must belong to one radio, sequence, and snapshot.',
      );
    }
    if (pages[index] != null && !_equal(pages[index]!, payload)) {
      throw const FormatException(
        'Conflicting copies of the same management page.',
      );
    }
    pages[index] = payload;
  }
  final ordered = pages.keys.toList()..sort();
  final first = pages[ordered.first]!;
  final acl = <ManagementAclEntry>[];
  final warnings = <String>[];
  Uint8List? root;
  Uint8List? wanted;
  if (password.isNotEmpty) {
    final encoded = utf8.encode(password);
    if (encoded.length < 12 || encoded.length > 96) {
      throw const FormatException(
        'Management passwords require 12-96 UTF-8 bytes.',
      );
    }
    root = Uint8List.fromList(sha256.convert([0x23, ...encoded]).bytes);
    if (candidate.trim().isNotEmpty) {
      final admin = packetHexBytes(candidate.trim());
      if (admin.length != 32) {
        throw const FormatException(
          'Candidate key must be 64 hexadecimal characters.',
        );
      }
      final radio = first.sublist(4, 20);
      final key = _derive(root, 'MeshCore-MGR1-ACL', radio);
      wanted = Uint8List.fromList(
        Hmac(sha256, key).convert([...radio, ...admin]).bytes.take(12).toList(),
      );
    }
    try {
      for (final index in ordered) {
        final page = pages[index]!;
        final key = _derive(root, 'MeshCore-MGR1-SIV', page.sublist(4, 20));
        final length = page[82] * 13;
        final tag = page.sublist(83 + length);
        final counter = Uint8List.fromList(tag);
        counter[8] &= 0x7f;
        counter[12] &= 0x7f;
        final cipher = pc.SICStreamCipher(pc.AESEngine())
          ..init(
            false,
            pc.ParametersWithIV(pc.KeyParameter(key.sublist(16)), counter),
          );
        final plaintext = cipher.process(page.sublist(83, 83 + length));
        try {
          final expected = _s2v(
            key.sublist(0, 16),
            page.sublist(0, 83),
            plaintext,
          );
          if (!_equal(tag, expected)) {
            throw const FormatException(
              'Wrong password or modified management page.',
            );
          }
          for (var at = 0; at < plaintext.length; at += 13) {
            final flags = plaintext[at + 12];
            if (flags == 0 || flags & ~3 != 0) {
              throw const FormatException(
                'Invalid authenticated ACL role flags.',
              );
            }
            final fingerprint = plaintext.sublist(at, at + 12);
            acl.add(
              ManagementAclEntry(
                page[81] + at ~/ 13,
                packetHex(fingerprint),
                flags,
                wanted == null ? null : _equal(fingerprint, wanted),
              ),
            );
          }
        } finally {
          plaintext.fillRange(0, plaintext.length, 0);
          key.fillRange(0, key.length, 0);
        }
      }
    } finally {
      root.fillRange(0, root.length, 0);
    }
    if (pages.length != first[79]) {
      warnings.add(
        'Only ${pages.length}/${first[79]} pages supplied; ACL is incomplete.',
      );
    }
    if (wanted != null && !acl.any((a) => a.candidateMatch == true)) {
      warnings.add('Candidate key was not found in the supplied ACL pages.');
    }
  } else {
    warnings.add(
      'Public fields are unauthenticated. Enter the management password to verify them and decrypt ACLs.',
    );
    if (candidate.isNotEmpty) {
      warnings.add(
        'Candidate key cannot be checked without the management password.',
      );
    }
  }
  final valid = packetUint16(first, 76);
  String version(int at) {
    final v = packetUint32(first, at);
    return '${v >> 24 & 255}.${v >> 16 & 255}.${v >> 8 & 255}.${v & 255}';
  }

  String temp(int v) => v == 0
      ? 'unavailable'
      : v == 252
      ? '< -50 C'
      : v == 253
      ? '> 200 C'
      : v > 253
      ? 'reserved'
      : '${v - 51} C';
  String extrema(int at) =>
      '${packetUint16(first, at)} mV; ${temp(first[at + 2])} to ${temp(first[at + 3])}';
  String features(int bits) => [
    for (final entry in {
      1: 'Wi-Fi',
      2: 'GPS',
      4: 'NTP time',
      8: 'USB data',
      16: 'LoRa OTA',
    }.entries)
      if (bits & entry.key != 0) entry.value,
  ].join(', ');
  final fields = <String, String>{
    'Reporter': packetHex(first.sublist(4, 20)),
    'Sequence': '${packetUint32(first, 20)}',
    'Report time (UTC)': DateTime.fromMillisecondsSinceEpoch(
      packetUint32(first, 24) * 1000,
      isUtc: true,
    ).toIso8601String(),
    'Role':
        {1: 'Repeater', 2: 'Room server', 3: 'Sensor'}[first[72]] ??
        'Unknown (${first[72]})',
    'Firmware': valid & 1 != 0 ? version(28) : 'unavailable',
    'Bootloader': valid & 2 != 0 ? version(32) : 'unavailable',
    'EndF target': valid & 4 != 0
        ? packetUint32(
            first,
            36,
          ).toRadixString(16).padLeft(8, '0').toUpperCase()
        : 'unavailable',
    'Delta base hash': valid & 4 != 0
        ? packetHex(first.sublist(40, 48))
        : 'unavailable',
    'Image length': valid & 4 != 0
        ? '${packetUint32(first, 48)} bytes'
        : 'unavailable',
    'Staging': valid & 8 != 0
        ? '${packetUint32(first, 52)} bytes'
        : 'unavailable',
    'OTA capabilities':
        '0x${packetUint32(first, 56).toRadixString(16).padLeft(8, '0')}',
    'Uptime': '${packetUint16(first, 60)} hours',
    'Weekly extrema': extrema(62),
    'Since-report extrema': extrema(66),
    'History': '${first[70]} hours${valid & 16 != 0 ? ' (partial)' : ''}',
    'Report interval': '${first[71]} days',
    'Compiled features': features(first[73]),
    'Known active features': features(first[74] & first[75]),
    'Unknown feature states': features(first[73] & ~first[75]),
    'Pages': '${pages.length}/${first[79]}',
    'ACL entries': '${first[80]} total',
    if (envelope != null) 'Route': '${envelope.route}; ${envelope.hops} hops',
  };
  return DecodedManagement(
    fields: fields,
    authenticated: password.isNotEmpty,
    suppliedPages: pages.length,
    pageCount: first[79],
    acl: acl,
    warnings: warnings,
  );
}

Uint8List _derive(Uint8List root, String domain, Uint8List radio) =>
    Uint8List.fromList(
      Hmac(sha256, root).convert([...utf8.encode(domain), ...radio]).bytes,
    );
bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

Uint8List _double(Uint8List input) {
  final out = Uint8List(16);
  for (var i = 0; i < 15; i++) {
    out[i] = ((input[i] << 1) | (input[i + 1] >> 7)) & 255;
  }
  out[15] = ((input[15] << 1) & 255) ^ (input[0] >> 7 != 0 ? 0x87 : 0);
  return out;
}

Uint8List _cmac(Uint8List key, Uint8List data) =>
    (pc.CMac(pc.AESEngine(), 128)..init(pc.KeyParameter(key))).process(data);
Uint8List _s2v(Uint8List key, Uint8List aad, Uint8List plaintext) {
  var d = _double(_cmac(key, Uint8List(16)));
  final ad = _cmac(key, aad);
  for (var i = 0; i < 16; i++) {
    d[i] ^= ad[i];
  }
  if (plaintext.length >= 16) {
    final adjusted = Uint8List.fromList(plaintext);
    for (var i = 0; i < 16; i++) {
      adjusted[adjusted.length - 16 + i] ^= d[i];
    }
    return _cmac(key, adjusted);
  }
  d = _double(d);
  final padded = Uint8List(16)..setAll(0, plaintext);
  padded[plaintext.length] = 0x80;
  for (var i = 0; i < 16; i++) {
    padded[i] ^= d[i];
  }
  return _cmac(key, padded);
}
