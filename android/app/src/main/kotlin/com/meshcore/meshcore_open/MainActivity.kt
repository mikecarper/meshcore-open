package com.meshcore.meshcore_open

import android.content.Intent
import android.app.ActivityManager
import android.content.Context
import android.provider.Settings
import io.flutter.plugin.common.MethodChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private val usbFunctions by lazy { MeshcoreUsbFunctions(this) }
    private val usbEspEngine by lazy { MeshcoreUsbEspEngine(this, usbFunctions) }
    private var imageCodec: MeshcoreImageCodec? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        usbFunctions.configureFlutterEngine(flutterEngine)
        usbEspEngine.configureFlutterEngine(flutterEngine)
        imageCodec = MeshcoreImageCodec(this, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.meshcore.meshcore_open/settings"
        ).setMethodCallHandler { call, result ->
            if (call.method == "openWifiSettings") {
                startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))
                result.success(null)
            } else if (call.method == "isNativeDfuStopped") {
                try {
                    val manager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                    // Android restricts this to our own app on newer releases;
                    // that is exactly the scope required here. Never inspect
                    // other apps or assume that an abort broadcast stopped it.
                    @Suppress("DEPRECATION")
                    val running = manager.getRunningServices(Int.MAX_VALUE)
                    val active = running.any { service ->
                        service.service.packageName == packageName &&
                            service.service.className.matches(
                                Regex("dev\\.steenbakker\\.nordicdfu\\.DfuService[2-8]?"))
                    }
                    result.success(!active)
                } catch (error: Exception) {
                    result.error("DFU_STATUS_UNAVAILABLE", "Native DFU lifetime could not be verified.", null)
                }
            } else {
                result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        imageCodec?.close()
        usbEspEngine.dispose()
        usbFunctions.dispose()
        super.onDestroy()
    }
}
