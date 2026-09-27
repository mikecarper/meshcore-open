import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/local_mota_builder.dart';

const _targetId = 0x11223344;
const _hardware = 'TEST_BOARD';

void main() {
  test('builds a signed delta that reconstructs the exact new image', () async {
    final baseBody = Uint8List.fromList(
      List<int>.generate(20000, (i) => (i * 13 + i ~/ 91) & 0xFF),
    );
    final nextBody = Uint8List.fromList(baseBody);
    nextBody.setRange(1700, 1810, List<int>.filled(110, 0xA5));
    nextBody.setRange(12900, 13000, List<int>.filled(100, 0x5A));
    final base = _image(baseBody, 0x01110104);
    final next = _image(nextBody, 0x01110105);
    final baseHash = FirmwareImageIdentity.read(base).bodyHashHex;

    final file = await LocalMotaBuilder().buildForTarget(
      installedImage: base,
      updatedImage: next,
      signingSeed: Uint8List.fromList(List<int>.generate(32, (i) => i + 1)),
      targetId: _targetId,
      targetBaseHash: baseHash,
      inplaceMemory: 0x98000,
    );

    expect(file.isSigned, isTrue);
    expect(file.isFull, isFalse);
    expect(file.targetId, _targetId);
    expect(file.baseHashPrefix, baseHash);
    expect(file.versionLabel, '1.17.1.5');
    expect(file.payloadSize, lessThan(next.length));
    final payload = await file.read(file.payloadOffset, file.payloadSize);
    expect(_applyInPlace(base, payload), next);
  });

  test('chooses a signed full image when a delta would be larger', () async {
    final base = _image(_randomBytes(12000, 0x12345678), 0x01110104);
    final next = _image(_randomBytes(12000, 0x87654321), 0x01110105);
    final file = await LocalMotaBuilder().buildForTarget(
      installedImage: base,
      updatedImage: next,
      signingSeed: Uint8List.fromList(List<int>.generate(32, (i) => i + 1)),
      targetId: _targetId,
      targetBaseHash: FirmwareImageIdentity.read(base).bodyHashHex,
      inplaceMemory: 0x98000,
    );

    expect(file.isFull, isTrue);
    expect(file.isSigned, isTrue);
    expect(await file.read(file.payloadOffset, file.payloadSize), next);
  });

  test('builds a signed full update without an installed image', () async {
    final next = _image(_randomBytes(12000, 0x87654321), 0x01110105);
    final file = await LocalMotaBuilder().buildFullForTarget(
      updatedImage: next,
      signingSeed: Uint8List.fromList(List<int>.generate(32, (i) => i + 1)),
      targetId: _targetId,
    );
    expect(file.isFull, isTrue);
    expect(file.isSigned, isTrue);
    expect(file.baseHashPrefix, '0000000000000000');
    expect(await file.read(file.payloadOffset, file.payloadSize), next);
  });

  test('internal-flash targets reject a full-image fallback', () async {
    final base = _image(_randomBytes(12000, 0x12345678), 0x01110104);
    final next = _image(_randomBytes(12000, 0x87654321), 0x01110105);
    await expectLater(
      LocalMotaBuilder().buildForTarget(
        installedImage: base,
        updatedImage: next,
        signingSeed: Uint8List(32),
        targetId: _targetId,
        targetBaseHash: FirmwareImageIdentity.read(base).bodyHashHex,
        inplaceMemory: 0x98000,
        allowFull: false,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('accepts raw or hex key files and rejects malformed keys', () {
    final seed = Uint8List.fromList(List<int>.generate(32, (i) => i));
    expect(LocalMotaBuilder.parseSigningSeed(seed), seed);
    final hex = seed.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    expect(
      LocalMotaBuilder.parseSigningSeed(
        Uint8List.fromList(utf8.encode('$hex\n')),
      ),
      seed,
    );
    expect(
      () => LocalMotaBuilder.parseSigningSeed(
        Uint8List.fromList(utf8.encode('bad key')),
      ),
      throwsFormatException,
    );
  });

  test(
    'does not build against a same-version but different base image',
    () async {
      final base = _image(_randomBytes(9000, 1), 0x01110104);
      final next = _image(_randomBytes(9000, 2), 0x01110105);
      await expectLater(
        LocalMotaBuilder().buildForTarget(
          installedImage: base,
          updatedImage: next,
          signingSeed: Uint8List(32),
          targetId: _targetId,
          targetBaseHash: 'C2CFC98C42CBEFDB',
          inplaceMemory: 0x98000,
        ),
        throwsA(isA<StateError>()),
      );
    },
  );

  test('rejects an image with a corrupted EndF hash', () {
    final image = _image(_randomBytes(4096, 7), 0x01110104);
    image[42] ^= 1;
    expect(() => FirmwareImageIdentity.read(image), throwsFormatException);
  });

  final oraclePython = Platform.environment['MOTA_DETOOLS_PYTHON'];
  final oracleShim = Platform.environment['MOTA_DETOOLS_SHIM'];
  test(
    'detools oracle applies the phone-generated in-place delta',
    () async {
      final body = _randomBytes(64000, 0xD311A);
      final updatedBody = Uint8List.fromList(body);
      updatedBody.setRange(8000, 8500, List<int>.filled(500, 0xA5));
      updatedBody.setRange(53000, 53200, List<int>.filled(200, 0x42));
      final base = _image(body, 0x01110104);
      final next = _image(updatedBody, 0x01110105);
      final package = await LocalMotaBuilder().buildForTarget(
        installedImage: base,
        updatedImage: next,
        signingSeed: Uint8List.fromList(List<int>.generate(32, (i) => i + 1)),
        targetId: _targetId,
        targetBaseHash: FirmwareImageIdentity.read(base).bodyHashHex,
        inplaceMemory: 0x98000,
      );
      expect(package.isFull, isFalse);

      final scratch = await Directory.systemTemp.createTemp('mota-oracle-');
      try {
        final basePath = '${scratch.path}/base.bin';
        final patchPath = '${scratch.path}/patch.bin';
        final outputPath = '${scratch.path}/out.bin';
        await File(basePath).writeAsBytes(base);
        await File(patchPath).writeAsBytes(
          await package.read(package.payloadOffset, package.payloadSize),
        );
        final result = await Process.run(oraclePython!, <String>[
          oracleShim!,
          'apply',
          basePath,
          patchPath,
          outputPath,
          '--patch-type',
          'in-place',
          '--memory-size',
          '622592',
          '--to-size',
          '${next.length}',
        ]);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(await File(outputPath).readAsBytes(), next);
      } finally {
        await scratch.delete(recursive: true);
      }
    },
    skip: oraclePython == null || oracleShim == null
        ? 'Set MOTA_DETOOLS_PYTHON and MOTA_DETOOLS_SHIM for decoder oracle'
        : false,
  );
}

Uint8List _image(Uint8List body, int version) {
  final image = Uint8List(body.length + 56)..setRange(0, body.length, body);
  final trailer = ByteData.sublistView(image, body.length);
  image.setRange(body.length, body.length + 4, 'EndF'.codeUnits);
  trailer.setUint32(4, body.length, Endian.little);
  image.setRange(
    body.length + 8,
    body.length + 16,
    crypto.sha256.convert(body).bytes.sublist(0, 8),
  );
  trailer.setUint32(16, version, Endian.little);
  trailer.setUint32(20, _targetId, Endian.little);
  image.setRange(
    body.length + 24,
    body.length + 24 + _hardware.length,
    _hardware.codeUnits,
  );
  return image;
}

Uint8List _randomBytes(int length, int seed) {
  var state = seed;
  return Uint8List.fromList(
    List<int>.generate(length, (_) {
      state ^= state << 13;
      state ^= state >> 17;
      state ^= state << 5;
      state &= 0xFFFFFFFF;
      return state & 0xFF;
    }),
  );
}

Uint8List _applyInPlace(Uint8List base, Uint8List patch) {
  var cursor = 0;
  expect(patch[cursor++], 0x12);
  int size() {
    final first = patch[cursor++];
    var value = first & 0x3F;
    var shift = 6;
    var current = first;
    while ((current & 0x80) != 0) {
      current = patch[cursor++];
      value |= (current & 0x7F) << shift;
      shift += 7;
    }
    return (first & 0x40) != 0 ? -value : value;
  }

  final memorySize = size();
  final segmentSize = size();
  final shiftSize = size();
  expect(size(), base.length);
  final targetSize = size();
  final compressed = patch.sublist(cursor);
  final body = BytesBuilder(copy: false);
  cursor = 0;
  int unsignedSize() {
    var value = 0;
    var shift = 0;
    var current = 0;
    do {
      current = compressed[cursor++];
      value |= (current & 0x7F) << shift;
      shift += 7;
    } while ((current & 0x80) != 0);
    return value;
  }

  while (cursor < compressed.length) {
    final kind = compressed[cursor++];
    final count = unsignedSize();
    if (kind == 0) {
      body.add(compressed.sublist(cursor, cursor + count));
      cursor += count;
    } else if (kind == 1) {
      body.add(
        Uint8List.fromList(List<int>.filled(count, compressed[cursor++])),
      );
    } else {
      fail('Invalid CRLE segment');
    }
  }

  final instructions = body.toBytes();
  cursor = 0;
  int instructionSize() {
    final first = instructions[cursor++];
    var value = first & 0x3F;
    var shift = 6;
    var current = first;
    while ((current & 0x80) != 0) {
      current = instructions[cursor++];
      value |= (current & 0x7F) << shift;
      shift += 7;
    }
    return (first & 0x40) != 0 ? -value : value;
  }

  final memory = Uint8List(memorySize);
  memory.setRange(shiftSize, shiftSize + base.length, base);
  for (var offset = 0; offset < targetSize; offset += segmentSize) {
    expect(instructionSize(), 0); // no data-format patch
    final segmentLength = math.min(segmentSize, targetSize - offset);
    var written = 0;
    var reference = math.max(offset + segmentSize, shiftSize);
    while (written < segmentLength) {
      final diffLength = instructionSize();
      for (var i = 0; i < diffLength; i++) {
        memory[offset + written + i] =
            (memory[reference + i] + instructions[cursor++]) & 0xFF;
      }
      reference += diffLength;
      written += diffLength;
      final extraLength = instructionSize();
      memory.setRange(
        offset + written,
        offset + written + extraLength,
        instructions,
        cursor,
      );
      cursor += extraLength;
      written += extraLength;
      reference += instructionSize();
    }
  }
  expect(cursor, instructions.length);
  return Uint8List.fromList(memory.sublist(0, targetSize));
}
