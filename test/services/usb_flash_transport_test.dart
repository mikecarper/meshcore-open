import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/usb_esp_flash_engine.dart';
import 'package:meshcore_open/services/usb_flash_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const rawChannel = MethodChannel('test/usb_flash');
  const espChannel = MethodChannel('test/usb_esp');
  const device = UsbFlashDevice(
    deviceName: '/dev/bus/usb/001/007',
    vendorId: 0x1a86,
    productId: 0x7523,
    driver: 'Ch34xSerialDriver',
    serialNumber: 'original-serial',
    manufacturerName: 'test',
  );
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(rawChannel, (call) async {
          calls.add(call);
          if (call.method == 'listDevices') return [device.toMap()];
          if (call.method == 'readIdentity') return device.toMap();
          if (call.method == 'read') return Uint8List.fromList([1, 2]);
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(espChannel, (call) async {
          calls.add(call);
          if (call.method == 'connect') {
            return {
              'chip': 9,
              'flashBytes': 8 * 1024 * 1024,
              'mac': '12:34:56:78:90:ab',
            };
          }
          if (call.method == 'readFlash') {
            final bytes = Uint8List(call.arguments['length'] as int);
            return {'data': bytes, 'md5': md5.convert(bytes).toString()};
          }
          if (call.method == 'writeFlash') {
            return {
              'md5': call.arguments['expectedMd5'],
              'mac': call.arguments['expectedMac'],
            };
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(rawChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(espChannel, null);
  });

  test('enumeration and raw open never request signals or reset', () async {
    final raw = UsbFlashTransport(channel: rawChannel);
    expect((await raw.listDevices()).single.driver, 'Ch34xSerialDriver');
    await raw.open(device);
    expect(calls.map((call) => call.method), [
      'listDevices',
      'open',
      'listDevices',
    ]);
    await raw.close();
    expect(raw.activeDevice, isNull);
  });
  test('raw I/O uses unframed byte arrays and bounded read', () async {
    final raw = UsbFlashTransport(channel: rawChannel);
    await raw.open(device);
    final bytes = Uint8List.fromList([0xc0, 0xdb, 0]);
    await raw.write(bytes);
    expect(calls.last.arguments['data'], bytes);
    expect(
      await raw.read(maxBytes: 12, timeout: const Duration(milliseconds: 50)),
      [1, 2],
    );
    expect(calls.last.arguments, {'maxBytes': 12, 'timeoutMs': 50});
    await expectLater(raw.read(maxBytes: 65537), throwsArgumentError);
  });
  test(
    'permission-only identity refresh does not open a serial port',
    () async {
      final raw = UsbFlashTransport(channel: rawChannel);
      expect((await raw.readIdentity(device)).serialNumber, 'original-serial');
      expect(calls.single.method, 'readIdentity');
    },
  );
  test(
    'known serial swap on a recycled Android bus path stops permission refresh',
    () async {
      final raw = UsbFlashTransport(channel: rawChannel);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(rawChannel, (call) async {
            calls.add(call);
            return {...device.toMap(), 'serialNumber': 'replacement'};
          });
      await expectLater(raw.readIdentity(device), throwsStateError);
      expect(calls.map((call) => call.method), ['readIdentity']);
    },
  );
  test(
    'descriptor swap during open closes the raw handle without resetting it',
    () async {
      final raw = UsbFlashTransport(channel: rawChannel);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(rawChannel, (call) async {
            calls.add(call);
            if (call.method == 'listDevices') {
              return [
                {...device.toMap(), 'serialNumber': 'replacement'},
              ];
            }
            return null;
          });
      await expectLater(raw.open(device), throwsStateError);
      expect(raw.activeDevice, isNull);
      expect(calls.map((call) => call.method), [
        'open',
        'listDevices',
        'close',
      ]);
      expect(calls.where((call) => call.method == 'setSignals'), isEmpty);
    },
  );
  test('permission identity must preserve VID PID and manufacturer', () {
    for (final replacement in [
      {...device.toMap(), 'vendorId': 999},
      {...device.toMap(), 'productId': 999},
      {...device.toMap(), 'manufacturerName': 'replacement'},
    ]) {
      expect(
        device.matchesSelectedDescriptor(UsbFlashDevice.fromMap(replacement)),
        isFalse,
      );
    }
  });
  test('CDC USB-UART adapters are not mistaken for native TinyUSB MCUs', () {
    for (final vendor in [0x1a86, 0x0403, 0x10c4, 0x067b]) {
      expect(
        UsbFlashDevice(
          deviceName: 'adapter',
          vendorId: vendor,
          productId: 1,
          driver: 'CdcAcmSerialDriver',
        ).isNativeUsb,
        isFalse,
      );
    }
    expect(
      const UsbFlashDevice(
        deviceName: 'native',
        vendorId: 0x303a,
        productId: 2,
        driver: 'CdcAcmSerialDriver',
      ).isNativeUsb,
      isTrue,
    );
  });
  test('VID/PID-only device matches cannot authorize re-enumeration', () async {
    final raw = UsbFlashTransport(channel: rawChannel);
    const unknown = UsbFlashDevice(
      deviceName: 'old',
      vendorId: 1,
      productId: 2,
    );
    await expectLater(raw.reacquire(unknown), throwsStateError);
    expect(calls, isEmpty);
  });
  test('DFU mode hints cover observed OTAFIX IDs and named boot drives', () {
    expect(
      const UsbFlashDevice(
        deviceName: 'dfu',
        vendorId: 0x239a,
        productId: 0x0029,
      ).isNrfDfu,
      isTrue,
    );
    expect(
      const UsbFlashDevice(
        deviceName: 'dfu',
        vendorId: 0x2886,
        productId: 0x0057,
      ).isNrfDfu,
      isTrue,
    );
    expect(
      const UsbFlashDevice(
        deviceName: 'dfu',
        vendorId: 0x239a,
        productId: 0x8029,
      ).isNrfDfu,
      isFalse,
    );
    expect(
      const UsbFlashDevice(
        deviceName: 'dfu',
        vendorId: 0x1209,
        productId: 1,
        productName: 'GAT562BOOT',
      ).isNrfDfu,
      isTrue,
    );
    expect(
      const UsbFlashDevice(
        deviceName: 'rom',
        vendorId: 0x303a,
        productId: 0x1001,
        productName: 'ESP32BOOT',
      ).isNrfDfu,
      isFalse,
    );
  });
  test(
    'reacquire requires exact original serial, not a different same-model node',
    () {
      final changed = UsbFlashDevice.fromMap({
        ...device.toMap(),
        'serialNumber': 'other',
      });
      expect(device.matchesAfterReenumeration(changed), isFalse);
      final returned = UsbFlashDevice.fromMap({
        ...device.toMap(),
        'deviceName': 'new',
        'productId': 0x1001,
      });
      expect(device.matchesAfterReenumeration(returned), isTrue);
    },
  );
  test('ESP reads chunk and verify device MD5', () async {
    final esp = UsbEspFlashEngine(
      UsbFlashTransport(channel: rawChannel),
      channel: espChannel,
    );
    final chip = await esp.connect(device, reset: false);
    expect(chip.mac, '1234567890ab');
    expect(calls.last.arguments['reset'], isFalse);
    expect((await esp.readFlash(0x9000, 70000)).length, 70000);
    final reads = calls.where((call) => call.method == 'readFlash').toList();
    expect(reads.length, 2);
    expect(reads.last.arguments['length'], 4464);
    expect(
      reads.every((call) => call.arguments['expectedMac'] == chip.mac),
      isTrue,
    );
  });
  test(
    'ESP never submits writes for a mismatched MAC or unaligned sector',
    () async {
      final esp = UsbEspFlashEngine(
        UsbFlashTransport(channel: rawChannel),
        channel: espChannel,
      );
      await esp.connect(device);
      await expectLater(
        esp.writeFlash(0x10000, Uint8List(8), expectedMac: 'aabbccddeeff'),
        throwsStateError,
      );
      await expectLater(
        esp.writeFlash(0x10001, Uint8List(8), expectedMac: '1234567890ab'),
        throwsArgumentError,
      );
      expect(calls.where((call) => call.method == 'writeFlash'), isEmpty);
    },
  );
  test(
    'ESP write passes exact payload hash and rejects failed verification',
    () async {
      final esp = UsbEspFlashEngine(
        UsbFlashTransport(channel: rawChannel),
        channel: espChannel,
      );
      await esp.connect(device);
      await esp.writeFlash(
        0x10000,
        Uint8List.fromList([1, 2, 3]),
        expectedMac: '1234567890ab',
      );
      expect(
        calls.last.arguments['expectedMd5'],
        md5.convert([1, 2, 3]).toString(),
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            espChannel,
            (call) async => {'md5': 'wrong', 'mac': '1234567890ab'},
          );
      await expectLater(
        esp.writeFlash(0x10000, Uint8List(8), expectedMac: '1234567890ab'),
        throwsStateError,
      );
    },
  );
  test('ESP read rejects a corrupt response', () async {
    final esp = UsbEspFlashEngine(
      UsbFlashTransport(channel: rawChannel),
      channel: espChannel,
    );
    await esp.connect(device);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          espChannel,
          (call) async => {'data': Uint8List(8), 'md5': 'wrong'},
        );
    await expectLater(esp.readFlash(0x9000, 8), throwsStateError);
  });
  test(
    'passive engine close never requests a reset and migration boot is explicit',
    () async {
      final esp = UsbEspFlashEngine(
        UsbFlashTransport(channel: rawChannel),
        channel: espChannel,
      );
      await esp.connect(device);
      await esp.runApplication(migrationBridge: true);
      expect(calls.last.arguments, {
        'expectedMac': '1234567890ab',
        'migrationBridge': true,
      });
      await esp.close();
      expect(calls.last.method, 'close');
      expect(calls.where((call) => call.method == 'setSignals'), isEmpty);
    },
  );
  test(
    'passive TinyUSB reconnect never touches 1200 baud or signals',
    () async {
      final esp = UsbEspFlashEngine(
        UsbFlashTransport(channel: rawChannel),
        channel: espChannel,
      );
      final native = UsbFlashDevice.fromMap({
        ...device.toMap(),
        'vendorId': 0x303a,
        'productId': 0x1002,
        'driver': 'CdcAcmSerialDriver',
      });
      await esp.connect(native, reset: false);
      expect(calls.map((call) => call.method), ['preflight', 'connect']);
      expect(calls.last.arguments['reset'], isFalse);
    },
  );
  test(
    'TinyUSB reset touch requires stable serial identity before changing signals',
    () async {
      final esp = UsbEspFlashEngine(
        UsbFlashTransport(channel: rawChannel),
        channel: espChannel,
      );
      final native = UsbFlashDevice.fromMap({
        ...device.toMap(),
        'vendorId': 0x303a,
        'productId': 0x1002,
        'driver': 'CdcAcmSerialDriver',
        'serialNumber': null,
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(rawChannel, (call) async {
            calls.add(call);
            return native.toMap();
          });
      await expectLater(
        esp.connect(native),
        throwsA(isA<UsbFlashReenumerationRequired>()),
      );
      expect(calls.map((call) => call.method), ['preflight', 'readIdentity']);
    },
  );
  test(
    'TinyUSB explicit reset touches once then uses no-reset ROM connect',
    () async {
      final esp = UsbEspFlashEngine(
        UsbFlashTransport(channel: rawChannel),
        channel: espChannel,
      );
      final native = UsbFlashDevice.fromMap({
        ...device.toMap(),
        'vendorId': 0x303a,
        'productId': 0x1002,
        'driver': 'CdcAcmSerialDriver',
      });
      final rom = UsbFlashDevice.fromMap({
        ...native.toMap(),
        'deviceName': 'new-ROM',
        'vendorId': 0x303a,
        'productId': 0x1001,
      });
      var touched = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(rawChannel, (call) async {
            calls.add(call);
            if (call.method == 'readIdentity') return native.toMap();
            if (call.method == 'setBaudRate') touched = true;
            if (call.method == 'listDevices') {
              return [(touched ? rom : native).toMap()];
            }
            return null;
          });
      await esp.connect(native);
      expect(calls.first.method, 'preflight');
      expect(
        calls
            .where((call) => call.method == 'setBaudRate')
            .single
            .arguments['baudRate'],
        1200,
      );
      expect(calls.last.method, 'connect');
      expect(calls.last.arguments['reset'], isFalse);
      expect(calls.last.arguments['deviceName'], 'new-ROM');
      expect(esp.connectedDevice?.deviceName, 'new-ROM');
      await esp.close();
      expect(esp.connectedDevice, isNull);
    },
  );
  test(
    'incompatible WebView fails before permission, open, touch or reset',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(espChannel, (call) async {
            calls.add(call);
            throw PlatformException(code: 'usb_esp_webview_incompatible');
          });
      final esp = UsbEspFlashEngine(
        UsbFlashTransport(channel: rawChannel),
        channel: espChannel,
      );
      final native = UsbFlashDevice.fromMap({
        ...device.toMap(),
        'vendorId': 0x303a,
        'productId': 0x1002,
        'driver': 'CdcAcmSerialDriver',
      });
      await expectLater(
        esp.connect(native),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'actionable message',
            contains('Update WebView'),
          ),
        ),
      );
      expect(calls.map((call) => call.method), ['preflight']);
      expect(esp.connectedDevice, isNull);
    },
  );
}
