import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/local_mota_downloads.dart';

void main() {
  test(
    'finds .mota files in legacy Downloads without the system picker',
    () async {
      final downloads = await Directory.systemTemp.createTemp(
        'mota-downloads-',
      );
      addTearDown(() => downloads.delete(recursive: true));
      await File('${downloads.path}/z.MOTA').writeAsBytes(<int>[1]);
      await File('${downloads.path}/a.mota').writeAsBytes(<int>[2]);
      await File('${downloads.path}/notes.txt').writeAsString('ignore');

      final files = await LocalMotaDownloads.scan(directory: downloads);

      expect(files.map((file) => file.name), <String>['a.mota', 'z.MOTA']);
    },
  );

  test('explains when Downloads contains no packages', () async {
    final downloads = await Directory.systemTemp.createTemp('mota-empty-');
    addTearDown(() => downloads.delete(recursive: true));

    expect(
      LocalMotaDownloads.scan(directory: downloads),
      throwsA(isA<StateError>()),
    );
  });
}
