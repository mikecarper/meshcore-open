import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'ble_mota_catalog.dart';
import 'esp32_partition_migration_package.dart';
import 'local_mota_builder.dart';

/// GitHub release discovery is advisory. Only a digest-checked, validated
/// .mota can enter the Bluetooth source catalog.
class GitHubMotaReleaseService {
  GitHubMotaReleaseService({http.Client? client})
    : _client = client,
      _ownsClient = client == null;

  static const _firmwareRepository = 'mikecarper/MeshCore';
  static const _officialFirmwareRepository = 'meshcore-dev/MeshCore';
  static const _bootloaderRepository =
      'mikecarper/Adafruit_nRF52_Bootloader_OTAFIX';

  http.Client? _client;
  Future<http.Client>? _clientFuture;
  final bool _ownsClient;

  void dispose() {
    if (_ownsClient) _client?.close();
  }

  Future<http.Client> _httpClient() {
    final existing = _client;
    if (existing != null) return Future<http.Client>.value(existing);
    return _clientFuture ??= _createClient();
  }

  Future<http.Client> _createClient() async {
    // GitHub's API chains through Sectigo E46/USERTrust ECC, while release
    // assets chain through ISRG X1. Android 5.1 cannot build either path from
    // its old trust store. Add only those public roots without disabling TLS
    // chain or hostname verification.
    final pem = await rootBundle.load('assets/certs/github_legacy_roots.pem');
    final bytes = pem.buffer.asUint8List(pem.offsetInBytes, pem.lengthInBytes);
    final context = SecurityContext(withTrustedRoots: true)
      ..setTrustedCertificatesBytes(bytes);
    return _client = IOClient(HttpClient(context: context));
  }

  Future<GitHubMotaDiscovery> findForTarget({
    required String targetEnvironment,
    String? receiverStorage,
  }) async {
    final targetPrefix = targetEnvironment.toLowerCase().replaceFirst(
      RegExp(r'_repeat$'),
      '_repeater',
    );
    if (!RegExp(r'^[a-z0-9_]+$').hasMatch(targetPrefix)) {
      throw const FormatException(
        'Target did not report a valid build profile',
      );
    }
    // Remote CLI replies share the LoRa frame limit. A long `ota status`
    // reply can end mid-profile (for example `_sdcard_repe`). In that case
    // accept a profile prefix only when the receiver's storage type is also
    // known; the actual .mota still has to pass its target-ID preflight.
    bool matchesProfile(String value) {
      final normalized = value.toLowerCase();
      return normalized.startsWith('${targetPrefix}_') ||
          (receiverStorage != null &&
              targetPrefix.length >= 16 &&
              normalized.startsWith(targetPrefix));
    }

    final results = await Future.wait(<Future<List<_Release>>>[
      _releases(_firmwareRepository),
      _releases(_bootloaderRepository),
    ]);

    _Release? firmware;
    GitHubReleaseAsset? capabilityAsset;
    for (final release in results[0]) {
      if (!release.tag.startsWith('lora-ota-')) continue;
      final matches = release.assets.where(
        (asset) =>
            matchesProfile(asset.name) &&
            asset.name.endsWith('.capabilities.json'),
      );
      for (final asset in matches) {
        final data = jsonDecode(utf8.decode(await _download(asset)));
        if (data is! Map<String, dynamic>) continue;
        final artifactTarget = data['artifact_target'];
        final methods = data['ota_update_methods'];
        final requirements = data['ota_update_requirements'];
        final lora = requirements is Map ? requirements['lora'] : null;
        final storage = lora is Map ? lora['storage'] : null;
        if (artifactTarget is! String ||
            !matchesProfile(artifactTarget) ||
            data['ota_update_verified'] != true ||
            methods is! List ||
            !methods.contains('lora') ||
            (receiverStorage != null && storage != receiverStorage)) {
          continue;
        }
        firmware = release;
        capabilityAsset = asset;
        break;
      }
      if (firmware != null) break;
    }

    GitHubReleaseAsset? applicationPackage;
    GitHubReleaseAsset? applicationFirmwareBundle;
    if (firmware != null && capabilityAsset != null) {
      final prefix = capabilityAsset.name.substring(
        0,
        capabilityAsset.name.length - '.capabilities.json'.length,
      );
      for (final asset in firmware.assets) {
        if (asset.name.startsWith(prefix) && asset.name.endsWith('.mota')) {
          applicationPackage = asset;
        } else if (asset.name.startsWith(prefix) &&
            asset.name.endsWith('.zip')) {
          applicationFirmwareBundle = asset;
        }
      }
    }

    _Release? bootloader;
    GitHubReleaseAsset? bootloaderBundle;
    for (final release in results[1]) {
      for (final asset in release.assets) {
        if (asset.name.endsWith('-bootloader-mota.zip')) {
          bootloader = release;
          bootloaderBundle = asset;
          break;
        }
      }
      if (bootloader != null) break;
    }

    return GitHubMotaDiscovery(
      firmwareName: firmware?.name,
      firmwareTag: firmware?.tag,
      firmwareUrl: firmware?.htmlUrl,
      applicationPackage: applicationPackage,
      applicationFirmwareBundle: applicationFirmwareBundle,
      bootloaderName: bootloader?.name,
      bootloaderTag: bootloader?.tag,
      bootloaderUrl: bootloader?.htmlUrl,
      bootloaderBundle: bootloaderBundle,
    );
  }

  Future<BleMotaFile> downloadApplication(
    GitHubMotaDiscovery discovery, {
    required int targetId,
  }) async {
    final asset = discovery.applicationPackage;
    if (asset == null) {
      throw StateError('This release has no signed application .mota');
    }
    final file = await BleMotaFile.load(
      XFile.fromData(
        await _download(asset),
        path: asset.name,
        name: asset.name,
      ),
    );
    if (file.isBootloader || file.targetId != targetId) {
      throw StateError('GitHub package does not match this repeater');
    }
    return file;
  }

  /// Returns the raw application image from a digest-checked board-specific
  /// release bundle. The caller still must match the target ID and require an
  /// exact installed-image hash before building a delta.
  Future<Uint8List> downloadApplicationImage(
    GitHubMotaDiscovery discovery, {
    required int targetId,
  }) async {
    final asset = discovery.applicationFirmwareBundle;
    if (asset == null) {
      throw StateError('This release has no matching firmware image bundle');
    }
    final archive = ZipDecoder().decodeBytes(await _download(asset));
    Uint8List? image;
    for (final member in archive.files) {
      if (!member.isFile ||
          !<String>{
            'firmware.bin',
            'application.bin',
          }.contains(member.name.split('/').last)) {
        continue;
      }
      if (member.size == 0 || member.size > 0x100000) {
        throw const FormatException('Release firmware image is too large');
      }
      final bytes = member.readBytes();
      if (bytes == null || bytes.isEmpty || bytes.length > 0x100000) {
        throw const FormatException('Release firmware image is invalid');
      }
      if (image != null) {
        throw const FormatException('Release has ambiguous firmware images');
      }
      image = Uint8List.fromList(bytes);
    }
    if (image == null ||
        FirmwareImageIdentity.read(image).targetId != targetId) {
      throw StateError('Release image does not match this radio');
    }
    return image;
  }

  Future<BleMotaFile> downloadBootloader(
    GitHubMotaDiscovery discovery, {
    required int targetId,
    required int storageCaps,
  }) async {
    final asset = discovery.bootloaderBundle;
    if (asset == null) {
      throw StateError('No published bootloader mOTA bundle was found');
    }
    final archive = ZipDecoder().decodeBytes(await _download(asset));
    BleMotaFile? match;
    for (final member in archive.files) {
      if (!member.isFile || !member.name.endsWith('.mota')) continue;
      final bytes = member.readBytes();
      if (bytes == null) continue;
      final name = member.name.split('/').last;
      final file = await BleMotaFile.load(
        XFile.fromData(bytes, path: name, name: name),
      );
      if (!file.isBootloader ||
          file.targetId != targetId ||
          file.bootloaderStorageCaps != storageCaps) {
        continue;
      }
      if (match != null) {
        throw StateError('Bootloader release has ambiguous board matches');
      }
      match = file;
    }
    if (match == null) {
      throw StateError('No bootloader in this release matches the target');
    }
    return match;
  }

  /// Lists only published board bundles. The exact radio/board still has to
  /// be confirmed by the user because legacy Wi-Fi builds may not expose an
  /// mOTA target ID over LoRa.
  Future<List<GitHubReleaseAsset>> findPartitionMigrationBundles() async {
    for (final release in await _releases(_firmwareRepository)) {
      final matches = release.assets
          .where((asset) => asset.name.endsWith('-migration.zip'))
          .toList();
      if (matches.isNotEmpty) {
        matches.sort((a, b) => a.name.compareTo(b.name));
        return matches;
      }
    }
    return <GitHubReleaseAsset>[];
  }

  Future<Esp32PartitionMigrationPackage> downloadPartitionMigrationBundle(
    GitHubReleaseAsset asset,
  ) async {
    if (!asset.name.endsWith('-migration.zip')) {
      throw const FormatException('This is not a migration release bundle.');
    }
    return Esp32PartitionMigrationPackage.load(await _download(asset));
  }

  /// Exact-board Companion BLE release assets from the upstream release feed.
  /// USB variants and merged ESP32 images are not suitable for phone OTA.
  Future<List<GitHubReleaseAsset>> findCompanionAssets(String board) async {
    final normalizedBoard = board.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]'),
      '',
    );
    if (normalizedBoard.length < 5) {
      throw const FormatException('Companion did not report a specific board.');
    }
    for (final release in await _releases(_officialFirmwareRepository)) {
      if (!release.tag.startsWith('companion-')) continue;
      final matches = release.assets.where((asset) {
        final name = asset.name.toLowerCase();
        final marker = name.indexOf('_companion_radio_ble-');
        if (marker <= 0 ||
            name.contains('-merged.bin') ||
            !(name.endsWith('.zip') || name.endsWith('.bin'))) {
          return false;
        }
        final assetBoard = name
            .substring(0, marker)
            .replaceAll(RegExp(r'[^a-z0-9]'), '');
        return assetBoard.length >= 5 &&
            (normalizedBoard == assetBoard ||
                normalizedBoard.endsWith(assetBoard));
      }).toList();
      if (matches.isNotEmpty) {
        matches.sort((a, b) => a.name.compareTo(b.name));
        return matches;
      }
    }
    return <GitHubReleaseAsset>[];
  }

  /// Returns false for equal/older versions, and null when either label has
  /// no comparable numeric version. A fork's fourth component is significant.
  static bool? isCompanionReleaseNewer(String installed, String assetName) {
    List<int>? version(String text) {
      final match = RegExp(
        r'v(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?',
        caseSensitive: false,
      ).firstMatch(text);
      if (match == null) return null;
      return List<int>.generate(
        4,
        (index) => int.parse(match.group(index + 1) ?? '0'),
      );
    }

    final current = version(installed);
    final release = version(assetName);
    if (current == null || release == null) return null;
    for (var i = 0; i < 4; i++) {
      if (release[i] != current[i]) return release[i] > current[i];
    }
    return false;
  }

  Future<Uint8List> downloadCompanionAsset(GitHubReleaseAsset asset) async {
    if (!asset.name.toLowerCase().contains('_companion_radio_ble-') ||
        asset.name.toLowerCase().contains('-merged.bin') ||
        !(asset.name.endsWith('.zip') || asset.name.endsWith('.bin'))) {
      throw const FormatException('Not a phone-updateable Companion asset.');
    }
    return _download(asset);
  }

  Future<List<_Release>> _releases(String repository) async {
    final uri = Uri.https('api.github.com', '/repos/$repository/releases', {
      'per_page': '30',
    });
    final client = await _httpClient();
    final response = await client
        .get(
          uri,
          headers: const {
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'meshcore-open-android',
          },
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw StateError('GitHub release lookup failed (${response.statusCode})');
    }
    final payload = jsonDecode(response.body);
    if (payload is! List) {
      throw const FormatException('GitHub returned invalid release data');
    }
    return payload
        .whereType<Map<String, dynamic>>()
        .map(_Release.fromJson)
        .toList();
  }

  Future<Uint8List> _download(GitHubReleaseAsset asset) async {
    final uri = Uri.tryParse(asset.url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        !(uri.path.startsWith('/mikecarper/') ||
            uri.path.startsWith('/meshcore-dev/'))) {
      throw const FormatException('Release asset URL is not trusted');
    }
    final digest = asset.digest;
    if (digest == null ||
        !RegExp(r'^sha256:[0-9a-fA-F]{64}$').hasMatch(digest)) {
      throw const FormatException('Release asset has no SHA-256 digest');
    }
    if (asset.size <= 0 || asset.size > 32 * 1024 * 1024) {
      throw const FormatException('Release asset size is unsupported');
    }
    final client = await _httpClient();
    final response = await client
        .get(uri, headers: const {'User-Agent': 'meshcore-open-android'})
        .timeout(const Duration(minutes: 5));
    if (response.statusCode != 200 || response.bodyBytes.length != asset.size) {
      throw StateError('Release asset download was incomplete');
    }
    final actual = crypto.sha256.convert(response.bodyBytes).toString();
    if (actual.toLowerCase() != digest.substring(7).toLowerCase()) {
      throw StateError('Release asset SHA-256 does not match GitHub metadata');
    }
    return response.bodyBytes;
  }
}

class GitHubMotaDiscovery {
  const GitHubMotaDiscovery({
    required this.firmwareName,
    required this.firmwareTag,
    required this.firmwareUrl,
    required this.applicationPackage,
    required this.applicationFirmwareBundle,
    required this.bootloaderName,
    required this.bootloaderTag,
    required this.bootloaderUrl,
    required this.bootloaderBundle,
  });

  final String? firmwareName;
  final String? firmwareTag;
  final String? firmwareUrl;
  final GitHubReleaseAsset? applicationPackage;
  final GitHubReleaseAsset? applicationFirmwareBundle;
  final String? bootloaderName;
  final String? bootloaderTag;
  final String? bootloaderUrl;
  final GitHubReleaseAsset? bootloaderBundle;

  bool get hasApplicationPackage => applicationPackage != null;
  bool get hasApplicationImage => applicationFirmwareBundle != null;
  bool get hasBootloaderBundle => bootloaderBundle != null;
}

class _Release {
  _Release.fromJson(Map<String, dynamic> json)
    : name = json['name'] is String ? json['name'] as String : '',
      tag = json['tag_name'] is String ? json['tag_name'] as String : '',
      htmlUrl = json['html_url'] is String ? json['html_url'] as String : '',
      assets = (json['assets'] is List ? json['assets'] as List : const [])
          .whereType<Map<String, dynamic>>()
          .map(GitHubReleaseAsset.fromJson)
          .toList();

  final String name;
  final String tag;
  final String htmlUrl;
  final List<GitHubReleaseAsset> assets;
}

class GitHubReleaseAsset {
  GitHubReleaseAsset.fromJson(Map<String, dynamic> json)
    : name = json['name'] is String ? json['name'] as String : '',
      url = json['browser_download_url'] is String
          ? json['browser_download_url'] as String
          : '',
      digest = json['digest'] is String ? json['digest'] as String : null,
      size = json['size'] is int ? json['size'] as int : 0;

  final String name;
  final String url;
  final String? digest;
  final int size;
}
