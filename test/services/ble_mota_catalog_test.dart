import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/ble_mota_catalog.dart';

import '../support/mota_test_data.dart';

void main() {
  group('BleMotaFile', () {
    test('validates a full container and exposes its descriptor', () async {
      final bytes = buildTestFullMotaContainer();
      final file = await BleMotaFile.load(
        XFile.fromData(bytes, path: 'firmware.mota', name: 'firmware.mota'),
      );

      expect(file.name, 'firmware.mota');
      expect(file.isFull, isTrue);
      expect(file.isSigned, isFalse);
      expect(file.versionLabel, '1.17.1.2');
      expect(file.hardwareId, 'TEST_BOARD');
      expect(file.blockCount, 3);
      expect(file.descriptor.length, bleMotaDescriptorSize);
      expect(file.manifestId, isNotEmpty);
      expect(file.imageHashPrefix, 'CC767F36F143D4F1');
    });

    test('rejects payload that no longer matches its leaves', () async {
      final bytes = buildTestFullMotaContainer();
      final payloadOffset = 8 + 197 + 3 * 4;
      bytes[payloadOffset + 10] ^= 0x80;

      await expectLater(
        BleMotaFile.load(
          XFile.fromData(bytes, path: 'bad.mota', name: 'bad.mota'),
        ),
        throwsA(isA<BleMotaFormatException>()),
      );
    });

    test('validates bootloader confirmation identifiers', () async {
      final file = await BleMotaFile.load(
        XFile.fromData(
          await buildTestBootloaderMotaContainer(),
          path: 'gat562-bootloader.mota',
          name: 'gat562-bootloader.mota',
        ),
      );

      expect(file.isBootloader, isTrue);
      expect(file.isFull, isTrue);
      expect(file.isSigned, isTrue);
      expect(file.targetId, 0xD50D2D44);
      expect(file.hardwareId, 'GAT562_DFU');
      expect(file.manifestId, hasLength(8));
      expect(file.imageHashPrefix, hasLength(16));
    });

    test(
      'tracks unique payload blocks separately from retransmitted reads',
      () async {
        final file = await BleMotaFile.load(
          XFile.fromData(
            buildTestFullMotaContainer(),
            path: 'firmware.mota',
            name: 'firmware.mota',
          ),
        );

        await file.read(file.payloadOffset, 512);
        expect(file.payloadBlocksServed, 0);
        expect(file.uniquePayloadBytesServed, 512);

        await file.read(file.payloadOffset + 512, 512);
        expect(file.payloadBlocksServed, 1);
        expect(file.uniquePayloadBytesServed, 1024);
        expect(file.sentProgress, closeTo(1 / 3, 0.0001));

        await file.read(file.payloadOffset, 1024);
        expect(file.payloadBlocksServed, 1);
        expect(file.uniquePayloadBytesServed, 1024);
        expect(file.bytesServed, 2048);

        file.resetTransferMetrics();
        expect(file.payloadBlocksServed, 0);
        expect(file.readRequests, 0);
      },
    );
  });

  group('BleMotaCatalog seeder protocol', () {
    test('serves count, descriptor, and bounded lazy reads', () async {
      final bytes = buildTestFullMotaContainer();
      final catalog = await BleMotaCatalog.load(<XFile>[
        XFile.fromData(bytes, path: 'firmware.mota', name: 'firmware.mota'),
      ]);

      final count = await catalog.handleRequest(_request(0x01));
      expect(count, isNotNull);
      expect(count!.sublist(0, 5), <int>[0x6D, 0x73, 0x01, 0x00, 0x01]);
      expect(count.last, _xor(count.sublist(0, count.length - 1)));

      final describe = await catalog.handleRequest(_request(0x02, <int>[0]));
      expect(describe, isNotNull);
      expect(describe!.length, 2 + 1 + 1 + bleMotaDescriptorSize + 1);
      expect(describe[3], 0);

      final args = Uint8List(7);
      final data = ByteData.sublistView(args);
      args[0] = 0;
      data.setUint32(1, 12, Endian.little);
      data.setUint16(5, 32, Endian.little);
      final read = await catalog.handleRequest(_request(0x03, args));
      expect(read, isNotNull);
      expect(read![3], 0);
      expect(read.sublist(4, 36), bytes.sublist(12, 44));
      expect(catalog.bytesServed, 32);
    });

    test('drops corrupt frames and errors on oversized reads', () async {
      final catalog = await BleMotaCatalog.load(<XFile>[
        XFile.fromData(
          buildTestFullMotaContainer(),
          path: 'firmware.mota',
          name: 'firmware.mota',
        ),
      ]);
      final corrupt = _request(0x01)..last ^= 1;
      expect(await catalog.handleRequest(corrupt), isNull);

      final args = Uint8List(7);
      final data = ByteData.sublistView(args);
      data.setUint16(5, bleMotaSeederReadMax + 1, Endian.little);
      final response = await catalog.handleRequest(_request(0x03, args));
      expect(response, isNotNull);
      expect(response!.sublist(0, 4), <int>[0x6D, 0x73, 0x03, 0x01]);
      expect(response.length, 5);
    });
  });
}

Uint8List _request(int operation, [List<int> args = const <int>[]]) {
  final result = Uint8List(4 + args.length);
  result[0] = 0x4D;
  result[1] = 0x53;
  result[2] = operation;
  result.setRange(3, 3 + args.length, args);
  result.last = _xor(<int>[operation, ...args]);
  return result;
}

int _xor(Iterable<int> bytes) {
  var result = 0;
  for (final byte in bytes) {
    result ^= byte;
  }
  return result;
}
