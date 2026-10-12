import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:meshcore_open/screens/packet_tools_screen.dart';
import 'package:meshcore_open/services/analyzer_packet_service.dart';
import 'package:meshcore_open/services/ble_debug_log_service.dart';

const raw = '3E00545642311122334455667788800092651E000800010264C8FEFFDC';
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Future<void> pump(
    WidgetTester tester, {
    AnalyzerPacketService? service,
  }) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => BleDebugLogService(),
        child: MaterialApp(home: PacketToolsScreen(analyzer: service)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'telemetry and authenticated management fit a small screen with keyboard',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await pump(tester);
      await tester.tap(find.text('Analyzer region'));
      await tester.pumpAndSettle();
      final helper = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.text('IATA region (e.g. SEA), not LoRa.'),
          matching: find.byType(RichText),
        ),
      );
      expect(helper.didExceedMaxLines, false);
      await tester.tap(find.text('Analyzer region'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Load example'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Source: 1122334455667788'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Source: 1122334455667788'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('Management'),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Management'));
      await tester.tap(find.text('Load example'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('management-auth')),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Password-authenticated 1/1 pages'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.byKey(const Key('management-password')),
        -250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(
        find.byKey(const Key('management-password')),
        'wrong management password',
      );
      await tester.ensureVisible(find.text('Decode'));
      await tester.tap(find.text('Decode'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Wrong password'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'requires selected region then imports and auto-decodes raw telemetry',
    (tester) async {
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        expect(request.url.queryParameters['region'], 'SEA');
        return http.Response(
          jsonEncode({
            'packets': [
              {'raw': raw},
            ],
          }),
          200,
        );
      });
      addTearDown(client.close);
      await pump(tester, service: AnalyzerPacketService(client: client));
      await tester.tap(find.text('Analyzer region'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.ancestor(
                of: find.text('Pull packets'),
                matching: find.byWidgetPredicate(
                  (widget) => widget is FilledButton,
                ),
              ),
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(find.byKey(const Key('analyzer-region')), 'SEA');
      await tester.tap(find.text('Select region'));
      await tester.pumpAndSettle();
      expect(requests, 0);
      await tester.runAsync(() async {
        await tester.tap(find.text('Pull packets'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(requests, 1);
      await tester.tap(find.textContaining('Raw custom - 0 hops'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Source: 1122334455667788'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Source: 1122334455667788'), findsOneWidget);
    },
  );
  testWidgets('403 errors offer paste fallback without hiding failure', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'packet_tools_analyzer_region': 'SEA',
    });
    final client = MockClient((_) async => http.Response('blocked', 403));
    addTearDown(client.close);
    await pump(tester, service: AnalyzerPacketService(client: client));
    await tester.tap(find.text('Analyzer region: SEA'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Pull packets'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('HTTP 403'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
