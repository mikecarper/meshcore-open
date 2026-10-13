package com.meshcore.meshcore_open

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Metadata-free pixel codecs, with one exec'd native worker per operation. */
class MeshcoreImageCodec(context: Context, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "com.meshcore.meshcore_open/image_codec")
    private val handler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private val controlExecutor = Executors.newSingleThreadExecutor()
    private val busy = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)
    private val native = MeshcoreImageNative()
    private val workerPath = File(context.applicationInfo.nativeLibraryDir, "libmesh_image_worker.so").absolutePath
    private val bpgWorkerPath = File(context.applicationInfo.nativeLibraryDir, "libmesh_bpg_worker.so").absolutePath
    private val unavailableReason: String?

    init {
        unavailableReason = try {
            System.loadLibrary("mesh_image_codec")
            if (File(workerPath).isFile && File(workerPath).canExecute()) null
            else "Native image worker is missing from this APK"
        } catch (error: UnsatisfiedLinkError) {
            "Native image codecs are not packaged for this CPU"
        }
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capabilities" -> result.success(CODECS.keys.filter { availabilityReason(it) == null })
            "capabilityDetails" -> result.success(details())
            "cancel" -> {
                // JNI coordinates exact PID ownership with the worker reaper.
                // Keep even a slow kernel reap off the Android UI thread.
                controlExecutor.execute {
                    if (unavailableReason == null) native.cancel()
                    // Wait for the worker task to reap its killed process
                    // before reporting cancellation and clearing the slot.
                    executor.execute { complete { result.success(null) } }
                }
            }
            "encode", "decode" -> run(call, result)
            else -> result.notImplemented()
        }
    }

    private fun details(): List<Map<String, Any>> {
        val supported = CODECS.keys.map { codec ->
            val reason = availabilityReason(codec)
            mapOf<String, Any>(
                "codec" to codec,
                "available" to (reason == null),
                "reason" to (reason ?: "Native encoder and decoder; metadata-free pixels"),
                "maxDimension" to 512,
                "maxDeadlineMs" to 120000,
            )
        }
        return supported + listOf(
            mapOf("codec" to "aeic", "available" to false, "reason" to "AEIC uses the separate model backend; the current model requires a 64-bit process"),
        )
    }

    private fun availabilityReason(codec: String): String? {
        if (unavailableReason != null) return unavailableReason
        if (codec == "bpg" && (!File(bpgWorkerPath).isFile || !File(bpgWorkerPath).canExecute())) return "The separate BPG codec worker is not packaged for this CPU"
        return null
    }

    private fun run(call: MethodCall, result: MethodChannel.Result) {
        if (unavailableReason != null) {
            result.error("unavailable", unavailableReason, null)
            return
        }
        val requestedCodec = call.argument<String>("codec")?.lowercase()
        val codecName = when (requestedCodec) {
            "jpegxl", "jpeg-xl" -> "jxl"
            "jpeg2000", "jpeg-2000" -> "jp2"
            "jpg" -> "jpeg"
            else -> requestedCodec
        }
        val codec = CODECS[codecName]
        val codecUnavailable = codecName?.let { availabilityReason(it) }
        if (codecUnavailable != null) {
            result.error("unavailable", codecUnavailable, null)
            return
        }
        val operation = if (call.method == "encode") 0 else 1
        val input = call.argument<ByteArray>(if (operation == 0) "rgba" else "bytes")
        val width = call.argument<Int>("width") ?: 0
        val height = call.argument<Int>("height") ?: 0
        val quality = call.argument<Int>("quality") ?: 50
        val requestedDeadline = call.argument<Int>("deadlineMs") ?: 120000
        val deadline = requestedDeadline.coerceIn(1, 120000)
        if (codec == null || input == null || input.isEmpty() || input.size > 4 * 1024 * 1024 || quality !in 0..100 ||
            (operation == 0 && (width !in 1..512 || height !in 1..512 || input.size != width * height * 4))) {
            result.error("invalid_image", "Unsupported codec or invalid image buffer", null)
            return
        }
        if (!busy.compareAndSet(false, true)) {
            result.error("busy", "Another image codec is running", null)
            return
        }
        // Capture before queuing: an immediate cancel must also invalidate a
        // worker task that has not yet entered JNI or created its process.
        val generation = native.token()
        executor.execute {
            val delivery: () -> Unit = try {
                val executable = if (codecName == "bpg") bpgWorkerPath else workerPath
                val output = native.run(executable, operation, codec, width, height, quality, input, deadline, generation)
                val response: Any = if (operation == 0) output else {
                    check(output.size >= 8) { "Decoded image result is truncated" }
                    val geometry = ByteBuffer.wrap(output, 0, 8).order(ByteOrder.LITTLE_ENDIAN)
                    val decodedWidth = geometry.int
                    val decodedHeight = geometry.int
                    check(decodedWidth in 1..512 && decodedHeight in 1..512 && output.size == 8 + decodedWidth * decodedHeight * 4) { "Decoded image geometry is invalid" }
                    mapOf("width" to decodedWidth, "height" to decodedHeight, "rgba" to output.copyOfRange(8, output.size))
                }
                val success: () -> Unit = { result.success(response) }
                success
            } catch (error: Exception) {
                val message = error.message ?: "Native image codec failed"
                val code = when {
                    message.contains("deadline") -> "timeout"
                    message.contains("cancelled") -> "cancelled"
                    else -> "codec_failed"
                }
                val failure: () -> Unit = { result.error(code, message, null) }
                failure
            } finally {
                busy.set(false)
            }
            // Release the slot before posting a reply: Dart can immediately
            // submit the next encode/decode as soon as it sees that reply.
            complete(delivery)
        }
    }

    private fun complete(action: () -> Unit) {
        handler.post { if (!closed.get()) action() }
    }

    fun close() {
        if (!closed.compareAndSet(false, true)) return
        channel.setMethodCallHandler(null)
        if (unavailableReason == null) controlExecutor.execute { native.cancel() }
        controlExecutor.shutdown()
        executor.shutdown()
    }

    companion object {
        private val CODECS = linkedMapOf("webp" to 1, "jpeg" to 2, "png" to 3, "avif" to 4, "jxl" to 5, "jp2" to 6, "vvc" to 7, "heic" to 8, "bpg" to 9)
    }
}

/** JNI names are preserved by the image codec ProGuard keep rule. */
class MeshcoreImageNative {
    external fun run(workerPath: String, operation: Int, codec: Int, width: Int, height: Int, quality: Int, bytes: ByteArray, deadlineMs: Int, generation: Long): ByteArray
    external fun cancel()
    external fun token(): Long
}
