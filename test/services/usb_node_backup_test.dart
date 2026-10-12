import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/usb_flash_transport.dart';
import 'package:meshcore_open/services/usb_node_backup.dart';

const device = UsbFlashDevice(
  deviceName: '/dev/bus/usb/001/002',
  vendorId: 0x2886,
  productId: 0x1666,
  serialNumber: 'UNIT-TEST-SERIAL',
  manufacturerName: 'Seeed',
  productName: 'Test node',
  driver: 'CdcAcmSerialDriver',
);
const publicHex =
    'ca4a448c3fc4d04945da9fdf920976c05e9bbe3d8cebb1858ea44d587c5e63c3';
Uint8List hex(String value) => Uint8List.fromList([
  for (var i = 0; i < value.length; i += 2)
    int.parse(value.substring(i, i + 2), radix: 16),
]);
Uint8List selfFrame({String key = publicHex, String name = 'Test companion'}) {
  final f = Uint8List(58 + utf8.encode(name).length);
  final v = ByteData.sublistView(f);
  f[0] = 5;
  f[1] = 1;
  f[2] = 22;
  f[3] = 26;
  f.setRange(4, 36, hex(key));
  v.setInt32(36, 1, Endian.little);
  v.setInt32(40, -122123456, Endian.little);
  f[44] = 2;
  f[45] = 1;
  f[46] = 0x15;
  f[47] = 1;
  v.setUint32(48, 911300, Endian.little);
  v.setUint32(52, 125000, Endian.little);
  f[56] = 8;
  f[57] = 5;
  f.setRange(58, f.length, utf8.encode(name));
  return f;
}

Uint8List infoFrame({
  String model = 'Test nRF52',
  String version = 'v1.18.0.1-test',
}) {
  final f = Uint8List(82);
  f[0] = 13;
  f[1] = 14;
  f[2] = 5;
  f[3] = 2;
  ByteData.sublistView(f).setUint32(4, 123456, Endian.little);
  f.setRange(8, 20, ascii.encode('11-Oct-2026\x00'));
  f.setRange(20, 20 + model.length, ascii.encode(model));
  f.setRange(60, 60 + version.length, ascii.encode(version));
  f[81] = 2;
  return f;
}

Uint8List contactFrame() {
  final f = Uint8List(148);
  f[0] = 3;
  f.setRange(1, 33, List.filled(32, 42));
  f[33] = 1;
  f[34] = 2;
  f[35] = 2;
  f[36] = 0;
  f[37] = 7;
  f.setRange(100, 104, ascii.encode('Peer'));
  ByteData.sublistView(f).setUint32(132, 321, Endian.little);
  return f;
}

class MockNode extends UsbFlashTransport {
  final rx = <int>[];
  final commands = <List<int>>[];
  final writes = <String>[];
  bool opened = false;
  int closed = 0;
  int selfQueries = 0;
  bool changeIdentity = false;
  bool badContacts = false;
  bool disablePrivate = false;
  bool commonCli = false;
  bool fullTerminal = false;
  bool binary = true;
  bool logging = true;
  String name = 'Test companion';
  String model = 'Test nRF52';
  String liveKey = publicHex;
  int channelWrites = 0;
  UsbFlashDevice endpoint = device;
  final signalRequests = <({bool dtr, bool rts})>[];
  @override
  UsbFlashDevice? get activeDevice => opened ? endpoint : null;
  @override
  Future<void> open(UsbFlashDevice target, {int baudRate = 115200}) async {
    opened = true;
    endpoint = target;
    binary = !fullTerminal;
  }

  @override
  Future<void> close() async {
    opened = false;
    closed++;
  }

  @override
  Future<void> purge() async {
    rx.clear();
  }

  @override
  Future<void> setSignals({required bool dtr, required bool rts}) async {
    signalRequests.add((dtr: dtr, rts: rts));
    expect(dtr, true);
    expect(rts, false);
  }

  void framed(List<int> payload) {
    rx.addAll([62, payload.length & 255, payload.length >> 8, ...payload]);
  }

  void text(String value) {
    rx.addAll(utf8.encode('$value\n'));
  }

  @override
  Future<void> write(Uint8List bytes) async {
    if (bytes[0] != 60) {
      final command = ascii.decode(bytes).trim();
      writes.add(command);
      if (command == '+++MESHCORE-TERM-START' && fullTerminal) {
        binary = false;
        text('OK - Terminal mode');
        return;
      }
      if (command == '+++MESHCORE-TERM-STOP' && fullTerminal) {
        binary = true;
        text('OK - Binary mode');
        return;
      }
      if (command == 'get usb.logging' && fullTerminal) {
        text('usb.logging ${logging ? 'on' : 'off'}; port: CDC');
        return;
      }
      if (command == 'set usb.logging off' && fullTerminal) {
        logging = false;
        text('OK - USB logging off (saved)');
        return;
      }
      if (command == 'set usb.logging on' && fullTerminal) {
        logging = true;
        text('OK - USB logging on (saved)');
        return;
      }
      if (commonCli) {
        if (command == 'get public.key') {
          text('> $publicHex');
        } else if (command == 'get prv.key') {
          text(
            '> ${List.generate(64, (i) => i.toRadixString(16).padLeft(2, '0')).join()}',
          );
        } else if (command == 'get role') {
          text('> repeater');
        } else {
          text('> example');
        }
      }
      return;
    }
    if (commonCli || !binary) return;
    final command = bytes.sublist(3);
    commands.add(command);
    switch (command[0]) {
      case 1:
        selfQueries++;
        framed(
          selfFrame(
            name: name,
            key: changeIdentity && selfQueries > 1 ? '11' * 32 : liveKey,
          ),
        );
      case 22:
        framed(infoFrame(model: model));
      case 23:
        framed(disablePrivate ? [15] : [14, ...List.generate(64, (i) => i)]);
      case 4:
        framed([2, badContacts ? 2 : 1, 0, 0, 0]);
        framed(contactFrame());
        framed([4, 0, 0, 0, 0]);
      case 31:
        final i = command[1];
        framed([
          18,
          i,
          ...List.generate(
            32,
            (n) => i == 0 && n < 4 ? 'Test'.codeUnitAt(n) : 0,
          ),
          ...List.filled(16, i + 1),
        ]);
      case 20:
        framed([12, 0x88, 0x13, 0, 0, 0, 0, 100, 0, 0, 0]);
      case 59:
        framed([25, 0]);
      case 64:
        framed([27]);
      case 43:
        framed([23, ...List.filled(8, 0)]);
      case 40:
        framed([21]);
      case 66:
        final cli = utf8.decode(command.sublist(1));
        writes.add(cli);
        if (cli == 'get bluetooth.name') {
          framed([
            29,
            ...utf8.encode('> MeshCore-$name (default from node name)'),
          ]);
        } else if (cli == 'get usb.logging') {
          framed([
            29,
            ...ascii.encode('usb.logging ${logging ? 'on' : 'off'}; port: CDC'),
          ]);
        } else if (cli == 'version') {
          framed([
            29,
            ...ascii.encode('Companion v1.18.0.1-long-keymind (protocol 14)'),
          ]);
        } else if (cli == 'get bluetooth') {
          framed([29, ...ascii.encode('bluetooth off')]);
        } else {
          framed([1, 2]);
        }
      case 8:
        name = utf8.decode(command.sublist(1));
        framed([0]);
      case 24:
        expect(command.sublist(1), List.generate(64, (i) => i));
        liveKey = publicHex;
        framed([0]);
      case 32:
        channelWrites++;
        framed([0]);
      case 14:
      case 12:
      case 11:
      case 38:
      case 37:
      case 58:
      case 21:
      case 63:
        framed([0]);
      default:
        framed([1, 2]);
    }
  }

  @override
  Future<Uint8List> read({
    int maxBytes = 4096,
    Duration timeout = const Duration(seconds: 1),
  }) async {
    if (rx.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      return Uint8List(0);
    }
    final result = Uint8List.fromList(rx.take(7).toList());
    rx.removeRange(0, result.length);
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'full archive accepted by configured firmware scripts validator',
    () async {
      final archive = await UsbNodeBackupService(
        MockNode()..logging = false,
      ).capture(device);
      final result = await Process.run(
        Platform.environment['MESHFIRMWARE_BACKUP_PYTHON']!,
        [
          '-c',
          'import sys,json; sys.path.insert(0,sys.argv[1]); import meshcore_backup; result=meshcore_backup.validate_archive_data(json.loads(sys.argv[2])); print(result["sha256"])',
          Platform.environment['MESHFIRMWARE_BACKUP_HELPER_DIR']!,
          jsonEncode(archive.toJson()),
        ],
      );
      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(result.stdout.toString().trim(), archive.sha256);
    },
    skip:
        Platform.environment['MESHFIRMWARE_BACKUP_PYTHON'] == null ||
            Platform.environment['MESHFIRMWARE_BACKUP_HELPER_DIR'] == null
        ? 'Optional cross-repository integration fixture not configured'
        : false,
  );
  test('expanded Ed25519 private key derives libsodium noclamp public key', () {
    expect(
      meshCoreExpandedPublicKey(
        Uint8List.fromList(List.generate(64, (i) => i)),
      ),
      publicHex,
    );
    expect(
      () => meshCoreExpandedPublicKey(Uint8List(64)),
      throwsFormatException,
    );
  });
  test(
    'complete framed companion backup is checksum verified and non-destructive',
    () async {
      final node = MockNode()..logging = false;
      final archive = await UsbNodeBackupService(node).capture(device);
      expect(archive.isComplete, true);
      expect(archive.publicKey, publicHex);
      expect(archive.deviceName, 'Test companion');
      final sections = (archive.toJson()['payload'] as Map)['sections'] as Map;
      expect(
        (sections['contacts']['data'] as Map).values.first['out_path'],
        '0007',
      );
      expect(sections['bluetooth_name']['data'], {
        'name': 'MeshCore-Test companion',
        'default': true,
      });
      expect(
        sections['device_info']['data']['ver_full'],
        'v1.18.0.1-long-keymind',
      );
      expect(
        node.commands.every(
          (c) => [1, 22, 23, 4, 31, 20, 59, 64, 43, 40, 66].contains(c[0]),
        ),
        true,
      );
      expect(node.closed, 1);
      expect(archive.warnings, isNotEmpty);
      expect(archive.sha256.length, 64);
      final corrupt = archive.toJson();
      ((corrupt['payload'] as Map)['sections']
              as Map)['self_info']['data']['name'] =
          'Edited';
      expect(
        () => UsbNodeBackupArchive.fromJson(corrupt),
        throwsFormatException,
      );
    },
  );
  test(
    'checksum matches Python canonical JSON including tiny coordinate',
    () async {
      final archive = await UsbNodeBackupService(
        MockNode()..logging = false,
      ).capture(device);
      final python = await Process.run('python3', [
        '-c',
        'import json,hashlib,sys; a=json.loads(sys.argv[1]); a.pop("integrity"); print(hashlib.sha256(json.dumps(a,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()).hexdigest())',
        jsonEncode(archive.toJson()),
      ]);
      expect(python.exitCode, 0);
      expect(python.stdout.toString().trim(), archive.sha256);
    },
    skip: Platform.isWindows
        ? 'Python3 interoperability check runs in Linux/WSL'
        : false,
  );
  test('DFU backup is refused before any port is opened', () async {
    final node = MockNode();
    await expectLater(
      UsbNodeBackupService(node).capture(device, isDfu: true),
      throwsA(isA<UsbBackupUnavailable>()),
    );
    expect(node.opened, false);
    expect(node.commands, isEmpty);
  });
  test('identity changes stop backup; handle closes', () async {
    final node = MockNode()..changeIdentity = true;
    await expectLater(
      UsbNodeBackupService(node).capture(device),
      throwsA(isA<UsbBackupUnavailable>()),
    );
    expect(node.closed, 1);
  });
  test('missing contact stream records create partial backup', () async {
    final node = MockNode()..badContacts = true;
    final archive = await UsbNodeBackupService(node).capture(device);
    expect(archive.isComplete, false);
    expect(archive.warnings, contains('required section incomplete: contacts'));
  });
  test('private export disabled cannot become a complete backup', () async {
    final archive = await UsbNodeBackupService(
      MockNode()..disablePrivate = true,
    ).capture(device);
    expect(archive.isComplete, false);
    expect(
      archive.warnings,
      contains('required section incomplete: identity_private_key'),
    );
  });
  test('Full terminal backup preserves original logging mode', () async {
    final node = MockNode()..fullTerminal = true;
    final archive = await UsbNodeBackupService(
      node,
      timeout: const Duration(milliseconds: 30),
    ).capture(device);
    expect(archive.isComplete, true);
    expect(node.logging, true);
    expect(node.binary, false);
    final section = archive.toJson()['payload']['sections']['usb_logging'];
    expect(section['data']['text'], contains('usb.logging on'));
    expect(
      node.writes,
      containsAllInOrder([
        '+++MESHCORE-TERM-START',
        'get usb.logging',
        'set usb.logging off',
        '+++MESHCORE-TERM-STOP',
        '+++MESHCORE-TERM-START',
        'set usb.logging on',
      ]),
    );
  });
  test(
    'CommonCLI fallback is a partial snapshot with verified identity',
    () async {
      final node = MockNode()..commonCli = true;
      final archive = await UsbNodeBackupService(
        node,
        timeout: const Duration(milliseconds: 10),
      ).capture(device);
      expect(archive.isComplete, false);
      expect(archive.publicKey, publicHex);
      expect(archive.toJson()['payload']['source']['node']['role'], 'repeater');
      await expectLater(
        UsbNodeBackupService(node).restore(device, archive),
        throwsA(isA<UsbBackupUnavailable>()),
      );
    },
  );
  test(
    'inspect queries real node hardware and complete version without secrets',
    () async {
      final node = MockNode();
      final info = await UsbNodeBackupService(node).inspect(device);
      expect(info.hardwareModel, 'Test nRF52');
      expect(info.firmwareVersion, 'v1.18.0.1-long-keymind');
      expect(node.commands.any((c) => c[0] == 23), false);
    },
  );
  test(
    'restore to different model requires explicit new hardware approval',
    () async {
      final archive = await UsbNodeBackupService(
        MockNode()..logging = false,
      ).capture(device);
      final target = MockNode()..model = 'Different board';
      await expectLater(
        UsbNodeBackupService(target).restore(device, archive),
        throwsA(isA<UsbBackupUnavailable>()),
      );
      expect(target.commands.where((c) => ![1, 22].contains(c[0])), isEmpty);
    },
  );
  test(
    'restore verifies every writable core section and never writes firmware metadata',
    () async {
      final archive = await UsbNodeBackupService(
        MockNode()..logging = false,
      ).capture(device);
      final target = MockNode()..logging = false;
      await UsbNodeBackupService(target).restore(device, archive);
      expect(target.channelWrites, 0);
      expect(target.commands.where((c) => c[0] == 63).single.length, 48);
      expect(
        target.writes.any(
          (s) =>
              s.startsWith('set version') ||
              s.startsWith('set ver') ||
              s.startsWith('set model'),
        ),
        false,
      );
      expect(target.closed, 1);
    },
  );
  test(
    'restore identity mismatch requires separate approval before writes',
    () async {
      final archive = await UsbNodeBackupService(
        MockNode()..logging = false,
      ).capture(device);
      final target = MockNode()..liveKey = '22' * 32;
      await expectLater(
        UsbNodeBackupService(target).restore(device, archive),
        throwsA(isA<UsbBackupUnavailable>()),
      );
      expect(target.commands.every((c) => [1, 22].contains(c[0])), true);
    },
  );
  test(
    'explicit new-hardware path preserves installed firmware metadata',
    () async {
      final archive = await UsbNodeBackupService(
        MockNode()..logging = false,
      ).capture(device);
      final target = MockNode()
        ..model = 'Different board'
        ..logging = false;
      await UsbNodeBackupService(
        target,
      ).restore(device, archive, newHardware: true);
      expect(target.model, 'Different board');
      expect(
        target.writes.any(
          (s) => s.startsWith('set model') || s.startsWith('set version'),
        ),
        false,
      );
    },
  );
  test(
    'ordinary nRF52 application announces DTR without asserting RTS',
    () async {
      final target = MockNode();
      await UsbNodeBackupService(target).inspect(device);
      expect(target.signalRequests, [(dtr: true, rts: false)]);
    },
  );
  test(
    'hardware ESP USB-Serial/JTAG inspection never changes reset lines',
    () async {
      final target = MockNode();
      await UsbNodeBackupService(target).inspect(
        const UsbFlashDevice(
          deviceName: 'hardware-jtag',
          vendorId: 0x303a,
          productId: 0x1001,
          productName: 'USB JTAG/serial debug unit',
          driver: 'CdcAcmSerialDriver',
        ),
      );
      expect(target.signalRequests, isEmpty);
    },
  );
  test(
    'other Espressif application CDC still receives normal DTR session',
    () async {
      final target = MockNode();
      await UsbNodeBackupService(target).inspect(
        const UsbFlashDevice(
          deviceName: 'application-cdc',
          vendorId: 0x303a,
          productId: 0x1002,
          productName: 'MeshCore application',
          driver: 'CdcAcmSerialDriver',
        ),
      );
      expect(target.signalRequests, [(dtr: true, rts: false)]);
    },
  );
  test(
    'new-hardware config-only restore retains target own identity without importing a key',
    () async {
      final archive = await UsbNodeBackupService(
        MockNode()..logging = false,
      ).capture(device);
      final target = MockNode()
        ..model = 'Different board'
        ..logging = false
        ..liveKey = '22' * 32;
      await UsbNodeBackupService(
        target,
      ).restore(device, archive, newHardware: true);
      expect(target.liveKey, '22' * 32);
      expect(target.commands.any((command) => command[0] == 24), false);
      expect(target.selfQueries, greaterThanOrEqualTo(3));
    },
  );
  test(
    'config-only restore rejects a target identity changing during writes',
    () async {
      final archive = await UsbNodeBackupService(
        MockNode()..logging = false,
      ).capture(device);
      final target = MockNode()
        ..logging = false
        ..changeIdentity = true;
      await expectLater(
        UsbNodeBackupService(
          target,
        ).restore(device, archive, newHardware: true),
        throwsA(isA<UsbBackupUnavailable>()),
      );
      expect(target.commands.any((command) => command[0] == 24), false);
    },
  );
  test(
    'original node identity replacement is an explicit separate authorization',
    () async {
      final archive = await UsbNodeBackupService(
        MockNode()..logging = false,
      ).capture(device);
      final target = MockNode()
        ..logging = false
        ..liveKey = '22' * 32;
      await UsbNodeBackupService(
        target,
      ).restore(device, archive, replaceIdentity: true);
      expect(target.liveKey, publicHex);
      expect(target.commands.where((command) => command[0] == 24).length, 1);
    },
  );
}
