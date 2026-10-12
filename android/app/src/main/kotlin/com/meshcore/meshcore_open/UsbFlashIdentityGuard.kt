package com.meshcore.meshcore_open

/** Pure descriptor gate, independently testable without an Android device. */
internal object UsbFlashIdentityGuard {
    fun verify(expected: Map<String, Any?>?, actual: Map<String, Any?>) {
        if (expected == null) return // Existing non-flashing companion API.
        val required = listOf("deviceName", "vendorId", "productId", "portNumber")
        for (field in required) {
            check(expected[field] == actual[field]) { "Selected USB $field changed; select the original node again" }
        }
        for (field in listOf("serialNumber", "manufacturerName", "productName", "driver")) {
            val selected = expected[field]
            if (selected != null && !(field == "driver" && selected == "unknown")) {
                check(selected == actual[field]) { "Selected USB $field changed; refusing to open or reset another node" }
            }
        }
    }
}
