import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/native_dfu_lifetime.dart';

void main() {
  test('requires two independent absent native-service observations', () async {
    var reads = 0, waits = 0;
    expect(
      await NativeDfuLifetime.verifyStopped(
        query: () async {
          reads++;
          return true;
        },
        wait: (duration) async {
          expect(duration, const Duration(seconds: 1));
          waits++;
        },
      ),
      isTrue,
    );
    expect(reads, 2);
    expect(waits, 1);
  });
  for (final result in [false, null]) {
    test(
      'missing or active status never permits a new native transfer ($result)',
      () async {
        var reads = 0;
        expect(
          await NativeDfuLifetime.verifyStopped(
            query: () async {
              reads++;
              return result;
            },
            wait: (_) async {},
          ),
          isFalse,
        );
        expect(reads, 1);
      },
    );
  }
  test('service reappearing between checks is not stopped', () async {
    var reads = 0;
    expect(
      await NativeDfuLifetime.verifyStopped(
        query: () async => ++reads == 1,
        wait: (_) async {},
      ),
      isFalse,
    );
  });
  test('OS or channel failure is fail closed', () async {
    expect(
      await NativeDfuLifetime.verifyStopped(
        query: () async => throw StateError('unavailable'),
        wait: (_) async {},
      ),
      isFalse,
    );
  });
}
