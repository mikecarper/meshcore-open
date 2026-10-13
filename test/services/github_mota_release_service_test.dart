import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshcore_open/services/github_mota_release_service.dart';
import 'package:meshcore_open/services/rak_bootloader_migration.dart';

import '../support/mota_test_data.dart';
import '../support/companion_firmware_test_data.dart';

void main() {
  test(
    'version history retains exact-board verified Full images from older releases',
    () async {
      const target = 'Heltec_tower_v2_companion_radio_full';
      final caps = utf8.encode(
        jsonEncode({
          'artifact_target': target,
          'build_profile': 'full',
          'verified': true,
          'ota_update_verified': true,
          'ota_update_methods': ['bluetooth'],
          'capabilities': ['profile.full'],
        }),
      );
      Map<String, Object> asset(String name, List<int> bytes) => {
        'name': name,
        'browser_download_url':
            'https://github.com/mikecarper/MeshCore/releases/download/test/$name',
        'size': bytes.length,
        'digest': 'sha256:${crypto.sha256.convert(bytes)}',
      };
      final service = GitHubMotaReleaseService(
        client: MockClient((request) async {
          if (request.url.host == 'api.github.com') {
            return http.Response(
              jsonEncode([
                for (final version in [
                  '1.17.1.10',
                  '1.17.1.9',
                  '1.17.1.8',
                  '1.17.1.7',
                ])
                  {
                    'tag_name': 'v$version',
                    'draft': version == '1.17.1.10',
                    'assets': [
                      asset('$target-v$version.zip', [1, 2, 3]),
                      // Unverified old firmware is not promoted by choosing history.
                      if (version != '1.17.1.7')
                        asset('$target-v$version.capabilities.json', caps),
                      asset('Heltec_t096_companion_radio_full-v$version.zip', [
                        1,
                        2,
                        3,
                      ]),
                      asset(
                        'Heltec_tower_v2_companion_radio_ble-v$version.zip',
                        [1, 2, 3],
                      ),
                    ],
                  },
              ]),
              200,
            );
          }
          expect(request.url.path.endsWith('.capabilities.json'), isTrue);
          return http.Response.bytes(caps, 200);
        }),
      );
      addTearDown(service.dispose);
      expect(
        (await service.findCompanionAssets(
          'Heltec Tower V2',
        )).map((a) => a.name),
        ['$target-v1.17.1.9.zip'],
      );
      expect(
        (await service.findCompanionAssets(
          'Heltec Tower V2',
          includeOlderVersions: true,
        )).map((a) => a.name),
        ['$target-v1.17.1.9.zip', '$target-v1.17.1.8.zip'],
      );
    },
  );

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
    'selects the installed RAK recovery identity and checks the nested ZIP',
    () async {
      const tag = 'v0.11.0-OTAFIX2.4.10';
      const profile = 'wiscore_rak4631_auto';
      const recoveryName =
          'R_wiscore_rak4631_auto_bootloader-v0.11.0-OTAFIX2.4.10_s140_6.1.1.zip';
      const normalName =
          'wiscore_rak4631_auto_bootloader-v0.11.0-OTAFIX2.4.10_s140_6.1.1.zip';
      const bundleName = 'OTAFIX-2.4.10-R_recovery.zip';
      final dfu = testNrfDfuZip(component: 'softdevice_bootloader');
      final member = 'boards/$profile/$recoveryName';
      final innerHash = crypto.sha256.convert(dfu).toString();
      final bundle = ZipEncoder().encodeBytes(
        Archive()
          ..add(ArchiveFile.bytes(member, dfu))
          ..add(
            ArchiveFile.bytes(
              'manifest.json',
              utf8.encode(
                jsonEncode({
                  'tag': tag,
                  'recovery_only': true,
                  'boards': [
                    {
                      'board': profile,
                      'device_name': '4631_AUTO_DFU',
                      'files': {recoveryName: innerHash},
                    },
                  ],
                }),
              ),
            ),
          )
          ..add(
            ArchiveFile.bytes(
              'SHA256SUMS.txt',
              utf8.encode('$innerHash  $member\n'),
            ),
          ),
      );
      Map<String, Object> asset(String name, List<int> bytes) => {
        'name': name,
        'browser_download_url':
            'https://github.com/mikecarper/Adafruit_nRF52_Bootloader_OTAFIX/releases/download/$tag/$name',
        'digest': 'sha256:${crypto.sha256.convert(bytes)}',
        'size': bytes.length,
      };
      final service = GitHubMotaReleaseService(
        client: MockClient((request) async {
          if (request.url.host == 'api.github.com') {
            return http.Response(
              jsonEncode([
                {
                  'name': 'OTAFIX 2.4.10',
                  'tag_name': tag,
                  'assets': [asset(normalName, dfu), asset(bundleName, bundle)],
                },
              ]),
              200,
            );
          }
          if (request.url.path.endsWith('/$normalName')) {
            return http.Response.bytes(dfu, 200);
          }
          if (request.url.path.endsWith('/$bundleName')) {
            return http.Response.bytes(bundle, 200);
          }
          return http.Response('Missing', 404);
        }),
      );
      final plan = RakBootloaderMigration.fromReplies(
        board: 'RAK 4631',
        bootloader: 'BL name=4631_AUTO_DFU abi=2 caps=02',
      );
      final files = await service.downloadRakBootloaderDfu(plan);
      expect(files.tag, tag);
      expect(files.recoveryName, recoveryName);
      expect(files.recoveryBytes, dfu);
      expect(files.normalName, normalName);
      expect(files.normalBytes, dfu);
    },
  );

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
          if (request.url.path == '/repos/mikecarper/MeshCore/releases') {
            return http.Response('[]', 200);
          }
          return http.Response(
            jsonEncode(<Object>[
              <String, Object>{
                'name': 'Companion',
                'tag_name': 'companion-v1.17.1',
                'html_url':
                    'https://github.com/meshcore-dev/MeshCore/releases/tag/companion-v1.17.1',
                'assets': <Object>[
                  asset('RAK_4631_companion_radio_ble-v1.17.1.zip'),
                  asset('RAK_4631_companion_radio_ble-v1.17.1.bin'),
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
    final assets = await service.findCompanionAssets(
      'RAK4631',
      preserveFullProfile: false,
    );
    expect(assets.map((asset) => asset.name), <String>[
      'RAK_4631_companion_radio_ble-v1.17.1.zip',
    ]);
    final nordic = await service.findCompanionAssets(
      'RAK4631',
      extension: 'zip',
      preserveFullProfile: false,
    );
    expect(nordic.map((asset) => asset.name), <String>[
      'RAK_4631_companion_radio_ble-v1.17.1.zip',
    ]);
    expect(await service.downloadCompanionAsset(nordic.single), bytes);
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

  test('separates a numeric-version reinstall from an older release', () {
    const installed = 'Companion v1.17.1.9-fork-build (protocol 14)';
    expect(
      GitHubMotaReleaseService.compareCompanionRelease(
        installed,
        'Heltec_t096_companion_radio_full-v1.17.1.9-other.zip',
      ),
      0,
    );
    expect(
      GitHubMotaReleaseService.isCompanionReleaseNewer(
        installed,
        'Heltec_t096_companion_radio_full-v1.17.1.9-other.zip',
      ),
      false,
    );
    expect(
      GitHubMotaReleaseService.compareCompanionRelease(
        installed,
        'Heltec_t096_companion_radio_full-v1.17.1.8.zip',
      ),
      lessThan(0),
    );
    expect(
      GitHubMotaReleaseService.compareCompanionRelease(
        installed,
        'Heltec_t096_companion_radio_full-v1.17.1.10.zip',
      ),
      greaterThan(0),
    );
    expect(
      GitHubMotaReleaseService.compareCompanionRelease(
        'Unknown firmware',
        'Heltec_t096_companion_radio_full-v1.17.1.9.zip',
      ),
      isNull,
    );
  });

  for (final entry in <String, String?>{
    'Heltec V4 OLED': 'heltec_v4',
    'Heltec V4.3 OLED': 'heltec_v4',
    'Heltec V4 TFT': 'heltec_v4_tft',
    'Heltec V4.3 TFT': 'heltec_v4_tft',
    'heltec_v4': 'heltec_v4',
    'heltec_v4_r8': 'heltec_v4_r8',
    'heltec_v4_r8_tft': 'heltec_v4_r8_tft',
    'Heltec V4.4 OLED': null,
    'Heltec V4.3': null,
    'Heltec V3 OLED': null,
    'Unknown Heltec V4.3 OLED': null,
  }.entries) {
    test('matches only the supported Companion build for ${entry.key}', () async {
      final service = GitHubMotaReleaseService(
        client: MockClient((request) async {
          if (request.url.path == '/repos/mikecarper/MeshCore/releases') {
            return http.Response('[]', 200);
          }
          expect(request.url.path, '/repos/meshcore-dev/MeshCore/releases');
          return http.Response(
            jsonEncode(<Object>[
              <String, Object>{
                'tag_name': 'companion-v1.17.1',
                'assets': <Object>[
                  for (final board in <String>[
                    'heltec_v4',
                    'heltec_v4_r8',
                    'heltec_v4_tft',
                    'heltec_v4_r8_tft',
                  ])
                    for (final suffix in <String>[
                      'ble-v1.17.1.bin',
                      'ble-v1.17.1-merged.bin',
                      'usb-v1.17.1.bin',
                    ])
                      <String, Object>{
                        'name': '${board}_companion_radio_$suffix',
                        'browser_download_url':
                            'https://github.com/meshcore-dev/MeshCore/releases/download/companion-v1.17.1/${board}_companion_radio_$suffix',
                        'size': 3,
                      },
                ],
              },
            ]),
            200,
          );
        }),
      );
      addTearDown(service.dispose);
      if (entry.value == null) {
        await expectLater(
          service.findCompanionAssets(entry.key, preserveFullProfile: false),
          throwsFormatException,
        );
        return;
      }
      final assets = await service.findCompanionAssets(
        entry.key,
        preserveFullProfile: false,
      );
      expect(assets.map((asset) => asset.name), <String>[
        if (entry.value != null)
          '${entry.value}_companion_radio_ble-v1.17.1.bin',
      ]);
    });
  }

  test('Full profile release metadata prevents fallback to stock BLE', () async {
    const name = 'heltec_v4_r8_companion_radio_full-v1.17.1.9-deadbeef.bin';
    const capName =
        'heltec_v4_r8_companion_radio_full-v1.17.1.9-deadbeef.capabilities.json';
    final image = testEspApplication(hardwareId: 'heltec_v4_r8', targetId: 0);
    final caps = utf8.encode(
      jsonEncode({
        'artifact_target': 'heltec_v4_r8_companion_radio_full',
        'build_profile': 'full',
        'verified': true,
        'ota_update_verified': true,
        'ota_update_methods': ['wifi'],
        'capabilities': ['profile.full'],
      }),
    );
    Map<String, Object> asset(String name, List<int> bytes) => {
      'name': name,
      'browser_download_url':
          'https://github.com/mikecarper/MeshCore/releases/download/test/$name',
      'size': bytes.length,
      'digest': 'sha256:${crypto.sha256.convert(bytes)}',
    };
    final service = GitHubMotaReleaseService(
      client: MockClient((request) async {
        if (request.url.host == 'api.github.com') {
          expect(request.url.path, '/repos/mikecarper/MeshCore/releases');
          return http.Response(
            jsonEncode([
              {
                'tag_name': 'full-test',
                'assets': [
                  asset(name, image),
                  asset(capName, caps),
                  asset('heltec_v4_r8_companion_radio_ble-v1.18.0.bin', image),
                ],
              },
            ]),
            200,
          );
        }
        return http.Response.bytes(
          request.url.path.endsWith(capName) ? caps : image,
          200,
        );
      }),
    );
    addTearDown(service.dispose);
    final assets = await service.findCompanionAssets('Heltec V4 R8 OLED');
    expect(assets.map((a) => a.name), [name]);
    final download = await service.downloadCompanionFirmware(
      assets.single,
      board: 'Heltec V4 R8 OLED',
    );
    expect(download.provenance.profile, 'full');
    await expectLater(
      service.downloadCompanionFirmware(assets.single, board: 'Heltec V4 OLED'),
      throwsFormatException,
    );
  });

  test(
    'Full metadata missing transport or linked proof is not offered',
    () async {
      const name =
          'Heltec_tower_v2_companion_radio_full-v1.17.1.9-deadbeef.zip';
      final bytes = testNrfDfuZip(
        image: testNrfApplication(hardwareId: 'Heltec_tower_v2', targetId: 0),
      );
      final service = GitHubMotaReleaseService(
        client: MockClient((request) async {
          expect(request.url.host, 'api.github.com');
          return http.Response(
            jsonEncode([
              {
                'tag_name': 'full-test',
                'assets': [
                  {
                    'name': name,
                    'browser_download_url':
                        'https://github.com/mikecarper/MeshCore/releases/download/test/$name',
                    'size': bytes.length,
                    'digest': 'sha256:${crypto.sha256.convert(bytes)}',
                  },
                ],
              },
            ]),
            200,
          );
        }),
      );
      addTearDown(service.dispose);
      expect(
        await service.findCompanionAssets('Heltec Mesh Tower V2 SD'),
        isEmpty,
      );
    },
  );
  test(
    'older trusted Nordic release is digest-bound; missing digest is blocked',
    () async {
      const name = 'Heltec_t096_companion_radio_ble-v1.17.1-deadbeef.zip';
      final bytes = testNrfDfuZip(image: testNrfApplication(marked: false));
      for (final digest in [
        'sha256:${crypto.sha256.convert(bytes)}',
        '',
        'sha256:${List.filled(64, '0').join()}',
      ]) {
        final service = GitHubMotaReleaseService(
          client: MockClient((request) async {
            if (request.url.host == 'api.github.com') {
              if (request.url.path.contains('/mikecarper/')) {
                return http.Response('[]', 200);
              }
              return http.Response(
                jsonEncode([
                  {
                    'tag_name': 'companion-test',
                    'assets': [
                      {
                        'name': name,
                        'size': bytes.length,
                        'digest': digest,
                        'browser_download_url':
                            'https://github.com/meshcore-dev/MeshCore/releases/download/test/$name',
                      },
                    ],
                  },
                ]),
                200,
              );
            }
            return http.Response.bytes(bytes, 200);
          }),
        );
        addTearDown(service.dispose);
        final assets = await service.findCompanionAssets(
          'Heltec T096',
          preserveFullProfile: false,
        );
        if (digest.endsWith(crypto.sha256.convert(bytes).toString())) {
          final download = await service.downloadCompanionFirmware(
            assets.single,
            board: 'Heltec T096',
          );
          expect(
            download.provenance.sha256,
            crypto.sha256.convert(bytes).toString(),
          );
        } else {
          await expectLater(
            service.downloadCompanionFirmware(
              assets.single,
              board: 'Heltec T096',
            ),
            throwsA(anyOf(isA<FormatException>(), isA<StateError>())),
          );
        }
      }
    },
  );
  test(
    'Tower aliases select only capability-verified Full Nordic firmware',
    () async {
      const name =
          'Heltec_tower_v2_companion_radio_full-v1.17.1.9-deadbeef.zip';
      final bytes = testNrfDfuZip(
        image: testNrfApplication(hardwareId: 'Heltec_tower_v2', targetId: 0),
      );
      final valid = <String, Object>{
        'artifact_target': 'Heltec_tower_v2_companion_radio_full',
        'build_profile': 'full',
        'verified': true,
        'ota_update_verified': true,
        'ota_update_methods': ['bluetooth'],
        'capabilities': ['profile.full'],
      };
      for (final invalid in [
        <String, Object>{},
        {'verified': false},
        {
          'ota_update_methods': ['wifi'],
        },
        {'artifact_target': 'Heltec_t114_companion_radio_full'},
        {
          'capabilities': ['profile.ble'],
        },
      ]) {
        final cap = utf8.encode(jsonEncode({...valid, ...invalid}));
        final capName = name.replaceFirst('.zip', '.capabilities.json');
        Map<String, Object> asset(String name, List<int> bytes) => {
          'name': name,
          'size': bytes.length,
          'digest': 'sha256:${crypto.sha256.convert(bytes)}',
          'browser_download_url':
              'https://github.com/mikecarper/MeshCore/releases/download/test/$name',
        };
        final service = GitHubMotaReleaseService(
          client: MockClient((request) async {
            if (request.url.host == 'api.github.com') {
              expect(request.url.path, '/repos/mikecarper/MeshCore/releases');
              return http.Response(
                jsonEncode([
                  {
                    'tag_name': 'full-test',
                    'assets': [asset(name, bytes), asset(capName, cap)],
                  },
                ]),
                200,
              );
            }
            return http.Response.bytes(
              request.url.path.endsWith(capName) ? cap : bytes,
              200,
            );
          }),
        );
        addTearDown(service.dispose);
        final assets = await service.findCompanionAssets(
          'Heltec Mesh Tower V2 SD',
        );
        if (invalid.isEmpty) {
          expect(assets.map((a) => a.name), [name]);
          await service.downloadCompanionFirmware(
            assets.single,
            board: 'Heltec Mesh Tower V2 SD',
          );
        } else {
          expect(assets, isEmpty);
        }
      }
    },
  );
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
