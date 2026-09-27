import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/esp32_partition_catalog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const live =
      '> int:esp32=4096K ext:none; '
      'nvs@0x9000+20K,otadata@0xE000+8K,'
      'app0*@0x10000+1280K,app1@0x150000+1280K,spiffs@0x290000+1472K';
  Map<String, dynamic> data({bool ambiguous = false, bool noOta = false}) => {
    'schema': 1,
    'layouts': {
      'old': {'dualOta': !noOta, 'slotBytes': noOta ? null : 0x140000},
      'new': {'dualOta': true, 'slotBytes': 0x1f0000},
    },
    'builds': [
      for (final version in [
        'v1.17.1',
        'PowerSaving17.1.3',
        'v1.17.1.6-halo-keymind-cascade-dev',
      ])
        {
          'board': 'Heltec_v3',
          'role': 'repeater',
          'version': version,
          'layout': 'old',
        },
      {
        'board': 'Heltec_v3',
        'role': 'companion_radio_ble',
        'version': 'v1.17.1',
        'layout': 'new',
      },
      if (ambiguous)
        {
          'board': 'Heltec_v3',
          'role': 'repeater_full',
          'version': 'v1.17.1',
          'layout': 'new',
        },
    ],
  };

  Esp32PartitionAssessment assess({
    String board = 'Heltec V3',
    String version = 'v1.17.1 (Build: yesterday)',
    String role = 'repeater',
    int size = 0x140001,
    String? reply,
    bool ambiguous = false,
    bool noOta = false,
  }) => Esp32PartitionCatalog.fromJson(data(ambiguous: ambiguous, noOta: noOta))
      .assess(
        board: board,
        version: version,
        role: role,
        imageBytes: size,
        storageReply: reply,
      );

  test('live table wins over a conflicting version catalog', () {
    final result = assess(role: 'companion_radio', reply: live);
    expect(result.source, Esp32PartitionSource.device);
    expect(result.action, Esp32PartitionAction.expand);
    expect(result.blocksUpload, isTrue);
  });

  test('exact slot boundary fits; one byte larger needs expansion', () {
    expect(
      assess(size: 0x140000, reply: live).action,
      Esp32PartitionAction.fits,
    );
    expect(
      assess(size: 0x140001, reply: live).action,
      Esp32PartitionAction.expand,
    );
  });

  test(
    'both completed slots still usable if later diagnostic is truncated',
    () {
      final truncated = live.substring(0, live.indexOf(',spiffs'));
      expect(
        assess(reply: '$truncated,...').source,
        Esp32PartitionSource.device,
      );
    },
  );

  test(
    'partial, overlapping, out of range or malformed live data falls back',
    () {
      for (final reply in [
        'Unknown command',
        live.substring(0, live.indexOf(',app1')),
        live.replaceFirst('0x150000', '0x10000'),
        live.replaceFirst('1280K,spiffs', '99999K,spiffs'),
        live.replaceFirst('4096K', '0K'),
        live.replaceFirst('4096K', '999999999999999999999999999K'),
        live.replaceFirst('1280K', '999999999999999999999999999K'),
        live.replaceFirst('0x150000', '0x999999999999999999999999999'),
        live.replaceFirst('otadata', 'not_ota'),
      ]) {
        expect(
          assess(reply: reply).source,
          Esp32PartitionSource.releaseCatalog,
        );
      }
    },
  );

  test('accepts standard ota_0 and ota_1 labels', () {
    expect(
      assess(
        reply: live.replaceAll('app0', 'ota_0').replaceAll('app1', 'ota_1'),
      ).source,
      Esp32PartitionSource.device,
    );
  });

  test('all firmware families match exact versions and retain caveat', () {
    for (final version in [
      '1.17.1',
      'PowerSaving17.1.3 (Build: yesterday)',
      'v1.17.1.6-halo-keymind-cascade-dev (Build: today)',
    ]) {
      final result = assess(version: version);
      expect(result.action, Esp32PartitionAction.expand);
      expect(result.source, Esp32PartitionSource.releaseCatalog);
      expect(result.message, contains('different partition table'));
    }
  });

  test('nearby versions and boards never match by substring', () {
    for (final version in [
      '1.17',
      '1.17.1.6',
      'PowerSaving17.1',
      'PowerSaving17.1.5',
      '1.17.1-custom',
    ]) {
      expect(assess(version: version).action, Esp32PartitionAction.unknown);
    }
    expect(
      assess(board: 'Heltec V3 Extra').action,
      Esp32PartitionAction.unknown,
    );
  });

  test('Companion wrapper and role are respected', () {
    expect(
      assess(
        version: 'Companion v1.17.1 (protocol 14, build today)',
        role: 'companion_radio',
      ).slotBytes,
      0x1f0000,
    );
  });

  test('ambiguous profiles must not silently choose an expanded layout', () {
    final result = assess(ambiguous: true);
    expect(result.action, Esp32PartitionAction.unknown);
    expect(result.message, contains('different layouts'));
  });

  test('single-app release blocks Wi-Fi and migration bridge uploads', () {
    final result = assess(noOta: true);
    expect(result.action, Esp32PartitionAction.cableRequired);
    expect(result.blocksUpload, isTrue);
  });

  test('live dual-OTA table overrides single-app release estimate', () {
    expect(
      assess(noOta: true, reply: live, size: 1024).action,
      Esp32PartitionAction.fits,
    );
  });

  test('complete live single-slot table overrides a dual-slot catalog', () {
    final single = live.replaceFirst('app1@0x150000+1280K,', '');
    expect(assess(reply: single).action, Esp32PartitionAction.cableRequired);
    expect(assess(reply: single).source, Esp32PartitionSource.device);
  });

  test('ambiguous capacities are usable when every candidate agrees', () {
    expect(
      assess(ambiguous: true, size: 1024).action,
      Esp32PartitionAction.fits,
    );
    expect(
      assess(ambiguous: true, size: 0x200000).action,
      Esp32PartitionAction.expand,
    );
  });

  test('reported commit narrows builds; unknown hash stays an estimate', () {
    final json = data(ambiguous: true);
    json['builds'][0]['buildVersion'] = 'v1.17.1-abcdef12';
    json['builds'].last['buildVersion'] = 'v1.17.1-12345678';
    final catalog = Esp32PartitionCatalog.fromJson(json);
    expect(
      catalog
          .assess(
            board: 'Heltec V3',
            version: 'v1.17.1-abcdef12',
            role: 'repeater',
            imageBytes: 0x140001,
          )
          .action,
      Esp32PartitionAction.expand,
    );
    expect(
      catalog
          .assess(
            board: 'Heltec V3',
            version: 'v1.17.1-87654321',
            role: 'repeater',
            imageBytes: 0x140001,
          )
          .action,
      Esp32PartitionAction.unknown,
    );
  });

  test(
    'unsupported schema and corrupt capacity do not authorize expansion',
    () {
      expect(
        () => Esp32PartitionCatalog.fromJson({...data(), 'schema': 2}),
        throwsFormatException,
      );
      final json = data();
      json['layouts']['old']['slotBytes'] = -1;
      expect(
        Esp32PartitionCatalog.fromJson(json)
            .assess(
              board: 'Heltec V3',
              version: '1.17.1',
              role: 'repeater',
              imageBytes: 100,
            )
            .action,
        Esp32PartitionAction.unknown,
      );
    },
  );

  test(
    'bundled snapshot indexes all three repositories and real images',
    () async {
      final json = jsonDecode(
        await File(
          'assets/firmware/esp32_partition_catalog.json',
        ).readAsString(),
      );
      expect(json['repositories'], [
        'meshcore-dev/MeshCore',
        'IoTThinks/EasySkyMesh',
        'mikecarper/MeshCore',
      ]);
      expect((json['builds'] as List).length, greaterThan(9000));
      final catalog = await Esp32PartitionCatalog.load();
      final result = catalog.assess(
        board: 'Heltec V3',
        version: '1.17.1',
        role: 'repeater',
        imageBytes: 4000000,
      );
      expect(result.action, Esp32PartitionAction.expand);
    },
  );

  test('unsupported storage query automatically falls back on phone', () async {
    final result = await Esp32PartitionCatalog.check(
      readStorage: () async => throw UnsupportedError('old firmware'),
      board: 'Heltec V3',
      version: 'v1.17.1',
      role: 'repeater',
      imageBytes: 4000000,
    );
    expect(result.source, Esp32PartitionSource.releaseCatalog);
    expect(result.action, Esp32PartitionAction.expand);
  });
}
