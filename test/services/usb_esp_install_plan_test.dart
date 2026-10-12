import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/usb_esp_flash_engine.dart';
import 'package:meshcore_open/services/usb_esp_install_plan.dart';
import 'package:meshcore_open/services/usb_firmware_package.dart';
import 'package:meshcore_open/services/usb_partition_expansion.dart';

final _rejects = throwsA(isA<UsbFirmwareValidationException>());
const _chip = UsbEspChipInfo(
  chip: 9,
  flashBytes: 16 << 20,
  mac: '0123456789ab',
);

/// Shared checksum-valid fixtures for controller tests; not hardware evidence.
Uint8List usbEspInstallTestImage({
  int chip = 9,
  bool app = false,
  bool endf = false,
  bool bootDescriptor = false,
  int payloadSize = 256,
  int? address,
  int? entry,
}) => _image(
  chip: chip,
  app: app,
  endf: endf,
  bootDescriptor: bootDescriptor,
  payloadSize: payloadSize,
  address: address,
  entry: entry,
);

Uint8List usbEspInstallTestMerged({int chip = 9, int? appChip}) =>
    _merged(chip: chip, appChip: appChip);

void main() {
  test('bootloader offsets are chip-specific with no manual override', () {
    for (final (chip, offset) in [
      (0, 0x1000),
      (2, 0x1000),
      (5, 0),
      (9, 0),
      (12, 0),
    ]) {
      final plan = UsbEspInstallPlan.inspectBootloader(
        name: 'bootloader.bin',
        bytes: _image(chip: chip),
      );
      expect(plan.bootOffset, offset);
      expect(plan.writes.single.offset, offset);
      expect(plan.requiresErase, isFalse);
      plan.validateForChip(
        UsbEspChipInfo(chip: chip, flashBytes: 16 << 20, mac: _chip.mac),
      );
    }
    expect(
      () => UsbEspInstallPlan.inspectBootloader(
        name: 'bootloader.bin',
        bytes: _image(chip: 13),
      ),
      _rejects,
    );
  });

  test('application and EndF images can never use bootloader mode', () {
    expect(
      () => UsbEspInstallPlan.inspectBootloader(
        name: 'renamed.bin',
        bytes: _image(app: true),
      ),
      _rejects,
    );
    expect(
      () => UsbEspInstallPlan.inspectBootloader(
        name: 'renamed.bin',
        bytes: _image(endf: true),
      ),
      _rejects,
    );
    final mapped = _image(address: 0x42000000);
    expect(
      () => UsbEspInstallPlan.inspectBootloader(
        name: 'renamed.bin',
        bytes: mapped,
      ),
      _rejects,
    );
  });

  test('recognized IDF bootloader cannot be written via application mode', () {
    final boot = _image(bootDescriptor: true);
    expect(usbHasBootloaderDescriptor(boot), isTrue);
    expect(() => UsbFirmwareImage.fromBytes('renamed.bin', boot), _rejects);
    expect(
      () => UsbFirmwareImage.fromBytes('bootloader.bin', _image()),
      _rejects,
    );
    expect(
      UsbEspInstallPlan.inspectBootloader(
        name: 'bootloader.bin',
        bytes: boot,
      ).requiresErase,
      isFalse,
    );
  });

  test('bootloader checksum SHA entry point and boundary are validated', () {
    final bad = _image()..[100] ^= 1;
    expect(
      () => UsbEspInstallPlan.inspectBootloader(
        name: 'bootloader.bin',
        bytes: bad,
      ),
      _rejects,
    );
    final badHash = _image();
    badHash[badHash.length - 1] ^= 1;
    expect(
      () => UsbEspInstallPlan.inspectBootloader(
        name: 'bootloader.bin',
        bytes: badHash,
      ),
      _rejects,
    );
    expect(
      () => UsbEspInstallPlan.inspectBootloader(
        name: 'bootloader.bin',
        bytes: _image(entry: 0),
      ),
      _rejects,
    );
    expect(
      () => UsbEspInstallPlan.inspectBootloader(
        name: 'bootloader.bin',
        bytes: _image(payloadSize: 0x8000),
      ),
      _rejects,
    );
    expect(
      () => UsbEspInstallPlan.inspectBootloader(
        name: 'bootloader.bin',
        bytes: Uint8List.fromList([..._image(), 0xff]),
      ),
      _rejects,
    );
  });

  test(
    'chip and capacity checks happen before any mutation; plan bytes frozen',
    () {
      final source = _image();
      final plan = UsbEspInstallPlan.inspectBootloader(
        name: 'bootloader.bin',
        bytes: source,
      );
      source[40] ^= 1;
      plan.validateForChip(_chip);
      expect(() => plan.bytes[40] = 0, throwsUnsupportedError);
      expect(() => plan.writes.single.bytes[40] = 0, throwsUnsupportedError);
      expect(
        () => plan.validateForChip(
          const UsbEspChipInfo(
            chip: 5,
            flashBytes: 16 << 20,
            mac: '0123456789ab',
          ),
        ),
        _rejects,
      );
      expect(
        () => plan.validateForChip(
          const UsbEspChipInfo(
            chip: 9,
            flashBytes: 4 << 20,
            mac: '0123456789ab',
          ),
        ),
        _rejects,
      );
    },
  );

  test('full install needs erase and writes bootloader LAST', () {
    final full = _merged();
    final plan = UsbEspInstallPlan.inspectFullInstall(
      name: 'firmware-merged.bin',
      bytes: full,
    );
    expect(plan.requiresErase, isTrue);
    expect(plan.writes.map((w) => w.offset), [0x10000, 0x8000, 0]);
    expect(plan.hardwareId, 'heltec_v4');
    expect(plan.firmwareVersion, 'v1.18.0.1');
    plan.validateForChip(_chip);
  });

  test(
    'classic zero-based merged image recognizes FF prefix and offset1000',
    () {
      final full = _merged(chip: 0);
      final plan = UsbEspInstallPlan.inspectFullInstall(
        name: 'full.bin',
        bytes: full,
      );
      expect(plan.bootOffset, 0x1000);
      expect(plan.writes.last.offset, 0x1000);
      expect(
        () => UsbEspInstallPlan.inspectFullInstall(
          name: 'full.bin',
          bytes: Uint8List.sublistView(full, 0x1000),
        ),
        _rejects,
      );
      full[0] = 0;
      expect(
        () =>
            UsbEspInstallPlan.inspectFullInstall(name: 'full.bin', bytes: full),
        _rejects,
      );
    },
  );

  test(
    'full install rejects app CRC/table mutations wrong chip and arbitrary trailing bytes',
    () {
      final appBad = _merged()..[0x10040] ^= 1;
      expect(
        () => UsbEspInstallPlan.inspectFullInstall(
          name: 'full.bin',
          bytes: appBad,
        ),
        _rejects,
      );
      final tableBad = _merged()..[0x8028] ^= 1;
      expect(
        () => UsbEspInstallPlan.inspectFullInstall(
          name: 'full.bin',
          bytes: tableBad,
        ),
        _rejects,
      );
      expect(
        () => UsbEspInstallPlan.inspectFullInstall(
          name: 'full.bin',
          bytes: _merged(appChip: 5),
        ),
        _rejects,
      );
      expect(
        () => UsbEspInstallPlan.inspectFullInstall(
          name: 'full.bin',
          bytes: Uint8List.fromList([..._merged(), 1]),
        ),
        _rejects,
      );
    },
  );

  test(
    'full install refuses preprovisioned NVS/unknown gaps and missing boot app',
    () {
      for (final address in [0x7000, 0x9000]) {
        final bytes = _merged()..[address] = 1;
        expect(
          () => UsbEspInstallPlan.inspectFullInstall(
            name: 'full.bin',
            bytes: bytes,
          ),
          _rejects,
        );
      }
      final noApp = _merged();
      noApp.fillRange(0x10000, noApp.length, 0xff);
      expect(
        () => UsbEspInstallPlan.inspectFullInstall(
          name: 'full.bin',
          bytes: noApp,
        ),
        _rejects,
      );
    },
  );

  test(
    'full install verifies OTA selection does not point to erased alternate slot',
    () {
      final bytes = _merged();
      final view = ByteData.sublistView(bytes);
      view.setUint32(0xe000, 2, Endian.little);
      view.setUint32(0xe018, 2, Endian.little);
      view.setUint32(
        0xe01c,
        usbCrc32(bytes.sublist(0xe000, 0xe004), 0xffffffff),
        Endian.little,
      );
      expect(
        () => UsbEspInstallPlan.inspectFullInstall(
          name: 'full.bin',
          bytes: bytes,
        ),
        _rejects,
      );
    },
  );

  test(
    'valid-MD5 tables still reject overlap overflow encryption and unsupported slots',
    () {
      for (final mutate in <void Function(Uint8List)>[
        (table) =>
            ByteData.sublistView(table).setUint32(104, 16 << 20, Endian.little),
        (table) =>
            ByteData.sublistView(table).setUint32(100, 0x10000, Endian.little),
        (table) => ByteData.sublistView(table).setUint32(92, 1, Endian.little),
        (table) => table[67] = 0x20,
      ]) {
        final bytes = _merged();
        _retable(bytes, mutate);
        expect(
          () => UsbEspInstallPlan.inspectFullInstall(
            name: 'full.bin',
            bytes: bytes,
          ),
          _rejects,
        );
      }
    },
  );

  test(
    'all present OTA apps and selected metadata validate before bootloader publication',
    () {
      final first = _merged();
      final parts = UsbPartitionExpansion.parseTable(
        Uint8List.sublistView(first, 0x8000, 0x9000),
        16 << 20,
      );
      final alternate = parts.singleWhere(
        (p) => p.type == 0 && p.subtype == 0x11,
      );
      final app = _image(app: true, endf: true);
      final full = Uint8List(alternate.offset + app.length)
        ..fillRange(0, alternate.offset + app.length, 0xff)
        ..setRange(0, first.length, first)
        ..setRange(alternate.offset, alternate.offset + app.length, app);
      final view = ByteData.sublistView(full);
      view.setUint32(0xe000, 2, Endian.little);
      view.setUint32(0xe018, 2, Endian.little);
      view.setUint32(
        0xe01c,
        usbCrc32(full.sublist(0xe000, 0xe004), 0xffffffff),
        Endian.little,
      );
      final plan = UsbEspInstallPlan.inspectFullInstall(
        name: 'full.bin',
        bytes: full,
      );
      expect(plan.writes.map((w) => w.offset), [
        0xe000,
        0x10000,
        alternate.offset,
        0x8000,
        0,
      ]);
      plan.validateForChip(_chip);
      full[alternate.offset + 100] ^= 1;
      expect(
        () =>
            UsbEspInstallPlan.inspectFullInstall(name: 'full.bin', bytes: full),
        _rejects,
      );
    },
  );

  test(
    'erased padding is harmless but malformed OTA and non-BIN inputs are rejected',
    () {
      final padded = Uint8List.fromList([
        ..._merged(),
        ...List.filled(4096, 0xff),
      ]);
      expect(
        UsbEspInstallPlan.inspectFullInstall(
          name: 'full.bin',
          bytes: padded,
        ).requiresErase,
        isTrue,
      );
      final badOta = _merged();
      ByteData.sublistView(badOta).setUint32(0xe000, 2, Endian.little);
      expect(
        () => UsbEspInstallPlan.inspectFullInstall(
          name: 'full.bin',
          bytes: badOta,
        ),
        _rejects,
      );
      expect(
        () => UsbEspInstallPlan.inspectFullInstall(
          name: 'full.zip',
          bytes: _merged(),
        ),
        _rejects,
      );
    },
  );

  final integration = Platform.environment['USB_MERGED_INTEGRATION'];
  test(
    'optional actual MeshCore merged BIN validates boot table and app',
    () {
      final file = File(integration!);
      final plan = UsbEspInstallPlan.inspectFullInstall(
        name: file.uri.pathSegments.last,
        bytes: file.readAsBytesSync(),
      );
      expect(plan.chip, 9);
      expect(plan.hardwareId, 'heltec_v4');
      expect(plan.firmwareVersion, 'v1.17.1.7');
      expect(plan.requiresErase, isTrue);
      expect(plan.writes.last.offset, 0);
      plan.validateForChip(_chip);
    },
    skip: integration == null,
  );
}

void _retable(Uint8List full, void Function(Uint8List) mutate) {
  final table = Uint8List.fromList(full.sublist(0x8000, 0x9000));
  mutate(table);
  for (var offset = 0; offset < table.length; offset += 32) {
    if (table[offset] == 0xeb && table[offset + 1] == 0xeb) {
      table.setRange(
        offset + 16,
        offset + 32,
        crypto.md5.convert(table.sublist(0, offset)).bytes,
      );
      break;
    }
  }
  full.setRange(0x8000, 0x9000, table);
}

Uint8List _image({
  int chip = 9,
  bool app = false,
  bool endf = false,
  bool bootDescriptor = false,
  int payloadSize = 256,
  int? address,
  int? entry,
}) {
  final header = Uint8List(24);
  header[0] = 0xe9;
  header[1] = 1;
  header[2] = 2;
  header[3] = 0x40;
  header[23] = 1;
  final view = ByteData.sublistView(header);
  view.setUint16(12, chip, Endian.little);
  final load =
      address ??
      (app
          ? (chip == 0 ? 0x3f400020 : 0x3c000020)
          : chip == 0
          ? 0x40078000
          : chip == 2
          ? 0x40020000
          : 0x403c9700);
  view.setUint32(4, entry ?? load, Endian.little);
  final segment = Uint8List(8);
  ByteData.sublistView(segment).setUint32(0, load, Endian.little);
  ByteData.sublistView(segment).setUint32(4, payloadSize, Endian.little);
  final payload = Uint8List(payloadSize);
  if (app) {
    ByteData.sublistView(payload).setUint32(0, 0xabcd5432, Endian.little);
  }
  if (bootDescriptor) {
    payload[0] = 0x50;
    payload.setRange(8, 14, ascii.encode('v5.5.0'));
  }
  final builder = BytesBuilder()
    ..add(header)
    ..add(segment)
    ..add(payload);
  final length = 32 + payloadSize;
  final pad = Uint8List(((length ~/ 16) + 1) * 16 - length);
  pad[pad.length - 1] = payload.fold(0xef, (a, b) => a ^ b);
  builder.add(pad);
  builder.add(crypto.sha256.convert(builder.toBytes()).bytes);
  final main = builder.toBytes();
  if (!endf) return main;
  final trailer = Uint8List(56)..setRange(0, 4, ascii.encode('EndF'));
  final tv = ByteData.sublistView(trailer);
  tv.setUint32(4, main.length, Endian.little);
  trailer.setRange(8, 16, crypto.sha256.convert(main).bytes.sublist(0, 8));
  tv.setUint32(16, 0x01120001, Endian.little);
  tv.setUint32(
    20,
    const UsbMigrationTarget('heltec-v4', 'heltec_v4_repeater').targetId,
    Endian.little,
  );
  trailer.setRange(24, 33, ascii.encode('heltec_v4'));
  return Uint8List.fromList([...main, ...trailer]);
}

Uint8List _merged({int chip = 9, int? appChip}) {
  final boot = _image(chip: chip);
  final app = _image(chip: appChip ?? chip, app: true, endf: true);
  final bytes = Uint8List(0x10000 + app.length)
    ..fillRange(0, 0x10000 + app.length, 0xff);
  final offset = (chip == 0 || chip == 2) ? 0x1000 : 0;
  bytes.setRange(offset, offset + boot.length, boot);
  bytes.setRange(
    0x8000,
    0x9000,
    UsbPartitionExpansion.canonicalTable(16 << 20),
  );
  bytes.setRange(0x10000, bytes.length, app);
  return bytes;
}
