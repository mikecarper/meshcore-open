import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshcore_open/services/esp32_wifi_ota_service.dart';

void main() {
  final image = Uint8List.fromList(<int>[
    0xE9,
    2,
    ...List<int>.filled(1022, 0),
  ]);

  test('accepts only private-network update URLs returned by target', () {
    expect(
      Esp32WifiOtaService.parseStartReply(
        'Started: http://192.168.4.1:8080/update',
      ).port,
      8080,
    );
    expect(
      Esp32WifiOtaService.parseStartReply(
        'Started: http://10.0.0.4/update',
      ).host,
      '10.0.0.4',
    );
    for (final bad in <String>[
      'OK',
      'Started: https://192.168.4.1/update',
      'Started: http://example.com/update',
      'Started: http://192.168.4.1:9999/update',
      'Started: http://192.168.4.1/erase',
    ]) {
      expect(
        () => Esp32WifiOtaService.parseStartReply(bad),
        throwsFormatException,
      );
    }
  });

  test('rejects merged or malformed firmware images', () {
    expect(
      () => Esp32WifiOtaService.validateImage('board.bin', image),
      returnsNormally,
    );
    expect(
      () => Esp32WifiOtaService.validateImage('board-merged.bin', image),
      throwsFormatException,
    );
    expect(
      () => Esp32WifiOtaService.validateImage(
        'board.bin',
        Uint8List.fromList(<int>[0x00, ...List<int>.filled(1023, 0)]),
      ),
      throwsFormatException,
    );
  });

  test('uploads raw image to lightweight dual-slot updater', () async {
    final calls = <http.Request>[];
    final client = MockClient((request) async {
      calls.add(request);
      if (request.method == 'GET') {
        return http.Response('<h2>MeshCore firmware update</h2>', 200);
      }
      return http.Response('OK - firmware installed; rebooting', 200);
    });
    final service = Esp32WifiOtaService(client: client);
    final uri = Uri.parse('http://192.168.4.1:8080/update');
    final probe = await service.probe(uri);
    expect(probe.protocol, Esp32WifiOtaProtocol.lightweight);
    await service.upload(
      updateUri: uri,
      protocol: probe.protocol,
      filename: 'Heltec_v3_repeater.bin',
      image: image,
    );
    expect(calls[1].headers['content-type'], 'application/octet-stream');
    expect(calls[1].bodyBytes, image);
    service.dispose();
  });

  test('legacy updater receives multipart image and MD5', () async {
    final calls = <http.Request>[];
    final client = MockClient((request) async {
      calls.add(request);
      if (request.method == 'GET') {
        return http.Response(
          jsonEncode(<String, String>{'id': 'Heltec v3', 'hardware': 'ESP32'}),
          200,
        );
      }
      return http.Response('OK', 200);
    });
    final service = Esp32WifiOtaService(client: client);
    final uri = Uri.parse('http://192.168.4.1/update');
    final probe = await service.probe(uri);
    expect(probe.protocol, Esp32WifiOtaProtocol.elegant);
    expect(probe.identity, 'Heltec v3');
    await service.upload(
      updateUri: uri,
      protocol: probe.protocol,
      filename: 'Heltec_v3_repeater.bin',
      image: image,
    );
    final multipartBody = latin1.decode(calls[1].bodyBytes);
    expect(multipartBody, contains('name="MD5"'));
    expect(multipartBody, contains('name="firmware"'));
    service.dispose();
  });

  test('migration bridge gates final upload on device readiness', () async {
    var body =
        '<h2>MeshCore Wi-Fi partition migration</h2>'
        'Legacy layout verified; migration begins shortly';
    final service = Esp32WifiOtaService(
      client: MockClient((_) async => http.Response(body, 200)),
    );
    expect(
      await service.probeMigrationBridge(),
      Esp32MigrationBridgeState.waiting,
    );
    body =
        '<h2>MeshCore Wi-Fi partition migration</h2>'
        'Expanded layout ready';
    expect(
      await service.probeMigrationBridge(),
      Esp32MigrationBridgeState.ready,
    );
    body =
        '<h2>MeshCore Wi-Fi partition migration</h2>'
        'Private identity recovery did not complete';
    await expectLater(service.probeMigrationBridge(), throwsStateError);
    service.dispose();
  });
}
