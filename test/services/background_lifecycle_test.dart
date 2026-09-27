import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/services/background_service.dart';
import 'package:meshcore_open/storage/last_device_store.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    PrefsManager.reset();
    SharedPreferences.setMockInitialValues({});
    await PrefsManager.initialize();
  });

  test(
    'first launch without saved BLE device does not attempt reconnect',
    () async {
      final connector = MeshCoreConnector();
      expect(await connector.tryAutoReconnect(), isFalse);
      expect(connector.state, MeshCoreConnectionState.disconnected);
      connector.dispose();
    },
  );

  test(
    'reconnect tolerates preferences not initialized in embedded tests',
    () async {
      PrefsManager.reset();
      final connector = MeshCoreConnector();
      expect(await connector.tryAutoReconnect(), isFalse);
      await PrefsManager.initialize();
      connector.dispose();
    },
  );

  test(
    'remembering and clearing a device leaves offline companion scope intact',
    () async {
      const scope = 'offline-scope';
      await PrefsManager.instance.setString(
        'last_companion_public_key_hex',
        scope,
      );
      final store = LastDeviceStore();
      await store.persistLastDevice('AA:BB:CC:DD:EE:FF', 'Test radio');
      expect(store.getPersistedDeviceId(), 'AA:BB:CC:DD:EE:FF');
      expect(store.getPersistedDeviceName(), 'Test radio');
      await store.clearPersistedDevice();
      expect(store.getPersistedDeviceId(), isNull);
      expect(store.getPersistedDeviceName(), isNull);
      expect(
        PrefsManager.instance.getString('last_companion_public_key_hex'),
        scope,
      );
    },
  );

  test(
    'lifecycle callbacks ignore inactive transitions and detach on dispose',
    () {
      final service = BackgroundService();
      var resumes = 0;
      var pauses = 0;
      service.onResume = () {
        resumes++;
      };
      service.onPause = () {
        pauses++;
      };
      service.didChangeAppLifecycleState(AppLifecycleState.inactive);
      expect(resumes + pauses, 0);
      service.didChangeAppLifecycleState(AppLifecycleState.paused);
      service.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(resumes, 1);
      expect(pauses, 1);
      service.dispose();
      service.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(resumes, 1);
    },
  );
}
