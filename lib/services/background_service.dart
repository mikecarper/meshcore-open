import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../l10n/app_localizations.dart';
import '../utils/platform_info.dart';

class BackgroundService with WidgetsBindingObserver {
  bool _initialized = false;
  bool _serviceRunning = false;
  bool get isRunning => _serviceRunning;
  VoidCallback? onResume;
  VoidCallback? onPause;
  String? Function()? _languageOverrideProvider;

  /// Allows the app to expose its current language override (e.g. from
  /// AppSettingsService) so the foreground notification matches the app UI
  /// language instead of only the system locale.
  void setLanguageOverrideProvider(String? Function()? provider) {
    _languageOverrideProvider = provider;
  }

  Future<void> initialize() async {
    if (_initialized) return;
    WidgetsBinding.instance.addObserver(this);
    _initialized = true;
    if (!PlatformInfo.isAndroid) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'meshcore_background',
        channelName: 'MeshCore Background',
        channelDescription: 'Keeps MeshCore running in the background.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(5000),
        autoRunOnBoot: false,
        allowWifiLock: false,
      ),
    );
    _initialized = true;
  }

  Future<void> start() async {
    if (!PlatformInfo.isMobile) return;
    if (!_initialized) {
      await initialize();
    }
    if (!PlatformInfo.isAndroid) {
      _serviceRunning = true;
      return;
    }
    final running = await FlutterForegroundTask.isRunningService;
    if (running) {
      _serviceRunning = true;
      return;
    }
    final l10n = await _loadLocalizations();
    await FlutterForegroundTask.startService(
      notificationTitle: l10n.background_serviceTitle,
      notificationText: l10n.background_serviceText,
      callback: startCallback,
    );
    _serviceRunning = await FlutterForegroundTask.isRunningService;
  }

  Future<AppLocalizations> _loadLocalizations() async {
    final supported = AppLocalizations.supportedLocales;
    final override = _languageOverrideProvider?.call();
    if (override != null && override.isNotEmpty) {
      final overrideLocale = Locale(override);
      final isSupported = supported.any(
        (l) => l.languageCode == overrideLocale.languageCode,
      );
      if (isSupported) {
        return AppLocalizations.delegate.load(overrideLocale);
      }
    }
    final preferred = WidgetsBinding.instance.platformDispatcher.locales;
    final match = basicLocaleListResolution(preferred, supported);
    return AppLocalizations.delegate.load(match);
  }

  Future<void> stop() async {
    _serviceRunning = false;
    if (!PlatformInfo.isAndroid) return;
    final running = await FlutterForegroundTask.isRunningService;
    if (!running) return;
    await FlutterForegroundTask.stopService();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) onResume?.call();
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      onPause?.call();
    }
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _initialized = false;
    onResume = null;
    onPause = null;
  }
}

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(_MeshCoreTaskHandler());
}

class _MeshCoreTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onNotificationButtonPressed(String id) {}

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp('/');
  }
}
