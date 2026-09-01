import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';

void main() {
  group('local OTA control frames', () {
    test('accepts every exact command used by the OTA workflow', () {
      for (final command in <String>[
        'normalradio',
        'tempradio',
        'tempradio 909.950,250,5,5,120',
        'tempradio 150,7.8,12,8,3',
        'tempradio 2500,500,5,5,10080',
        'ota ls',
        'ota status',
        'ota pull 44332211 flash',
        'ota pull a1b2c3d4 flash',
        'ota install',
      ]) {
        expect(
          isAllowedLocalOtaControlCommand(command),
          isTrue,
          reason: command,
        );
      }
    });

    test('rejects malformed or non-finite temporary-radio commands', () {
      for (final command in <String>[
        'tempradio NaN,250,5,5,120',
        'tempradio Infinity,250,5,5,120',
        'tempradio -Infinity,250,5,5,120',
        'tempradio 149.999,250,5,5,120',
        'tempradio 2500.001,250,5,5,120',
        'tempradio 909.950,100,5,5,120',
        'tempradio 909.950,250,4,5,120',
        'tempradio 909.950,250,5,9,120',
        'tempradio 909.950,250,5,5,2',
        'tempradio 909.950,250,5,5,10081',
        'tempradio 909.950,250,5,5',
        'tempradio 909.950,250,5,5,120,extra',
        'tempradio 909.950, 250,5,5,120',
      ]) {
        expect(
          isAllowedLocalOtaControlCommand(command),
          isFalse,
          reason: command,
        );
      }
    });

    test('rejects unexpected OTA verbs, arguments, and injection syntax', () {
      for (final command in <String>[
        'ota',
        'ota help',
        'ota folder on',
        'ota erase',
        'ota cancel',
        'ota ls all',
        'ota status now',
        'ota install now',
        'ota pull 4433221 flash',
        'ota pull 443322110 flash',
        'ota pull 44332Z11 flash',
        'ota pull 44332211 ram',
        'ota pull 44332211 flash extra',
        'ota status; reboot',
        'ota status && reboot',
        'ota status|reboot',
        'ota status\nreboot',
        r'ota status$(reboot)',
        'ota status`reboot`',
        'ota "status"',
        'reboot',
      ]) {
        expect(
          isAllowedLocalOtaControlCommand(command),
          isFalse,
          reason: command,
        );
      }
    });

    test('builds and parses the length-delimited protocol-v14 reply', () {
      final frame = buildLocalOtaControlFrame('ota status');
      expect(frame.first, cmdExecLocalOtaControl);
      expect(frame.sublist(1), 'ota status'.codeUnits);

      final reply = Uint8List.fromList(<int>[respCodeOk, 2, ...'OK'.codeUnits]);
      expect(parseLocalOtaControlResponse(reply), 'OK');
      expect(
        () => parseLocalOtaControlResponse(
          Uint8List.fromList(<int>[respCodeOk, 3, ...'OK'.codeUnits]),
        ),
        throwsFormatException,
      );
    });
  });

  test('parses exact Bluetooth source status and rejects wrong action', () {
    final frame = Uint8List.fromList(<int>[
      respCodeOk,
      bleMotaActionStart,
      bleMotaFlagChannelReady | bleMotaFlagAttached,
      2,
      0,
      2,
      0,
      0x78,
      0x56,
      0x34,
      0x12,
    ]);
    final status = parseBleMotaSourceResponse(
      frame,
      expectedAction: bleMotaActionStart,
    );
    expect(status.channelReady, isTrue);
    expect(status.attached, isTrue);
    expect(status.offered, 2);
    expect(status.advertised, 2);
    expect(status.packetsSent, 0x12345678);

    final legacyStatus = parseBleMotaSourceResponse(
      Uint8List.fromList(frame.sublist(0, 7)),
      expectedAction: bleMotaActionStart,
    );
    expect(legacyStatus.packetsSent, isNull);

    expect(
      () =>
          parseBleMotaSourceResponse(frame, expectedAction: bleMotaActionStop),
      throwsFormatException,
    );
  });
}
