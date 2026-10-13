import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/models/app_settings.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/screens/channel_chat_screen.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/services/chat_text_scale_service.dart';
import 'package:meshcore_open/services/compact_image_codec_service.dart';
import 'package:meshcore_open/services/image_codec_service.dart';
import 'package:meshcore_open/widgets/image_send_codec_binding.dart';
import 'package:meshcore_open/widgets/image_send_preview_sheet.dart';
import 'package:provider/provider.dart';

class _ConnectedChannel extends MeshCoreConnector {
  @override
  bool get isConnected => true;

  @override
  void setActiveChannel(int? channelIndex) {}
}

class _ImageSettings extends AppSettingsService {
  @override
  AppSettings get settings => AppSettings(imageMessagesEnabled: true);
}

class _NeuralCodec extends ImageCodecService {
  _NeuralCodec(super.settings);

  bool ready = true;
  bool busy = false;
  ImageCodecRatePoint? encodedRate;

  @override
  ImageCodecAvailability get availability =>
      ready ? ImageCodecAvailability.ready : ImageCodecAvailability.disabled;

  @override
  bool get isBusy => busy;

  @override
  Future<Uint8List> encode(Uint8List bytes, ImageCodecRatePoint rate) async {
    encodedRate = rate;
    return Uint8List(100);
  }
}

void main() {
  testWidgets(
    'ready AEIC remains a separate legacy-rate send path beside compact images',
    (tester) async {
      final connector = _ConnectedChannel();
      final settings = _ImageSettings();
      final compact = CompactImageCodecService();
      final neural = _NeuralCodec(settings);
      final textScale = ChatTextScaleService();
      addTearDown(connector.dispose);
      addTearDown(settings.dispose);
      addTearDown(compact.dispose);
      addTearDown(neural.dispose);
      addTearDown(textScale.dispose);
      const pickerChannel = MethodChannel('plugins.flutter.io/image_picker');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(pickerChannel, (call) async {
        if (call.method == 'pickImage') {
          return 'assets/image_compression/sample_photo.png';
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(pickerChannel, null),
      );
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<MeshCoreConnector>.value(value: connector),
            ChangeNotifierProvider<AppSettingsService>.value(value: settings),
            ChangeNotifierProvider<CompactImageCodecService>.value(
              value: compact,
            ),
            ChangeNotifierProvider<ImageCodecService>.value(value: neural),
            ChangeNotifierProvider<ChatTextScaleService>.value(
              value: textScale,
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ChannelChatScreen(
              channel: Channel.fromHex(0, '#test', '11' * 16),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final sendMenu = find.byIcon(Icons.add_circle_outline);
      await tester.tap(sendMenu);
      await tester.pumpAndSettle();
      final aeicAction = find.byKey(const ValueKey('channel-send-aeic-image'));
      expect(aeicAction, findsOneWidget);
      await tester.tap(aeicAction);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final clock = Stopwatch()..start();
        while (find.byType(ImageSendPreviewSheet).evaluate().isEmpty &&
            clock.elapsed < const Duration(seconds: 5)) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          await tester.pump();
        }
      });
      await tester.pumpAndSettle();
      expect(find.byType(ImageSendPreviewSheet), findsOneWidget);
      expect(
        tester
            .widget<ImageSendPreviewSheet>(find.byType(ImageSendPreviewSheet))
            .codec,
        same(neural),
      );
      expect(neural.encodedRate, kImageSendRatePoint);
      expect(neural.encodedRate, isNot(ImageCodecRatePoint.compact));
      expect(
        find.byKey(const ValueKey('compression-packet-budget')),
        findsNothing,
      );
      await tester.tap(find.byType(OutlinedButton));
      await tester.pumpAndSettle();

      for (final busy in [false, true]) {
        neural
          ..ready = busy
          ..busy = busy
          ..notifyListeners();
        await tester.pumpAndSettle();
        await tester.tap(sendMenu);
        await tester.pumpAndSettle();
        expect(aeicAction, findsNothing);
        tester.state<NavigatorState>(find.byType(Navigator).first).pop();
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
    },
  );
}
