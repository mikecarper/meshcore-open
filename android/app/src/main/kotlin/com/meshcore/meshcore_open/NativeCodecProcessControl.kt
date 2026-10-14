package com.meshcore.meshcore_open

/** Signals only the group declared by the packaged executable's early handshake. */
internal class NativeCodecProcessControl(
    private val signal: (Int, Int) -> Unit,
    private val stopSignal: Int,
    private val continueSignal: Int,
    private val terminateSignal: Int,
    private val killSignal: Int,
    private val clockMillis: () -> Long = { System.nanoTime() / 1_000_000 },
    private val recordPausedMillis: (Long) -> Unit = {},
) {
    var processId = 0
        private set
    var groupId = 0
        private set
    var pauseRequested = false
        private set
    var paused = false
        private set
    var cancelled = false
        private set
    var hasExited = false
        private set
    private var pauseStarted = 0L
    var totalPausedMillis = 0L
        private set

    @Synchronized fun acceptHandshake(line: String): Boolean {
        val match = Regex("PROCESS_INFO pid=([1-9][0-9]*) group=([1-9][0-9]*)").matchEntire(line)
            ?: return false
        val pid = match.groupValues[1].toIntOrNull() ?: return false
        val group = match.groupValues[2].toIntOrNull() ?: return false
        if (pid <= 1 || pid != group || groupId != 0 || hasExited) return false
        processId = pid
        groupId = group
        if (cancelled) signal(-groupId, terminateSignal)
        else if (pauseRequested) {
            signal(-groupId, stopSignal)
            pauseStarted = clockMillis()
            paused = true
        }
        return true
    }

    /** The supervisor has reaped this worker; its PID/group must never be signalled again. */
    @Synchronized fun acceptExit(line: String): Boolean {
        val match = Regex("PROCESS_EXIT pid=([1-9][0-9]*) group=([1-9][0-9]*)").matchEntire(line)
            ?: return false
        val pid = match.groupValues[1].toIntOrNull() ?: return false
        val group = match.groupValues[2].toIntOrNull() ?: return false
        if (groupId == 0 || pid != processId || group != groupId || hasExited) return false
        markExited()
        return true
    }

    @Synchronized fun markExited() {
        hasExited = true
        pauseRequested = false
        paused = false
    }

    @Synchronized fun pause() {
        if (cancelled || hasExited) return
        pauseRequested = true
        if (groupId != 0 && !paused) {
            signal(-groupId, stopSignal)
            pauseStarted = clockMillis()
            paused = true
        }
    }

    @Synchronized fun resume() {
        if (hasExited) return
        pauseRequested = false
        if (groupId != 0 && paused) {
            totalPausedMillis += (clockMillis() - pauseStarted).coerceAtLeast(0)
            paused = false
            try { recordPausedMillis(totalPausedMillis) }
            finally { signal(-groupId, continueSignal) }
        }
        paused = false
    }

    @Synchronized fun cancel() {
        if (cancelled || hasExited) return
        try { resume() } finally {
            cancelled = true
            if (groupId != 0) signal(-groupId, terminateSignal)
        }
    }

    @Synchronized fun forceKill() {
        if (hasExited) return
        resume()
        if (groupId != 0) signal(-groupId, killSignal)
    }
}
