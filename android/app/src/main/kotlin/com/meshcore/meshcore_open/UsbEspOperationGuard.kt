package com.meshcore.meshcore_open

/** A new UI call cannot revive a timed-out JNI call on the serial I/O worker. */
internal class UsbEspOperationGuard {
    @Volatile private var generation = 0
    @Volatile private var cancelled = false
    @Volatile private var disposed = false
    private var ioGeneration = 0 // accessed only on USB's single I/O worker
    fun begin(): Int {
        check(!disposed) { "USB update activity closed" }
        generation += 1
        cancelled = false
        return generation
    }
    fun bind(id: Int): Boolean {
        if (!isCurrent(id)) return false
        ioGeneration = id
        return true
    }
    fun isCurrent(id: Int) = !disposed && !cancelled && id == generation
    fun isCancelled() = disposed || cancelled || ioGeneration != generation
    fun cancel() { cancelled = true; generation += 1 }
    fun dispose() { disposed = true; cancel() }
}
