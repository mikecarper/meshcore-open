package com.meshcore.meshcore_open

/** Run with the production guard; no Android SDK or USB access is needed. */
fun main() {
    val original = mapOf<String, Any?>("deviceName" to "/dev/bus/usb/001/001", "portNumber" to 0,
        "vendorId" to 0x303a, "productId" to 0x1001, "serialNumber" to "original",
        "manufacturerName" to "Espressif", "productName" to "USB serial", "driver" to "CdcAcmSerialDriver")
    UsbFlashIdentityGuard.verify(original, original)
    var failures = 0
    for (field in original.keys) {
        val replacement = if (original[field] is Int) 999 else "replacement"
        var refused = false
        try {
            UsbFlashIdentityGuard.verify(original, original + (field to replacement))
        } catch (_: IllegalStateException) { refused = true }
        check(refused) { "Selected identity replacement was accepted: $field" }
        failures++
    }
    check(failures == original.size)
    var missingRefused = false
    try {
        UsbFlashIdentityGuard.verify(original, original + ("serialNumber" to null))
    } catch (_: IllegalStateException) { missingRefused = true }
    check(missingRefused) { "A known serial became unavailable and was accepted" }
    // Initial permission-only selection can learn a previously hidden serial;
    // it may not replace known VID/PID/path/manufacturer or port identifiers.
    UsbFlashIdentityGuard.verify(original + ("serialNumber" to null), original)
    println("USB identity guard passed exact identity and 9 replacement/missing-field cases.")
}
