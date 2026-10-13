import 'dart:io';

import 'package:flutter/services.dart';

/// An independent OS check is needed when Dart lost its terminal callback.
/// A negative result is not an instruction to dispatch another native service.
class NativeDfuLifetime {
  static const _channel = MethodChannel('com.meshcore.meshcore_open/settings');

  static Future<bool> verifyStopped({
    Future<bool?> Function()? query,
    Future<void> Function(Duration)? wait,
  }) async {
    if (query == null && !Platform.isAndroid) return false;
    final read =
        query ?? () => _channel.invokeMethod<bool>('isNativeDfuStopped');
    try {
      if (await read() != true) return false;
      await (wait ?? Future<void>.delayed)(const Duration(seconds: 1));
      return await read() == true;
    } catch (_) {
      return false;
    }
  }
}
