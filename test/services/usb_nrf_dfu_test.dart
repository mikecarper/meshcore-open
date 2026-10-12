import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/usb_flash_transport.dart';
import 'package:meshcore_open/services/usb_nrf_dfu.dart';

Uint8List fixture({
  bool bootloader = false,
  bool corruptCrc = false,
  int size = 1200,
}) {
  final firmware = Uint8List.fromList(List.generate(size, (i) => i & 255));
  final init = Uint8List(14);
  final dat = ByteData.sublistView(init);
  dat.setUint16(0, 82, Endian.little);
  dat.setUint16(2, 65535, Endian.little);
  dat.setUint32(4, 0xffffffff, Endian.little);
  dat.setUint16(8, 1, Endian.little);
  dat.setUint16(10, 0x123, Endian.little);
  dat.setUint16(
    12,
    nrfDfuCrc16(firmware) ^ (corruptCrc ? 1 : 0),
    Endian.little,
  );
  final manifest = {
    'manifest': {
      'dfu_version': .5,
      'application': {'bin_file': 'firmware.bin', 'dat_file': 'firmware.dat'},
      if (bootloader)
        'bootloader': {'bin_file': 'firmware.bin', 'dat_file': 'firmware.dat'},
    },
  };
  final manifestBytes = utf8.encode(jsonEncode(manifest));
  final archive = Archive()
    ..addFile(ArchiveFile('manifest.json', manifestBytes.length, manifestBytes))
    ..addFile(ArchiveFile('firmware.bin', firmware.length, firmware))
    ..addFile(ArchiveFile('firmware.dat', init.length, init));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

class MockDfu extends UsbFlashTransport {
  final List<Uint8List> payloads = [];
  final List<int> rx = [];
  bool corruptAck = false;
  int drops = 0;
  @override
  Future<void> purge() async {
    rx.clear();
  }

  @override
  Future<void> setSignals({required bool dtr, required bool rts}) async {
    expect(dtr, true);
    expect(rts, false);
  }

  @override
  Future<void> write(Uint8List bytes) async {
    final raw = nrfDfuSlipDecode(bytes.sublist(1, bytes.length - 1));
    expect((raw.take(4).reduce((a, b) => a + b) & 255), 0);
    expect(
      nrfDfuCrc16(raw.sublist(0, raw.length - 2)),
      raw[raw.length - 2] | raw.last << 8,
    );
    payloads.add(Uint8List.fromList(raw.sublist(4, raw.length - 2)));
    if (drops-- > 0) return;
    final ack = ((((raw[0] & 7) + 1) & 7) << 3);
    final header = [ack, 0, 0, (-ack) & 255];
    if (corruptAck) header[3] ^= 1;
    rx.addAll(nrfDfuSlipEncode(header));
  }

  @override
  Future<Uint8List> read({
    int maxBytes = 4096,
    Duration timeout = const Duration(seconds: 1),
  }) async {
    if (rx.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return Uint8List(0);
    }
    // Intentionally fragmented replies, including split SLIP delimiters.
    final result = Uint8List.fromList(rx.take(2).toList());
    rx.removeRange(0, result.length);
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real published legacy application ZIP validates without USB access',
    () async {
      final path = Platform.environment['NRFDFU_TEST_ZIP']!;
      final package = UsbNrfDfuPackage.fromBytes(
        'fixture.zip',
        await File(path).readAsBytes(),
      );
      expect(package.application.length, greaterThan(100000));
      expect(package.initPacket.length, 14);
      expect(package.sha256.length, 64);
    },
    skip: Platform.environment['NRFDFU_TEST_ZIP'] == null
        ? 'Optional published application ZIP not configured'
        : false,
  );
  test('CRC16 and SLIP published wire vectors', () {
    expect(nrfDfuCrc16(ascii.encode('123456789')), 0x29b1);
    final encoded = nrfDfuSlipEncode([0xc0, 0xdb, 1]);
    expect(encoded, [0xc0, 0xdb, 0xdc, 0xdb, 0xdd, 1, 0xc0]);
    expect(nrfDfuSlipDecode(encoded.sublist(1, encoded.length - 1)), [
      0xc0,
      0xdb,
      1,
    ]);
    expect(() => nrfDfuSlipDecode([0xdb, 1]), throwsFormatException);
    expect(
      nrfDfuHciPacket(
        Uint8List.fromList([
          3,
          0,
          0,
          0,
          4,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          176,
          4,
          0,
          0,
        ]),
        1,
      ),
      [
        0xc0,
        0xd1,
        0x4e,
        1,
        0xe0,
        3,
        0,
        0,
        0,
        4,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0xb0,
        4,
        0,
        0,
        0x7a,
        0x82,
        0xc0,
      ],
    );
  });
  test('application ZIP validates init CRC before writes', () {
    final package = UsbNrfDfuPackage.fromBytes('node.zip', fixture());
    expect(package.application.length, 1200);
    expect(package.sha256.length, 64);
    expect(
      () => UsbNrfDfuPackage.fromBytes('bad.zip', fixture(corruptCrc: true)),
      throwsFormatException,
    );
    expect(
      () => UsbNrfDfuPackage.fromBytes('boot.zip', fixture(bootloader: true)),
      throwsFormatException,
    );
  });
  test('real legacy serial start init chunks stop and waits', () async {
    final transport = MockDfu();
    final waits = <Duration>[];
    final package = UsbNrfDfuPackage.fromBytes('node.zip', fixture());
    final result = await UsbNrfDfuUpdater(
      transport,
      delay: (d) async {
        waits.add(d);
      },
    ).flash(package);
    expect(
      transport.payloads
          .map((p) => ByteData.sublistView(p).getUint32(0, Endian.little))
          .toList(),
      [3, 1, 4, 4, 4, 5],
    );
    expect(transport.payloads.first, [
      3,
      0,
      0,
      0,
      4,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      176,
      4,
      0,
      0,
    ]);
    final data = transport.payloads
        .where((p) => p[0] == 4)
        .expand((p) => p.skip(4))
        .toList();
    expect(data, package.application);
    expect(waits.first.inMilliseconds, 500);
    expect(result.transportVerified, true);
    expect(result.applicationBootVerified, false);
  });
  test('wrong ACK header checksum stops, never activates', () async {
    final transport = MockDfu()..corruptAck = true;
    final package = UsbNrfDfuPackage.fromBytes('node.zip', fixture());
    await expectLater(
      UsbNrfDfuUpdater(transport, delay: (d) async {}).flash(package),
      throwsFormatException,
    );
    expect(transport.payloads.length, 1);
  });
  test('mutated validated package stops before USB writes', () async {
    final transport = MockDfu();
    final package = UsbNrfDfuPackage.fromBytes('node.zip', fixture());
    package.application[0] ^= 1;
    await expectLater(
      UsbNrfDfuUpdater(transport).flash(package),
      throwsStateError,
    );
    expect(transport.payloads, isEmpty);
  });
  test('HCI sequence wraps across eight chunks', () async {
    final transport = MockDfu();
    final package = UsbNrfDfuPackage.fromBytes('node.zip', fixture(size: 6000));
    final result = await UsbNrfDfuUpdater(
      transport,
      delay: (d) async {},
    ).flash(package);
    expect(result.bytesWritten, 6000);
    expect(transport.payloads.length, 15);
  });
  test(
    'one lost ACK retransmits identical HCI sequence before continuing',
    () async {
      final transport = MockDfu()..drops = 1;
      final package = UsbNrfDfuPackage.fromBytes('node.zip', fixture());
      await UsbNrfDfuUpdater(transport, delay: (d) async {}).flash(package);
      expect(transport.payloads[0], transport.payloads[1]);
      expect(transport.payloads.length, 7);
    },
  );
  test('expected USB endpoint mismatch stops before DFU start', () async {
    final transport = MockDfu();
    final package = UsbNrfDfuPackage.fromBytes('node.zip', fixture());
    await expectLater(
      UsbNrfDfuUpdater(transport).flash(
        package,
        expectedDevice: const UsbFlashDevice(
          deviceName: 'test',
          vendorId: 0x239a,
          productId: 0x0029,
          serialNumber: 'one',
        ),
      ),
      throwsStateError,
    );
    expect(transport.payloads, isEmpty);
  });
}
