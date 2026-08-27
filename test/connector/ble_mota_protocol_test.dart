import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';

void main() {
  group('local OTA control frames', () {
    test('accepts only the firmware allowlisted command families', () {
      expect(isAllowedLocalOtaControlCommand('normalradio'), isTrue);
      expect(isAllowedLocalOtaControlCommand('tempradio'), isTrue);
      expect(
        isAllowedLocalOtaControlCommand('tempradio 909.950,250,5,5,120'),
        isTrue,
      );
      expect(isAllowedLocalOtaControlCommand('ota status'), isTrue);
      expect(isAllowedLocalOtaControlCommand('ota folder on'), isFalse);
      expect(isAllowedLocalOtaControlCommand('ota status; reboot'), isFalse);
      expect(isAllowedLocalOtaControlCommand('ota status\nreboot'), isFalse);
      expect(isAllowedLocalOtaControlCommand('reboot'), isFalse);
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
