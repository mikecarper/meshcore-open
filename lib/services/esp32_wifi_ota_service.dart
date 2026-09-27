import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'companion_firmware_inspector.dart';

enum Esp32WifiOtaProtocol { lightweight, elegant }

enum Esp32MigrationBridgeState { waiting, ready }

class Esp32WifiOtaProbe {
  const Esp32WifiOtaProbe({required this.protocol, required this.identity});

  final Esp32WifiOtaProtocol protocol;
  final String identity;
}

/// Uploads an ESP32 application image directly from the phone. The target
/// returns the URL after an authenticated `start ota` command; no Wi-Fi
/// password or firmware image passes through a helper computer.
class Esp32WifiOtaService {
  Esp32WifiOtaService({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  static Uri parseStartReply(String reply) {
    final match = RegExp(
      r'\bStarted:\s*(http://\S+/update)\b',
    ).firstMatch(reply);
    if (match == null) {
      throw const FormatException('The radio did not return an OTA URL.');
    }
    final uri = Uri.tryParse(match.group(1)!);
    if (uri == null ||
        uri.scheme != 'http' ||
        uri.path != '/update' ||
        uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        (uri.port != 80 && uri.port != 8080) ||
        !_isPrivateIpv4(uri.host)) {
      throw const FormatException(
        'OTA URL is not a private-network update endpoint.',
      );
    }
    return uri;
  }

  static final Uri migrationBridgeUri = Uri.parse('http://192.168.4.1/update');

  /// The bridge deliberately refuses a Full upload until its new partition
  /// table and preserved private identity both passed device-side checks.
  Future<Esp32MigrationBridgeState> probeMigrationBridge() async {
    final response = await _client
        .get(migrationBridgeUri.replace(path: '/'))
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200 ||
        !response.body.contains('MeshCore Wi-Fi partition migration')) {
      throw const FormatException('This is not a MeshCore migration bridge.');
    }
    final body = response.body;
    if (body.contains('Expanded layout ready')) {
      return Esp32MigrationBridgeState.ready;
    }
    if (body.contains('Refused:') ||
        body.contains('Private identity recovery did not complete')) {
      throw StateError('The migration bridge refused or failed recovery.');
    }
    return Esp32MigrationBridgeState.waiting;
  }

  static bool _isPrivateIpv4(String host) {
    final octets = host.split('.').map(int.tryParse).toList();
    if (octets.length != 4 ||
        octets.any((part) => part == null || part < 0 || part > 255)) {
      return false;
    }
    final a = octets[0]!;
    final b = octets[1]!;
    return a == 10 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168);
  }

  static void validateImage(String name, Uint8List image) {
    final lower = name.toLowerCase();
    if (!lower.endsWith('.bin')) {
      throw const FormatException('Choose an ESP32 application .bin.');
    }
    if (CompanionFirmwareInspector.inspectEsp32(image) ==
            Esp32FirmwareLayout.fullFlash ||
        lower.contains('merged') ||
        lower.contains('cleaninstall') ||
        lower.contains('factory')) {
      throw const FormatException(
        'This is a full/erase ESP32 image, not a Wi-Fi OTA application. '
        'Use an exact-board wired installer.',
      );
    }
  }

  Future<Esp32WifiOtaProbe> probe(Uri updateUri) async {
    final response = await _client
        .get(updateUri.replace(path: '/'))
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw StateError('OTA server returned HTTP ${response.statusCode}.');
    }
    final body = response.body;
    if (body.contains('MeshCore firmware update')) {
      return const Esp32WifiOtaProbe(
        protocol: Esp32WifiOtaProtocol.lightweight,
        identity: 'MeshCore lightweight updater',
      );
    }
    try {
      final info = jsonDecode(body);
      if (info is Map && info['hardware'] == 'ESP32' && info['id'] is String) {
        return Esp32WifiOtaProbe(
          protocol: Esp32WifiOtaProtocol.elegant,
          identity: info['id'] as String,
        );
      }
    } catch (_) {
      // A non-JSON page is not the expected legacy OTA server.
    }
    throw const FormatException(
      'This URL did not identify a MeshCore ESP32 updater.',
    );
  }

  Future<void> upload({
    required Uri updateUri,
    required Esp32WifiOtaProtocol protocol,
    required String filename,
    required Uint8List image,
  }) async {
    validateImage(filename, image);
    final http.Response response;
    if (protocol == Esp32WifiOtaProtocol.lightweight) {
      response = await _client
          .post(
            updateUri,
            headers: const {'Content-Type': 'application/octet-stream'},
            body: image,
          )
          .timeout(const Duration(minutes: 5));
    } else {
      final request = http.MultipartRequest('POST', updateUri)
        ..fields['MD5'] = md5.convert(image).toString()
        ..files.add(
          http.MultipartFile.fromBytes('firmware', image, filename: 'firmware'),
        );
      final streamed = await _client
          .send(request)
          .timeout(const Duration(minutes: 5));
      response = await http.Response.fromStream(streamed);
    }
    if (response.statusCode != 200 ||
        !response.body.trimLeft().startsWith('OK')) {
      throw StateError(
        'OTA upload was not confirmed: HTTP ${response.statusCode} '
        '${response.body.trim()}',
      );
    }
  }

  void dispose() => _client.close();
}
