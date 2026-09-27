import 'dart:io';

import 'package:file_selector/file_selector.dart';

/// Android 5's DocumentsUI can expose an empty Downloads provider even when
/// files are present on shared storage. Read that directory directly as a
/// fallback; every candidate is still verified by [BleMotaCatalog.load].
class LocalMotaDownloads {
  static Future<List<XFile>> scan({Directory? directory}) async {
    if (directory == null && !Platform.isAndroid) {
      throw StateError('Downloads import is available on Android only.');
    }
    final downloads = directory ?? Directory('/sdcard/Download');
    if (!await downloads.exists()) {
      throw StateError('The Downloads folder is unavailable on this phone.');
    }
    final files = <File>[];
    await for (final entry in downloads.list(followLinks: false)) {
      if (entry is File && entry.path.toLowerCase().endsWith('.mota')) {
        files.add(entry);
      }
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    if (files.isEmpty) {
      throw StateError('No .mota files were found in Downloads.');
    }
    if (files.length > 16) {
      throw StateError(
        'Downloads has more than 16 .mota files. Move older files out first.',
      );
    }
    return files.map((file) => XFile(file.path)).toList();
  }
}
