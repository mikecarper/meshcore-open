package com.meshcore.meshcore_open

fun main() {
    val guard = UsbEspOperationGuard()
    val first = guard.begin()
    check(guard.bind(first) && !guard.isCancelled())
    guard.cancel()
    check(guard.isCancelled() && !guard.isCurrent(first))
    val second = guard.begin()
    // Critical race: starting a new operation MUST NOT resume old JNI work.
    check(guard.isCancelled() && !guard.bind(first))
    check(guard.bind(second) && !guard.isCancelled())
    guard.dispose()
    check(guard.isCancelled() && !guard.bind(second))
    check(runCatching { guard.begin() }.isFailure)
    println("Native ESP operation-generation cancellation tests passed")
}
