import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/models/path_selection.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:meshcore_open/widgets/repeater_login_dialog.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ImmediateLoginConnector extends MeshCoreConnector {
  _ImmediateLoginConnector(this.target);

  final Contact target;
  int sentLogins = 0;
  bool? pathResult;

  @override
  Future<PathSelection> preparePathForContactSend(
    Contact contact, {
    PathSelection? explicitSelection,
  }) async => const PathSelection(pathBytes: [], hopCount: 0, useFlood: false);

  @override
  int calculateTimeout({
    required int pathLength,
    int messageBytes = 100,
    String? contactKey,
    int? deviceTimeoutMs,
  }) => 100;

  @override
  Future<void> sendFrame(
    Uint8List data, {
    String? channelSendQueueId,
    bool expectsGenericAck = false,
    bool waitForGenericAck = false,
  }) async {
    if (data[0] != cmdSendLogin) return;
    sentLogins++;
    handleFrameForTest(
      Uint8List.fromList([
        pushCodeLoginSuccess,
        1,
        ...target.publicKey.take(6),
      ]),
    );
  }

  @override
  void recordRepeaterPathResult(
    Contact contact,
    PathSelection selection,
    bool success,
    int? tripTimeMs,
  ) {
    pathResult = success;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a 15-byte password fits when revealed on a 5.1.1 phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(480, 854);
    tester.view.devicePixelRatio = 1.5;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    final repeater = Contact(
      publicKey: Uint8List.fromList(List<int>.generate(pubKeySize, (i) => i)),
      name: 'Test repeater',
      type: advTypeRepeater,
      pathLength: 0,
      path: Uint8List(0),
      lastSeen: DateTime(2026, 9, 26),
    );
    final connector = MeshCoreConnector();
    addTearDown(connector.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<MeshCoreConnector>.value(
        value: connector,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => RepeaterLoginDialog(
                    repeater: repeater,
                    onLogin: (_, _) {},
                  ),
                ),
                child: const Text('Open login'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open login'));
    await tester.pumpAndSettle();
    const password = '1234567890abcde';
    await tester.enterText(find.byType(TextField), password);
    await tester.tap(find.byIcon(Icons.visibility));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      password,
    );
    final editable = tester.allRenderObjects.whereType<RenderEditable>().single;
    expect(
      editable.maxScrollExtent,
      0,
      reason:
          'editable=${editable.size} field=${tester.getSize(find.byType(TextField))}',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'login fields and actions remain scrollable above API 22 keyboard',
    (tester) async {
      tester.view.physicalSize = const Size(480, 854);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      SharedPreferences.setMockInitialValues({});
      PrefsManager.reset();
      await PrefsManager.initialize();

      final connector = MeshCoreConnector();
      addTearDown(connector.dispose);
      final repeater = Contact(
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
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => RepeaterLoginDialog(
                      repeater: repeater,
                      onLogin: (_, _) {},
                    ),
                  ),
                  child: const Text('Open login'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open login'));
      await tester.pumpAndSettle();

      tester.view.viewInsets = const FakeViewPadding(bottom: 400);
      await tester.pumpAndSettle();
      final passwordField = find.byType(TextField);
      final loginButton = find.byWidgetPredicate(
        (widget) => widget is FilledButton && widget.onPressed != null,
      );
      expect(passwordField, findsOneWidget);
      expect(loginButton, findsOneWidget);

      await tester.ensureVisible(passwordField);
      await tester.pumpAndSettle();
      expect(tester.getRect(passwordField).bottom, lessThan(454));
      await tester.ensureVisible(loginButton);
      await tester.pumpAndSettle();
      expect(tester.getRect(loginButton).bottom, lessThan(454));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('captures a direct login reply before the BLE write returns', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    final repeater = Contact(
      publicKey: Uint8List.fromList(List<int>.generate(pubKeySize, (i) => i)),
      name: 'Nearby repeater',
      type: advTypeRepeater,
      pathLength: 0,
      path: Uint8List(0),
      lastSeen: DateTime(2026, 9, 26),
    );
    final connector = _ImmediateLoginConnector(repeater);
    addTearDown(connector.dispose);
    var received = 0;
    final subscription = connector.receivedFrames.listen((_) => received++);
    addTearDown(subscription.cancel);
    bool? wasAdmin;
    await tester.pumpWidget(
      ChangeNotifierProvider<MeshCoreConnector>.value(
        value: connector,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => RepeaterLoginDialog(
                    repeater: repeater,
                    onLogin: (_, isAdmin) => wasAdmin = isAdmin,
                  ),
                ),
                child: const Text('Open login'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open login'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'test-password');
    final loginButton = find.byWidgetPredicate(
      (widget) => widget is FilledButton && widget.onPressed != null,
    );
    await tester.ensureVisible(loginButton);
    await tester.tap(loginButton);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    expect(connector.sentLogins, 1);
    expect(received, greaterThanOrEqualTo(1));
    expect(connector.pathResult, isTrue);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    expect(wasAdmin, isTrue);
    await tester.pumpAndSettle();
    expect(find.byType(RepeaterLoginDialog), findsNothing);
  });
}
