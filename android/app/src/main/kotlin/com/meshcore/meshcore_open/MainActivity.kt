package com.meshcore.meshcore_open

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private val nativeCodec by lazy { AndroidNativeCodec(this) }
    private val usbFunctions by lazy { MeshcoreUsbFunctions(this) }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        nativeCodec.configureFlutterEngine(flutterEngine)
        usbFunctions.configureFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        nativeCodec.dispose()
        usbFunctions.dispose()
        super.onDestroy()
    }
}
