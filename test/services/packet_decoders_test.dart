import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/mesh_packet_decoder.dart';
import 'package:meshcore_open/services/telemetry_packet_decoder.dart';
import 'package:meshcore_open/services/management_packet_decoder.dart';

const tempPacket = '3E00545442311122334455667788800092651E0008000102354A4E5082';
const voltagePacket =
    '3E00545642311122334455667788800092651E000800010264C8FEFFDC';

void main() {
  test(
    'multi-page management authentication matches independent browser crypto',
    () {
      final fixture =
          jsonDecode(
                File(
                  'test/fixtures/meshcore_management_decoder_golden.json',
                ).readAsStringSync(),
              )
              as Map;
      final pages = (fixture['pages'] as List).cast<String>();
      final result = decodeManagement(
        pages.reversed.join('\n'),
        password: fixture['password'] as String,
        candidate: fixture['candidate'] as String,
      );
      expect(result.suppliedPages, 2);
      expect(result.authenticated, true);
      expect(result.acl.length, 7);
      expect(result.acl.first.fingerprint, fixture['matchedFingerprint']);
      expect(result.acl.first.candidateMatch, true);
      expect(result.warnings, isEmpty);
      final partial = decodeManagement(
        pages.first,
        password: fixture['password'] as String,
      );
      expect(partial.warnings.single, contains('incomplete'));
      final conflict = '${pages.first.substring(0, pages.first.length - 2)}00';
      expect(
        () => decodeManagement('${pages.first}\n$conflict'),
        throwsFormatException,
      );
    },
  );
  final golden =
      jsonDecode(
            File(
              'test/fixtures/meshcore_telemetry_decoder_golden.json',
            ).readAsStringSync(),
          )
          as Map;
  for (final entry in golden.entries) {
    test('matches MeshCore browser telemetry decoder: ${entry.key}', () {
      final expected = entry.value as Map;
      final result = decodeTelemetry(expected['input'] as String);
      final rows = expected['rows'] as List;
      expect(result.samples.length, rows.length);
      expect(result.source, expected['source']);
      expect(result.channel, expected['channel']);
      expect(result.interval, expected['interval']);
      for (var i = 0; i < rows.length; i++) {
        final actual = result.samples[i];
        final row = rows[i] as Map;
        expect(actual.epoch, row['epoch']);
        expect(actual.status, row['status']);
        if (row['valueC'] != null) expect(actual.value, '${row['valueC']} C');
        if (row['millivolts'] != null) {
          expect(
            actual.value,
            '${((row['millivolts'] as num) / 1000).toStringAsFixed(2)} V',
          );
        }
        if (row['latitude'] != null) {
          final coordinates = actual.value.split(', ');
          expect(
            double.parse(coordinates[0]),
            closeTo(row['latitude'] as num, 0.0000001),
          );
          expect(
            double.parse(coordinates[1]),
            closeTo(row['longitude'] as num, 0.0000001),
          );
        }
      }
      expect(result.csv.split('\n').length, rows.length + 1);
    });
  }
  test('raw envelope supports all routes and path widths', () {
    for (var route = 0; route < 4; route++) {
      for (var width = 1; width <= 3; width++) {
        final bytes = [
          0x3c | route,
          if (route == 0 || route == 3) ...[1, 2, 3, 4],
          ((width - 1) << 6) | 2,
          ...List.filled(width * 2, 0xA1),
          0x99,
        ];
        final packet = decodeMeshPacket(packetHexBytes(packetHex(bytes)));
        expect(packet.hops, 2);
        expect(packet.pathWidth, width);
        expect(packet.payload, [0x99]);
      }
    }
  });
  test('rejects malformed paths, truncated samples, and huge input', () {
    for (final hex in ['3E', '3EC099', '3E3F99', '3E02A1', '3E0054']) {
      expect(() => decodeTelemetry(hex), throwsFormatException);
    }
    expect(() => packetInputBytes('A' * 32769), throwsFormatException);
    expect(
      () =>
          decodeTelemetry(voltagePacket.substring(0, voltagePacket.length - 2)),
      throwsFormatException,
    );
  });
  test('accepts canonical payload, MQTT JSON and spaced hex', () {
    for (final input in [
      tempPacket.substring(4),
      jsonEncode({'raw': tempPacket}),
      tempPacket.replaceAllMapped(RegExp(r'..'), (m) => '${m[0]}:'),
    ]) {
      expect(decodeTelemetry(input).samples.length, 8);
    }
  });
  test('deduplicates packets and refuses incompatible sources/types', () {
    expect(decodeTelemetry('$voltagePacket\n$voltagePacket').samples.length, 8);
    expect(
      () => decodeTelemetry('$tempPacket\n$voltagePacket'),
      throwsFormatException,
    );
    final differentSource = voltagePacket.replaceFirst(
      '1122334455667788',
      '9922334455667788',
    );
    expect(
      () => decodeTelemetry('$voltagePacket\n$differentSource'),
      throwsFormatException,
    );
  });
  test('CLI pages merge by timestamp and reject conflicts', () {
    String page(int epoch, List<int> codes) =>
        '> ${base64Encode([0x12, epoch & 255, epoch >> 8 & 255, epoch >> 16 & 255, epoch >> 24 & 255, 30, codes.length, ...codes])}';
    final merged = decodeTelemetry(
      '${page(1704067200, [2, 3])}\n${page(1704070800, [4, 5])}',
    );
    expect(merged.samples.length, 4);
    expect(merged.samples.last.value, '1.91 V');
    expect(
      () =>
          decodeTelemetry('${page(1704067200, [2])}\n${page(1704067200, [3])}'),
      throwsFormatException,
    );
  });
  test('management public fields make no authentication claim', () {
    final result = decodeManagement(managementExamplePage);
    expect(result.authenticated, false);
    expect(result.fields['Firmware'], '1.17.1.5');
    expect(result.acl, isEmpty);
    expect(result.warnings.first, contains('unauthenticated'));
  });
  test(
    'management AES-SIV verifies browser fixture and decrypts permissions',
    () {
      final result = decodeManagement(
        managementExamplePage,
        password: managementExamplePassword,
      );
      expect(result.authenticated, true);
      expect(result.fields['Bootloader'], '0.2.4.6');
      expect(result.fields['EndF target'], '1234ABCD');
      expect(result.acl.single.fingerprint, 'AABBCCDDEEFF001122334455');
      expect(result.acl.single.flags, 3);
    },
  );
  test('management packet supports routed zero padding and deduplication', () {
    final packet = '1A0177${managementExamplePage}000000';
    final result = decodeManagement(
      jsonEncode({
        'packets': [
          {'raw': packet},
          {'raw': packet},
        ],
      }),
      password: managementExamplePassword,
    );
    expect(result.suppliedPages, 1);
    expect(result.fields['Route'], 'Direct; 1 hops');
    expect(result.acl.single.flags, 3);
    expect(
      () => decodeManagement('${packet.substring(0, packet.length - 2)}01'),
      throwsFormatException,
    );
  });
  test(
    'authenticates empty ACL, rejecting wrong password and tampered public/tag bytes',
    () {
      const empty =
          '4D475231000102030405060708090A0B0C0D0E0F2A00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000A815011F051F4F000001000000DAA550D7FEFAEB13412CF9E457A45F2A';
      expect(
        decodeManagement(
          empty,
          password: managementExamplePassword,
        ).authenticated,
        true,
      );
      for (final input in [
        '${managementExamplePage.substring(0, managementExamplePage.length - 2)}00',
        managementExamplePage.replaceFirst('2A000000', '2B000000'),
      ]) {
        expect(
          () => decodeManagement(input, password: managementExamplePassword),
          throwsFormatException,
        );
      }
      expect(
        () => decodeManagement(
          managementExamplePage,
          password: 'wrong management password',
        ),
        throwsFormatException,
      );
      expect(
        () => decodeManagement(managementExamplePage, password: 'short'),
        throwsFormatException,
      );
      expect(
        () => decodeManagement(
          managementExamplePage,
          password: managementExamplePassword,
          candidate: 'ab',
        ),
        throwsFormatException,
      );
    },
  );
  test('candidate not in ACL is never claimed as matched', () {
    final result = decodeManagement(
      managementExamplePage,
      password: managementExamplePassword,
      candidate: '00' * 32,
    );
    expect(result.acl.single.candidateMatch, false);
    expect(result.warnings.last, contains('not found'));
  });
}
