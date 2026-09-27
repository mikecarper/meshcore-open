import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/message_age_policy.dart';
import 'package:meshcore_open/models/app_settings.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
  });

  test('old messages expire at selected age, Never keeps all', () {
    final now = DateTime.utc(2026, 9, 27, 12);
    final times = [
      now.subtract(const Duration(hours: 4)),
      now.subtract(const Duration(hours: 2)),
      now,
    ];
    expect(MessageAgePolicy.keep(times, (t) => t, 3, now: now), [
      times[1],
      times[2],
    ]);
    expect(MessageAgePolicy.keep(times, (t) => t, 0, now: now), times);
    expect(MessageAgePolicy.isExpired(times.first, 3, now: now), isTrue);
    expect(MessageAgePolicy.isExpired(times.last, 3, now: now), isFalse);
  });

  test(
    'default ages and overrides persist by contact key and channel PSK',
    () async {
      final public = Channel.fromHex(0, 'Public', Channel.publicChannelPsk);
      final hashtag = Channel.fromHex(
        1,
        '#town',
        '22222222222222222222222222222222',
      );
      final private = Channel.fromHex(
        2,
        'Friends',
        '33333333333333333333333333333333',
      );
      final settings = AppSettingsService();
      expect(settings.settings.messageAgeHoursForContact('abc'), 0);
      expect(settings.settings.messageAgeHoursForChannel(public), 72);
      expect(settings.settings.messageAgeHoursForChannel(hashtag), 168);
      expect(settings.settings.messageAgeHoursForChannel(private), 0);

      await settings.setMessageAgeForContact('abc', 1);
      await settings.setMessageAgeForChannel(public, 720);
      final loaded = AppSettingsService();
      await loaded.loadSettings();
      expect(loaded.settings.messageAgeHoursForContact('abc'), 1);
      expect(
        loaded.settings.messageAgeHoursForChannel(
          Channel.fromHex(3, 'Renamed', Channel.publicChannelPsk),
        ),
        720,
      );
      expect(
        AppSettings.fromJson(
          loaded.settings.toJson(),
        ).messageAgeHoursForChannel(public),
        720,
      );
      expect(
        () => settings.setMessageAgeForContact('abc', -1),
        throwsArgumentError,
      );
    },
  );
}
