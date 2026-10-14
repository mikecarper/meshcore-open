import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart' show AccumulatorSink;
import 'package:crypto/crypto.dart';

import '../models/image_codec_support.dart';
import '../models/native_image_codec_bundle.dart';

/// Imports an uncompressed USTAR bundle without retaining its weight data.
/// The first regular member is manifest.json; all other members are declared
/// regular files. Relative shared links come only from the validated manifest.
class NativeImageCodecInstaller {
  static const directoryName = kNativeFt2ModelId;

  Future<ImageCodecModelRecord> importArchive({
    required String modelRoot,
    required Stream<List<int>> chunks,
    void Function(int completed, int total)? onProgress,
  }) async {
    final root = Directory(modelRoot).absolute;
    await root.create(recursive: true);
    final destination = Directory('${root.path}/$directoryName');
    if (await destination.exists()) {
      throw StateError('Remove the installed FT2 model before importing another copy.');
    }
    final staging = await root.createTemp('.native_ft2_import_');
    final reader = _TarReader(chunks);
    var promoted = false;
    try {
      final header = await reader.header();
      if (header == null || header.name != 'manifest.json' || header.size > 2 * 1024 * 1024) {
        throw const FormatException('The archive must start with manifest.json.');
      }
      final text = utf8.decode(await reader.bytes(header.size));
      await reader.padding(header.size);
      final manifest = NativeImageCodecManifest.parse(text);
      final seen = <String>{};
      var completed = 0;
      while (true) {
        final member = await reader.header();
        if (member == null) break;
        final asset = manifest.files[member.name];
        if (asset == null || asset.size != member.size || !seen.add(member.name)) {
          throw const FormatException('The archive does not match its model manifest.');
        }
        final file = File('${staging.path}/${asset.path}');
        await file.parent.create(recursive: true);
        final hash = AccumulatorSink<Digest>();
        final converter = sha256.startChunkedConversion(hash);
        final sink = file.openWrite();
        try {
          await sink.addStream(reader.take(asset.size).map((chunk) {
            converter.add(chunk);
            completed += chunk.length;
            onProgress?.call(completed, manifest.totalFileBytes);
            return chunk;
          }));
        } finally {
          converter.close();
          await sink.close();
        }
        if (hash.events.single.toString() != asset.sha256) {
          throw FormatException('The checksum failed for ${asset.path}.');
        }
        await reader.padding(asset.size);
      }
      if (seen.length != manifest.files.length) {
        throw const FormatException('The model archive is incomplete.');
      }
      await File('${staging.path}/manifest.json').writeAsString(text, flush: true);
      await _createLinks(staging.path, manifest);
      await _validateStages(staging.path, manifest);
      await staging.rename(destination.path);
      promoted = true;
      return _record(destination.path, manifest);
    } finally {
      await reader.close();
      if (!promoted && await staging.exists()) await staging.delete(recursive: true);
    }
  }

  /// Validates a bundle installed into this exact private directory by an
  /// external debug installer. It never copies weights or follows arbitrary
  /// links. This also permits per-file installation on a nearly full phone.
  Future<ImageCodecModelRecord> validateInstalled(String modelRoot) async {
    final directory = Directory('$modelRoot/$directoryName');
    await _validateDirectories(directory.path);
    final text = await _readManifest(directory.path);
    final manifest = NativeImageCodecManifest.parse(text);
    for (final asset in manifest.files.values) {
      final path = '${directory.path}/${asset.path}';
      if (await FileSystemEntity.type(path, followLinks: false) != FileSystemEntityType.file ||
          await File(path).length() != asset.size ||
          (await sha256.bind(File(path).openRead()).first).toString() != asset.sha256) {
        throw FormatException('The installed file failed verification: ${asset.path}.');
      }
    }
    await _createLinks(directory.path, manifest);
    await _validateStages(directory.path, manifest);
    return _record(directory.path, manifest);
  }

  /// Startup checks the persisted manifest and controlled links. Full content
  /// hashing happens at installation, rather than every application launch.
  Future<ImageCodecModelRecord?> scanInstalled(String modelRoot) async {
    final directory = Directory('$modelRoot/$directoryName');
    final manifestFile = File('${directory.path}/manifest.json');
    if (!await manifestFile.exists()) return null;
    await _validateDirectories(directory.path);
    final manifest = NativeImageCodecManifest.parse(await _readManifest(directory.path));
    for (final asset in manifest.files.values) {
      final path = '${directory.path}/${asset.path}';
      if (await FileSystemEntity.type(path, followLinks: false) != FileSystemEntityType.file ||
          await File(path).length() != asset.size) {
        throw FormatException('The installed model is incomplete: ${asset.path}.');
      }
    }
    for (final link in manifest.links.entries) {
      final path = '${directory.path}/${link.key}';
      if (await FileSystemEntity.type(path, followLinks: false) != FileSystemEntityType.link ||
          await Link(path).target() != link.value) {
        throw const FormatException('An installed shared model link changed.');
      }
    }
    await _validateStages(directory.path, manifest);
    return _record(directory.path, manifest);
  }

  Future<void> _createLinks(String root, NativeImageCodecManifest manifest) async {
    for (final entry in manifest.links.entries) {
      final path = '$root/${entry.key}';
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.link) {
        if (await Link(path).target() != entry.value) {
          throw const FormatException('A shared model link points outside its bundle.');
        }
      } else if (type == FileSystemEntityType.notFound) {
        await Link(path).parent.create(recursive: true);
        await Link(path).create(entry.value);
      } else {
        throw const FormatException('A shared model link conflicts with an existing file.');
      }
    }
  }

  Future<void> _validateDirectories(String root) async {
    for (final path in [root, '$root/shared',
      for (final size in kNativeFt2Resolutions) '$root/codec$size']) {
      if (await FileSystemEntity.type(path, followLinks: false) != FileSystemEntityType.directory) {
        throw const FormatException('Model directories must stay inside private storage.');
      }
    }
  }

  Future<String> _readManifest(String root) async {
    final path = '$root/manifest.json';
    if (await FileSystemEntity.type(path, followLinks: false) != FileSystemEntityType.file ||
        await File(path).length() > 2 * 1024 * 1024) {
      throw const FormatException('Invalid installed model manifest.');
    }
    return File(path).readAsString();
  }

  Future<void> _validateStages(String root, NativeImageCodecManifest manifest) async {
    for (final size in kNativeFt2Resolutions) {
      for (final config in {'codec.tsv': 15, 'encoder.tsv': 14, 'renderer.tsv': 492}.entries) {
        var count = 0;
        final names = <String>{};
        for (final line in await File('$root/codec$size/${config.key}').readAsLines()) {
          if (!line.startsWith('stage\t')) continue;
          final fields = line.split('\t');
          if (fields.length != 6 || !names.add(fields[1])) {
            throw const FormatException('Invalid native stage configuration.');
          }
          for (final field in [fields[2], fields[3]]) {
            if (!RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.-]*$').hasMatch(field) ||
                (!manifest.files.containsKey('codec$size/$field') &&
                 !manifest.links.containsKey('codec$size/$field'))) {
              throw const FormatException('A native stage references an undeclared file.');
            }
          }
          count++;
        }
        if (count != config.value) throw const FormatException('The native stage list is incomplete.');
      }
    }
  }

  ImageCodecModelRecord _record(String directory, NativeImageCodecManifest manifest) =>
      ImageCodecModelRecord(
        id: kNativeFt2ModelId, name: nativeFt2ModelSpec.name, sourceUrl: '',
        localPath: '$directory/manifest.json', downloadedAt: DateTime.now(),
        fileSizeBytes: manifest.totalFileBytes, bundleVersion: 1,
        bundleKind: ImageCodecBundleKind.nativeFt2Ncnn,
      );
}

class _TarMember {
  final String name;
  final int size;
  const _TarMember(this.name, this.size);
}

class _TarReader {
  final StreamIterator<List<int>> _iterator;
  List<int> _chunk = const [];
  int _position = 0;
  _TarReader(Stream<List<int>> chunks) : _iterator = StreamIterator(chunks);

  Future<void> close() => _iterator.cancel();
  Future<Uint8List> bytes(int count) async {
    final output = Uint8List(count);
    var written = 0;
    await for (final part in take(count)) {
      output.setRange(written, written + part.length, part);
      written += part.length;
    }
    return output;
  }

  Stream<List<int>> take(int count) async* {
    while (count > 0) {
      while (_position == _chunk.length) {
        if (!await _iterator.moveNext()) throw const FormatException('The model archive was truncated.');
        _chunk = _iterator.current;
        _position = 0;
      }
      final remaining = _chunk.length - _position;
      final length = count < remaining ? count : remaining;
      final bounded = length > 65536 ? 65536 : length;
      yield Uint8List.fromList(_chunk.sublist(_position, _position + bounded));
      _position += bounded;
      count -= bounded;
    }
  }

  Future<void> padding(int size) async { await bytes((512 - size % 512) % 512); }

  Future<_TarMember?> header() async {
    final data = await bytes(512);
    if (data.every((byte) => byte == 0)) {
      final second = await bytes(512);
      if (second.any((byte) => byte != 0)) throw const FormatException('Invalid archive terminator.');
      return null;
    }
    String field(int offset, int length) => ascii.decode(
      data.sublist(offset, offset + length).takeWhile((byte) => byte != 0).toList());
    final stored = int.tryParse(field(148, 8).trim(), radix: 8);
    final computed = Iterable<int>.generate(512).fold<int>(0,
      (sum, i) => sum + (i >= 148 && i < 156 ? 32 : data[i]));
    if (stored != computed || (data[156] != 0 && data[156] != 48) ||
        field(257, 5) != 'ustar' || field(345, 155).isNotEmpty) {
      throw const FormatException('Use an uncompressed USTAR archive with regular files only.');
    }
    final name = field(0, 100);
    final size = int.tryParse(field(124, 12).trim(), radix: 8);
    if (name.isEmpty || size == null || size < 0 || size > 256 * 1024 * 1024) {
      throw const FormatException('Invalid archive member.');
    }
    return _TarMember(name, size);
  }
}
