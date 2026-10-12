import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/usb_firmware_package.dart';
import 'package:meshcore_open/services/usb_partition_expansion.dart';

const _name =
    'heltec_v4_repeater-full-v1.18.0.1-halo-keymind-cascade-dev-12345678.bin';
const _flash = 16 << 20;
final _rejects = throwsA(isA<UsbFirmwareValidationException>());

void main() {
  test('CRC32 matches Python zlib seed convention', () {
    expect(usbCrc32(ascii.encode('123456789')), 0xcbf43926);
    expect(usbCrc32(ascii.encode('123456789'), 0xffffffff), 0xd202d277);
  });

  test('ESP image verifies segments, checksum, SHA and EndF', () {
    final image = UsbFirmwareImage.fromBytes(_name, _image(payloadSize: 100));
    expect(image.chip, 9);
    expect(image.declaredFlashBytes, _flash);
    expect(image.endf!.hardwareId, 'heltec-v4');
    expect(image.endf!.version, 0x01120001);
    expect(image.release!.sourceCommit, '12345678');
    final corrupt = Uint8List.fromList(image.bytes)..[40] ^= 1;
    expect(() => UsbFirmwareImage.fromBytes(_name, corrupt), _rejects);
    expect(() => image.bytes[0] = 1, throwsUnsupportedError);
  });

  test('merged, ZIP, trailing data and wrong ESP checksums are refused', () {
    final bytes = _image(payloadSize: 100, endf: false);
    expect(
      () => UsbFirmwareImage.fromBytes('firmware-merged.bin', bytes),
      _rejects,
    );
    expect(() => UsbFirmwareImage.fromBytes('firmware.zip', bytes), _rejects);
    expect(
      () => UsbFirmwareImage.fromBytes(
        'firmware.bin',
        Uint8List.fromList([...bytes, 0xff]),
      ),
      _rejects,
    );
    final bad = Uint8List.fromList(bytes)..[40] ^= 1;
    expect(() => UsbFirmwareImage.fromBytes('firmware.bin', bad), _rejects);
  });

  test('canonical table geometries and MD5 are checked for 4/8/16 MiB', () {
    for (final (flash, app1, slot) in [
      (4 << 20, 0x200000, 0x1f0000),
      (8 << 20, 0x340000, 0x330000),
      (16 << 20, 0x650000, 0x640000),
    ]) {
      final table = UsbPartitionExpansion.canonicalTable(flash);
      final parts = UsbPartitionExpansion.parseTable(table, flash);
      expect(parts.where((p) => p.type == 0).map((p) => p.offset), [
        0x10000,
        app1,
      ]);
      expect(
        parts.where((p) => p.type == 0).every((p) => p.size == slot),
        isTrue,
      );
      final bad = Uint8List.fromList(table)..[40] ^= 1;
      expect(() => UsbPartitionExpansion.parseTable(bad, flash), _rejects);
    }
  });

  test('tables refuse overlap, duplicate labels and unsafe flags', () {
    final entries = _sourceEntries();
    final overlap = [...entries]
      ..[3] = const UsbFlashPartition(
        name: 'app1',
        type: 0,
        subtype: 0x11,
        offset: 0x10000,
        size: 0x140000,
      );
    expect(
      () => UsbPartitionExpansion.parseTable(_table(overlap), _flash),
      _rejects,
    );
    final duplicate = [...entries]
      ..[3] = const UsbFlashPartition(
        name: 'app0',
        type: 0,
        subtype: 0x11,
        offset: 0x150000,
        size: 0x140000,
      );
    expect(
      () => UsbPartitionExpansion.parseTable(_table(duplicate), _flash),
      _rejects,
    );
    final flags = [...entries]
      ..[0] = const UsbFlashPartition(
        name: 'nvs',
        type: 1,
        subtype: 2,
        offset: 0x9000,
        size: 0x5000,
        flags: 4,
      );
    expect(
      () => UsbPartitionExpansion.parseTable(_table(flags), _flash),
      _rejects,
    );
  });

  test('ordinary update writes inactive first and CRC-valid active last', () {
    final image = UsbFirmwareImage.fromBytes(_name, _image(payloadSize: 100));
    final analysis = UsbPartitionExpansion.analyze(
      image: image,
      table: _sourceTable(),
      flashBytes: _flash,
      chip: 9,
      otadata: _ota(sequence: 2),
      nvs: _erased(0x5000),
    );
    expect(analysis.needed, isFalse);
    expect(analysis.appOffsets, [0x10000, 0x150000]);
    expect(analysis.activeOffset, 0x150000);
    expect(analysis.nvsOffset, 0x9000);
    expect(analysis.otaOffset, 0xe000);
  });

  test('factory ordinary update without NVS/OTA remains supported', () {
    final image = UsbFirmwareImage.fromBytes(
      'ordinary.bin',
      _image(payloadSize: 100, endf: false),
    );
    final table = _table([
      const UsbFlashPartition(
        name: 'factory',
        type: 0,
        subtype: 0,
        offset: 0x10000,
        size: 0x140000,
      ),
    ]);
    final analysis = UsbPartitionExpansion.analyze(
      image: image,
      table: table,
      flashBytes: _flash,
      chip: 9,
    );
    expect(analysis.needed, isFalse);
    expect(analysis.appOffsets, [0x10000]);
    expect(analysis.nvsOffset, isNull);
    expect(analysis.otaOffset, isNull);
  });

  test('ordinary update still requires actual NVS and OTA snapshots', () {
    final image = UsbFirmwareImage.fromBytes(_name, _image(payloadSize: 100));
    expect(
      () => UsbPartitionExpansion.analyze(
        image: image,
        table: _sourceTable(),
        flashBytes: _flash,
        chip: 9,
        nvs: _erased(0x5000),
      ),
      _rejects,
    );
    expect(
      () => UsbPartitionExpansion.analyze(
        image: image,
        table: _sourceTable(),
        flashBytes: _flash,
        chip: 9,
        otadata: _ota(),
      ),
      _rejects,
    );
    expect(
      () => UsbPartitionExpansion.analyze(
        image: image,
        table: _sourceTable(),
        flashBytes: _flash,
        chip: 5,
        otadata: _ota(),
        nvs: _erased(0x5000),
      ),
      _rejects,
    );
  });

  test(
    'live pending NVS blocks ordinary writes even without local journal',
    () {
      final image = UsbFirmwareImage.fromBytes(_name, _image(payloadSize: 100));
      for (final nvs in [
        _nvs(restored: true, pending: true),
        _nvs(restored: false),
        _nvs(restored: true, identityPending: true),
      ]) {
        expect(
          () => UsbPartitionExpansion.analyze(
            image: image,
            table: _sourceTable(),
            flashBytes: _flash,
            chip: 9,
            otadata: _ota(),
            nvs: nvs,
          ),
          _rejects,
        );
      }
    },
  );

  test('OTA sequence rollover, erased initial and ambiguous ordering', () {
    final parts = UsbPartitionExpansion.parseTable(_sourceTable(), _flash);
    expect(UsbPartitionExpansion.activeOtaOffset(parts, _ota()), 0x10000);
    expect(
      UsbPartitionExpansion.activeOtaOffset(
        parts,
        _ota(sequence: 0xfffffffe, second: 1),
      ),
      0x10000,
    );
    expect(
      () => UsbPartitionExpansion.activeOtaOffset(
        parts,
        _ota(sequence: 1, second: 0x80000001),
      ),
      _rejects,
    );
    final invalid = _ota(sequence: 1)..[28] ^= 1;
    expect(
      () => UsbPartitionExpansion.activeOtaOffset(parts, invalid),
      _rejects,
    );
  });

  test('NVS validates entry/page CRCs, erased states and primitive types', () {
    final nvs = _nvs(restored: true);
    final markers = UsbPartitionExpansion.parseNvsMarkers(nvs);
    expect(markers.namespaceExists, isTrue);
    expect(markers.configurationRestored, isTrue);
    expect(markers.unfinished, isFalse);
    final pageCrc = Uint8List.fromList(nvs)..[28] ^= 1;
    expect(() => UsbPartitionExpansion.parseNvsMarkers(pageCrc), _rejects);
    final entryCrc = Uint8List.fromList(nvs)..[96 + 4] ^= 1;
    expect(() => UsbPartitionExpansion.parseNvsMarkers(entryCrc), _rejects);
    final erasedMarker = Uint8List.fromList(nvs)..[32] &= ~(3 << 2);
    expect(
      UsbPartitionExpansion.parseNvsMarkers(erasedMarker).configurationRestored,
      isFalse,
    );
    final wrongType = _nvs(restored: true, restoredKind: 2);
    expect(() => UsbPartitionExpansion.parseNvsMarkers(wrongType), _rejects);
  });

  test('NVS newer variable-length flag supersedes stale primitive true', () {
    final nvs = _nvs(restored: true);
    final page = Uint8List.sublistView(nvs, 0, 4096);
    _setNvsEntry(
      page,
      2,
      namespace: 1,
      key: 'cfg-restored',
      kind: 0x21,
      value: 0,
      span: 2,
      body: Uint8List.fromList([0]),
    );
    expect(() => UsbPartitionExpansion.parseNvsMarkers(nvs), _rejects);
  });

  test(
    'NVS duplicate namespace identity and multiple active pages are refused',
    () {
      final nvs = _nvs(restored: true);
      final page = Uint8List.sublistView(nvs, 0, 4096);
      _setNvsEntry(page, 2, namespace: 0, key: 'other', value: 1);
      expect(() => UsbPartitionExpansion.parseNvsMarkers(nvs), _rejects);
      final two = _nvs(restored: true);
      two.setRange(4096, 8192, two.sublist(0, 4096));
      final view = ByteData.sublistView(two);
      view.setUint32(4100, 2, Endian.little);
      view.setUint32(
        4096 + 28,
        usbCrc32(two.sublist(4100, 4124), 0xffffffff),
        Endian.little,
      );
      expect(() => UsbPartitionExpansion.parseNvsMarkers(two), _rejects);
    },
  );

  test(
    'expansion pairs exact Full image release, target, and qualified caps',
    () {
      final image = UsbFirmwareImage.fromBytes(_name, _image());
      final analysis = _analysis(image);
      expect(analysis.needed, isTrue);
      expect(
        analysis.packageUrl,
        'https://github.com/mikecarper/MeshCore/releases/download/utility-v1.18.0.1-halo-keymind-cascade-dev-12345678/heltec-v4-v1.18.0.1-halo-keymind-cascade-dev-12345678-migration.zip',
      );
      final plan = UsbPartitionExpansion.createPlan(
        analysis: analysis,
        packageZip: _package(image),
      );
      expect(plan.board, 'heltec-v4');
      expect(plan.bridgeOffsets, [0x150000, 0x10000]);
      expect(plan.automaticRomReturn, isTrue);
      expect(plan.atomicPowerLossRecovery, isFalse);
      plan.verifyArtifacts();
    },
  );

  test(
    'mismatched release Full board and capabilities never produce a plan',
    () {
      final image = UsbFirmwareImage.fromBytes(_name, _image());
      final analysis = _analysis(image);
      for (final changed in <String, dynamic>{
        'source_commit': '87654321',
        'board': 'heltec-v3-repeater',
        'hardware_id': 'wrong',
        'flash_bytes': 8 << 20,
        'legacy_slot_bytes': 0x150000,
        'expanded_slot_bytes': 0x640000.toDouble(),
        'atomic_power_loss_recovery': true,
      }.entries) {
        expect(
          () => UsbPartitionExpansion.createPlan(
            analysis: analysis,
            packageZip: _package(image, metadata: {changed.key: changed.value}),
          ),
          _rejects,
        );
      }
      expect(
        () => UsbPartitionExpansion.createPlan(
          analysis: analysis,
          packageZip: _package(image, badCaps: true),
        ),
        _rejects,
      );
      final other = UsbFirmwareImage.fromBytes(
        _name,
        _image(payloadSize: 0x140001),
      );
      expect(
        () => UsbPartitionExpansion.createPlan(
          analysis: analysis,
          packageZip: _package(other),
        ),
        _rejects,
      );
    },
  );

  test(
    'Wi-Fi-only bridge does not substitute for USB and partial metadata fails',
    () {
      final image = UsbFirmwareImage.fromBytes(_name, _image());
      final analysis = _analysis(image);
      expect(
        () => UsbPartitionExpansion.createPlan(
          analysis: analysis,
          packageZip: _package(image, embeddedUsb: false),
        ),
        _rejects,
      );
      expect(
        () => UsbPartitionExpansion.createPlan(
          analysis: analysis,
          packageZip: _package(
            image,
            metadata: {
              'usb_migration': {'bridge': 'usb-bridge.bin'},
            },
          ),
        ),
        _rejects,
      );
    },
  );

  test(
    'six-profile standalone USB set is fully validated and pin enforced',
    () {
      final image = UsbFirmwareImage.fromBytes(_name, _image());
      final analysis = _analysis(image);
      final set = _usbSet();
      expect(
        () => UsbPartitionExpansion.createPlan(
          analysis: analysis,
          packageZip: _package(image, embeddedUsb: false),
          usbSetZip: set,
        ),
        _rejects,
      );
      final plan = UsbPartitionExpansion.createPlan(
        analysis: analysis,
        packageZip: _package(image, embeddedUsb: false),
        usbSetZip: set,
        requirePinnedUsbSet: false,
      ); // explicit locally supplied qualified set
      expect(plan.usbSetSha256, usbSha256(set));
      expect(
        () => UsbPartitionExpansion.bridgeFromUsbSet(
          _usbSet(omitLast: true),
          9,
          _flash,
        ),
        _rejects,
      );
      expect(
        () => UsbPartitionExpansion.bridgeFromUsbSet(
          _usbSet(badMarker: true),
          9,
          _flash,
        ),
        _rejects,
      );
    },
  );

  test(
    'recovery needs exact target table and verified live restoration before final writes',
    () {
      final image = UsbFirmwareImage.fromBytes(_name, _image());
      final plan = UsbPartitionExpansion.createPlan(
        analysis: _analysis(image),
        packageZip: _package(image),
      );
      final recovery = UsbPartitionExpansion.verifyRecovery(
        plan: plan,
        table: plan.targetTable,
        nvs: _nvs(restored: true),
        otadata: _ota(sequence: 2),
      );
      expect(recovery.appOffsets, [0x10000, 0x650000]);
      expect(recovery.identityRestored, isTrue);
      for (final nvs in [
        _erased(0x5000),
        _nvs(restored: false),
        _nvs(restored: true, pending: true),
        _nvs(restored: true, identityPending: true),
      ]) {
        expect(
          () => UsbPartitionExpansion.verifyRecovery(
            plan: plan,
            table: plan.targetTable,
            nvs: nvs,
            otadata: _ota(),
          ),
          _rejects,
        );
      }
      expect(
        () => UsbPartitionExpansion.verifyRecovery(
          plan: plan,
          table: _sourceTable(),
          nvs: _nvs(restored: true),
          otadata: _ota(),
        ),
        _rejects,
      );
    },
  );

  test(
    'strict JSON refuses duplicate keys, excessive depth and trailing data',
    () {
      expect(
        () => usbStrictJson(Uint8List.fromList(utf8.encode('{"a":1,"a":2}'))),
        _rejects,
      );
      expect(
        () => usbStrictJson(
          Uint8List.fromList(utf8.encode('${'[' * 70}0${']' * 70}')),
        ),
        _rejects,
      );
      expect(
        () => usbStrictJson(Uint8List.fromList(utf8.encode('{} {}'))),
        _rejects,
      );
      expect(
        usbStrictJson(
          Uint8List.fromList(utf8.encode('{"a":"\\"","b":[true,null,3]}')),
        ),
        {
          'a': '"',
          'b': [true, null, 3],
        },
      );
    },
  );

  test(
    'ZIP rejects unsafe paths, symlinks, CRC corruption and bounded expansion',
    () {
      final normal = _zip({
        'manifest.json': Uint8List.fromList([1, 2, 3]),
      });
      expect(checkedZipEntries(normal).keys, ['manifest.json']);
      expect(
        () => checkedZipEntries(
          _zip({
            '../escape.bin': Uint8List.fromList([1]),
          }),
        ),
        _rejects,
      );
      expect(() => checkedZipEntries(normal, maxExpandedBytes: 2), _rejects);
      final bad = Uint8List.fromList(normal);
      final central = _centralOffset(bad);
      ByteData.sublistView(bad).setUint32(central + 16, 123, Endian.little);
      ByteData.sublistView(bad).setUint32(14, 123, Endian.little);
      expect(() => checkedZipEntries(bad), _rejects);
      final link = Uint8List.fromList(normal);
      ByteData.sublistView(
        link,
      ).setUint32(_centralOffset(link) + 38, 0xa1ff << 16, Endian.little);
      expect(() => checkedZipEntries(link), _rejects);
      final wrongName = Uint8List.fromList(normal)..[30] ^= 1;
      expect(() => checkedZipEntries(wrongName), _rejects);
    },
  );

  test(
    'only fully qualified legacy Full package requests the USB fallback',
    () {
      final image = UsbFirmwareImage.fromBytes(_name, _image());
      final analysis = _analysis(image);
      expect(
        () => UsbPartitionExpansion.createPlan(
          analysis: analysis,
          packageZip: _package(image, embeddedUsb: false),
        ),
        throwsA(
          isA<UsbFirmwareValidationException>().having(
            (e) => e.code,
            'code',
            'usb_bridge_missing',
          ),
        ),
      );
      for (final zip in [
        _package(image, embeddedUsb: false, badCaps: true),
        _package(
          image,
          embeddedUsb: false,
          metadata: {'source_commit': '87654321'},
        ),
        _package(image, embeddedUsb: false, metadata: {'usb_migration': {}}),
      ]) {
        expect(
          () => UsbPartitionExpansion.createPlan(
            analysis: analysis,
            packageZip: zip,
          ),
          throwsA(
            isA<UsbFirmwareValidationException>().having(
              (e) => e.code,
              'code',
              isNull,
            ),
          ),
        );
      }
    },
  );

  test('ZIP duplicate names are rejected before decoder can merge them', () {
    final zip = _zip({
      'one.bin': Uint8List.fromList([1]),
      'two.bin': Uint8List.fromList([2]),
    });
    final bad = Uint8List.fromList(zip);
    var central = _centralOffset(bad);
    central +=
        46 +
        usbUint16(bad, central + 28) +
        usbUint16(bad, central + 30) +
        usbUint16(bad, central + 32);
    final local = usbUint32(bad, central + 42);
    bad.setRange(central + 46, central + 53, ascii.encode('one.bin'));
    bad.setRange(local + 30, local + 37, ascii.encode('one.bin'));
    expect(() => checkedZipEntries(bad), _rejects);
  });

  test(
    'lying ZIP uncompressed size stops inflation before declared ceiling',
    () {
      final zip = _zip({'payload.bin': Uint8List(100000)});
      final central = _centralOffset(zip);
      final local = usbUint32(zip, central + 42);
      final view = ByteData.sublistView(zip);
      view.setUint32(central + 24, 1, Endian.little);
      view.setUint32(local + 22, 1, Endian.little);
      expect(() => checkedZipEntries(zip), _rejects);
    },
  );

  final integrationDirectory =
      Platform.environment['USB_MIGRATION_INTEGRATION'];
  final integrationSet = Platform.environment['USB_MIGRATION_SET'];
  test(
    'optional real published 4/8/16 MiB packages match desktop policy',
    () {
      final directory = Directory(integrationDirectory!);
      final set = File(integrationSet!).readAsBytesSync();
      for (final (board, flash) in [
        ('heltec-v4', 16 << 20),
        ('heltec-v3-repeater', 8 << 20),
        ('thinknode-m2-repeater', 4 << 20),
      ]) {
        final package = File(
          '${directory.path}/$board-v1.17.1.9-halo-keymind-cascade-dev-88c85108-migration.zip',
        ).readAsBytesSync();
        final fixture = Directory('${directory.path}/$board-fixtures');
        final binFile = fixture.listSync().whereType<File>().firstWhere(
          (f) => f.path.contains('-full-usa-') && f.path.endsWith('.bin'),
        );
        final image = UsbFirmwareImage.fromBytes(
          binFile.uri.pathSegments.last,
          binFile.readAsBytesSync(),
        );
        final analysis = UsbPartitionExpansion.analyze(
          image: image,
          table: File('${fixture.path}/legacy-table.bin').readAsBytesSync(),
          flashBytes: flash,
          chip: 9,
          otadata: File('${fixture.path}/otadata.bin').readAsBytesSync(),
          nvs: File('${fixture.path}/erased-nvs.bin').readAsBytesSync(),
        );
        final plan = UsbPartitionExpansion.createPlan(
          analysis: analysis,
          packageZip: package,
          usbSetZip: set,
        );
        final recovery = UsbPartitionExpansion.verifyRecovery(
          plan: plan,
          table: File('${fixture.path}/expanded-table.bin').readAsBytesSync(),
          nvs: File(
            '${fixture.path}/synthetic-completed-nvs.bin',
          ).readAsBytesSync(),
          otadata: File('${fixture.path}/otadata.bin').readAsBytesSync(),
        );
        expect(plan.board, board);
        expect(recovery.appOffsets.last, 0x10000);
        expect(
          recovery.appOffsets.first,
          {4 << 20: 0x200000, 8 << 20: 0x340000, 16 << 20: 0x650000}[flash],
        );
      }
    },
    skip: integrationDirectory == null || integrationSet == null,
  );

  test('manifest and SHA256SUMS inventories cannot omit or add entries', () {
    final image = UsbFirmwareImage.fromBytes(_name, _image());
    final package = _package(image);
    final files = checkedZipEntries(package);
    final sums = Uint8List.fromList(
      ascii.encode('0' * 64 + '  manifest.json\n'),
    );
    expect(
      () =>
          UsbVerifiedPackage.fromZip(_zip({...files, 'SHA256SUMS.txt': sums})),
      _rejects,
    );
    expect(
      () => UsbVerifiedPackage.fromZip(
        _zip({
          ...files,
          'unexpected.bin': Uint8List.fromList([1]),
        }),
      ),
      _rejects,
    );
  });
}

UsbPartitionAnalysis _analysis(UsbFirmwareImage image) =>
    UsbPartitionExpansion.analyze(
      image: image,
      table: _sourceTable(),
      flashBytes: _flash,
      chip: 9,
      otadata: _ota(),
      nvs: _erased(0x5000),
    );

Uint8List _erased(int length) => Uint8List(length)..fillRange(0, length, 0xff);

Uint8List _image({
  int payloadSize = 0x140000,
  int chip = 9,
  int flash = _flash,
  bool endf = true,
  List<int>? payloadPrefix,
}) {
  final header = Uint8List(24);
  header[0] = 0xe9;
  header[1] = 1;
  header[2] = 2;
  header[3] = ((flash.bitLength - 21) << 4);
  header[23] = 1;
  ByteData.sublistView(header).setUint16(12, chip, Endian.little);
  final segment = Uint8List(8);
  ByteData.sublistView(segment).setUint32(4, payloadSize, Endian.little);
  final payload = Uint8List(payloadSize);
  if (payloadPrefix != null) {
    payload.setRange(0, payloadPrefix.length, payloadPrefix);
  }
  final builder = BytesBuilder()
    ..add(header)
    ..add(segment)
    ..add(payload);
  final length = 32 + payloadSize;
  final padding = Uint8List(((length ~/ 16) + 1) * 16 - length);
  padding[padding.length - 1] = payload.fold(0xef, (a, b) => a ^ b);
  builder.add(padding);
  final withoutHash = builder.toBytes();
  builder.add(crypto.sha256.convert(withoutHash).bytes);
  final application = builder.toBytes();
  if (!endf) return application;
  final trailer = Uint8List(56)..setRange(0, 4, ascii.encode('EndF'));
  final view = ByteData.sublistView(trailer);
  view.setUint32(4, application.length, Endian.little);
  trailer.setRange(
    8,
    16,
    crypto.sha256.convert(application).bytes.sublist(0, 8),
  );
  view.setUint32(16, 0x01120001, Endian.little);
  final target = const UsbMigrationTarget(
    'heltec-v4',
    'heltec_v4_repeater',
  ).targetId;
  view.setUint32(20, target, Endian.little);
  trailer.setRange(24, 33, ascii.encode('heltec-v4'));
  return Uint8List.fromList([...application, ...trailer]);
}

List<UsbFlashPartition> _sourceEntries() => const [
  UsbFlashPartition(
    name: 'nvs',
    type: 1,
    subtype: 2,
    offset: 0x9000,
    size: 0x5000,
  ),
  UsbFlashPartition(
    name: 'otadata',
    type: 1,
    subtype: 0,
    offset: 0xe000,
    size: 0x2000,
  ),
  UsbFlashPartition(
    name: 'app0',
    type: 0,
    subtype: 0x10,
    offset: 0x10000,
    size: 0x140000,
  ),
  UsbFlashPartition(
    name: 'app1',
    type: 0,
    subtype: 0x11,
    offset: 0x150000,
    size: 0x140000,
  ),
  UsbFlashPartition(
    name: 'spiffs',
    type: 1,
    subtype: 0x82,
    offset: 0x290000,
    size: 0x160000,
  ),
];
Uint8List _sourceTable() => _table(_sourceEntries());
Uint8List _table(List<UsbFlashPartition> entries) {
  final bytes = _erased(4096);
  final view = ByteData.sublistView(bytes);
  var offset = 0;
  for (final p in entries) {
    bytes.fillRange(offset, offset + 32, 0);
    bytes[offset] = 0xaa;
    bytes[offset + 1] = 0x50;
    bytes[offset + 2] = p.type;
    bytes[offset + 3] = p.subtype;
    view.setUint32(offset + 4, p.offset, Endian.little);
    view.setUint32(offset + 8, p.size, Endian.little);
    bytes.setRange(
      offset + 12,
      offset + 12 + p.name.length,
      ascii.encode(p.name),
    );
    view.setUint32(offset + 28, p.flags, Endian.little);
    offset += 32;
  }
  bytes[offset] = bytes[offset + 1] = 0xeb;
  bytes.setRange(
    offset + 16,
    offset + 32,
    crypto.md5.convert(bytes.sublist(0, offset)).bytes,
  );
  return bytes;
}

Uint8List _ota({int? sequence, int? second}) {
  final bytes = _erased(8192);
  final view = ByteData.sublistView(bytes);
  for (final (offset, seq) in [(0, sequence), (4096, second)]) {
    if (seq == null) continue;
    view.setUint32(offset, seq, Endian.little);
    view.setUint32(offset + 24, 2, Endian.little);
    view.setUint32(
      offset + 28,
      usbCrc32(bytes.sublist(offset, offset + 4), 0xffffffff),
      Endian.little,
    );
  }
  return bytes;
}

Uint8List _nvs({
  required bool restored,
  bool pending = false,
  bool identityPending = false,
  int restoredKind = 1,
}) {
  final bytes = _erased(0x5000);
  final page = Uint8List.sublistView(bytes, 0, 4096);
  final view = ByteData.sublistView(page);
  view.setUint32(0, 0xfffffffe, Endian.little);
  view.setUint32(4, 1, Endian.little);
  view.setUint32(28, usbCrc32(page.sublist(4, 28), 0xffffffff), Endian.little);
  _setNvsEntry(page, 0, namespace: 0, key: 'mesh-pt-migrate', value: 1);
  _setNvsEntry(
    page,
    1,
    namespace: 1,
    key: 'cfg-restored',
    value: restored ? 1 : 0,
    kind: restoredKind,
  );
  if (pending) {
    _setNvsEntry(page, 2, namespace: 1, key: 'cfg-pending', value: 1);
  }
  if (identityPending) {
    _setNvsEntry(
      page,
      pending ? 3 : 2,
      namespace: 1,
      key: 'id-pending',
      value: 1,
    );
  }
  return bytes;
}

void _setNvsEntry(
  Uint8List page,
  int index, {
  required int namespace,
  required String key,
  required int value,
  int kind = 1,
  int span = 1,
  Uint8List? body,
}) {
  for (var i = index; i < index + span; i++) {
    final bit = i * 2;
    final offset = 32 + bit ~/ 8;
    page[offset] = (page[offset] & ~(3 << (bit % 8))) | (2 << (bit % 8));
  }
  final entry = Uint8List.sublistView(page, 64 + 32 * index, 96 + 32 * index);
  entry.fillRange(0, entry.length, 0xff);
  entry[0] = namespace;
  entry[1] = kind;
  entry[2] = span;
  entry[3] = 0xff;
  entry.fillRange(8, 24, 0);
  entry.setRange(8, 8 + key.length, ascii.encode(key));
  final view = ByteData.sublistView(entry);
  if (body == null) {
    entry[24] = value;
  } else {
    view.setUint16(24, body.length, Endian.little);
    view.setUint32(28, usbCrc32(body, 0xffffffff), Endian.little);
    page.setRange(
      64 + 32 * (index + 1),
      64 + 32 * (index + 1) + body.length,
      body,
    );
  }
  view.setUint32(
    4,
    usbCrc32([...entry.sublist(0, 4), ...entry.sublist(8)], 0xffffffff),
    Endian.little,
  );
}

Uint8List _bridge(int chip, int flash, {bool badMarker = false}) => _image(
  payloadSize: 200,
  chip: chip,
  flash: flash,
  endf: false,
  payloadPrefix: ascii.encode(
    '${badMarker ? 'bad' : UsbPartitionExpansion.usbBridgeMarker}\x00${UsbPartitionExpansion.usbNvsGuardMarker}',
  ),
);

Map<String, dynamic> _usbMetadata(int chip) => {
  'format': 'meshcore-usb-partition-migration-v1',
  'bridge': 'usb-bridge.bin',
  'automatic_rom_return': chip != 0,
  'uart_completion_status': chip == 0,
  'host_software_bootloader_entry': true,
  'application_usb_cdc': false,
};

Uint8List _package(
  UsbFirmwareImage image, {
  Map<String, dynamic> metadata = const {},
  bool embeddedUsb = true,
  bool badCaps = false,
}) {
  final files = <String, Uint8List>{
    'wifi-bridge.bin': Uint8List.fromList([1]),
    'full-application.bin': image.bytes,
    'target-partitions.bin': UsbPartitionExpansion.canonicalTable(_flash),
    'capabilities.json': Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'target': 'heltec_v4_repeater',
          'build_profile': badCaps ? 'lite' : 'full',
          'platform': 'ESP32_PLATFORM',
          'ota_update_verified': true,
        }),
      ),
    ),
    if (embeddedUsb) 'usb-bridge.bin': _bridge(9, _flash),
  };
  return _inventoryZip(files, {
    'firmware_version': 'v1.18.0.1-halo-keymind-cascade-dev',
    'source_commit': '12345678',
    'board': 'heltec-v4',
    'target': 'heltec_v4_repeater',
    'hardware_id': 'heltec-v4',
    'target_id': '0x${image.endf!.targetId.toRadixString(16).padLeft(8, '0')}',
    'role': 'repeater',
    'flash_bytes': _flash,
    'atomic_power_loss_recovery': false,
    'legacy_slot_bytes': 0x140000,
    'expanded_slot_bytes': 0x640000,
    if (embeddedUsb) 'usb_migration': _usbMetadata(9),
    ...metadata,
  });
}

Uint8List _usbSet({bool omitLast = false, bool badMarker = false}) {
  final profiles = [
    (0, 4 << 20),
    (0, 8 << 20),
    (5, 4 << 20),
    (9, 4 << 20),
    (9, 8 << 20),
    if (!omitLast) (9, 16 << 20),
  ];
  final files = <String, Uint8List>{
    'README.md': Uint8List.fromList(ascii.encode('USB utility')),
  };
  final bridges = <Map<String, dynamic>>[];
  for (final (chip, flash) in profiles) {
    final name = 'bridge-$chip-$flash.bin';
    files[name] = _bridge(chip, flash, badMarker: badMarker && chip == 0);
    bridges.add({
      ..._usbMetadata(chip),
      'chip': chip,
      'flash_bytes': flash,
      'file': name,
    });
  }
  return _inventoryZip(files, {
    'format': 'meshcore-usb-partition-bridges-v1',
    'source_commit': '12345678',
    'working_tree_dirty': false,
    'source_tree_sha256': '0' * 64,
    'bridges': bridges,
  });
}

Uint8List _inventoryZip(
  Map<String, Uint8List> source,
  Map<String, dynamic> metadata,
) {
  final manifest = {
    ...metadata,
    'files': {
      for (final entry in source.entries)
        entry.key: {
          'bytes': entry.value.length,
          'sha256': usbSha256(entry.value),
        },
    },
  };
  final files = {
    ...source,
    'manifest.json': Uint8List.fromList(utf8.encode(jsonEncode(manifest))),
  };
  files['SHA256SUMS.txt'] = Uint8List.fromList(
    ascii.encode(
      files.entries.map((e) => '${usbSha256(e.value)}  ${e.key}\n').join(),
    ),
  );
  return _zip(files);
}

Uint8List _zip(Map<String, Uint8List> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.add(ArchiveFile.bytes(entry.key, entry.value));
  }
  return ZipEncoder().encodeBytes(archive);
}

int _centralOffset(Uint8List bytes) {
  for (var offset = bytes.length - 22; offset >= 0; offset--) {
    if (usbUint32(bytes, offset) == 0x06054b50) {
      return usbUint32(bytes, offset + 16);
    }
  }
  throw StateError('missing zip footer');
}

// Public-data fixture builders shared with the orchestration safety tests.
// These are generated test images and synthetic metadata, never node secrets.
Uint8List usbUpdateTestImage({int payloadSize = 0x140000}) =>
    _image(payloadSize: payloadSize);
Uint8List usbUpdateTestSourceTable() => _sourceTable();
Uint8List usbUpdateTestTable(List<UsbFlashPartition> entries) =>
    _table(entries);
Uint8List usbUpdateTestOta({int? sequence}) => _ota(sequence: sequence);
Uint8List usbUpdateTestNvs({bool restored = true, bool pending = false}) =>
    _nvs(restored: restored, pending: pending);
Uint8List usbUpdateTestPackage(UsbFirmwareImage image) => _package(image);
Uint8List usbUpdateTestUsbSet() => _usbSet();
