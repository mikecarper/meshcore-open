import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:meshcore_open/services/compact_image_backend.dart';
import 'package:meshcore_open/services/compact_image_codec_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a native stop error cannot release a quarantined codec worker',
    () async {
      const channel = MethodChannel('test/compact_image_stop_ack');
      final entered = Completer<void>();
      final pending = Completer<Uint8List>();
      var failStop = true;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'capabilities') return ['webp'];
        if (call.method == 'capabilityDetails') return <Object?>[];
        if (call.method == 'encode') {
          if (!entered.isCompleted) entered.complete();
          return pending.future;
        }
        if (call.method == 'cancel') {
          if (failStop) {
            throw PlatformException(
              code: 'stop_failed',
              message: 'Worker stop was not acknowledged',
            );
          }
          return null;
        }
        throw PlatformException(code: 'unexpected_call');
      });
      final service = CompactImageCodecService(
        backend: LocalCompactImageBackend(channel: channel),
      );
      addTearDown(() async {
        failStop = false;
        if (!pending.isCompleted) pending.complete(Uint8List(100));
        service.dispose();
        await Future<void>.delayed(Duration.zero);
        messenger.setMockMethodCallHandler(channel, null);
      });
      final source = image.Image(width: 128, height: 128, numChannels: 4);
      source.clear(image.ColorRgba8(20, 40, 60, 255));
      final job = service.compress(
        image.encodePng(source),
        codecs: [CompactImageCodec.webp],
      );
      final jobStopped = expectLater(
        job,
        throwsA(isA<CompactImageCancelled>()),
      );
      await entered.future.timeout(const Duration(seconds: 5));
      await expectLater(service.cancelEncode(), throwsStateError);
      await jobStopped;
      await expectLater(
        service.compress(
          image.encodePng(source),
          codecs: [CompactImageCodec.webp],
        ),
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
