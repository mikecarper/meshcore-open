import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart' show compute;

import 'companion_firmware_inspector.dart';
import 'companion_board_catalog.dart';
import 'companion_image_validator.dart';
import 'usb_firmware_package.dart';

enum Esp32WifiOtaProtocol { lightweight, elegant }

enum Esp32MigrationBridgeState { waiting, ready }

UsbFirmwareImage _inspectWifiImage((String, Uint8List) request) =>
    Esp32WifiOtaService.inspectImage(request.$1, request.$2);

class Esp32WifiOtaProbe {
  const Esp32WifiOtaProbe({
    required this.protocol,
    required this.identity,
    required this.binding,
  });

  final Esp32WifiOtaProtocol protocol;
  final String identity;
  final Esp32WifiOtaBinding binding;
}

/// Obtained over the authenticated radio link, not inferred from an AP name.
/// This prevents accidental updates to another nearby OTA AP. Plain HTTP is
/// not a defence against a hostile network that can intercept this token.
class Esp32WifiOtaBinding {
  const Esp32WifiOtaBinding({
    required this.session,
    required this.device,
    required this.chip,
    required this.slot,
    required this.hardware,
  });
  final String session, device, hardware;
  final int chip, slot;

  static Esp32WifiOtaBinding parse(String reply, {required String board}) {
    final match = RegExp(
      r'^OTA1 s=([0-9a-f]{32}) d=([0-9a-f]{12}) c=([0-9]{1,3}) slot=([0-9]{1,8}) hw=([A-Za-z0-9_.-]{1,32})$',
    ).firstMatch(reply.trim());
    final spec = CompanionBoardCatalog.lookup(board);
    if (match == null ||
        spec?.family != CompanionChipFamily.esp32 ||
        !spec!.supportsWifiOta) {
      throw const FormatException(
        'This firmware cannot prove the Wi-Fi updater belongs to this radio. Update it by USB first; no wireless image was sent.',
      );
    }
    final value = Esp32WifiOtaBinding(
      session: match.group(1)!,
      device: match.group(2)!,
      chip: int.parse(match.group(3)!),
      slot: int.parse(match.group(4)!),
      hardware: match.group(5)!,
    );
    if (value.slot < 65536 ||
        value.slot > 0x1000000 ||
        spec.espChipId == null ||
        value.chip != spec.espChipId ||
        !spec.hardwareIds.any(
          (id) =>
              CompanionBoardCatalog.normalize(id) ==
              CompanionBoardCatalog.normalize(value.hardware),
        )) {
      throw const FormatException(
        'The OTA identity does not match this exact board and partition. Use an exact-board wired update.',
      );
    }
    return value;
  }

  bool matches(Esp32WifiOtaBinding other) =>
      session == other.session &&
      device == other.device &&
      chip == other.chip &&
      slot == other.slot &&
      hardware == other.hardware;
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
  Future<Esp32MigrationBridgeState> probeMigrationBridge({
    required Esp32WifiOtaBinding binding,
  }) async {
    // A legacy bridge page alone does not identify a physical radio.
    await probe(migrationBridgeUri, binding: binding);
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

  static void validateImage(String name, Uint8List image) =>
      inspectImage(name, image);

  static Future<UsbFirmwareImage> inspectImageAsync(
    String name,
    Uint8List image,
  ) => compute(_inspectWifiImage, (
    name,
    image,
  ), debugLabel: 'Wi-Fi firmware validation');

  static UsbFirmwareImage inspectImage(String name, Uint8List image) {
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
    try {
      return UsbFirmwareImage.fromBytes(name, image);
    } on UsbFirmwareValidationException catch (error) {
      throw FormatException(error.message);
    }
  }

  Future<Esp32WifiOtaProbe> probe(
    Uri updateUri, {
    required Esp32WifiOtaBinding binding,
  }) async {
    final response = await _client
        .get(updateUri.replace(path: '/ota/info'))
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw StateError('OTA server returned HTTP ${response.statusCode}.');
    }
    if (response.bodyBytes.length > 2048) {
      throw const FormatException('OTA identity response is too large.');
    }
    try {
      final info = usbStrictJson(response.bodyBytes);
      if (info is Map &&
          info['version'] == 1 &&
          info['protocol'] == 'lightweight' &&
          info['session'] is String &&
          info['device'] is String &&
          info['hardware'] is String &&
          info['chip'] is int &&
          info['slot'] is int) {
        final actual = Esp32WifiOtaBinding(
          session: info['session'] as String,
          device: info['device'] as String,
          chip: info['chip'] as int,
          slot: info['slot'] as int,
          hardware: info['hardware'] as String,
        );
        if (!binding.matches(actual)) {
          throw StateError(
            'This Wi-Fi updater belongs to a different radio or session. No firmware was sent.',
          );
        }
        return Esp32WifiOtaProbe(
          protocol: Esp32WifiOtaProtocol.lightweight,
          identity: '${binding.hardware} (${binding.device})',
          binding: binding,
        );
      }
    } on FormatException {
      // Do not accept an arbitrary legacy HTML page as device identity.
    }
    throw const FormatException(
      'This updater cannot prove the selected radio identity. Use a verified wired update first.',
    );
  }

  Future<void> upload({
    required Uri updateUri,
    required Esp32WifiOtaProtocol protocol,
    required String filename,
    required Uint8List image,
    required Esp32WifiOtaBinding binding,
    CompanionFirmwareProvenance? provenance,
  }) async {
    final verified = await inspectImageAsync(filename, image);
    if (image.length > binding.slot) {
      throw const FormatException(
        'The image exceeds the measured inactive OTA partition.',
      );
    }
    final identity = verified.endf;
    if (identity == null) {
      throw const FormatException(
        'The device-bound Wi-Fi updater requires a verified EndF footer. Use a marked exact-board release or wired installer.',
      );
    }
    if (identity.targetId == 0) {
      final matches = CompanionBoardCatalog.specs
          .where(
            (spec) =>
                spec.hardwareIds.contains(binding.hardware) &&
                spec.espChipId == binding.chip &&
                spec.id == provenance?.boardId,
          )
          .toList();
      if (matches.length != 1 ||
          provenance == null ||
          provenance.profile != 'full' ||
          !provenance.matches(matches.single, verified.sha256)) {
        throw const FormatException(
          'This source-only Full image has no byte-bound exact-board Full release proof. Use a trusted release or wired installer.',
        );
      }
    }
    if (verified.chip != binding.chip ||
        (CompanionBoardCatalog.normalize(identity.hardwareId) !=
            CompanionBoardCatalog.normalize(binding.hardware))) {
      throw const FormatException(
        'The image does not match the authenticated OTA board.',
      );
    }
    // Recheck immediately before POST: the phone may have roamed to another
    // MeshCore-OTA access point while the confirmation was open.
    final fresh = await probe(updateUri, binding: binding);
    if (fresh.protocol != protocol) {
      throw StateError(
        'The Wi-Fi update protocol changed. No firmware was sent.',
      );
    }
    final http.Response response;
    if (protocol == Esp32WifiOtaProtocol.lightweight) {
      response = await _client
          .post(
            updateUri,
            headers: {
              'Content-Type': 'application/octet-stream',
              'X-MeshCore-OTA-Session': binding.session,
            },
            body: image,
          )
          .timeout(const Duration(minutes: 5));
    } else {
      final request = http.MultipartRequest('POST', updateUri)
        ..headers['X-MeshCore-OTA-Session'] = binding.session
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
