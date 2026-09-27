import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/nrf_dfu_package.dart';

void main() {
  Uint8List package({String binName = 'application.bin'}) {
    final manifest = jsonEncode({
      'manifest': {
        'application': {'bin_file': binName, 'dat_file': 'application.dat'},
      },
    });
    final archive = Archive()
      ..add(ArchiveFile.bytes('manifest.json', utf8.encode(manifest)))
      ..add(ArchiveFile.bytes('application.bin', List<int>.filled(1024, 0x55)))
      ..add(ArchiveFile.bytes('application.dat', List<int>.filled(32, 0x33)));
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  test('recognizes a standard application DFU distribution', () {
    final parsed = NrfDfuPackage.inspect(package());
    expect(parsed.components, ['application']);
  });

  test('rejects a missing manifest member or path traversal', () {
    expect(
      () => NrfDfuPackage.inspect(package(binName: 'wrong.bin')),
      throwsFormatException,
    );
    expect(
      () => NrfDfuPackage.inspect(package(binName: '../application.bin')),
      throwsFormatException,
    );
  });

  test('uses the exact DFU address reported by the radio', () {
    expect(
      NrfDfuPackage.macFromStartReply('OK - mac: 44:1b:f6:69:cf:99'),
      '44:1B:F6:69:CF:99',
    );
    expect(() => NrfDfuPackage.macFromStartReply('OK'), throwsFormatException);
  });
}
