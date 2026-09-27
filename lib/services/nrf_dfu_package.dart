import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// A Nordic DFU distribution ZIP is distinct from a LoRa .mota container.
/// Check its manifest and referenced binaries before asking the bootloader
/// to accept it. Board compatibility must still be confirmed by the user.
class NrfDfuPackage {
  const NrfDfuPackage({required this.components, required this.size});

  final List<String> components;
  final int size;

  static String macFromStartReply(String reply) {
    final match = RegExp(
      r'\bmac:\s*([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5})\b',
    ).firstMatch(reply);
    if (match == null) {
      throw const FormatException(
        'The radio did not return a Bluetooth DFU address.',
      );
    }
    return match.group(1)!.toUpperCase();
  }

  static NrfDfuPackage inspect(Uint8List bytes) {
    if (bytes.length < 256 || bytes.length > 0x1000000) {
      throw const FormatException(
        'DFU ZIP size is outside the supported range.',
      );
    }
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    final manifestFile = archive.findFile('manifest.json');
    final manifestBytes = manifestFile?.readBytes();
    if (manifestBytes == null) {
      throw const FormatException('Nordic DFU ZIP has no manifest.json.');
    }
    final decoded = jsonDecode(utf8.decode(manifestBytes));
    if (decoded is! Map || decoded['manifest'] is! Map) {
      throw const FormatException('Nordic DFU manifest is invalid.');
    }
    final manifest = decoded['manifest'] as Map;
    final components = <String>[];
    for (final kind in <String>[
      'application',
      'bootloader',
      'softdevice',
      'softdevice_bootloader',
    ]) {
      final entry = manifest[kind];
      if (entry == null) continue;
      if (entry is! Map ||
          entry['bin_file'] is! String ||
          entry['dat_file'] is! String) {
        throw FormatException('$kind is missing its Nordic DFU files.');
      }
      for (final field in <String>['bin_file', 'dat_file']) {
        final name = entry[field] as String;
        if (name.contains('..') ||
            name.startsWith('/') ||
            archive.findFile(name) == null) {
          throw FormatException('$kind references a missing or unsafe $field.');
        }
      }
      components.add(kind);
    }
    if (components.isEmpty) {
      throw const FormatException(
        'Nordic DFU ZIP contains no firmware components.',
      );
    }
    return NrfDfuPackage(components: components, size: bytes.length);
  }
}
