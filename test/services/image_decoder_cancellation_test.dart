import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/main.dart' show ImageCodecServiceDecoder;
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/services/compact_image_backend.dart';
import 'package:meshcore_open/services/compact_image_codec_service.dart';
import 'package:meshcore_open/services/image_codec_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'lifecycle cancellation contains a failed stop and keeps quarantine',
    () async {
      const channel = MethodChannel('test/image_decoder_stop_ack');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final stopRequested = Completer<void>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'cancel') {
          if (!stopRequested.isCompleted) stopRequested.complete();
          throw PlatformException(
            code: 'stop_failed',
            message: 'Worker stop was not acknowledged',
          );
        }
        throw PlatformException(code: 'unexpected_call');
      });
      final compact = CompactImageCodecService(
        backend: LocalCompactImageBackend(channel: channel),
      );
      final neural = ImageCodecService(AppSettingsService());
      final decoder = ImageCodecServiceDecoder(neural, compact);
      final uncaughtErrors = <Object>[];
      final logs = <String>[];
      final previousDebugPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) logs.add(message);
      };
      addTearDown(() async {
        compact.dispose();
        neural.dispose();
        await Future<void>.delayed(Duration.zero);
        messenger.setMockMethodCallHandler(channel, null);
        debugPrint = previousDebugPrint;
      });

      final cancellationSettled = Completer<void>();
      runZonedGuarded(() async {
        decoder.cancelCodecJob();
        await stopRequested.future;
        // Drain the method-channel reply and both cancellation continuations.
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        cancellationSettled.complete();
      }, (error, stack) => uncaughtErrors.add(error));
      await cancellationSettled.future.timeout(const Duration(seconds: 5));

      expect(uncaughtErrors, isEmpty);
      expect(logs, contains(contains('Compact image cancellation failed:')));
      expect(compact.isBusy, isFalse);
      await expectLater(
        compact.compress(Uint8List(0)),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'reason',
            contains('previous worker'),
          ),
        ),
      );
    },
  );
}
