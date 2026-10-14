package com.meshcore.meshcore_open

import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.Build
import android.os.SystemClock
import android.util.Log
import android.system.Os
import android.system.OsConstants
import android.system.ErrnoException
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.InputStreamReader
import java.util.UUID
import java.util.concurrent.Executors

/** API21-compatible process runner. It never invokes a shell. */
class AndroidNativeCodec(context: Context) {
    private val app = context.applicationContext
    private val debugLogging = app.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
    private val executor = Executors.newSingleThreadExecutor()
    private val controlExecutor = Executors.newCachedThreadPool()
    private val lock = Any()
    private val jobs = LinkedHashMap<String, Job>()
    private var channel: MethodChannel? = null
    private var disposed = false
    private val workRoot get() = File(app.cacheDir, "native_image_codec").canonicalFile
    private val executable get() = File(app.applicationInfo.nativeLibraryDir, "libaeic_codec_exec.so")

    private class Job(val id: String, val workspace: File, val operation: String, val stages: Int, val debugLogging: Boolean) {
        @Volatile var process: Process? = null
        @Volatile var cancelled = false
        var finished = false
        var exitCode: Int? = null
        var error: String? = null
        var progress = 0.0
        var completedStages = 0
        var sawCompletion = false
        var degraded = false
        var recoveryEvents = 0
        val warnings = ArrayList<String>()
        val tail = StringBuilder()
        val control = NativeCodecProcessControl(
            signal = { target, code ->
                try { Os.kill(target, code) }
                catch (error: ErrnoException) {
                    if (error.errno != OsConstants.ESRCH) throw error
                }
            },
            stopSignal = OsConstants.SIGSTOP,
            continueSignal = OsConstants.SIGCONT,
            terminateSignal = OsConstants.SIGTERM,
            killSignal = OsConstants.SIGKILL,
            clockMillis = { SystemClock.uptimeMillis() }, // CLOCK_MONOTONIC, excluding deep sleep
            recordPausedMillis = { milliseconds ->
                try {
                    val temporary = File(workspace, "pause-ms.tmp")
                    temporary.writeText("$milliseconds\n", Charsets.UTF_8)
                    check(temporary.renameTo(File(workspace, "pause-ms"))) { "Cannot update pause counter" }
                } catch (error: Exception) {
                    // Cancellation must resume/terminate even if scratch storage fails.
                    if (debugLogging) Log.e("AEICNativeCodec", "Pause counter failed", error)
                }
            },
        )
    }

    fun configureFlutterEngine(engine: FlutterEngine) {
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(::handle)
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "info" -> {
                    workRoot.mkdirs()
                    result.success(mapOf("available" to (executable.isFile && executable.canExecute()),
                        "apiLevel" to Build.VERSION.SDK_INT, "abi" to Build.SUPPORTED_ABIS.firstOrNull(),
                        "codecIdentity" to IDENTITY, "workspaceRoot" to workRoot.path,
                        "usableGpuAcceleration" to false, // This ncnn build has Vulkan disabled.
                        "supportedResolutions" to (128..576 step 64).toList()))
                }
                "createWorkspace" -> {
                    check(!disposed) { "Native codec was disposed" }
                    val directory = File(workRoot, UUID.randomUUID().toString())
                    check(directory.mkdirs()) { "Cannot create codec workspace" }
                    result.success(directory.path)
                }
                "start" -> result.success(mapOf("jobId" to start(call)))
                "poll" -> {
                    val id = call.argument<String>("jobId") ?: error("jobId is required")
                    result.success(synchronized(lock) {
                        val job = jobs[id] ?: error("Unknown codec job")
                        mapOf("finished" to job.finished, "exitCode" to job.exitCode,
                            "cancelled" to job.cancelled, "progress" to job.progress,
                            "pauseRequested" to job.control.pauseRequested, "paused" to job.control.paused,
                            "processId" to job.control.processId, "processGroup" to job.control.groupId,
                            "complete" to job.sawCompletion, "error" to job.error,
                            "degraded" to job.degraded, "recoveryEvents" to job.recoveryEvents,
                            "warnings" to job.warnings.toList(), "logTail" to if (job.finished) job.tail.toString() else "")
                    })
                }
                "pauseAll", "resumeAll" -> {
                    val paused = call.method == "pauseAll"
                    val ids = synchronized(lock) {
                        jobs.values.filter { !it.finished }.map {
                            if (paused) it.control.pause() else it.control.resume()
                            it.id
                        }
                    }
                    result.success(ids)
                }
                "pause", "resume" -> {
                    val id = call.argument<String>("jobId") ?: error("jobId is required")
                    synchronized(lock) {
                        val job = jobs[id] ?: error("Unknown codec job")
                        check(!job.finished) { "Codec job already finished" }
                        if (call.method == "pause") job.control.pause() else job.control.resume()
                    }
                    result.success(null)
                }
                "activeJobs" -> result.success(synchronized(lock) {
                    jobs.values.filter { !it.finished }.map { it.id }
                })
                "cancel" -> {
                    val id = call.argument<String>("jobId") ?: error("jobId is required")
                    synchronized(lock) { jobs[id]?.let(::cancel) }
                    result.success(null)
                }
                "cancelAll" -> {
                    val ids = synchronized(lock) { jobs.values.filter { !it.finished }.map { it.id } }
                    cancelAll(); result.success(ids)
                }
                "forget" -> {
                    val id = call.argument<String>("jobId") ?: error("jobId is required")
                    synchronized(lock) {
                        val job = jobs[id]
                        check(job == null || job.finished) { "Codec job is still running" }
                        jobs.remove(id)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error("native_codec", error.message ?: error.javaClass.simpleName, null)
        }
    }

    private fun start(call: MethodCall): String {
        check(!disposed) { "Native codec was disposed" }
        check(executable.isFile && executable.canExecute()) { "Native codec executable is missing for this ABI" }
        require(call.argument<String>("codecIdentity") == IDENTITY) { "Native codec requires the FT2 bundle identity" }
        val operation = call.argument<String>("operation") ?: error("operation is required")
        require(operation == "encode" || operation == "decode") { "Unknown codec operation" }
        val size = call.argument<Int>("resolution") ?: error("resolution is required")
        require(size in 128..576 && size % 64 == 0) { "Unsupported codec dimensions" }
        val threads = call.argument<Int>("threads") ?: 2
        require(threads in 1..4) { "threads must be 1..4" }
        val bestEffort = call.argument<Boolean>("bestEffort") ?: false
        val decoderMode = call.argument<String>("decoderMode") ?: "fast"
        require(decoderMode == "fast" || decoderMode == "accurate") { "Unknown decoder mode" }
        val model = File(call.argument<String>("modelDirectory") ?: error("modelDirectory is required")).canonicalFile
        require(model.isDirectory && appOwned(model)) { "Model directory must be installed in app storage" }
        val workspace = File(call.argument<String>("workspace") ?: error("workspace is required")).canonicalFile
        require(workspace.isDirectory && workspace.parentFile == workRoot) { "Invalid codec workspace" }
        val input = File(workspace, if (operation == "encode") "input.ppm" else "input.aeic").canonicalFile
        val output = File(workspace, if (operation == "encode") "output.aeic" else "output.ppm").canonicalFile
        require(input.parentFile == workspace && output.parentFile == workspace) { "Invalid workspace file" }
        require(input.isFile && input.length() in 1..(64L shl 20)) { "Invalid codec input file" }
        require(!output.exists()) { "Codec output must be a new file" }
        val required = listOf("codec.tsv", "encoder.tsv", "renderer.tsv", "metadata.tsv")
        require(required.all { File(model, it).isFile }) { "Native bundle is incomplete" }
        val spill = File(workspace, "spill").canonicalFile
        require(spill.parentFile == workspace && !spill.exists()) { "Invalid spill directory" }
        check(spill.mkdir()) { "Cannot create codec scratch space" }
        val pauseTime = File(workspace, "pause-ms")
        pauseTime.writeText("0\n", Charsets.UTF_8)
        val stageCount = if (operation == "encode") countStages(File(model, "encoder.tsv")) + 5
            else countStages(File(model, "codec.tsv")) + countStages(File(model, "renderer.tsv"))
        val id = UUID.randomUUID().toString()
        val job = Job(id, workspace, operation, stageCount.coerceAtLeast(1), debugLogging)
        synchronized(lock) {
            check(jobs.values.none { !it.finished }) { "A codec job is already running" }
            while (jobs.size >= 8) jobs.remove(jobs.entries.first().key)
            jobs[id] = job
        }
        val command = arrayListOf(executable.path, "--supervise", "--model-dir", model.path, "--model-size", size.toString(),
            "--threads", threads.toString(), "--spill-dir", spill.path, "--pause-time-file", pauseTime.path)
        if (operation == "encode") command.addAll(listOf("--encode", "--input", input.path,
            "--bitstream-output", output.path))
        else command.addAll(listOf("--bitstream", input.path, "--output", output.path,
            "--decoder-mode", decoderMode))
        if (bestEffort) command.add("--best-effort")
        executor.execute { run(job, command) }
        return id
    }

    private fun run(job: Job, command: List<String>) {
        var exitObserved = false
        try {
            if (job.cancelled) return
            val process = ProcessBuilder(command).directory(job.workspace).redirectErrorStream(true).start()
            job.process = process
            if (job.cancelled) stopProcess(job)
            InputStreamReader(process.inputStream, Charsets.UTF_8).use { reader ->
                val buffer = CharArray(2048)
                val line = StringBuilder()
                var truncated = false
                while (true) {
                    val count = reader.read(buffer)
                    if (count < 0) break
                    for (index in 0 until count) {
                        val character = buffer[index]
                        if (character == '\n') {
                            record(job, line.toString() + if (truncated) " [line truncated]" else "")
                            line.setLength(0); truncated = false
                        } else if (line.length < 4096) line.append(character) else truncated = true
                    }
                }
                if (line.isNotEmpty()) record(job, line.toString())
            }
            // The native supervisor remains in the app group. Android 5's
            // ProcessManager uses waitpid(0), so it cannot reap a detached worker.
            val exit = process.waitFor()
            job.control.markExited()
            exitObserved = true
            synchronized(lock) {
                job.exitCode = exit
                if (!job.cancelled && (exit != 0 || !job.sawCompletion))
                    job.error = "Native codec did not complete (exit $exit)"
                if (exit == 0 && job.sawCompletion) job.progress = 1.0
            }
        } catch (error: Exception) {
            synchronized(lock) { job.error = error.message ?: error.javaClass.simpleName }
        } finally {
            // No caller may remove scratch while a child still owns file handles.
            val process = job.process
            if (process != null && !exitObserved) {
                stopProcess(job)
                try { job.exitCode = process.waitFor() } catch (_: InterruptedException) {
                    job.control.forceKill()
                    // waitFor clears the interrupted flag; reap before reporting finished.
                    job.exitCode = process.waitFor()
                }
            }
            synchronized(lock) {
                job.control.markExited()
                job.process = null
                job.finished = true
                if (debugLogging && job.error != null) {
                    Log.e("AEICNativeCodec", "NATIVE_FAILURE operation=${job.operation} exit=${job.exitCode}\n${job.tail.takeLast(8192)}")
                }
            }
        }
    }

    private fun record(job: Job, line: String) = synchronized(lock) {
        val lifecycle = job.control.acceptHandshake(line) || job.control.acceptExit(line)
        if (lifecycle && debugLogging) Log.i("AEICNativeCodec", line)
        if (debugLogging && (line.startsWith("ENCODE_COMPLETE ") ||
                line.startsWith("DECODE_COMPLETE ") || line.startsWith("RESULT_STATUS "))) {
            // Only final process measurements are logged in debug builds.
            Log.i("AEICNativeCodec", line)
        }
        job.tail.append(line).append('\n')
        if (job.tail.length > 65536) job.tail.delete(0, job.tail.length - 65536)
        if (line.startsWith("STAGE_END ")) {
            job.completedStages++
            job.progress = (job.completedStages.toDouble() / job.stages).coerceIn(0.0, 0.99)
        }
        if (line.startsWith("DEGRADED ")) {
            job.degraded = true
            job.recoveryEvents++
            if (job.warnings.size < 32) job.warnings.add(line.take(512))
        }
        if (line.startsWith(if (job.operation == "encode") "ENCODE_COMPLETE " else "DECODE_COMPLETE "))
            job.sawCompletion = true
    }

    private fun appOwned(file: File): Boolean {
        val roots = arrayListOf(File(app.applicationInfo.dataDir).canonicalFile)
        app.getExternalFilesDirs(null).filterNotNull().forEach { roots.add(it.canonicalFile) }
        return roots.any { file.path.startsWith(it.path + File.separator) }
    }
    private fun countStages(file: File): Int = file.useLines { lines -> lines.count { it.startsWith("stage\t") } }
    private fun stopProcess(job: Job) {
        if (job.finished || job.control.hasExited) return
        // Queue cancellation before the startup handshake. Keep reading so the
        // trusted worker group can receive TERM; its supervisor must reap it.
        job.control.cancel() // resumes a stopped group before SIGTERM
        try { controlExecutor.execute {
            Thread.sleep(500)
            synchronized(lock) {
                if (!job.finished && !job.control.hasExited && job.process != null) {
                    job.control.forceKill()
                    if (job.control.groupId == 0) job.process?.destroy()
                }
            }
        } } catch (_: java.util.concurrent.RejectedExecutionException) {
            synchronized(lock) {
                if (!job.finished && !job.control.hasExited) {
                    job.control.forceKill()
                    if (job.control.groupId == 0) job.process?.destroy()
                }
            }
        }
    }
    private fun cancel(job: Job) {
        if (job.finished) return
        job.cancelled = true
        stopProcess(job)
    }
    fun cancelAll() = synchronized(lock) {
        jobs.values.filter { !it.finished }.forEach(::cancel)
    }
    fun dispose() {
        disposed = true
        cancelAll()
        channel?.setMethodCallHandler(null)
        executor.shutdown()
        controlExecutor.shutdown()
    }
    companion object {
        const val CHANNEL = "com.meshcore.meshcore_open/native_image_codec"
        const val IDENTITY = "AEIC_SE_FT2_NCNN"
    }
}
