import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

Uint8List buildTestFullMotaContainer() {
  final payload = Uint8List.fromList(
    List<int>.generate(2500, (index) => (index * 17 + 3) & 0xFF),
  );
  const blockSize = 1024;
  final leaves = <Uint8List>[];
  for (var offset = 0; offset < payload.length; offset += blockSize) {
    final end = offset + blockSize < payload.length
        ? offset + blockSize
        : payload.length;
    leaves.add(
      Uint8List.fromList(
        crypto.sha256.convert(payload.sublist(offset, end)).bytes.sublist(0, 4),
      ),
    );
  }
  final root = _merkleRoot(leaves);

  final manifest = Uint8List(197);
  final manifestData = ByteData.sublistView(manifest);
  manifest[0] = 2;
  manifest[1] = 0x01;
  manifest[2] = 0x12;
  manifestData.setUint32(3, 0x11223344, Endian.little);
  manifestData.setUint32(7, 0x01110102, Endian.little);
  manifestData.setUint32(11, payload.length, Endian.little);
  manifestData.setUint32(15, payload.length, Endian.little);
  manifest[19] = 10;
  manifest.setRange(20, 24, root);
  manifest.setRange(24, 56, crypto.sha256.convert(payload).bytes);
  manifest[56] = 0;
  manifest.setRange(57, 67, 'TEST_BOARD'.codeUnits);
  manifest.fillRange(193, 197, 0xFF);

  final total = 8 + manifest.length + leaves.length * 4 + payload.length + 5;
  final result = BytesBuilder(copy: false)
    ..add('mOTA'.codeUnits)
    ..add(_uint32(total))
    ..add(manifest);
  for (final leaf in leaves) {
    result.add(leaf);
  }
  result
    ..add(payload)
    ..add('vk496'.codeUnits);
  return result.toBytes();
}

Future<Uint8List> buildTestBootloaderMotaContainer() async {
  final payload = Uint8List.fromList(
    List<int>.generate(0xA000, (index) => (index * 29 + 7) & 0xFF),
  );
  const blockSize = 1024;
  final leaves = <Uint8List>[];
  for (var offset = 0; offset < payload.length; offset += blockSize) {
    leaves.add(
      Uint8List.fromList(
        crypto.sha256
            .convert(payload.sublist(offset, offset + blockSize))
            .bytes
            .sublist(0, 4),
      ),
    );
  }

  final manifest = Uint8List(197);
  final manifestData = ByteData.sublistView(manifest);
  manifest[0] = 3;
  manifest[1] = 0x07;
  manifest[2] = 0x12;
  manifestData.setUint32(3, 0xD50D2D44, Endian.little);
  manifestData.setUint32(7, 0x02040500, Endian.little);
  manifestData.setUint32(11, payload.length, Endian.little);
  manifestData.setUint32(15, payload.length, Endian.little);
  manifest[19] = 10;
  manifest.setRange(20, 24, _merkleRoot(leaves));
  manifest.setRange(24, 56, crypto.sha256.convert(payload).bytes);
  manifest[56] = 0;
  manifest.setRange(57, 67, 'GAT562_DFU'.codeUnits);

  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPairFromSeed(
    List<int>.generate(32, (index) => index + 1),
  );
  final publicKey = await keyPair.extractPublicKey();
  manifest.setRange(97, 129, publicKey.bytes);
  final signature = await algorithm.sign(
    manifest.sublist(0, 129),
    keyPair: keyPair,
  );
  manifest.setRange(129, 193, signature.bytes);
  manifest.fillRange(193, 197, 0xFF);

  final total = 8 + manifest.length + leaves.length * 4 + payload.length + 5;
  final result = BytesBuilder(copy: false)
    ..add('mOTA'.codeUnits)
    ..add(_uint32(total))
    ..add(manifest);
  for (final leaf in leaves) {
    result.add(leaf);
  }
  result
    ..add(payload)
    ..add('vk496'.codeUnits);
  return result.toBytes();
}

Uint8List _uint32(int value) {
  return Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.little);
}

Uint8List _merkleRoot(List<Uint8List> leaves) {
  var level = leaves;
  while (level.length > 1) {
    final next = <Uint8List>[];
    for (var index = 0; index < level.length; index += 2) {
      if (index + 1 == level.length) {
        next.add(level[index]);
      } else {
        next.add(
          Uint8List.fromList(
            crypto.sha256
                .convert(<int>[...level[index], ...level[index + 1]])
                .bytes
                .sublist(0, 4),
          ),
        );
      }
    }
    level = next;
  }
  return level.single;
}
