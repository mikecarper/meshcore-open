import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/image_codec_support.dart';
import 'package:meshcore_open/models/native_image_codec_bundle.dart';
import 'package:meshcore_open/services/native_image_codec_installer.dart';

Map<String, dynamic> _manifest() =>
    jsonDecode(
          File('test/fixtures/native_ft2_manifest.json').readAsStringSync(),
        )
        as Map<String, dynamic>;

Uint8List _member(String name, List<int> data, {int type = 48}) {
  final bytes = Uint8List(512 + ((data.length + 511) ~/ 512) * 512);
  void field(int offset, String text) =>
      bytes.setRange(offset, offset + text.length, ascii.encode(text));
  field(0, name);
  field(100, '0000644\x00');
  field(124, '${data.length.toRadixString(8).padLeft(11, '0')}\x00');
  bytes.fillRange(148, 156, 32);
  bytes[156] = type;
  field(257, 'ustar\x00');
  field(
    148,
    '${bytes.sublist(0, 512).fold<int>(0, (s, n) => s + n).toRadixString(8).padLeft(6, '0')}\x00 ',
  );
  bytes.setRange(512, 512 + data.length, data);
  return bytes;
}

void main() {
  test(
    'all eight sizes share the pinned FT2 weight and entropy identities',
    () {
      final manifest = NativeImageCodecManifest.parse(jsonEncode(_manifest()));
      expect(
        manifest.files.values.where((f) => f.path.endsWith('.ncnn.bin')).length,
        521,
      );
      for (final size in kNativeFt2Resolutions) {
        expect(manifest.links['codec$size/y_cdf.bin'], '../shared/y_cdf.bin');
      }
    },
  );

  test('a legacy identity, mixed weights or entropy assets are refused', () {
    for (final mutation in [
      (Map<String, dynamic> m) => m['codec_identity'] = 'AEIC_SE_FT32_ONNX',
      (Map<String, dynamic> m) =>
          (m['files'] as List).first['sha256'] = '0' * 64,
      (Map<String, dynamic> m) => (m['files'] as List).firstWhere(
        (f) => f['path'] == 'shared/y_cdf.bin',
      )['sha256'] = '0' * 64,
    ]) {
      final raw = _manifest();
      mutation(raw);
      expect(
        () => NativeImageCodecManifest.parse(jsonEncode(raw)),
        throwsFormatException,
      );
    }
  });

  test('undeclared resolutions and escaping links are refused', () {
    final raw = _manifest();
    (raw['links'] as List).first['target'] = '../../outside/model.bin';
    expect(
      () => NativeImageCodecManifest.parse(jsonEncode(raw)),
      throwsFormatException,
    );
    raw['links'] = _manifest()['links'];
    raw['resolutions'] = [128, 256];
    expect(
      () => NativeImageCodecManifest.parse(jsonEncode(raw)),
      throwsFormatException,
    );
  });

  test('truncated streams clean only their own staging directory', () async {
    final root = await Directory.systemTemp.createTemp('ft2_import_test_');
    addTearDown(() => root.delete(recursive: true));
    final unrelated = File('${root.path}/legacy.onnx');
    await unrelated.writeAsString('keep');
    final archive = _member(
      'manifest.json',
      utf8.encode(jsonEncode(_manifest())),
    );
    await expectLater(
      NativeImageCodecInstaller().importArchive(
        modelRoot: root.path,
        chunks: Stream<List<int>>.fromIterable([
          for (var i = 0; i < archive.length; i += 31)
            archive.sublist(i, (i + 31).clamp(0, archive.length)),
        ]),
      ),
      throwsFormatException,
    );
    expect(await unrelated.readAsString(), 'keep');
    expect(await root.list().length, 1);
  });

  test('archive links cannot bypass controlled manifest links', () async {
    final root = await Directory.systemTemp.createTemp('ft2_link_test_');
    addTearDown(() => root.delete(recursive: true));
    final bytes = [
      ..._member('manifest.json', utf8.encode(jsonEncode(_manifest()))),
      ..._member('shared/escape', const [], type: 50),
      ...List<int>.filled(1024, 0),
    ];
    await expectLater(
      NativeImageCodecInstaller().importArchive(
        modelRoot: root.path,
        chunks: Stream.value(bytes),
      ),
      throwsFormatException,
    );
    expect(await root.list().length, 0);
  });
}
