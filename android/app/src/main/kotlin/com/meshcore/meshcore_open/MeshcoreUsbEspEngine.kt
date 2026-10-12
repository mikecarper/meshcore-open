package com.meshcore.meshcore_open

import android.annotation.SuppressLint
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.security.MessageDigest

/** Offline-only official esptool engine; never loads remote JavaScript. */
class MeshcoreUsbEspEngine(private val activity: FlutterActivity, private val usb: MeshcoreUsbFunctions) {
    private val main = Handler(Looper.getMainLooper())
    private var page: WebView? = null
    @Volatile private var ready = false
    private var sequence = 1
    private var active: MethodChannel.Result? = null
    private var activeId = 0
    private var startWhenReady: (() -> Unit)? = null
    @Volatile private var ownsUsb = false
    private var openingUsb = false
    @Volatile private var pageGeneration = 0
    private val watchdog = Runnable {
        val wasReady = ready
        val result = active
        active = null
        startWhenReady = null
        // Destroying the engine cancels stale callbacks. USB is closed without
        // resetting a potentially mid-migration node.
        destroyPage()
        if (openingUsb || ownsUsb) {
            openingUsb = false; ownsUsb = false
            usb.cancelPendingRaw(); usb.submit { usb.closeRaw() }
        }
        if (!wasReady) result?.error("usb_esp_webview_incompatible", incompatibleWebViewMessage, null)
        else result?.error("usb_esp_timeout", "ESP operation timed out; USB was closed without reset", null)
    }
    private val incompatibleWebViewMessage = "ESP32 USB flashing requires an updated Android System WebView with ES module support (61 or newer; 95 supports Android 5.1). Update WebView. Backup and nRF52 USB DFU remain available."

    fun configureFlutterEngine(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "meshcore_open/usb_esp")
            .setMethodCallHandler { call, result ->
                if (call.method !in listOf("preflight", "connect", "readFlash", "writeFlash", "runApplication", "close")) {
                    result.notImplemented(); return@setMethodCallHandler
                }
                if (active != null) { result.error("usb_busy", "ESP operation already in progress", null); return@setMethodCallHandler }
                // Do not first wrap the firmware ByteArray in a giant JSON
                // numeric array; only its one base64 representation crosses JS.
                val arguments = ((call.arguments as? Map<*, *>) ?: emptyMap<Any, Any>()).filterKeys { it != "data" }
                val args = JSONObject(arguments)
                if (call.method == "writeFlash") {
                    val data = call.argument<ByteArray>("data")
                    if (data == null || data.isEmpty() || data.size > 32 * 1024 * 1024) {
                        result.error("usb_esp_invalid_image", "Firmware size is invalid", null); return@setMethodCallHandler
                    }
                    args.put("data", Base64.encodeToString(data, Base64.NO_WRAP))
                }
                active = result
                activeId = sequence++
                val operationId = activeId
                // Slow CH340/UART links may legitimately take several minutes
                // for multi-megabyte images. Runtime remains foreground-owned.
                main.postDelayed(watchdog, if (ready) 15 * 60 * 1000L else 10000L)
                val invoke = {
                    try {
                        ensurePage()
                        val dispatch = { page?.evaluateJavascript("window.meshUsbDispatch(${JSONObject().put("id", activeId).put("op", call.method).put("args", args)});", null); Unit }
                        val start = {
                            main.removeCallbacks(watchdog)
                            if (call.method == "preflight") finish(null)
                            else {
                                main.postDelayed(watchdog, 15 * 60 * 1000L)
                                if (call.method == "connect") {
                                    val expected = args.keys().asSequence().associateWith { key -> args.opt(key).takeUnless { it == JSONObject.NULL } }
                                    openingUsb = true
                                    usb.openAsync(args.optString("deviceName"), args.optInt("portNumber"), 115200, expected = expected) { error ->
                                        openingUsb = false
                                        if (active == null || activeId != operationId) { if (error == null) usb.submit { usb.closeRaw() } }
                                        else if (error != null) finishError(error.message ?: "USB open failed")
                                        else { ownsUsb = true; dispatch() }
                                    }
                                } else dispatch()
                            }
                            Unit
                        }
                        if (ready) start() else startWhenReady = start
                    } catch (error: Throwable) { finishError(error.message ?: "Unable to initialize offline ESP engine") }
                }
                if (call.method == "close" && page == null) {
                    if (ownsUsb) usb.submit { usb.closeRaw(); main.post { ownsUsb = false; finish(null) } }
                    else finish(null)
                } else invoke()
            }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun ensurePage() {
        if (page != null) return
        val bundle = activity.assets.open("esptool/bundle.js").use { it.readBytes() }
        val hash = MessageDigest.getInstance("SHA-256").digest(bundle).joinToString("") { "%02x".format(it) }
        check(hash == "00ebe6fb0b202976d3e2a3c6b9a6bd438c26a81d2af6739c95ac276a64c1a84e") { "Offline esptool bundle checksum failed" }
        val generation = ++pageGeneration
        page = WebView(activity).apply {
            settings.javaScriptEnabled = true
            settings.allowFileAccess = false
            settings.allowContentAccess = false
            settings.domStorageEnabled = false
            settings.databaseEnabled = false
            settings.blockNetworkLoads = true
            settings.javaScriptCanOpenWindowsAutomatically = false
            settings.setSupportMultipleWindows(false)
            webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean = true
                override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse {
                    val uri = request.url
                    val name = uri.path?.removePrefix("/")
                    if (uri.scheme == "https" && uri.host == "meshcore-usb.invalid" &&
                        name in listOf("index.html", "bootstrap.js", "bridge.js", "bundle.js")) {
                        val mime = if (name == "index.html") "text/html" else "text/javascript"
                        return WebResourceResponse(mime, "UTF-8", activity.assets.open("esptool/$name"))
                    }
                    return WebResourceResponse("text/plain", "UTF-8", 403, "Forbidden", emptyMap(), ByteArrayInputStream(ByteArray(0)))
                }
            }
            addJavascriptInterface(NativeBridge(generation), "MeshUsb")
            loadUrl("https://meshcore-usb.invalid/index.html")
        }
    }

    private fun destroyPage() {
        ++pageGeneration
        page?.destroy(); page = null; ready = false
    }

    private inner class NativeBridge(private val generation: Int) {
        @JavascriptInterface fun incompatible(message: String) {
            main.post {
                if (generation == pageGeneration && page != null && !ready) {
                    destroyPage()
                    finishError(incompatibleWebViewMessage, "usb_esp_webview_incompatible")
                }
            }
        }
        @JavascriptInterface fun ready() { main.post {
            if (generation != pageGeneration || page == null) return@post
            ready = true; val launch = startWhenReady; startWhenReady = null; launch?.invoke()
        } }
        @JavascriptInterface fun request(encoded: String) {
            if (generation != pageGeneration || !ready || !ownsUsb) return
            val request = try { JSONObject(encoded) } catch (_: Exception) { return }
            val id = request.optInt("id")
            val args = request.optJSONObject("args") ?: JSONObject()
            val originPage = page
            usb.submit {
                if (generation != pageGeneration || !ready || !ownsUsb) return@submit
                val response = JSONObject().put("id", id)
                try {
                    val value: Any? = when (request.optString("op")) {
                        "read" -> Base64.encodeToString(usb.readRaw(args.optInt("maxBytes", 4096), args.optInt("timeoutMs", 50)), Base64.NO_WRAP)
                        "write" -> { usb.writeRaw(Base64.decode(args.getString("data"), Base64.NO_WRAP)); null }
                        "setSignals" -> { usb.setSignals(args.getBoolean("dtr"), args.getBoolean("rts")); null }
                        "setBaudRate" -> { usb.setBaudRate(args.getInt("baudRate")); null }
                        "close" -> { usb.closeRaw(); main.post { ownsUsb = false }; null }
                        else -> error("Unsupported native USB operation")
                    }
                    response.put("value", value ?: JSONObject.NULL)
                } catch (error: Throwable) { response.put("error", error.message ?: "USB I/O failed") }
                main.post { if (generation == pageGeneration && page === originPage) page?.evaluateJavascript("window.meshUsbNativeReply($response);", null) }
            }
        }
        @JavascriptInterface fun result(encoded: String) {
            val response = try { JSONObject(encoded) } catch (_: Exception) { return }
            main.post {
                if (generation != pageGeneration || page == null) return@post
                if (response.optInt("id") != activeId || active == null) return@post
                if (response.has("error")) finishError(response.getString("error"))
                else finish(toFlutter(response.opt("value")))
            }
        }
    }

    private fun toFlutter(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is JSONObject -> value.keys().asSequence().associateWith { key ->
            if (key == "data") Base64.decode(value.getString(key), Base64.NO_WRAP) else toFlutter(value.opt(key))
        }
        else -> value
    }
    private fun finish(value: Any?) {
        main.removeCallbacks(watchdog)
        val result = active; active = null
        result?.success(value)
    }
    private fun finishError(message: String, code: String = "usb_esp_failed") {
        main.removeCallbacks(watchdog)
        val result = active; active = null; startWhenReady = null
        result?.error(code, message, null)
    }
    fun dispose() {
        main.removeCallbacks(watchdog)
        active?.error("usb_esp_closed", "USB update activity closed", null)
        active = null; startWhenReady = null
        if (openingUsb || ownsUsb) usb.cancelPendingRaw()
        openingUsb = false; ownsUsb = false
        destroyPage()
    }
}
