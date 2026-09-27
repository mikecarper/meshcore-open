import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/storage/channel_store.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final key = List.filled(32, '12').join();
  setUp(() async {
    PrefsManager.reset();
    SharedPreferences.setMockInitialValues({});
    await PrefsManager.initialize();
  });

  test(
    'restores last companion channels offline without another device data',
    () async {
      await PrefsManager.instance.setString(
        'last_companion_public_key_hex',
        key,
      );
      final store = ChannelStore()..setPublicKeyHex = key;
      await store.saveChannels([
        Channel(index: 0, name: 'Saved channel', psk: Uint8List(16)),
      ]);
      final other = ChannelStore()
        ..setPublicKeyHex = List.filled(32, '34').join();
      await other.saveChannels([
        Channel(index: 0, name: 'Other radio', psk: Uint8List(16)),
      ]);
      final connector = MeshCoreConnector();
      await connector.restoreLastCompanionScope();
      await connector.loadAllCachedDataForCurrentCompanion();
      expect(connector.selfPublicKeyHex, key);
      expect(connector.isConnected, isFalse);
      expect(connector.channels.single.name, 'Saved channel');
      connector.dispose();
    },
  );

  test(
    'invalid saved companion key does not enable an invalid storage scope',
    () async {
      await PrefsManager.instance.setString(
        'last_companion_public_key_hex',
        '12',
      );
      final connector = MeshCoreConnector();
      await connector.restoreLastCompanionScope();
      expect(connector.selfPublicKeyHex, isEmpty);
      connector.dispose();
    },
  );

  test(
    'cached channel deduplication keeps last index but allows shared keys',
    () async {
      final store = ChannelStore()..setPublicKeyHex = key;
      await store.saveChannels([
        Channel(index: 0, name: 'Old', psk: Uint8List(16)),
        Channel(index: 0, name: 'Current', psk: Uint8List(16)),
        Channel(index: 1, name: 'Second slot', psk: Uint8List(16)),
      ]);
      expect((await store.loadChannels()).map((c) => c.name), [
        'Current',
        'Second slot',
      ]);
    },
  );
}
