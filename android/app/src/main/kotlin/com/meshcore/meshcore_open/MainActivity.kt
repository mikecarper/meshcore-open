package com.meshcore.meshcore_open

import android.content.Intent
import android.provider.Settings
import io.flutter.plugin.common.MethodChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private val usbFunctions by lazy { MeshcoreUsbFunctions(this) }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        usbFunctions.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.meshcore.meshcore_open/settings"
        ).setMethodCallHandler { call, result ->
            if (call.method == "openWifiSettings") {
                startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        usbFunctions.dispose()
        super.onDestroy()
    }
}
