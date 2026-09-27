import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';

Uint8List _frame(String text) => Uint8List.fromList(<int>[
  respCodeContactMsgRecv,
  1, 2, 3, 4, 5, 6, // sender prefix
  0, // path length
  txtTypeCliData,
  1, 2, 3, 4, // timestamp
  ...text.codeUnits,
  0,
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('diverts key material before the generic frame stream', () async {
    final connector = MeshCoreConnector();
    final frames = <Uint8List>[];
    final subscription = connector.receivedFrames.listen(frames.add);
    connector.handleFrameForTest(
      _frame(
        'KEYBACKUP 0011223344556677 '
        'AABBCCDDEEFF00112233445566778899'
        'AABBCCDDEEFF00112233445566778899'
        'AABBCCDDEEFF00112233445566778899'
        'AABBCCDDEEFF00112233445566778899',
      ),
    );
    connector.handleFrameForTest(_frame('KEYBACKUP malformed'));
    connector.handleFrameForTest(_frame('ordinary CLI reply'));
    await Future<void>.delayed(Duration.zero);
    expect(frames, hasLength(1));
    expect(parseContactMessageText(frames.single)?.text, 'ordinary CLI reply');
    await subscription.cancel();
    connector.dispose();
  });
}
