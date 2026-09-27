import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/screens/remote_key_backup_screen.dart';
import 'package:provider/provider.dart';

class _BackupCapableConnector extends MeshCoreConnector {
  @override
  Future<String> executeLocalCliCommand(
    String command, {
    Duration timeout = const Duration(seconds: 8),
  }) async => 'ephemeral-routed-v1';
}

void main() {
  testWidgets('backup passphrase and action scroll above API 22 keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(480, 854);
    tester.view.devicePixelRatio = 1.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);

    final connector = _BackupCapableConnector();
    addTearDown(connector.dispose);
    final target = Contact(
      publicKey: Uint8List.fromList(List<int>.generate(pubKeySize, (i) => i)),
      name: 'Test repeater',
      type: advTypeRepeater,
      pathLength: 0,
      path: Uint8List(0),
      lastSeen: DateTime(2026, 9, 26),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<MeshCoreConnector>.value(
        value: connector,
        child: MaterialApp(home: RemoteKeyBackupScreen(target: target)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create encrypted backup'));
    await tester.pumpAndSettle();

    tester.view.viewInsets = const FakeViewPadding(bottom: 400);
    await tester.pumpAndSettle();
    final fields = find.byType(TextFormField);
    final action = find.text('Request backup');
    expect(fields, findsNWidgets(2));
    expect(action, findsOneWidget);
    await tester.ensureVisible(fields.last);
    await tester.pumpAndSettle();
    expect(tester.getRect(fields.last).bottom, lessThan(454 / 1.5));
    await tester.ensureVisible(action);
    await tester.pumpAndSettle();
    expect(tester.getRect(action).bottom, lessThan(454 / 1.5));
    expect(tester.takeException(), isNull);
  });
}
