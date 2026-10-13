package com.meshcore.meshcore_open;

import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

/** Exercises the real JNI/process owner on the host, including queued cancel. */
public final class NativeImageWorkerTest {
    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    private static byte[] pixels(int dimension) {
        byte[] bytes = new byte[dimension * dimension * 4];
        for (int i = 0; i < bytes.length; i += 4) {
            bytes[i] = (byte)(i % 256);
            bytes[i + 1] = (byte)((i / 16) % 256);
            bytes[i + 2] = (byte)((i / 64) % 256);
            bytes[i + 3] = (byte)255;
        }
        return bytes;
    }

    private static void failure(Runnable action, String expected) {
        try {
            action.run();
            throw new AssertionError("Expected native failure: " + expected);
        } catch (IllegalStateException error) {
            check(error.getMessage().contains(expected), error.getMessage());
        }
    }

    public static void main(String[] args) throws Exception {
        System.load(args[0]);
        String worker = args[1];
        String stalledWorker = args[2];
        MeshcoreImageNative nativeCodec = new MeshcoreImageNative();

        byte[] encoded = nativeCodec.run(worker, 0, 1, 128, 128, 30, pixels(128), 30000, nativeCodec.token());
        byte[] decoded = nativeCodec.run(worker, 1, 1, 0, 0, 30, encoded, 30000, nativeCodec.token());
        check(encoded.length > 0 && decoded.length == 8 + 128 * 128 * 4, "Real JNI WebP roundtrip failed");

        long oldGeneration = nativeCodec.token();
        nativeCodec.cancel();
        long started = System.nanoTime();
        failure(() -> nativeCodec.run(stalledWorker, 0, 1, 512, 512, 30, pixels(512), 120000, oldGeneration), "cancelled");
        check(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started) < 1000, "A queued cancelled job started work");

        started = System.nanoTime();
        failure(() -> nativeCodec.run(stalledWorker, 0, 1, 512, 512, 30, pixels(512), 40, nativeCodec.token()), "deadline");
        check(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started) < 1000, "Deadline did not stop a blocked input pipe");

        var executor = Executors.newSingleThreadExecutor();
        try {
            long generation = nativeCodec.token();
            var future = executor.submit(() -> {
                failure(() -> nativeCodec.run(stalledWorker, 0, 1, 512, 512, 30, pixels(512), 120000, generation), "cancelled");
            });
            Thread.sleep(50);
            started = System.nanoTime();
            nativeCodec.cancel();
            future.get(1, TimeUnit.SECONDS);
            check(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started) < 1000, "Active cancellation did not reap the process");
        } finally {
            executor.shutdownNow();
        }

        encoded = nativeCodec.run(worker, 0, 2, 64, 64, 30, pixels(64), 30000, nativeCodec.token());
        check(encoded.length > 0, "Native worker ownership was not released after cancellation");
        System.out.println("PASS: JNI real roundtrip, queued cancellation, input-pipe deadline, active cancellation, and next-codec ownership");
    }
}

final class MeshcoreImageNative {
    native byte[] run(String path, int operation, int codec, int width, int height, int quality, byte[] input, int deadlineMs, long generation);
    native void cancel();
    native long token();
}
