import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
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

  test('only the standard Public channel is muted by default', () {
    final settings = AppSettingsService();

    expect(settings.isChannelMuted('Public', isPublicChannel: true), isTrue);
    expect(settings.isChannelMuted('Public'), isFalse);
    expect(settings.isChannelMuted('Private'), isFalse);
    expect(settings.isChannelMuted('Renamed', isPublicChannel: true), isTrue);
  });

  test('default alerts cover direct and private messages only', () {
    final settings = AppSettingsService();
    final private = Channel.fromHex(
      1,
      'Friends',
      '11111111111111111111111111111111',
    );
    final public = Channel.fromHex(
      0,
      'Public',
      '00000000000000000000000000000000',
    );
    final hashtag = Channel.fromHex(
      2,
      '#town',
      '22222222222222222222222222222222',
    );

    expect(settings.settings.notifyOnNewMessage, isTrue);
    expect(settings.settings.notifyOnNewAdvert, isFalse);
    expect(settings.shouldNotifyChannel(private, ChannelType.private), isTrue);
    expect(settings.shouldNotifyChannel(public, ChannelType.public), isFalse);
    expect(settings.shouldNotifyChannel(hashtag, ChannelType.hashtag), isFalse);
    expect(
      settings.shouldNotifyChannel(private, ChannelType.communityPublic),
      isFalse,
    );
    expect(
      settings.shouldNotifyChannel(hashtag, ChannelType.communityHashtag),
      isFalse,
    );
  });

  test('private switch does not turn on Public or hashtags', () async {
    final settings = AppSettingsService();
    final private = Channel.fromHex(
      1,
      'Friends',
      '11111111111111111111111111111111',
    );
    final public = Channel.fromHex(
      0,
      'Public',
      '00000000000000000000000000000000',
    );
    final hashtag = Channel.fromHex(
      2,
      '#town',
      '22222222222222222222222222222222',
    );

    await settings.setNotifyOnNewChannelMessage(false);
    expect(settings.shouldNotifyChannel(private, ChannelType.private), isFalse);
    await settings.setNotifyOnNewChannelMessage(true);
    expect(settings.shouldNotifyChannel(private, ChannelType.private), isTrue);
    expect(settings.shouldNotifyChannel(public, ChannelType.public), isFalse);
    expect(settings.shouldNotifyChannel(hashtag, ChannelType.hashtag), isFalse);
    await settings.unmuteChannel('Public', isPublicChannel: true);
    expect(settings.shouldNotifyChannel(public, ChannelType.public), isTrue);
    expect(settings.shouldNotifyChannel(hashtag, ChannelType.hashtag), isFalse);
  });

  test('existing settings without the new preference default to muted', () {
    final restored = AppSettings.fromJson({
      'muted_channels': <String>[],
      'notify_on_new_channel_message': true,
    });

    expect(restored.notifyOnPublicChannelMessages, isFalse);
    expect(restored.notifyOnNewChannelMessage, isTrue);
  });

  test('legacy advert alerts switch off once, later opt-in persists', () async {
    await PrefsManager.instance.setString(
      'app_settings',
      jsonEncode({'notify_on_new_advert': true, 'notify_on_new_message': true}),
    );
    final migrated = AppSettingsService();
    await migrated.loadSettings();
    expect(migrated.settings.notifyOnNewAdvert, isFalse);
    await migrated.setNotifyOnNewAdvert(true);
    final reloaded = AppSettingsService();
    await reloaded.loadSettings();
    expect(reloaded.settings.notifyOnNewAdvert, isTrue);
  });

  test('unmute and mute Public persist across settings reloads', () async {
    final settings = AppSettingsService();
    await settings.unmuteChannel('Public', isPublicChannel: true);
    expect(settings.isChannelMuted('Public', isPublicChannel: true), isFalse);

    final reloaded = AppSettingsService();
    await reloaded.loadSettings();
    expect(reloaded.isChannelMuted('Renamed', isPublicChannel: true), isFalse);
    expect(reloaded.settings.notifyOnPublicChannelMessages, isTrue);

    await reloaded.muteChannel('Renamed', isPublicChannel: true);
    expect(reloaded.isChannelMuted('Public', isPublicChannel: true), isTrue);
    expect(reloaded.isChannelMuted('Renamed'), isFalse);

    final mutedAfterReload = AppSettingsService();
    await mutedAfterReload.loadSettings();
    expect(
      mutedAfterReload.isChannelMuted('Public', isPublicChannel: true),
      isTrue,
    );
  });

  test('explicitly muted private channels remain muted', () async {
    final settings = AppSettingsService();
    await settings.muteChannel('Friends');

    expect(settings.isChannelMuted('Friends'), isTrue);
    expect(settings.isChannelMuted('Other'), isFalse);

    await settings.unmuteChannel('Friends');
    expect(settings.isChannelMuted('Friends'), isFalse);
  });
}
