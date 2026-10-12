import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/usb_esp_flash_engine.dart';
import 'package:meshcore_open/services/usb_firmware_catalog.dart';
import 'package:meshcore_open/services/usb_firmware_package.dart';
import 'package:meshcore_open/services/usb_flash_transport.dart';
import 'package:meshcore_open/services/usb_node_backup.dart';
import 'package:meshcore_open/services/usb_node_update_service.dart';
import 'package:meshcore_open/services/usb_partition_expansion.dart';

import 'usb_node_backup_test.dart' as backup_fixture;
import 'usb_partition_expansion_test.dart' as fixture;

const _firmwareName =
    'heltec_v4_repeater-full-v1.18.0.1-halo-keymind-cascade-dev-12345678.bin';
const _device = UsbFlashDevice(
  deviceName: '/dev/bus/usb/001/012',
  vendorId: 0x303a,
  productId: 0x1001,
  serialNumber: 'FAKE-MAC-BOUND-ENDPOINT',
  manufacturerName: 'Espressif',
  productName: 'Test Heltec V4',
  driver: 'CdcAcmSerialDriver',
);
const _chip = UsbEspChipInfo(
  chip: 9,
  flashBytes: 16 << 20,
  mac: '0123456789ab',
  name: 'ESP32-S3',
);
const _before = UsbNodeInfo(
  publicKey: backup_fixture.publicHex,
  role: 'repeater',
  hardwareModel: 'heltec-v4',
  firmwareVersion: 'v1.17.0',
);
const _after = UsbNodeInfo(
  publicKey: backup_fixture.publicHex,
  role: 'repeater',
  hardwareModel: 'heltec-v4',
  firmwareVersion: 'v1.18.0.1-test',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late List<String> events;
  late _FakeTransport transport;
  late _FakeEsp esp;
  late _FakeBackup backup;
  late _FakeCatalog catalog;
  late UsbNodeUpdateService service;
  late UsbNodeBackupArchive archive;

  setUpAll(() async {
    archive = await UsbNodeBackupService(
      backup_fixture.MockNode()..logging = false,
      timeout: const Duration(milliseconds: 30),
    ).capture(_device);
    expect(archive.isComplete, isTrue);
  });
  setUp(() async {
    root = await Directory.systemTemp.createTemp('meshcore-usb-update-test-');
    events = [];
    transport = _FakeTransport(events);
    esp = _FakeEsp(transport, events);
    backup = _FakeBackup(transport, events, archive);
    catalog = _FakeCatalog();
    service = UsbNodeUpdateService(
      transport: transport,
      esp: esp,
      backupService: backup,
      catalog: catalog,
      directory: () async => root,
    );
  });
  tearDown(() async {
    service.dispose();
    catalog.dispose();
    await root.delete(recursive: true);
  });

  Future<bool> consent(UsbUpdateQuestion question) async {
    events.add('confirm:${question.title}');
    return true;
  }

  Future<void> updateOrdinary({
    UsbUpdateConfirm? confirm,
    bool createBackup = true,
  }) => service.update(
    _device,
    _firmwareName,
    fixture.usbUpdateTestImage(payloadSize: 100),
    confirm: confirm ?? consent,
    createBackup: createBackup,
  );
  Future<void> updateExpansion({UsbUpdateConfirm? confirm}) {
    final image = UsbFirmwareImage.fromBytes(
      _firmwareName,
      fixture.usbUpdateTestImage(),
    );
    return service.update(
      _device,
      _firmwareName,
      image.bytes,
      confirm: confirm ?? consent,
      localMigrationZip: fixture.usbUpdateTestPackage(image),
      localUsbSetZip: fixture.usbUpdateTestUsbSet(),
    );
  }

  test(
    'denied prepare consent closes without any bootloader reset or write',
    () async {
      await updateOrdinary(confirm: (q) async => false);
      expect(events, contains('backup:capture'));
      expect(esp.connects, isEmpty);
      expect(esp.writes, isEmpty);
      expect(esp.runs, isEmpty);
      expect(service.succeeded, isFalse);
      expect(service.error, contains('cancelled'));
      expect(service.busy, isFalse);
    },
  );

  test(
    'backup saves and verifies before prepare consent and ROM connection',
    () async {
      await updateOrdinary();
      expect(service.succeeded, isTrue);
      final capture = events.indexOf('backup:capture');
      final prepare = events.indexOf(
        'confirm:Prepare this node for an update?',
      );
      final connect = events.indexOf('esp:connect:true');
      expect(capture, lessThan(prepare));
      expect(prepare, lessThan(connect));
      final saved = File(service.backupPath!);
      expect(await saved.exists(), isTrue);
      UsbNodeBackupArchive.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(await saved.readAsString()) as Map,
        ),
      ).verify();
      expect(esp.writes.map((w) => w.offset), [0x150000, 0x10000]);
      expect(esp.writes.every((w) => w.expectedMac == _chip.mac), isTrue);
    },
  );

  test(
    'denied write consent permits ROM inspection but no flash write',
    () async {
      await updateOrdinary(
        confirm: (q) async => q.title != 'Write application firmware?',
      );
      expect(esp.connects, [true]);
      expect(esp.writes, isEmpty);
      expect(esp.runs, isEmpty);
      expect(service.succeeded, isFalse);
    },
  );

  test(
    'backup failure needs explicit continue and denial stops before prepare',
    () async {
      backup.captureFailure = const UsbBackupUnavailable(
        'No companion response',
      );
      await updateOrdinary(
        confirm: (q) async {
          events.add('confirm:${q.title}');
          return false;
        },
      );
      expect(events, contains('confirm:Continue without a usable backup?'));
      expect(esp.connects, isEmpty);
      expect(esp.writes, isEmpty);
    },
  );

  test('wrong physical chip stops before snapshots or writes', () async {
    esp.connectedChip = const UsbEspChipInfo(
      chip: 5,
      flashBytes: 4 << 20,
      mac: '0123456789ab',
      name: 'ESP32-C3',
    );
    await updateOrdinary();
    expect(esp.reads, isEmpty);
    expect(esp.writes, isEmpty);
    expect(service.error, contains('different chip'));
  });

  test('ordinary update respects current active OTA slot', () async {
    esp.ota = fixture.usbUpdateTestOta(sequence: 2);
    await updateOrdinary(createBackup: false);
    expect(service.succeeded, isTrue);
    expect(esp.writes.map((w) => w.offset), [0x10000, 0x150000]);
  });

  test('cached final image mutation before write is refused', () async {
    await updateOrdinary(
      confirm: (q) async {
        if (q.title == 'Write application firmware?') {
          final artifacts = Directory('${root.path}/usb-updater/artifacts');
          final file = await artifacts
              .list(recursive: true)
              .where((e) => e is File && e.path.endsWith('.bin'))
              .cast<File>()
              .first;
          final bytes = await file.readAsBytes();
          bytes[40] ^= 1;
          await file.writeAsBytes(bytes, flush: true);
        }
        return true;
      },
    );
    expect(esp.writes, isEmpty);
    expect(service.error, contains('changed before writing'));
  });

  test(
    'expansion denial creates no pending journal and writes nothing',
    () async {
      await updateExpansion(
        confirm: (q) async => q.title != 'Expand partitions and update?',
      );
      expect(esp.writes, isEmpty);
      final journal = File(
        '${root.path}/usb-updater/recovery/${_chip.mac}/plan.json',
      );
      expect(await journal.exists(), isFalse);
    },
  );

  test(
    'native expansion writes bridge then waits passively before proven final slots',
    () async {
      await updateExpansion();
      expect(service.succeeded, isTrue);
      expect(esp.connects, [true, false]);
      expect(esp.writes.map((w) => w.offset), [
        0x150000,
        0x10000,
        0x650000,
        0x10000,
      ]);
      expect(esp.runs, [true, false]);
      expect(
        events.indexOf('transport:reacquire'),
        greaterThan(events.indexOf('esp:run:true')),
      );
      expect(esp.writes.every((w) => w.expectedMac == _chip.mac), isTrue);
      final journal =
          jsonDecode(
                await File(
                  '${root.path}/usb-updater/recovery/${_chip.mac}/plan.json',
                ).readAsString(),
              )
              as Map;
      expect(journal['completed'], isTrue);
      expect(journal.keys, isNot(contains('nvs')));
      expect(jsonEncode(journal), isNot(contains('private_key')));
    },
  );

  test('different recovered MAC blocks final firmware after bridge', () async {
    esp.recoveredChip = const UsbEspChipInfo(
      chip: 9,
      flashBytes: 16 << 20,
      mac: 'aaaaaaaaaaaa',
      name: 'ESP32-S3',
    );
    await updateExpansion();
    expect(esp.connects, [true, false]);
    expect(esp.writes.length, 2);
    expect(esp.runs, [true]);
    expect(service.succeeded, isFalse);
    expect(service.error, contains('different chip'));
  });

  test(
    'expanded table alone is insufficient: missing live restoration blocks final write',
    () async {
      esp.restored = false;
      await updateExpansion();
      expect(esp.writes.length, 2);
      expect(esp.runs, [true]);
      expect(service.succeeded, isFalse);
      expect(service.error, contains('restoration'));
    },
  );

  test(
    'pending other-image journal blocks even a fitting ordinary application',
    () async {
      final image = UsbFirmwareImage.fromBytes(
        _firmwareName,
        fixture.usbUpdateTestImage(),
      );
      await _seedJournal(root, image);
      await updateOrdinary();
      expect(esp.writes, isEmpty);
      expect(esp.reads, isEmpty);
      expect(service.error, contains('migration is pending'));
    },
  );

  test(
    'interrupted target layout resumes without bridge rewrite only after real NVS proof',
    () async {
      final image = UsbFirmwareImage.fromBytes(
        _firmwareName,
        fixture.usbUpdateTestImage(),
      );
      await _seedJournal(root, image);
      esp.expanded = true;
      esp.restored = false;
      await updateExpansion();
      expect(esp.writes, isEmpty);
      expect(esp.runs, isEmpty);
      expect(service.succeeded, isFalse);
      expect(service.error, contains('restoration'));
      esp.restored = true;
      await updateExpansion();
      expect(service.succeeded, isTrue);
      expect(esp.writes.map((w) => w.offset), [0x650000, 0x10000]);
      expect(esp.runs, [false]);
    },
  );

  test(
    'pending-source retry uses LIVE OTA ordering rather than cached pre-bridge OTA',
    () async {
      final image = UsbFirmwareImage.fromBytes(
        _firmwareName,
        fixture.usbUpdateTestImage(),
      );
      await _seedJournal(root, image);
      esp.ota = fixture.usbUpdateTestOta(sequence: 2);
      await updateExpansion();
      expect(service.succeeded, isTrue);
      expect(esp.writes.take(2).map((w) => w.offset), [0x10000, 0x150000]);
    },
  );

  test('recovery package mutation refuses every bridge/final write', () async {
    final image = UsbFirmwareImage.fromBytes(
      _firmwareName,
      fixture.usbUpdateTestImage(),
    );
    final journal = await _seedJournal(root, image);
    final package = File(journal['packagePath'] as String);
    final bytes = await package.readAsBytes();
    bytes[40] ^= 1;
    await package.writeAsBytes(bytes, flush: true);
    await updateExpansion();
    expect(esp.writes, isEmpty);
    expect(
      service.error,
      matches(RegExp(r'artifact.*changed', caseSensitive: false)),
    );
  });

  test(
    'malformed format and original OTA hash in pending journal are refused',
    () async {
      final image = UsbFirmwareImage.fromBytes(
        _firmwareName,
        fixture.usbUpdateTestImage(),
      );
      final journal = await _seedJournal(root, image);
      final file = File(
        '${root.path}/usb-updater/recovery/${_chip.mac}/plan.json',
      );
      journal['format'] = 'untrusted-format';
      await file.writeAsString(jsonEncode(journal));
      await updateExpansion();
      expect(esp.writes, isEmpty);
      expect(service.succeeded, isFalse);
      journal['format'] = 'meshcore-open-usb-migration-v1';
      journal['sourceOtadata'] = base64Encode(
        fixture.usbUpdateTestOta(sequence: 2),
      );
      await file.writeAsString(jsonEncode(journal));
      await updateExpansion();
      expect(esp.writes, isEmpty);
      expect(service.succeeded, isFalse);
    },
  );
  test(
    'journal cannot read recovery packages outside the private cache',
    () async {
      final image = UsbFirmwareImage.fromBytes(
        _firmwareName,
        fixture.usbUpdateTestImage(),
      );
      final journal = await _seedJournal(root, image);
      final source = File(journal['packagePath'] as String);
      final external = File('${root.path}/outside-private-artifacts.zip');
      await external.writeAsBytes(await source.readAsBytes(), flush: true);
      journal['packagePath'] = external.path;
      await File(
        '${root.path}/usb-updater/recovery/${_chip.mac}/plan.json',
      ).writeAsString(jsonEncode(journal), flush: true);
      await updateExpansion();
      expect(service.succeeded, isFalse);
      expect(esp.writes, isEmpty);
      expect(service.error, contains('outside the private cache'));
    },
  );

  test('qualified embedded USB bridge requires no extra download', () async {
    final image = UsbFirmwareImage.fromBytes(
      _firmwareName,
      fixture.usbUpdateTestImage(),
    );
    await service.update(
      _device,
      _firmwareName,
      image.bytes,
      confirm: consent,
      localMigrationZip: fixture.usbUpdateTestPackage(image),
    );
    expect(service.succeeded, isTrue, reason: service.error);
    expect(catalog.downloads, isEmpty);
  });

  test(
    'retry cannot redefine original identity after final identity verification failed',
    () async {
      backup.after = const UsbNodeInfo(
        publicKey: 'changed-public-identity',
        role: 'repeater',
        hardwareModel: 'heltec-v4',
        firmwareVersion: 'v1.18.0.1',
      );
      await updateExpansion();
      expect(service.succeeded, isFalse);
      await updateExpansion();
      expect(service.succeeded, isFalse);
      final journal =
          jsonDecode(
                await File(
                  '${root.path}/usb-updater/recovery/${_chip.mac}/plan.json',
                ).readAsString(),
              )
              as Map;
      expect(journal['completed'], isFalse);
    },
  );

  test('denied private-identity token stops before ANY USB access', () async {
    final questions = <UsbUpdateQuestion>[];
    await expectLater(
      service.restoreBackup(
        _device,
        archive,
        replaceIdentity: true,
        confirm: (question) async {
          questions.add(question);
          return question.token != 'replace-private-identity';
        },
      ),
      throwsA(isA<UsbUpdateCancelled>()),
    );
    expect(questions.map((q) => q.token), [null, 'replace-private-identity']);
    expect(events, isEmpty);
    expect(backup.restores, isEmpty);
    expect(esp.writes, isEmpty);
    expect(service.busy, isFalse);
  });

  test(
    'settings-only restore on new hardware keeps identity and requires only hardware token',
    () async {
      final questions = <UsbUpdateQuestion>[];
      await service.restoreBackup(
        _device,
        archive,
        newHardware: true,
        replaceIdentity: false,
        confirm: (question) async {
          questions.add(question);
          return true;
        },
      );
      expect(questions.map((q) => q.token), ['restore-to-new-hardware']);
      expect(backup.restores, [(_device, true, false)]);
      expect(service.succeeded, isTrue);
      expect(service.busy, isFalse);
      expect(esp.writes, isEmpty);
      expect(
        events.indexOf('transport:identity'),
        lessThan(events.indexOf('backup:restore')),
      );
    },
  );

  test(
    'identity import to new hardware separately requires BOTH tokens',
    () async {
      final questions = <UsbUpdateQuestion>[];
      await service.restoreBackup(
        _device,
        archive,
        newHardware: true,
        replaceIdentity: true,
        confirm: (question) async {
          questions.add(question);
          return true;
        },
      );
      expect(questions.map((q) => q.token), [
        'restore-to-new-hardware',
        'replace-private-identity',
      ]);
      expect(backup.restores, [(_device, true, true)]);
      expect(service.succeeded, isTrue);
    },
  );

  test(
    'new-hardware consent cannot substitute for denied private-key import',
    () async {
      final questions = <UsbUpdateQuestion>[];
      await expectLater(
        service.restoreBackup(
          _device,
          archive,
          newHardware: true,
          replaceIdentity: true,
          confirm: (question) async {
            questions.add(question);
            return question.token != 'replace-private-identity';
          },
        ),
        throwsA(isA<UsbUpdateCancelled>()),
      );
      expect(questions.map((q) => q.token), [
        'restore-to-new-hardware',
        'replace-private-identity',
      ]);
      expect(events, isEmpty);
      expect(backup.restores, isEmpty);
    },
  );

  test('larger OTA partition reads exactly the selection records', () async {
    esp.tableOverride = fixture.usbUpdateTestTable(const [
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
        size: 0x4000,
      ),
      UsbFlashPartition(
        name: 'app0',
        type: 0,
        subtype: 0x10,
        offset: 0x20000,
        size: 0x140000,
      ),
      UsbFlashPartition(
        name: 'app1',
        type: 0,
        subtype: 0x11,
        offset: 0x160000,
        size: 0x140000,
      ),
    ]);
    await updateOrdinary();
    expect(service.succeeded, isTrue);
    expect(esp.reads, contains((0xe000, 0x2000)));
    expect(esp.reads, isNot(contains((0xe000, 0x4000))));
    expect(esp.writes.map((w) => w.offset), [0x160000, 0x20000]);
  });

  test(
    'cached firmware mutation during expansion consent blocks FIRST bridge write',
    () async {
      await updateExpansion(
        confirm: (q) async {
          if (q.title == 'Expand partitions and update?') {
            final artifacts = Directory('${root.path}/usb-updater/artifacts');
            final file = await artifacts
                .list(recursive: true)
                .where((e) => e is File && e.path.endsWith('.bin'))
                .cast<File>()
                .first;
            final bytes = await file.readAsBytes();
            bytes[40] ^= 1;
            await file.writeAsBytes(bytes, flush: true);
          }
          return true;
        },
      );
      expect(esp.writes, isEmpty);
      expect(esp.runs, isEmpty);
      expect(service.succeeded, isFalse);
    },
  );

  test('final application identity mismatch leaves recovery pending', () async {
    backup.after = const UsbNodeInfo(
      publicKey: 'changed-public-identity',
      role: 'repeater',
      hardwareModel: 'heltec-v4',
      firmwareVersion: 'v1.18.0.1',
    );
    await updateExpansion();
    expect(service.succeeded, isFalse);
    expect(service.error, contains('identity changed'));
    final journal =
        jsonDecode(
              await File(
                '${root.path}/usb-updater/recovery/${_chip.mac}/plan.json',
              ).readAsString(),
            )
            as Map;
    expect(journal['completed'], isFalse);
  });

  test('local qualified USB set resumes without reselecting its ZIP', () async {
    final image = UsbFirmwareImage.fromBytes(
      _firmwareName,
      fixture.usbUpdateTestImage(),
    );
    await _seedJournal(root, image);
    esp.expanded = true;
    await service.update(
      _device,
      _firmwareName,
      image.bytes,
      confirm: consent,
      createBackup: false,
    );
    expect(service.succeeded, isTrue, reason: service.error);
    expect(esp.writes.map((w) => w.offset), [0x650000, 0x10000]);
  });
}

class _Write {
  _Write(this.offset, this.bytes, this.expectedMac);
  final int offset;
  final Uint8List bytes;
  final String expectedMac;
}

class _FakeEsp extends UsbEspFlashEngine {
  _FakeEsp(super.transport, this.events);
  final List<String> events;
  UsbEspChipInfo connectedChip = _chip;
  UsbEspChipInfo? recoveredChip;
  final connects = <bool>[], runs = <bool>[];
  final writes = <_Write>[];
  final reads = <(int, int)>[];
  UsbEspChipInfo? activeChip;
  bool expanded = false, restored = true;
  Uint8List? tableOverride;
  Uint8List ota = fixture.usbUpdateTestOta();
  @override
  UsbEspChipInfo? get chipInfo => activeChip;
  @override
  Future<UsbEspChipInfo> connect(
    UsbFlashDevice device, {
    bool reset = true,
  }) async {
    events.add('esp:connect:$reset');
    connects.add(reset);
    activeChip = connects.length > 1
        ? recoveredChip ?? connectedChip
        : connectedChip;
    return activeChip!;
  }

  @override
  Future<Uint8List> readFlash(int offset, int length) async {
    reads.add((offset, length));
    if (offset == 0x8000) {
      return expanded
          ? UsbPartitionExpansion.canonicalTable(16 << 20)
          : tableOverride ?? fixture.usbUpdateTestSourceTable();
    }
    if (offset == 0x9000) {
      if (expanded) return fixture.usbUpdateTestNvs(restored: restored);
      return Uint8List(0x5000)..fillRange(0, 0x5000, 0xff);
    }
    if (offset == 0xe000) return ota;
    throw StateError('Unexpected synthetic flash region');
  }

  @override
  Future<void> writeFlash(
    int offset,
    Uint8List bytes, {
    required String expectedMac,
  }) async {
    if (expectedMac != activeChip?.mac) {
      throw StateError('Connected chip identity changed');
    }
    events.add('esp:write:$offset');
    writes.add(_Write(offset, Uint8List.fromList(bytes), expectedMac));
  }

  @override
  Future<void> runApplication({bool migrationBridge = false}) async {
    events.add('esp:run:$migrationBridge');
    runs.add(migrationBridge);
    if (migrationBridge) expanded = true;
    activeChip = null;
  }

  @override
  Future<void> close() async {
    events.add('esp:close');
    activeChip = null;
  }
}

class _FakeTransport extends UsbFlashTransport {
  _FakeTransport(this.events);
  final List<String> events;
  UsbFlashDevice? active;
  @override
  UsbFlashDevice? get activeDevice => active;
  @override
  Future<UsbFlashDevice> readIdentity(UsbFlashDevice device) async {
    events.add('transport:identity');
    return device;
  }

  @override
  Future<void> open(UsbFlashDevice device, {int baudRate = 115200}) async {
    events.add('transport:open');
    active = device;
  }

  @override
  Future<UsbFlashDevice> reacquire(
    UsbFlashDevice original, {
    Duration timeout = const Duration(seconds: 180),
  }) async {
    events.add('transport:reacquire');
    return original;
  }

  @override
  Future<void> close() async {
    events.add('transport:close');
    active = null;
  }

  @override
  Future<void> setKeepAwake(bool enabled) async => events.add('awake:$enabled');
  @override
  Future<List<UsbFlashDevice>> listDevices() async => [_device];
}

class _FakeBackup extends UsbNodeBackupService {
  _FakeBackup(super.transport, this.events, this.archive);
  final List<String> events;
  final UsbNodeBackupArchive archive;
  Object? captureFailure;
  var inspections = 0;
  UsbNodeInfo after = _after;
  final restores = <(UsbFlashDevice, bool, bool)>[];
  @override
  Future<void> restore(
    UsbFlashDevice device,
    UsbNodeBackupArchive archive, {
    bool replaceIdentity = false,
    bool newHardware = false,
    void Function(double progress, String stage)? onProgress,
  }) async {
    events.add('backup:restore');
    archive.verify();
    restores.add((device, newHardware, replaceIdentity));
    await transport.open(device);
    onProgress?.call(1, 'Synthetic settings restore verified.');
    await transport.close();
  }

  @override
  Future<UsbNodeBackupArchive> capture(
    UsbFlashDevice device, {
    bool isDfu = false,
  }) async {
    events.add('backup:capture');
    if (captureFailure != null) throw captureFailure!;
    return archive;
  }

  @override
  Future<UsbNodeInfo> inspect(
    UsbFlashDevice device, {
    bool isDfu = false,
  }) async {
    events.add('backup:inspect');
    return inspections++ == 0 ? _before : after;
  }
}

class _FakeCatalog extends UsbFirmwareCatalog {
  final downloads = <Uri>[];
  @override
  Future<Uint8List> download(
    Uri url, {
    int limit = UsbFirmwareCatalog.maxArtifactBytes,
    String? expectedSha256,
    int? expectedBytes,
  }) async {
    downloads.add(url);
    throw StateError('Tests must not access the network');
  }
}

Future<Map<String, dynamic>> _seedJournal(
  Directory root,
  UsbFirmwareImage image,
) async {
  final directory = Directory('${root.path}/usb-updater/recovery/${_chip.mac}');
  await directory.create(recursive: true);
  final packageZip = fixture.usbUpdateTestPackage(image);
  final usbSet = fixture.usbUpdateTestUsbSet();
  final packageDirectory = Directory(
    '${root.path}/usb-updater/artifacts/${usbSha256(packageZip)}',
  );
  final usbDirectory = Directory(
    '${root.path}/usb-updater/artifacts/${usbSha256(usbSet)}',
  );
  final firmwareDirectory = Directory(
    '${root.path}/usb-updater/artifacts/${image.sha256}',
  );
  await packageDirectory.create(recursive: true);
  await usbDirectory.create(recursive: true);
  await firmwareDirectory.create(recursive: true);
  final package = File('${packageDirectory.path}/full-migration.zip');
  final usb = File('${usbDirectory.path}/usb-bridges.zip');
  final firmware = File('${firmwareDirectory.path}/${image.name}');
  await package.writeAsBytes(packageZip, flush: true);
  await usb.writeAsBytes(usbSet, flush: true);
  await firmware.writeAsBytes(image.bytes, flush: true);
  final originalTable = fixture.usbUpdateTestSourceTable();
  final originalOta = fixture.usbUpdateTestOta();
  final journal = <String, dynamic>{
    'format': 'meshcore-open-usb-migration-v1',
    'mac': _chip.mac,
    'chip': _chip.chip,
    'flashBytes': _chip.flashBytes,
    'firmwareSha256': image.sha256,
    'firmwarePath': firmware.path,
    'packagePath': package.path,
    'packageSha256': usbSha256(packageZip),
    'usbSetPath': usb.path,
    'usbSetSha256': usbSha256(usbSet),
    'localUsbSet': true,
    'usbSetPinned': false,
    'originalPublicKey': _before.publicKey,
    'sourceTable': base64Encode(originalTable),
    'sourceTableSha256': usbSha256(originalTable),
    'sourceOtadata': base64Encode(originalOta),
    'sourceOtadataSha256': usbSha256(originalOta),
    'started': true,
    'completed': false,
  };
  await File(
    '${directory.path}/plan.json',
  ).writeAsString(jsonEncode(journal), flush: true);
  return journal;
}
