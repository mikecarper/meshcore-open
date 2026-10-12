import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/usb_flash_transport.dart';
import 'package:meshcore_open/services/usb_firmware_package.dart';
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

Uint8List recoveryFixture({
  bool combined = false,
  bool corruptCrc = false,
  int? sdSize,
  int? blSize,
}) {
  final payload = Uint8List.fromList(
    List.generate(combined ? 12288 : 4096, (i) => i & 255),
  );
  final init = Uint8List(14);
  final dat = ByteData.sublistView(init);
  dat.setUint16(0, 0x52, Endian.little);
  dat.setUint16(2, 52840, Endian.little);
  dat.setUint32(4, 0xffffffff, Endian.little);
  dat.setUint16(8, 1, Endian.little);
  dat.setUint16(10, 0xfffe, Endian.little);
  dat.setUint16(12, nrfDfuCrc16(payload) ^ (corruptCrc ? 1 : 0), Endian.little);
  final manifest = {
    'manifest': {
      'dfu_version': .5,
      combined ? 'softdevice_bootloader' : 'bootloader': {
        'bin_file': 'firmware.bin',
        'dat_file': 'firmware.dat',
        if (combined) 'sd_size': sdSize ?? 8192,
        if (combined) 'bl_size': blSize ?? 4096,
        'init_packet_data': {
          'device_type': 0x52,
          'device_revision': 52840,
          'application_version': 0xffffffff,
          'softdevice_req': [0xfffe],
          'firmware_crc16': nrfDfuCrc16(payload),
        },
      },
    },
  };
  final archive = Archive()
    ..addFile(
      ArchiveFile.bytes('manifest.json', utf8.encode(jsonEncode(manifest))),
    )
    ..addFile(ArchiveFile.bytes('firmware.bin', payload))
    ..addFile(ArchiveFile.bytes('firmware.dat', init));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Uint8List _rewriteManifest(
  Uint8List package,
  void Function(Map<String, dynamic>) modify,
) {
  final original = ZipDecoder().decodeBytes(package);
  final manifest =
      jsonDecode(utf8.decode(original.findFile('manifest.json')!.readBytes()!))
          as Map<String, dynamic>;
  modify(manifest['manifest'] as Map<String, dynamic>);
  final updated = Archive();
  for (final file in original.files) {
    updated.addFile(
      ArchiveFile.bytes(
        file.name,
        file.name == 'manifest.json'
            ? utf8.encode(jsonEncode(manifest))
            : file.readBytes()!,
      ),
    );
  }
  return Uint8List.fromList(ZipEncoder().encode(updated));
}

Uint8List _rewriteFiles(
  Uint8List package,
  void Function(Map<String, Uint8List>) modify,
) {
  final archive = ZipDecoder().decodeBytes(package);
  final files = <String, Uint8List>{
    for (final file in archive.files)
      file.name: Uint8List.fromList(file.readBytes()!),
  };
  modify(files);
  final updated = Archive();
  for (final entry in files.entries) {
    updated.addFile(ArchiveFile.bytes(entry.key, entry.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(updated));
}

class MockDfu extends UsbFlashTransport {
  final List<Uint8List> payloads = [];
  final List<int> rx = [];
  final List<String> operations = [];
  bool corruptAck = false;
  int drops = 0;
  @override
  Future<void> purge() async {
    operations.add('purge');
    rx.clear();
  }

  @override
  Future<void> setSignals({required bool dtr, required bool rts}) async {
    operations.add('setSignals');
    expect(dtr, true);
    expect(rts, false);
  }

  @override
  Future<void> write(Uint8List bytes) async {
    operations.add('write');
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
    operations.add('read');
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
  test(
    'native bootloader and combined packages validate legacy type and sizes',
    () {
      final boot = UsbNrfDfuPackage.fromBytes('boot.zip', recoveryFixture());
      expect(boot.kind, UsbNrfDfuKind.bootloader);
      expect(boot.displayName, 'Bootloader');
      expect(boot.isBootloaderUpdate, true);
      expect(boot.dfuMode, 2);
      expect(
        [boot.softdeviceSize, boot.bootloaderSize, boot.applicationSize],
        [0, 4096, 0],
      );
      expect(boot.deviceType, 0x52);
      expect(boot.deviceRevision, 52840);
      expect(boot.requiredSoftdevices, [0xfffe]);
      expect(boot.hardwareId, isNull);
      expect(boot.firmwareVersion, isNull);
      final combined = UsbNrfDfuPackage.fromBytes(
        'combined.zip',
        recoveryFixture(combined: true),
      );
      expect(combined.kind, UsbNrfDfuKind.softdeviceBootloader);
      expect(combined.dfuMode, 3);
      expect(combined.displayName, 'SoftDevice + bootloader');
      expect(
        [
          combined.softdeviceSize,
          combined.bootloaderSize,
          combined.applicationSize,
        ],
        [8192, 4096, 0],
      );
      expect(combined.payload.length, 12288);
    },
  );
  test('combined component boundaries and CRC must match the complete BIN', () {
    for (final bytes in [
      recoveryFixture(combined: true, sdSize: 0),
      recoveryFixture(combined: true, blSize: 0),
      recoveryFixture(combined: true, sdSize: -4),
      recoveryFixture(combined: true, sdSize: 8191, blSize: 4097),
      recoveryFixture(combined: true, blSize: 8192),
      recoveryFixture(combined: true, corruptCrc: true),
    ]) {
      expect(
        () => UsbNrfDfuPackage.fromBytes('invalid.zip', bytes),
        throwsFormatException,
      );
    }
  });
  test(
    'bootloader manifest must agree with classic DAT compatibility metadata',
    () {
      for (final mutation in <void Function(Map<String, dynamic>)>[
        (manifest) => manifest['dfu_version'] = .8,
        (manifest) => (manifest['bootloader'] as Map)['sd_size'] = 4096,
        (manifest) =>
            ((manifest['bootloader'] as Map)['init_packet_data']
                    as Map)['device_revision'] =
                52832,
        (manifest) =>
            ((manifest['bootloader'] as Map)['init_packet_data']
                    as Map)['device_type'] =
                0x51,
        (manifest) =>
            ((manifest['bootloader'] as Map)['init_packet_data']
                    as Map)['firmware_crc16'] =
                0,
        (manifest) =>
            ((manifest['bootloader'] as Map)['init_packet_data']
                as Map)['softdevice_req'] = [
              0x123,
            ],
        (manifest) =>
            ((manifest['bootloader'] as Map)['init_packet_data']
                    as Map)['firmware_hash'] =
                'not-legacy',
        (manifest) => manifest['softdevice'] = manifest.remove('bootloader'),
        (manifest) =>
            (manifest['bootloader'] as Map)['bin_file'] = 'manifest.json',
      ]) {
        expect(
          () => UsbNrfDfuPackage.fromBytes(
            'invalid.zip',
            _rewriteManifest(recoveryFixture(), mutation),
          ),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'bootloader requires recovery authorization before any USB operation',
    () async {
      final transport = MockDfu();
      final package = UsbNrfDfuPackage.fromBytes('boot.zip', recoveryFixture());
      await expectLater(
        UsbNrfDfuUpdater(transport).flash(package),
        throwsStateError,
      );
      expect(transport.payloads, isEmpty);
      expect(transport.operations, isEmpty);
    },
  );
  test(
    'expert parsing reports CRC/metadata mismatch but never repairs the provided DAT',
    () {
      final zip = recoveryFixture(corruptCrc: true);
      expect(
        () => UsbNrfDfuPackage.fromBytes('mismatch.zip', zip),
        throwsFormatException,
      );
      final package = UsbNrfDfuPackage.fromBytes(
        'mismatch.zip',
        zip,
        allowUnverified: true,
      );
      final original = ZipDecoder().decodeBytes(zip);
      expect(package.isUnverified, true);
      expect(package.warnings, isNotEmpty);
      expect(package.warnings.any((w) => w.contains('CRC')), true);
      expect(
        package.initPacket,
        original.findFile('firmware.dat')!.readBytes(),
      );
      expect(package.payload, original.findFile('firmware.bin')!.readBytes());
      expect(() => package.warnings.add('changed'), throwsUnsupportedError);
    },
  );
  test(
    'expert wrong device type and contradictory metadata remain warnings, not fabricated fixes',
    () {
      final zip = _rewriteFiles(recoveryFixture(), (files) {
        ByteData.sublistView(
          files['firmware.dat']!,
        ).setUint16(0, 0x51, Endian.little);
      });
      expect(
        () => UsbNrfDfuPackage.fromBytes('wrong.zip', zip),
        throwsFormatException,
      );
      final package = UsbNrfDfuPackage.fromBytes(
        'wrong.zip',
        zip,
        allowUnverified: true,
      );
      expect(package.deviceType, 0x51);
      expect(package.warnings.length, greaterThanOrEqualTo(2));
      expect(
        ByteData.sublistView(package.initPacket).getUint16(0, Endian.little),
        0x51,
      );
    },
  );
  test(
    'expert flag always needs a separate updater approval before raw USB access',
    () async {
      final package = UsbNrfDfuPackage.fromBytes(
        'clean.zip',
        fixture(),
        allowUnverified: true,
      );
      expect(package.isUnverified, true);
      final transport = MockDfu();
      await expectLater(
        UsbNrfDfuUpdater(transport).flash(package),
        throwsStateError,
      );
      expect(transport.operations, isEmpty);
    },
  );
  test(
    'expert sends exact CRC-mismatched bytes only with BOTH recovery and expert approvals',
    () async {
      final package = UsbNrfDfuPackage.fromBytes(
        'mismatch.zip',
        recoveryFixture(corruptCrc: true),
        allowUnverified: true,
      );
      final denied = MockDfu();
      await expectLater(
        UsbNrfDfuUpdater(denied).flash(package, allowUnverified: true),
        throwsStateError,
      );
      expect(denied.operations, isEmpty);
      final accepted = MockDfu();
      await UsbNrfDfuUpdater(
        accepted,
        delay: (_) async {},
      ).flash(package, allowBootloaderUpdate: true, allowUnverified: true);
      expect(accepted.payloads[1].sublist(4), [...package.initPacket, 0, 0]);
      expect(
        accepted.payloads.where((p) => p[0] == 4).expand((p) => p.skip(4)),
        package.payload,
      );
    },
  );
  test('expert flags never make payload or DAT buffers mutable', () async {
    for (final mutateDat in [false, true]) {
      final package = UsbNrfDfuPackage.fromBytes(
        'mismatch.zip',
        recoveryFixture(corruptCrc: true),
        allowUnverified: true,
      );
      final transport = MockDfu();
      final bytes = mutateDat ? package.initPacket : package.payload;
      expect(() => bytes[0] ^= 1, throwsUnsupportedError);
      expect(() => bytes.buffer.asUint8List()[0] ^= 1, throwsUnsupportedError);
      expect(transport.operations, isEmpty);
    }
  });
  test(
    'expert SoftDevice-only ZIP uses real legacy mode1 with no invented bootloader size',
    () async {
      final zip = _rewriteManifest(recoveryFixture(), (manifest) {
        manifest['softdevice'] = manifest.remove('bootloader');
      });
      expect(
        () => UsbNrfDfuPackage.fromBytes('sd.zip', zip),
        throwsFormatException,
      );
      final package = UsbNrfDfuPackage.fromBytes(
        'sd.zip',
        zip,
        allowUnverified: true,
      );
      expect(package.kind, UsbNrfDfuKind.softdevice);
      expect(package.dfuMode, 1);
      expect(package.softdeviceSize, 4096);
      expect(package.bootloaderSize, 0);
      expect(package.applicationSize, 0);
      expect(package.isBootloaderUpdate, true);
      expect(package.warnings, isNotEmpty);
      final transport = MockDfu();
      await UsbNrfDfuUpdater(
        transport,
        delay: (_) async {},
      ).flash(package, allowBootloaderUpdate: true, allowUnverified: true);
      final start = ByteData.sublistView(transport.payloads.first);
      expect(
        [for (var i = 0; i < 5; i++) start.getUint32(i * 4, Endian.little)],
        [3, 1, 4096, 0, 0],
      );
    },
  );
  test(
    'expert acknowledgements cannot invent malformed ZIP, size boundaries, or secure DFU support',
    () {
      for (final zip in [
        fixture(bootloader: true),
        recoveryFixture(combined: true, blSize: 1),
        _rewriteManifest(recoveryFixture(), (m) => m['dfu_version'] = .8),
        _rewriteManifest(
          recoveryFixture(),
          (m) => (m['bootloader'] as Map).remove('dat_file'),
        ),
        _rewriteFiles(
          recoveryFixture(),
          (files) => files['firmware.dat'] = Uint8List(8),
        ),
      ]) {
        expect(
          () => UsbNrfDfuPackage.fromBytes(
            'invalid.zip',
            zip,
            allowUnverified: true,
          ),
          throwsFormatException,
        );
      }
      expect(
        () => UsbNrfDfuPackage.fromBytes(
          'not-zip.zip',
          Uint8List.fromList([1, 2, 3]),
          allowUnverified: true,
        ),
        throwsA(isA<UsbFirmwareValidationException>()),
      );
    },
  );
  test(
    'nRF native MethodChannel path does not invoke the ESP engine',
    () async {
      const channel = MethodChannel('test/native-nrf-raw');
      const espChannel = MethodChannel('meshcore_open/usb_esp');
      const device = UsbFlashDevice(
        deviceName: '/dev/bus/usb/001/002',
        vendorId: 0x2886,
        productId: 0x1667,
        serialNumber: 'native-nrf',
        manufacturerName: 'Seeed Studio',
        driver: 'CdcAcmSerialDriver',
      );
      final operations = <String>[];
      final replies = <int>[];
      var browserCalls = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(espChannel, (_) async {
        browserCalls++;
        throw StateError('nRF USB must never enter the ESP flash engine');
      });
      messenger.setMockMethodCallHandler(channel, (call) async {
        operations.add(call.method);
        if (call.method == 'listDevices') return [device.toMap()];
        if (call.method == 'write') {
          final bytes = (call.arguments as Map)['data'] as Uint8List;
          final frame = nrfDfuSlipDecode(bytes.sublist(1, bytes.length - 1));
          final ack = (((frame[0] & 7) + 1) & 7) << 3;
          replies.addAll(nrfDfuSlipEncode([ack, 0, 0, -ack & 255]));
        }
        if (call.method == 'read') {
          final bytes = Uint8List.fromList(replies);
          replies.clear();
          return bytes;
        }
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        messenger.setMockMethodCallHandler(espChannel, null);
      });
      final transport = UsbFlashTransport(channel: channel);
      await transport.open(device);
      final result = await UsbNrfDfuUpdater(transport, delay: (_) async {})
          .flash(
            UsbNrfDfuPackage.fromBytes('native.zip', recoveryFixture()),
            expectedDevice: device,
            allowBootloaderUpdate: true,
          );
      await transport.close();
      expect(result.bytesWritten, 4096);
      expect(operations.first, 'open');
      expect(
        operations,
        containsAll([
          'listDevices',
          'setSignals',
          'purge',
          'write',
          'read',
          'close',
        ]),
      );
      expect(browserCalls, 0);
    },
  );
  test(
    'native serial bootloader modes send the actual component sizes and init',
    () async {
      for (final combined in [false, true]) {
        final transport = MockDfu();
        final waits = <Duration>[];
        final stages = <String>[];
        final package = UsbNrfDfuPackage.fromBytes(
          'boot.zip',
          recoveryFixture(combined: combined),
        );
        final result =
            await UsbNrfDfuUpdater(
              transport,
              delay: (d) async => waits.add(d),
            ).flash(
              package,
              allowBootloaderUpdate: true,
              onProgress: (_, stage) => stages.add(stage),
            );
        final start = ByteData.sublistView(transport.payloads.first);
        expect(
          [for (var i = 0; i < 5; i++) start.getUint32(i * 4, Endian.little)],
          [3, combined ? 3 : 2, combined ? 8192 : 0, 4096, 0],
        );
        expect(transport.payloads[1].sublist(4), [...package.initPacket, 0, 0]);
        expect(
          transport.payloads.where((p) => p[0] == 4).expand((p) => p.skip(4)),
          package.payload,
        );
        expect(transport.payloads.last, [5, 0, 0, 0]);
        expect(result.bytesWritten, package.payload.length);
        expect(result.applicationBootVerified, false);
        expect(stages.last, contains('installed version remains unverified'));
        final pages = package.payload.length ~/ 4096 + 1;
        expect(waits.last.inMilliseconds, 500 + (pages * 204.8).ceil());
      }
    },
  );
  test(
    'immutable recovery firmware and bad ACK never finish or trigger reset',
    () async {
      final package = UsbNrfDfuPackage.fromBytes('boot.zip', recoveryFixture());
      final altered = MockDfu();
      expect(() => package.payload[0] ^= 1, throwsUnsupportedError);
      expect(altered.payloads, isEmpty);
      final invalidAck = MockDfu()..corruptAck = true;
      await expectLater(
        UsbNrfDfuUpdater(invalidAck).flash(
          UsbNrfDfuPackage.fromBytes('boot.zip', recoveryFixture()),
          allowBootloaderUpdate: true,
        ),
        throwsFormatException,
      );
      expect(invalidAck.payloads, hasLength(1));
      expect(invalidAck.payloads.where((p) => p[0] == 5), isEmpty);
    },
  );
  test(
    'real published OTAFIX combined ZIP validates without USB access',
    () async {
      final package = UsbNrfDfuPackage.fromBytes(
        'published-bootloader.zip',
        await File(
          Platform.environment['NRFDFU_BOOTLOADER_TEST_ZIP']!,
        ).readAsBytes(),
      );
      expect(package.kind, UsbNrfDfuKind.softdeviceBootloader);
      expect(
        package.softdeviceSize + package.bootloaderSize,
        package.payload.length,
      );
      expect(package.deviceRevision, 52840);
      expect(package.hardwareId, isNull);
    },
    skip: Platform.environment['NRFDFU_BOOTLOADER_TEST_ZIP'] == null
        ? 'Optional published bootloader ZIP not configured'
        : false,
  );
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
  test('validated package aliases and byte buffers are immutable', () async {
    final transport = MockDfu();
    final package = UsbNrfDfuPackage.fromBytes('node.zip', fixture());
    expect(() => package.application[0] ^= 1, throwsUnsupportedError);
    expect(
      () => ByteData.sublistView(package.initPacket).setUint16(0, 0),
      throwsUnsupportedError,
    );
    expect(
      () => package.payload.buffer.asUint8List()[0] ^= 1,
      throwsUnsupportedError,
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
