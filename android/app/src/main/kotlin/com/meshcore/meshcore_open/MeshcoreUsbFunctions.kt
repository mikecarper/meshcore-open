package com.meshcore.meshcore_open

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.view.WindowManager
import com.hoho.android.usbserial.driver.UsbSerialPort
import com.hoho.android.usbserial.driver.UsbSerialProber
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.Locale
import java.util.concurrent.Executors

/** One physical USB owner shared by companion framing and raw firmware I/O. */
class MeshcoreUsbFunctions(private val activity: FlutterActivity) {
    private val manager = activity.getSystemService(Context.USB_SERVICE) as UsbManager
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private val permissionAction = "${activity.packageName}.USB_SERIAL_PERMISSION"
    @Volatile private var port: UsbSerialPort? = null
    @Volatile private var connection: UsbDeviceConnection? = null
    @Volatile private var owner: String? = null
    @Volatile private var reading = false
    @Volatile private var events: EventChannel.EventSink? = null
    private var reader: Thread? = null
    private var pending: PendingOpen? = null
    private var updateWakeLock: PowerManager.WakeLock? = null
    private data class PendingOpen(val device: UsbDevice, val portNumber: Int, val baud: Int, val owner: String,
        val expected: Map<String, Any?>?, val finish: (Throwable?) -> Unit)

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val device = if (Build.VERSION.SDK_INT >= 33) {
                intent?.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent?.getParcelableExtra(UsbManager.EXTRA_DEVICE)
            }
            when (intent?.action) {
                UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                    if (device?.deviceName == port?.device?.deviceName) {
                        if (owner == "companion") events?.error("usb_detached", "USB node disconnected", null)
                        io.execute { closePort() }
                    }
                    val request = pending
                    if (request != null && request.device.deviceName == device?.deviceName) {
                        pending = null
                        request.finish(IOException("USB node disconnected before permission was granted"))
                    }
                }
                permissionAction -> {
                    val request = pending ?: return
                    // Ignore unrelated or stale permission broadcasts.
                    if (request.device.deviceId != device?.deviceId) return
                    pending = null
                    if (!intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false) || !manager.hasPermission(request.device)) {
                        request.finish(SecurityException("USB permission was denied"))
                    } else { performOpen(request) }
                }
            }
        }
    }

    fun configureFlutterEngine(engine: FlutterEngine) {
        val filter = IntentFilter(permissionAction).apply { addAction(UsbManager.ACTION_USB_DEVICE_DETACHED) }
        if (Build.VERSION.SDK_INT >= 33) activity.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        else { @Suppress("DEPRECATION") activity.registerReceiver(receiver, filter) }
        MethodChannel(engine.dartExecutor.binaryMessenger, "meshcore_open/android_usb_serial")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "listPorts" -> result.success(listDevices().map {
                        val ids = String.format(Locale.US, "VID:%04X PID:%04X", it["vendorId"], it["productId"])
                        "${it["deviceName"]} - ${it["productName"] ?: it["driver"]} - $ids"
                    })
                    "connect" -> {
                        val name = call.argument<String>("portName")?.substringBefore(" - ")?.trim()
                        if (name.isNullOrBlank()) result.error("usb_invalid_port", "Select a USB serial node", null)
                        else openAsync(name, 0, call.argument<Int>("baudRate") ?: 115200, "companion") { error ->
                            if (error == null) result.success(null) else result.error("usb_connect_failed", error.message, null)
                        }
                    }
                    "write" -> execute(result) { requireOwner("companion").write(call.argument<ByteArray>("data") ?: error("Missing USB data"), 10000); null }
                    "disconnect" -> execute(result) { if (owner == "companion") closePort(); null }
                    else -> result.notImplemented()
                }
            }
        EventChannel(engine.dartExecutor.binaryMessenger, "meshcore_open/android_usb_serial_events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink) { events = sink }
                override fun onCancel(arguments: Any?) { events = null }
            })
        MethodChannel(engine.dartExecutor.binaryMessenger, "meshcore_open/usb_flash")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "listDevices" -> result.success(listDevices())
                    "setKeepAwake" -> { setKeepAwake(call.argument<Boolean>("enabled") == true); result.success(null) }
                    "readIdentity" -> {
                        val name = call.argument<String>("deviceName") ?: ""
                        val number = call.argument<Int>("portNumber") ?: 0
                        openAsync(name, number, 0, "identity", descriptorArguments(call.arguments)) { error ->
                            if (error != null) result.error("usb_identity_failed", error.message, null)
                            else result.success(listDevices().firstOrNull { it["deviceName"] == name && it["portNumber"] == number })
                        }
                    }
                    "open" -> openAsync(call.argument<String>("deviceName") ?: "", call.argument<Int>("portNumber") ?: 0,
                        call.argument<Int>("baudRate") ?: 115200, "flash", descriptorArguments(call.arguments)) { error ->
                        if (error == null) result.success(null) else result.error("usb_open_failed", error.message, null)
                    }
                    "read" -> execute(result) { readRaw(call.argument<Int>("maxBytes") ?: 4096, call.argument<Int>("timeoutMs") ?: 1000) }
                    "write" -> execute(result) { writeRaw(call.argument<ByteArray>("data") ?: error("Missing USB data")); null }
                    "setSignals" -> execute(result) { setSignals(call.argument<Boolean>("dtr") ?: false, call.argument<Boolean>("rts") ?: false); null }
                    "setBaudRate" -> execute(result) { setBaudRate(call.argument<Int>("baudRate") ?: error("Missing baud rate")); null }
                    "purge" -> execute(result) { purge(); null }
                    "close" -> { cancelPendingRaw(); execute(result) { closeRaw(); null } }
                    else -> result.notImplemented()
                }
            }
    }

    fun listDevices(): List<Map<String, Any?>> = UsbSerialProber.getDefaultProber().findAllDrivers(manager).flatMap { driver ->
        driver.ports.map { serial ->
            val device = driver.device
            mapOf("deviceName" to device.deviceName, "vendorId" to device.vendorId, "productId" to device.productId,
                "serialNumber" to (if (manager.hasPermission(device)) try { device.serialNumber } catch (_: SecurityException) { null } else null),
                "manufacturerName" to device.manufacturerName, "productName" to device.productName,
                "portNumber" to serial.portNumber, "driver" to driver.javaClass.simpleName)
        }
    }

    fun openAsync(name: String, portNumber: Int, baud: Int, requestedOwner: String = "flash",
        expected: Map<String, Any?>? = null, finish: (Throwable?) -> Unit) {
        if (owner != null || pending != null) { finish(IllegalStateException("USB is busy; disconnect the companion before updating")); return }
        val device = manager.deviceList.values.firstOrNull { it.deviceName == name }
        if (device == null) { finish(IOException("The selected USB node is no longer attached")); return }
        if (baud <= 0 && requestedOwner != "identity") { finish(IllegalArgumentException("Invalid baud rate")); return }
        val request = PendingOpen(device, portNumber, baud, requestedOwner, expected, finish)
        // Reserve before permission/UI scheduling; another channel cannot race
        // an in-flight open and silently take over the same physical endpoint.
        pending = request
        if (manager.hasPermission(device)) { pending = null; owner = requestedOwner; performOpen(request); return }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
        val permission = PendingIntent.getBroadcast(activity, device.deviceId, Intent(permissionAction).setPackage(activity.packageName), flags)
        manager.requestPermission(device, permission)
    }

    private fun performOpen(request: PendingOpen) {
        if (request.owner == "identity") {
            owner = null
            try {
                val actual = listDevices().firstOrNull { it["deviceName"] == request.device.deviceName && it["portNumber"] == request.portNumber }
                    ?: error("Selected USB endpoint disappeared before permission")
                UsbFlashIdentityGuard.verify(request.expected, actual)
                request.finish(null)
            } catch (error: Throwable) { request.finish(error) }
            return
        }
        owner = request.owner
        io.execute {
            try {
                val currentDevice = manager.deviceList.values.firstOrNull { it.deviceName == request.device.deviceName }
                    ?: error("Selected USB endpoint disappeared before open")
                val actual = listDevices().firstOrNull { it["deviceName"] == currentDevice.deviceName && it["portNumber"] == request.portNumber }
                    ?: error("Selected USB serial interface disappeared")
                UsbFlashIdentityGuard.verify(request.expected, actual)
                val driver = UsbSerialProber.getDefaultProber().probeDevice(currentDevice) ?: error("No supported USB driver for this node")
                val serial = driver.ports.firstOrNull { it.portNumber == request.portNumber } ?: error("Selected USB serial interface is unavailable")
                val handle = manager.openDevice(currentDevice) ?: error("USB permission or connection was lost")
                connection = handle
                // Re-read the serial through the actual native handle before
                // driver initialization can change any modem control lines.
                UsbFlashIdentityGuard.verify(request.expected, actual + ("serialNumber" to handle.serial))
                port = serial
                serial.open(handle)
                serial.setParameters(request.baud, 8, UsbSerialPort.STOPBITS_1, UsbSerialPort.PARITY_NONE)
                // No raw DTR/RTS toggle. Companion DTR announces an app client.
                if (request.owner == "companion") { serial.setRTS(false); serial.setDTR(true); startReadLoop(serial) }
                main.post { request.finish(null) }
            } catch (error: Throwable) { closePort(); main.post { request.finish(error) } }
        }
    }

    private fun requireOwner(expected: String): UsbSerialPort {
        if (owner != expected) error("USB transport is not open for $expected")
        return port ?: error("USB node is no longer connected")
    }
    private fun descriptorArguments(arguments: Any?): Map<String, Any?>? =
        (arguments as? Map<*, *>)?.entries?.associate { it.key.toString() to it.value }
    fun readRaw(maxBytes: Int, timeoutMs: Int): ByteArray {
        require(maxBytes in 1..65536 && timeoutMs in 1..30000) { "Invalid USB read bounds" }
        val buffer = ByteArray(maxBytes)
        return buffer.copyOf(requireOwner("flash").read(buffer, timeoutMs))
    }
    fun writeRaw(bytes: ByteArray) { require(bytes.size <= 1024 * 1024); requireOwner("flash").write(bytes, 30000) }
    fun setBaudRate(baud: Int) { require(baud in 1..4000000); requireOwner("flash").setParameters(baud, 8, UsbSerialPort.STOPBITS_1, UsbSerialPort.PARITY_NONE) }
    fun purge() {
        val serial = requireOwner("flash")
        try { serial.purgeHwBuffers(true, true) } catch (_: UnsupportedOperationException) {
            val buffer = ByteArray(4096)
            for (unused in 0 until 16) if (serial.read(buffer, 10) == 0) break
        }
    }

    /** Atomic DTR+RTS transfer; sequential calls can accidentally boot an ESP. */
    fun setSignals(dtr: Boolean, rts: Boolean) {
        val serial = requireOwner("flash")
        val handle = connection ?: error("USB connection is missing")
        val value = (if (dtr) 1 else 0) or (if (rts) 2 else 0)
        val result = when (serial.driver.javaClass.simpleName) {
            "CdcAcmSerialDriver" -> {
                val controls = (0 until serial.device.interfaceCount).map { serial.device.getInterface(it) }
                    .filter { it.interfaceClass == UsbConstants.USB_CLASS_COMM }
                val control = controls.getOrNull(serial.portNumber.coerceAtLeast(0)) ?: error("Cannot resolve selected CDC control interface")
                handle.controlTransfer(0x21, 0x22, value, control.id, null, 0, 1000)
            }
            "Ch34xSerialDriver" -> handle.controlTransfer(0x40, 0xa4,
                ((if (dtr) 0x20 else 0) or (if (rts) 0x40 else 0)).inv() and 0xffff, 0, null, 0, 1000)
            "Cp21xxSerialDriver" -> handle.controlTransfer(0x41, 0x07, 0x300 or value, serial.portNumber, null, 0, 1000)
            "FtdiSerialDriver" -> handle.controlTransfer(0x40, 0x01, 0x300 or value, serial.portNumber + 1, null, 0, 1000)
            else -> { serial.setDTR(dtr); serial.setRTS(rts); 0 }
        }
        if (result < 0) throw IOException("USB control-line transfer failed")
    }
    fun submit(work: () -> Unit) { io.execute(work) }
    fun cancelPendingRaw() {
        val request = pending?.takeIf { it.owner == "flash" } ?: return
        pending = null
        request.finish(IOException("USB open was cancelled"))
    }
    fun setKeepAwake(enabled: Boolean) {
        if (enabled) {
            activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            if (updateWakeLock == null) {
                val power = activity.getSystemService(Context.POWER_SERVICE) as PowerManager
                updateWakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "${activity.packageName}:UsbFirmwareUpdate")
                    .also { it.setReferenceCounted(false); it.acquire(30 * 60 * 1000L) }
            }
        } else {
            activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            updateWakeLock?.let { if (it.isHeld) it.release() }
            updateWakeLock = null
        }
    }
    fun closeRaw() { if (owner == "flash") closePort() }
    private fun execute(result: MethodChannel.Result, action: () -> Any?) {
        io.execute {
            try { val value = action(); main.post { result.success(value) } }
            catch (error: Throwable) { main.post { result.error("usb_io_failed", error.message, null) } }
        }
    }
    private fun startReadLoop(serial: UsbSerialPort) {
        reading = true
        reader = Thread({
            val buffer = ByteArray(4096)
            try {
                while (reading && port === serial) {
                    val count = serial.read(buffer, 250)
                    if (count > 0) { val packet = buffer.copyOf(count); main.post { if (reading) events?.success(packet) } }
                }
            } catch (error: Throwable) { if (reading) main.post { events?.error("usb_io_error", error.message, null) } }
        }, "MeshCoreUsbRead").also { it.isDaemon = true; it.start() }
    }
    private fun closePort() {
        reading = false
        val serial = port
        port = null
        try { serial?.close() } catch (_: Exception) { }
        try { connection?.close() } catch (_: Exception) { }
        connection = null
        owner = null
        reader = null
    }
    fun dispose() {
        setKeepAwake(false)
        val request = pending
        pending = null
        request?.finish(IllegalStateException("USB activity was closed"))
        closePort()
        io.shutdownNow()
        try { activity.unregisterReceiver(receiver) } catch (_: IllegalArgumentException) { }
    }
}
