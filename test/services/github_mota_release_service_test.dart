import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshcore_open/services/github_mota_release_service.dart';

import '../support/mota_test_data.dart';

void main() {
  const environment = 'Heltec_tower_v2_sdcard_repeat';
  const prefix = 'Heltec_tower_v2_sdcard_repeater_lora_ota';
  final capabilities = utf8.encode(
    jsonEncode(<String, Object>{
      'artifact_target': prefix,
      'ota_update_verified': true,
      'ota_update_methods': <String>['bluetooth', 'lora'],
      'ota_update_requirements': <String, Object>{
        'lora': <String, String>{'storage': 'external_sd'},
      },
    }),
  );

  test('finds exact SD release and reports missing application mOTA', () async {
    final service = GitHubMotaReleaseService(
      client: _client(capabilities: capabilities),
    );
    final discovery = await service.findForTarget(
      targetEnvironment: environment,
      receiverStorage: 'external_sd',
    );
    expect(discovery.firmwareTag, 'lora-ota-v1.17.1.6');
    expect(discovery.hasApplicationPackage, isFalse);
    expect(discovery.hasBootloaderBundle, isTrue);
  });

  test('finds SD release when LoRa truncates the build profile', () async {
    final service = GitHubMotaReleaseService(
      client: _client(capabilities: capabilities),
    );
    final discovery = await service.findForTarget(
      targetEnvironment: 'Heltec_tower_v2_sdcard_repe',
      receiverStorage: 'external_sd',
    );
    expect(discovery.firmwareTag, 'lora-ota-v1.17.1.6');
    expect(discovery.hasApplicationPackage, isFalse);
  });

  test(
    'rejects truncated build profile with a different storage type',
    () async {
      final service = GitHubMotaReleaseService(
        client: _client(capabilities: capabilities),
      );
      final discovery = await service.findForTarget(
        targetEnvironment: 'Heltec_tower_v2_sdcard_repe',
        receiverStorage: 'external_qspi',
      );
      expect(discovery.firmwareTag, isNull);
    },
  );

  test('loads only the bootloader with exact storage capability', () async {
    final internal = await buildTestBootloaderMotaContainer(storageCaps: 0x0A);
    final sd = await buildTestBootloaderMotaContainer(storageCaps: 0x09);
    final archive = Archive()
      ..add(ArchiveFile.bytes('mota/internal.mota', internal))
      ..add(ArchiveFile.bytes('mota/sd.mota', sd));
    final bundle = ZipEncoder().encodeBytes(archive);
    final service = GitHubMotaReleaseService(
      client: _client(capabilities: capabilities, bundle: bundle),
    );
    final discovery = await service.findForTarget(
      targetEnvironment: environment,
      receiverStorage: 'external_sd',
    );
    final file = await service.downloadBootloader(
      discovery,
      targetId: 0xD50D2D44,
      storageCaps: 0x09,
    );
    expect(file.name, 'sd.mota');
    expect(file.bootloaderStorageCaps, 0x09);
    expect(file.isSigned, isTrue);
  });

  test(
    'downloads a digest-checked exact-board raw image for phone build',
    () async {
      final image = _firmwareImage(targetId: 0x11223344);
      final archive = Archive()..add(ArchiveFile.bytes('firmware.bin', image));
      final bundle = ZipEncoder().encodeBytes(archive);
      final service = GitHubMotaReleaseService(
        client: _client(capabilities: capabilities, firmwareBundle: bundle),
      );
      final discovery = await service.findForTarget(
        targetEnvironment: environment,
        receiverStorage: 'external_sd',
      );
      expect(discovery.hasApplicationImage, isTrue);
      expect(
        await service.downloadApplicationImage(discovery, targetId: 0x11223344),
        image,
      );
      await expectLater(
        service.downloadApplicationImage(discovery, targetId: 0x55667788),
        throwsStateError,
      );
    },
  );

  test('rejects GitHub asset when its digest is wrong', () async {
    final service = GitHubMotaReleaseService(
      client: _client(
        capabilities: capabilities,
        corruptCapabilityDigest: true,
      ),
    );
    await expectLater(
      service.findForTarget(
        targetEnvironment: environment,
        receiverStorage: 'external_sd',
      ),
      throwsStateError,
    );
  });

  test('lists migration bundles and rejects a bad GitHub digest', () async {
    final service = GitHubMotaReleaseService(
      client: _client(
        capabilities: capabilities,
        migrationBundle: Uint8List.fromList(<int>[1, 2, 3]),
        corruptMigrationDigest: true,
      ),
    );
    final assets = await service.findPartitionMigrationBundles();
    expect(assets, hasLength(1));
    expect(assets.single.name, endsWith('-migration.zip'));
    await expectLater(
      service.downloadPartitionMigrationBundle(assets.single),
      throwsStateError,
    );
  });

  test('finds only exact-board BLE Companion OTA assets', () async {
    final bytes = Uint8List.fromList(<int>[1, 2, 3]);
    final digest = crypto.sha256.convert(bytes).toString();
    Map<String, Object> asset(String name) => <String, Object>{
      'name': name,
      'browser_download_url':
          'https://github.com/meshcore-dev/MeshCore/releases/download/companion-v1.17.1/$name',
      'digest': 'sha256:$digest',
      'size': bytes.length,
    };
    final service = GitHubMotaReleaseService(
      client: MockClient((request) async {
        if (request.url.host == 'api.github.com') {
          return http.Response(
            jsonEncode(<Object>[
              <String, Object>{
                'name': 'Companion',
                'tag_name': 'companion-v1.17.1',
                'html_url':
                    'https://github.com/meshcore-dev/MeshCore/releases/tag/companion-v1.17.1',
                'assets': <Object>[
                  asset('RAK_4631_companion_radio_ble-v1.17.1.zip'),
                  asset('RAK_4631_companion_radio_usb-v1.17.1.zip'),
                  asset('RAK_4631_companion_radio_ble-v1.17.1-merged.bin'),
                  asset('Other_companion_radio_ble-v1.17.1.zip'),
                ],
              },
            ]),
            200,
          );
        }
        return http.Response.bytes(bytes, 200);
      }),
    );
    final assets = await service.findCompanionAssets('RAKwireless RAK4631');
    expect(assets.map((asset) => asset.name), <String>[
      'RAK_4631_companion_radio_ble-v1.17.1.zip',
    ]);
    expect(await service.downloadCompanionAsset(assets.single), bytes);
  });

  test('does not treat an older upstream Companion as an upgrade', () {
    expect(
      GitHubMotaReleaseService.isCompanionReleaseNewer(
        'Companion v1.17.1.7-halo-keymind',
        'Heltec_t096_companion_radio_ble-v1.17.1-d929643.zip',
      ),
      isFalse,
    );
    expect(
      GitHubMotaReleaseService.isCompanionReleaseNewer(
        'Companion v1.17.1.7-halo-keymind',
        'Heltec_t096_companion_radio_ble-v1.17.2-d929643.zip',
      ),
      isTrue,
    );
    expect(
      GitHubMotaReleaseService.isCompanionReleaseNewer(
        'Unknown firmware',
        'Heltec_t096_companion_radio_ble-v1.17.2.zip',
      ),
      isNull,
    );
  });
}

MockClient _client({
  required List<int> capabilities,
  Uint8List? bundle,
  Uint8List? firmwareBundle,
  Uint8List? migrationBundle,
  bool corruptCapabilityDigest = false,
  bool corruptMigrationDigest = false,
}) {
  const prefix = 'Heltec_tower_v2_sdcard_repeater_lora_ota';
  const capabilitiesName = '$prefix.capabilities.json';
  const firmwareName = '$prefix.zip';
  const bundleName = 'OTAFIX-2.4.7-bootloader-mota.zip';
  const migrationName = 'heltec-v4-test-migration.zip';
  final bundleBytes = bundle ?? Uint8List.fromList(<int>[1, 2, 3]);

  Map<String, Object> asset(String name, List<int> bytes, String repository) {
    final digest = crypto.sha256.convert(bytes).toString();
    return <String, Object>{
      'name': name,
      'browser_download_url':
          'https://github.com/mikecarper/$repository/releases/download/test/$name',
      'digest':
          'sha256:${(corruptCapabilityDigest && name == capabilitiesName) || (corruptMigrationDigest && name == migrationName) ? List<String>.filled(64, '0').join() : digest}',
      'size': bytes.length,
    };
  }

  final firmware = <String, Object>{
    'name': 'MeshCore 1.17.1.6 LoRa OTA',
    'tag_name': 'lora-ota-v1.17.1.6',
    'html_url': 'https://github.com/mikecarper/MeshCore/releases/tag/test',
    'assets': <Object>[
      asset(capabilitiesName, capabilities, 'MeshCore'),
      if (firmwareBundle != null)
        asset(firmwareName, firmwareBundle, 'MeshCore'),
      if (migrationBundle != null)
        asset(migrationName, migrationBundle, 'MeshCore'),
    ],
  };
  final bootloader = <String, Object>{
    'name': 'OTAFIX 2.4.7',
    'tag_name': '0.11.0-OTAFIX2.4.7',
    'html_url':
        'https://github.com/mikecarper/Adafruit_nRF52_Bootloader_OTAFIX/releases/tag/test',
    'assets': <Object>[
      asset(bundleName, bundleBytes, 'Adafruit_nRF52_Bootloader_OTAFIX'),
    ],
  };
  return MockClient((request) async {
    if (request.url.host == 'api.github.com') {
      if (request.url.path.contains('/MeshCore/')) {
        return http.Response(jsonEncode(<Object>[firmware]), 200);
      }
      return http.Response(jsonEncode(<Object>[bootloader]), 200);
    }
    if (request.url.path.endsWith(capabilitiesName)) {
      return http.Response.bytes(capabilities, 200);
    }
    if (firmwareBundle != null && request.url.path.endsWith(firmwareName)) {
      return http.Response.bytes(firmwareBundle, 200);
    }
    if (migrationBundle != null && request.url.path.endsWith(migrationName)) {
      return http.Response.bytes(migrationBundle, 200);
    }
    if (request.url.path.endsWith(bundleName)) {
      return http.Response.bytes(bundleBytes, 200);
    }
    return http.Response('Not found', 404);
  });
}

Uint8List _firmwareImage({required int targetId}) {
  final body = Uint8List.fromList(List<int>.generate(4096, (i) => i & 0xFF));
  final image = Uint8List(body.length + 56)..setRange(0, body.length, body);
  final trailer = ByteData.sublistView(image, body.length);
  image.setRange(body.length, body.length + 4, 'EndF'.codeUnits);
  trailer.setUint32(4, body.length, Endian.little);
  image.setRange(
    body.length + 8,
    body.length + 16,
    crypto.sha256.convert(body).bytes.sublist(0, 8),
  );
  trailer.setUint32(16, 0x01110106, Endian.little);
  trailer.setUint32(20, targetId, Endian.little);
  image.setRange(body.length + 24, body.length + 34, 'TEST_BOARD'.codeUnits);
  return image;
}
