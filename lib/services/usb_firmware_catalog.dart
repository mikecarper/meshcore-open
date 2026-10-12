import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

class UsbFirmwareDownload {
  const UsbFirmwareDownload({
    required this.name,
    required this.url,
    required this.release,
    required this.bytes,
    this.sha256Hex,
  });

  final String name;
  final Uri url;
  final String release;
  final int bytes;
  final String? sha256Hex;
}

/// Fetches bounded public artifacts; never executes a download or touches USB.
class UsbFirmwareCatalog {
  UsbFirmwareCatalog({http.Client? client, AssetBundle? assetBundle})
    : _client = client,
      _ownsClient = client == null,
      _assetBundle = assetBundle ?? rootBundle;

  static const maxArtifactBytes = 32 * 1024 * 1024;
  static const legacyRootsAsset = 'assets/certs/github_legacy_roots.pem';
  http.Client? _client;
  Future<http.Client>? _clientFuture;
  final bool _ownsClient;
  final AssetBundle _assetBundle;
  bool _disposed = false;

  Future<http.Client> _httpClient() {
    if (_disposed) throw StateError('USB firmware catalog is disposed.');
    final client = _client;
    if (client != null) return Future.value(client);
    return _clientFuture ??= _createClient();
  }

  Future<http.Client> _createClient() async {
    // Match the existing GitHub updater's public trust roots for Android 5.1.
    // Retain system roots and normal certificate/hostname verification; never
    // accept an invalid certificate to work around the old platform store.
    final pem = await _assetBundle.load(legacyRootsAsset);
    if (_disposed) throw StateError('USB firmware catalog is disposed.');
    final context = SecurityContext(withTrustedRoots: true)
      ..setTrustedCertificatesBytes(
        pem.buffer.asUint8List(pem.offsetInBytes, pem.lengthInBytes),
      );
    final client = IOClient(HttpClient(context: context));
    if (_disposed) {
      client.close();
      throw StateError('USB firmware catalog is disposed.');
    }
    return _client = client;
  }

  Future<Uint8List> download(
    Uri url, {
    int limit = maxArtifactBytes,
    String? expectedSha256,
    int? expectedBytes,
  }) async {
    if (url.scheme != 'https' || url.userInfo.isNotEmpty) {
      throw const FormatException('Firmware downloads require HTTPS.');
    }
    final client = await _httpClient();
    final watch = Stopwatch()..start();
    var current = url;
    http.StreamedResponse? response;
    for (var redirects = 0; redirects <= 5; redirects++) {
      if (current.scheme != 'https' || current.userInfo.isNotEmpty) {
        throw const FormatException('Firmware redirects must remain HTTPS.');
      }
      response = await client
          .send(
            http.Request('GET', current)
              ..followRedirects = false
              ..headers['User-Agent'] = 'MeshCore-Open-USB-Updater',
          )
          .timeout(const Duration(seconds: 30));
      if (![301, 302, 303, 307, 308].contains(response.statusCode)) break;
      final location = response.headers['location'];
      await response.stream.listen((_) {}).cancel();
      if (location == null || redirects == 5) {
        throw const FormatException('Invalid or excessive firmware redirects.');
      }
      current = current.resolve(location);
    }
    if (response == null) throw StateError('Firmware server did not answer.');
    if (response.statusCode != 200) {
      throw StateError('Firmware download failed (${response.statusCode}).');
    }
    if (response.contentLength != null && response.contentLength! > limit) {
      throw const FormatException('Firmware download is too large.');
    }
    final output = BytesBuilder(copy: false);
    await for (final part in response.stream.timeout(
      const Duration(seconds: 30),
    )) {
      if (watch.elapsed > const Duration(minutes: 3)) {
        throw StateError('Firmware download exceeded its total time limit.');
      }
      if (output.length + part.length > limit) {
        throw const FormatException(
          'Firmware download exceeded its size limit.',
        );
      }
      output.add(part);
    }
    final bytes = output.takeBytes();
    if (bytes.isEmpty ||
        (expectedBytes != null && bytes.length != expectedBytes)) {
      throw const FormatException('Firmware download is empty or incomplete.');
    }
    if (expectedSha256 != null &&
        sha256.convert(bytes).toString() != expectedSha256.toLowerCase()) {
      throw const FormatException('Firmware download checksum does not match.');
    }
    return bytes;
  }

  Future<List<UsbFirmwareDownload>> listKeymind() async {
    final bytes = await download(
      Uri.parse(
        'https://api.github.com/repos/mikecarper/MeshCore/releases?per_page=12',
      ),
      limit: 8 * 1024 * 1024,
    );
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! List) {
      throw const FormatException('Invalid firmware release listing.');
    }
    final result = <UsbFirmwareDownload>[];
    for (final item in decoded) {
      if (item is! Map<String, dynamic> || item['draft'] == true) continue;
      final tag = item['tag_name'];
      final assets = item['assets'];
      if (tag is! String || tag.startsWith('utility-') || assets is! List) {
        continue;
      }
      for (final asset in assets) {
        if (asset is! Map<String, dynamic>) continue;
        final name = asset['name'];
        final url = asset['browser_download_url'];
        final size = asset['size'];
        if (name is! String ||
            url is! String ||
            size is! int ||
            size <= 0 ||
            size > maxArtifactBytes ||
            !RegExp(r'^[A-Za-z0-9_.-]+\.(bin|zip)$').hasMatch(name) ||
            !RegExp(r'companion|repeater|room_server|sensor').hasMatch(name) ||
            name.contains('migration') ||
            name.contains('bootloader')) {
          continue;
        }
        final uri = Uri.tryParse(url);
        final expectedPrefix =
            'https://github.com/mikecarper/MeshCore/releases/download/$tag/';
        if (uri == null || !url.startsWith(expectedPrefix)) continue;
        final digest = asset['digest'];
        final checksum =
            digest is String &&
                RegExp(r'^sha256:[a-f0-9]{64}$').hasMatch(digest)
            ? digest.substring(7)
            : null;
        result.add(
          UsbFirmwareDownload(
            name: name,
            url: uri,
            release: tag,
            bytes: size,
            sha256Hex: checksum,
          ),
        );
      }
    }
    return result;
  }

  void dispose() {
    _disposed = true;
    if (_ownsClient) _client?.close();
  }
}
