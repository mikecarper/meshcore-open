package com.meshcore.meshcore_open

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.IOException
import java.security.MessageDigest

/** Pinned official Espressif C library over the existing native USB drivers. */
class MeshcoreUsbEspEngine(private val activity: FlutterActivity, private val usb: MeshcoreUsbFunctions) {
    private val main = Handler(Looper.getMainLooper())
    private val operations = UsbEspOperationGuard()
    private var active: MethodChannel.Result? = null
    @Volatile private var sequence = 0
    // Only usb's single I/O executor accesses nativeContext/JNI callbacks.
    private var nativeContext = 0L
    @Volatile private var loaded = false
    private var opening = false
    @Volatile private var ownsUsb = false
    private val watchdog = Runnable {
        operations.cancel()
        val result = active; active = null
        if (opening) usb.cancelPendingRaw()
        usb.submit { destroyContext(); if (ownsUsb) usb.closeRaw(); ownsUsb = false }
        result?.error("usb_esp_timeout", "Native ESP operation timed out; no reset was requested", null)
    }

    fun configureFlutterEngine(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "meshcore_open/usb_esp")
            .setMethodCallHandler { call, result ->
                if (call.method !in listOf("preflight", "connect", "readFlash", "writeFlash", "eraseFlash", "runApplication", "close")) {
                    result.notImplemented(); return@setMethodCallHandler
                }
                if (active != null) { result.error("usb_busy", "Native ESP operation already in progress", null); return@setMethodCallHandler }
                val id = try { operations.begin() } catch (error: IllegalStateException) {
                    result.error("usb_esp_closed", "USB update activity closed", null); return@setMethodCallHandler
                }
                active = result; sequence = id
                main.postDelayed(watchdog, 15 * 60 * 1000L)
                if (call.method == "preflight") {
                    usb.submit {
                        if (!operations.bind(id)) return@submit
                        try { prepareNative(); finish(id, null) }
                        catch (error: Throwable) { finishError(id, "usb_esp_native_unavailable", "Native ESP flashing engine is unavailable for this APK/device. Backup and nRF52 DFU remain available.") }
                    }
                } else if (call.method == "connect") {
                    // Gate readiness before permission/open, independently of
                    // Dart's gate before its deliberate TinyUSB1200-baud touch.
                    try { prepareNative() } catch (error: Throwable) {
                        finishError(id, "usb_esp_native_unavailable", "Native ESP flashing engine is unavailable for this APK/device.")
                        return@setMethodCallHandler
                    }
                    opening = true
                    val expected = (call.arguments as? Map<*, *>)?.entries?.associate { it.key.toString() to it.value }
                    usb.openAsync(call.argument<String>("deviceName") ?: "", call.argument<Int>("portNumber") ?: 0,
                        115200, expected = expected) { error ->
                        opening = false
                        if (active == null || !operations.isCurrent(id)) { if (error == null) usb.submit { usb.closeRaw() } }
                        else if (error != null) finishError(id, "usb_esp_failed", error.message ?: "USB open failed")
                        else { ownsUsb = true; execute(id, call) }
                    }
                } else execute(id, call)
            }
    }
    private fun prepareNative() {
        if (!loaded) { System.loadLibrary("meshcore_esp_flasher"); loaded = true }
        check(nativeVersion() == "esp-serial-flasher/2.1.0/24997fe693ff17e6598d7eb1d37af312752100aa") { "Native ESP version does not match pinned source" }
    }
    private fun execute(id: Int, call: MethodCall) {
        usb.submit {
            if (!operations.bind(id)) return@submit
            try {
                val value: Any? = when (call.method) {
                    "connect" -> {
                        destroyContext(); usb.purge()
                        nativeContext = nativeCreate()
                        check(nativeContext != 0L) { "Native ESP context was not initialized" }
                        val vendor = call.argument<Int>("vendorId") ?: 0
                        val pid = call.argument<Int>("productId") ?: 0
                        val nativeUsb = call.argument<String>("driver") == "CdcAcmSerialDriver" && vendor !in listOf(0x1a86, 0x0403, 0x10c4, 0x067b)
                        val info = JSONObject(nativeConnect(nativeContext, call.argument<Boolean>("reset") ?: true,
                            nativeUsb, vendor == 0x303a && pid == 0x1001, call.argument<Boolean>("allowUnreviewed") ?: false))
                        info.keys().asSequence().associateWith { key -> info.get(key) }
                    }
                    "readFlash" -> {
                        val data = nativeReadFlash(nativeContext, required(call, "offset"), required(call, "length"), required(call, "expectedMac"))
                        mapOf("data" to data, "md5" to digest(data))
                    }
                    "writeFlash" -> {
                        val data: ByteArray = required(call, "data")
                        val mac: String = required(call, "expectedMac")
                        val md5: String = required(call, "expectedMd5")
                        nativeWriteFlash(nativeContext, required(call, "offset"), data, mac, md5)
                        mapOf("mac" to mac, "md5" to md5)
                    }
                    "eraseFlash" -> {
                        val mac: String = required(call, "expectedMac")
                        nativeEraseFlash(nativeContext, mac)
                        mapOf("mac" to mac, "erased" to true)
                    }
                    "runApplication" -> {
                        nativeRunApplication(nativeContext, required(call, "expectedMac"))
                        destroyContext(); if (ownsUsb) usb.closeRaw(); ownsUsb = false
                        null
                    }
                    "close" -> { destroyContext(); if (ownsUsb) usb.closeRaw(); ownsUsb = false; null }
                    else -> error("Unsupported native ESP operation")
                }
                finish(id, value)
            } catch (error: Throwable) {
                // Failed writes stay in loader; cleanup never resets.
                val message = error.message ?: "Native ESP operation failed"
                val code = if (message.startsWith("Manual reset required:")) "usb_esp_manual_reset_required" else "usb_esp_failed"
                finishError(id, code, message)
            }
        }
    }
    private inline fun <reified T> required(call: MethodCall, key: String): T =
        call.argument<T>(key) ?: throw IllegalArgumentException("Missing $key")
    private fun digest(data: ByteArray) = MessageDigest.getInstance("MD5").digest(data).joinToString("") { "%02x".format(it) }
    private fun destroyContext() { if (nativeContext != 0L) { nativeDestroy(nativeContext); nativeContext = 0L } }
    private fun finish(id: Int, value: Any?) { main.post {
        if (!operations.isCurrent(id) || active == null) return@post
        main.removeCallbacks(watchdog); val result = active; active = null; result?.success(value)
    } }
    private fun finishError(id: Int, code: String, message: String) { main.post {
        if (!operations.isCurrent(id) || active == null) return@post
        main.removeCallbacks(watchdog); val result = active; active = null; result?.error(code, message, null)
    } }
    fun dispose() {
        operations.dispose(); main.removeCallbacks(watchdog)
        active?.error("usb_esp_closed", "Native USB update activity closed", null); active = null
        if (opening) usb.cancelPendingRaw()
        usb.submit { destroyContext(); if (ownsUsb) usb.closeRaw(); ownsUsb = false }
    }

    // JNI invokes callbacks synchronously on the same I/O worker. A nested
    // usb.submit here would deadlock. No callback asserts reset implicitly.
    private fun checkOperation() { if (operations.isCancelled()) throw IOException("USB operation cancelled") }
    private fun nativeUsbRead(size: Int, timeout: Int): ByteArray { checkOperation(); return usb.readRaw(size, timeout.coerceIn(1, 30000)) }
    private fun nativeUsbWrite(data: ByteArray) { checkOperation(); usb.writeRaw(data) }
    private fun nativeUsbSignals(dtr: Boolean, rts: Boolean) {
        checkOperation()
        usb.setSignals(dtr, rts)
    }
    private fun nativeUsbBaud(baud: Int) { checkOperation(); usb.setBaudRate(baud) }
    private fun nativeUsbCancelled() = operations.isCancelled()
    private fun nativeUsbDelay(ms: Int) {
        var remaining = ms
        while (remaining > 0) {
            checkOperation()
            val step = remaining.coerceAtMost(10); Thread.sleep(step.toLong()); remaining -= step
        }
    }
    private external fun nativeVersion(): String
    private external fun nativeCreate(): Long
    private external fun nativeConnect(handle: Long, reset: Boolean, nativeUsb: Boolean, usbJtag: Boolean, allowUnreviewed: Boolean): String
    private external fun nativeReadFlash(handle: Long, offset: Int, length: Int, mac: String): ByteArray
    private external fun nativeWriteFlash(handle: Long, offset: Int, data: ByteArray, mac: String, md5: String)
    private external fun nativeEraseFlash(handle: Long, mac: String)
    private external fun nativeRunApplication(handle: Long, mac: String)
    private external fun nativeDestroy(handle: Long)
}
