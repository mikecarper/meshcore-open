import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshcore_open/services/esp32_wifi_ota_service.dart';
import 'package:meshcore_open/services/companion_board_catalog.dart';
import 'package:meshcore_open/services/companion_image_validator.dart';
import 'package:meshcore_open/services/usb_firmware_package.dart';

import '../support/companion_firmware_test_data.dart';

const binding = Esp32WifiOtaBinding(
  session: '0123456789abcdef0123456789abcdef',
  device: '001122334455',
  chip: 9,
  slot: 131072,
  hardware: 'heltec_v4',
);

String info({
  String? device,
  String? session,
  int? slot,
  int? chip,
  String? hardware,
  String protocol = 'lightweight',
}) => jsonEncode({
  'version': 1,
  'protocol': protocol,
  'session': session ?? binding.session,
  'device': device ?? binding.device,
  'chip': chip ?? binding.chip,
  'slot': slot ?? binding.slot,
  'hardware': hardware ?? binding.hardware,
});

void main() {
  final image = testEspApplication();
  final uri = Uri.parse('http://192.168.4.1:8080/update');

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
    for (final bad in [
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

  test('authenticated OTA binding requires exact board chip and usable slot', () {
    final reply =
        'OTA1 s=${binding.session} d=${binding.device} c=9 slot=131072 hw=heltec_v4';
    expect(
      Esp32WifiOtaBinding.parse(
        reply,
        board: 'Heltec V4 OLED',
      ).matches(binding),
      isTrue,
    );
    for (final bad in [
      reply.replaceFirst('c=9', 'c=0'),
      reply.replaceFirst('slot=131072', 'slot=0'),
      reply.replaceFirst('slot=131072', 'slot=99999999'),
      reply.replaceFirst('hw=heltec_v4', 'hw=heltec_v4_r8'),
      reply.replaceFirst('0123456789abcdef0123456789abcdef', 'short'),
      'legacy updater',
    ]) {
      expect(
        () => Esp32WifiOtaBinding.parse(bad, board: 'Heltec V4 OLED'),
        throwsFormatException,
      );
    }
    for (final board in ['Heltec T096', 'Xiao C6', 'Unknown Heltec V4']) {
      expect(
        () => Esp32WifiOtaBinding.parse(reply, board: board),
        throwsFormatException,
      );
    }
  });

  test(
    'valid image uploads exact bytes only after fresh bound identity check',
    () async {
      final calls = <http.Request>[];
      final service = Esp32WifiOtaService(
        client: MockClient((request) async {
          calls.add(request);
          return http.Response(
            request.method == 'GET' ? info() : 'OK - installed',
            200,
          );
        }),
      );
      addTearDown(service.dispose);
      final probe = await service.probe(uri, binding: binding);
      expect(probe.binding.matches(binding), isTrue);
      expect(probe.protocol, Esp32WifiOtaProtocol.lightweight);
      await service.upload(
        updateUri: uri,
        protocol: probe.protocol,
        filename: 'app.bin',
        image: image,
        binding: binding,
      );
      expect(calls.map((r) => r.method), ['GET', 'GET', 'POST']);
      expect(calls[0].url.path, '/ota/info');
      expect(calls[1].url.path, '/ota/info');
      expect(calls[2].headers['content-type'], 'application/octet-stream');
      expect(
        calls[2].headers['X-MeshCore-OTA-Session'] ??
            calls[2].headers['x-meshcore-ota-session'],
        binding.session,
      );
      expect(calls[2].bodyBytes, image);
    },
  );

  for (final entry in {
    'wrong AP': info(device: 'aabbccddeeff'),
    'wrong session': info(session: 'fedcba9876543210fedcba9876543210'),
    'wrong chip': info(chip: 0),
    'wrong partition': info(slot: 65536),
    'wrong hardware': info(hardware: 'heltec_v4_r8'),
  }.entries) {
    test('${entry.key} cannot receive a POST', () async {
      final calls = <http.Request>[];
      final service = Esp32WifiOtaService(
        client: MockClient((request) async {
          calls.add(request);
          return http.Response(entry.value, 200);
        }),
      );
      addTearDown(service.dispose);
      await expectLater(
        service.upload(
          updateUri: uri,
          protocol: Esp32WifiOtaProtocol.lightweight,
          filename: 'app.bin',
          image: image,
          binding: binding,
        ),
        throwsStateError,
      );
      expect(calls.map((r) => r.method), ['GET']);
    });
  }

  test(
    'roaming after initial probe fails the fresh pre-upload check',
    () async {
      final calls = <http.Request>[];
      final service = Esp32WifiOtaService(
        client: MockClient((request) async {
          calls.add(request);
          return http.Response(
            calls.length == 1 ? info() : info(device: 'aabbccddeeff'),
            200,
          );
        }),
      );
      addTearDown(service.dispose);
      await service.probe(uri, binding: binding);
      await expectLater(
        service.upload(
          updateUri: uri,
          protocol: Esp32WifiOtaProtocol.lightweight,
          filename: 'app.bin',
          image: image,
          binding: binding,
        ),
        throwsStateError,
      );
      expect(calls.map((r) => r.method), ['GET', 'GET']);
    },
  );

  test(
    'malformed or legacy identity responses never identify a radio',
    () async {
      for (final body in [
        'not JSON',
        '<h2>MeshCore firmware update</h2>',
        jsonEncode({'id': 'Heltec v3', 'hardware': 'ESP32'}),
        '{}',
        '[]',
        info(protocol: 'elegant'),
        info().replaceFirst('"chip":9', '"chip":"9"'),
        info().replaceFirst('"version":1', '"version":2'),
        'x' * 2049,
        info().replaceFirst('{', '{"session":"different",'),
      ]) {
        final calls = <http.Request>[];
        final service = Esp32WifiOtaService(
          client: MockClient((request) async {
            calls.add(request);
            return http.Response(body, 200);
          }),
        );
        addTearDown(service.dispose);
        await expectLater(
          service.upload(
            updateUri: uri,
            protocol: Esp32WifiOtaProtocol.lightweight,
            filename: 'app.bin',
            image: image,
            binding: binding,
          ),
          throwsA(isA<Object>()),
        );
        expect(calls.map((r) => r.method), ['GET']);
      }
    },
  );

  test(
    'oversize or corrupt application fails before any HTTP request',
    () async {
      final corrupt = testEspApplication()..[32] ^= 1;
      final oversize = testEspApplication(dataBytes: binding.slot);
      final wrongChip = testEspApplication(chip: 0);
      final wrongBoard = testEspApplication(hardwareId: 'heltec_v4_r8');
      for (final bytes in [corrupt, oversize, wrongChip, wrongBoard]) {
        final calls = <http.Request>[];
        final service = Esp32WifiOtaService(
          client: MockClient((request) async {
            calls.add(request);
            return http.Response(info(), 200);
          }),
        );
        addTearDown(service.dispose);
        await expectLater(
          service.upload(
            updateUri: uri,
            protocol: Esp32WifiOtaProtocol.lightweight,
            filename: 'app.bin',
            image: bytes,
            binding: binding,
          ),
          throwsA(isA<Object>()),
        );
        expect(calls, isEmpty);
      }
    },
  );

  test(
    'multipart protocol cannot bypass authenticated lightweight proof',
    () async {
      final calls = <http.Request>[];
      final service = Esp32WifiOtaService(
        client: MockClient((request) async {
          calls.add(request);
          return http.Response(info(), 200);
        }),
      );
      addTearDown(service.dispose);
      await expectLater(
        service.upload(
          updateUri: uri,
          protocol: Esp32WifiOtaProtocol.elegant,
          filename: 'app.bin',
          image: image,
          binding: binding,
        ),
        throwsStateError,
      );
      expect(calls.map((r) => r.method), ['GET']);
    },
  );

  test(
    'unmarked image cannot bypass the footer requirement even with release proof',
    () async {
      final bytes = testEspApplication(marked: false);
      final calls = <http.Request>[];
      final service = Esp32WifiOtaService(
        client: MockClient((request) async {
          calls.add(request);
          return http.Response(request.method == 'GET' ? info() : 'OK', 200);
        }),
      );
      addTearDown(service.dispose);
      await expectLater(
        service.upload(
          updateUri: uri,
          protocol: Esp32WifiOtaProtocol.lightweight,
          filename: 'app.bin',
          image: bytes,
          binding: binding,
        ),
        throwsFormatException,
      );
      expect(calls, isEmpty);
      final proof = CompanionFirmwareProvenance(
        boardId: CompanionBoardCatalog.lookup('Heltec V4 OLED')!.id,
        sha256: usbSha256(bytes),
        profile: 'full',
      );
      await expectLater(
        service.upload(
          updateUri: uri,
          protocol: Esp32WifiOtaProtocol.lightweight,
          filename: 'app.bin',
          image: bytes,
          binding: binding,
          provenance: proof,
        ),
        throwsFormatException,
      );
      expect(calls, isEmpty);
    },
  );

  test(
    'zero-target Full upload requires exact byte-bound Full release proof',
    () async {
      final bytes = testEspApplication(targetId: 0);
      final spec = CompanionBoardCatalog.lookup('Heltec V4 OLED')!;
      for (final proof in [
        null,
        CompanionFirmwareProvenance(
          boardId: spec.id,
          sha256: usbSha256(bytes),
          profile: 'ble',
        ),
        CompanionFirmwareProvenance(
          boardId: spec.id,
          sha256: usbSha256(bytes),
          profile: 'full',
        ),
      ]) {
        final calls = <http.Request>[];
        final service = Esp32WifiOtaService(
          client: MockClient((request) async {
            calls.add(request);
            return http.Response(request.method == 'GET' ? info() : 'OK', 200);
          }),
        );
        addTearDown(service.dispose);
        final future = service.upload(
          updateUri: uri,
          protocol: Esp32WifiOtaProtocol.lightweight,
          filename: 'full.bin',
          image: bytes,
          binding: binding,
          provenance: proof,
        );
        if (proof?.profile == 'full') {
          await future;
          expect(calls.map((r) => r.method), ['GET', 'POST']);
        } else {
          await expectLater(future, throwsFormatException);
          expect(calls, isEmpty);
        }
      }
    },
  );

  test(
    'migration bridge gates readiness after identifying exact radio',
    () async {
      var body = '<h2>MeshCore Wi-Fi partition migration</h2> Waiting';
      final service = Esp32WifiOtaService(
        client: MockClient(
          (request) async => http.Response(
            request.url.path == '/ota/info' ? info() : body,
            200,
          ),
        ),
      );
      addTearDown(service.dispose);
      expect(
        await service.probeMigrationBridge(binding: binding),
        Esp32MigrationBridgeState.waiting,
      );
      body =
          '<h2>MeshCore Wi-Fi partition migration</h2> Expanded layout ready';
      expect(
        await service.probeMigrationBridge(binding: binding),
        Esp32MigrationBridgeState.ready,
      );
      body =
          '<h2>MeshCore Wi-Fi partition migration</h2> Private identity recovery did not complete';
      await expectLater(
        service.probeMigrationBridge(binding: binding),
        throwsStateError,
      );
    },
  );
}
