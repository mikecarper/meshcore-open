# Native FT2 image codec

The packaged executable is a PIE ELF named `libaeic_codec_exec.so`, with
API21 builds for `armeabi-v7a` and `arm64-v8a`. Gradle uses legacy native
library packaging so the executable is extracted into `nativeLibraryDir`.
The process plugin passes argument lists directly to ProcessBuilder, and
creates all temporary input/output files under its private cache directory.
USB activity hooks are preserved. Native models install separately.

The native source and reproducible build recipe are in `tools/aeic_native/`.
Build on Linux with CMake, Git, ripgrep, and Android NDK29.0.14206865:

```sh
bash tools/aeic_native/build_android.sh "$ANDROID_NDK_HOME" \
  /path/to/meshcore-open/android/app/src/main/jniLibs /path/to/build-native
```

ncnn is pinned to commit `b0f97f43f266617ff5e5096d440dbe3f9a4c35b8`, with
version 20261013, CPU inference, NEON, static C++ and OpenMP. Vulkan is disabled.
Modern ARM82/SVE extensions are disabled for the ARM64 build. Native stage
arithmetic stays FP32, while renderer disk weights may be FP16. The entropy
model remains FP32. Direct allocators release intermediates and avoid the
ncnn local-pool output clone. Tiled attention considers all keys. Large skip
tensors can spill to bounded scratch files, and eligible adds reuse owned
tensor storage. The updated 576-pixel host decode used 312.7 MiB peak RSS
(previously 561.4 MiB), took 133.567 seconds, and preserved all 511 FP32
tensor hashes and final PNG bytes. All ten native CTests pass, including
paused-time deadline accounting and app-process supervision. The current
ARMv7 build completed the supervised 576-pixel app cycle. The historical CLI
and 128-pixel app measurements below used earlier builds.

The app launches with `--supervise`. The direct Java child stays in the
app's process group, while a supervised worker has its own group for
pause/resume/cancel. The supervisor reaps that worker and reports its exit
before returning to Java. This accommodates Android 5.1's
[ProcessManager process-group reaper](https://android.googlesource.com/platform/libcore/+/5d930ca/luni/src/main/java/java/lang/ProcessManager.java),
which otherwise misses a direct child moved into a separate group. Trusted
`PROCESS_INFO` and `PROCESS_EXIT` records limit control signals to the active
worker. Host tests cover completion, stop/continue, cancellation, interrupted
waits, parent death, and zombie-free reaping. Android 5.1 phone checks now
verify pause/resume, cancellation, full 576-pixel completion, and clean reaping.

Current prebuilts:

| ABI | SHA256 | Validation |
|---|---|---|
| armeabi-v7a | `4b6cd2babc3b1b5385cd996812976665210da640808e330b02ad2ab9094f2d1f` | Android 5.1 supervised 576-pixel app cycle and controls verified |
| arm64-v8a | `160e8ed01abcdf13dd74f8ea75b8fc3b2c1946982b6b122c159cff57372326e4` | Cross-compiled; hardware interoperability still needs a device |

Host CTest covers entropy, damaged streams, isolated process recovery,
output ownership, streaming statistics, native attention equivalence, and
PNG encoding. `validate_recovery.py` checks strict rejection and best-effort
behavior against actual model fixtures. Pinned sources/flags permit repeatable
functional builds; toolchain paths/build IDs may affect binary hashes.

The native bundle ID is `AEIC_SE_FT2_NCNN`, separate from legacy FT32 data.
It supports 128 through 576 in steps of 64. The install root contains
`codec128` through `codec576` configs and shared weights. Each selected codec
folder supplies `metadata.tsv`, `codec.tsv`, `encoder.tsv`, and `renderer.tsv`.
The backend receives and produces packed RGB for the actual selected size.
Recovery is opt-in; `DEGRADED` warnings and recovery counts travel with results.

The complete eight-size bundle shares weights and occupies 2,036,938,808 bytes
of regular model assets (about 2 GB), separately from the APK. Importing an archive
or replacing an existing installation can require additional temporary disk space.
The settings page can also validate an already installed private model directory.
Decoding loads and releases individual graphs; the measured 576-pixel app run
took about 41 minutes on the 1 GB Android 5.1 handset. Earlier full native CLI
reconstruction passed at:

| Image size | Phone-generated file | Full CLI decode time | Peak RSS |
| --- | ---: | ---: | ---: |
| 128 × 128 | 137 bytes | 114.477 seconds | 236.5 MiB |
| 256 × 256 | 407 bytes | 367.101 seconds | 242.7 MiB |
| 512 × 512 | 1,363 bytes | 1,664.579 seconds | 550.5 MiB |

These are native CLI measurements. The real Android 5.1 app-service cycle at
128 pixels has also passed: encoding produced the original CPU codec's exact
137-byte stream, and decoding produced a 41,372-byte PNG with 49,152 RGB bytes
and `degraded=false`.

| App image size | Operation | Service wall time | Native process wall time | Native process peak RSS |
| --- | --- | ---: | ---: | ---: |
| 128 × 128 | Encode | 3,565 ms | 2.474 seconds | 119,252 KiB (116.5 MiB) |
| 128 × 128 | Decode | 124,263 ms | 123.770 seconds | 242,384 KiB (236.7 MiB) |
| 576 × 576 | Encode | 12,984 ms | 12.553 seconds | 98,024 KiB (95.7 MiB) |
| 576 × 576 | Decode | 2,465,714 ms | 2,465.188 seconds | 294,092 KiB (287.2 MiB) |

The actual Dart installer validated all 2 GB of shared assets and all 4,192
controlled links. The supervised 576-pixel app cycle encoded the original CPU
codec's exact 1,783-byte stream and fully decoded that same file into a
755,951-byte PNG containing 995,328 RGB bytes, with `degraded=false`.
The 576-pixel service and native wall times include a deliberate 1.249-second
pause. The native peak is process RSS; it does not include the Flutter app.

The result differs from the CPU reference by 0.508 RGB8 levels on average
(50.441 dB PSNR). It remains lossy: PSNR against the scaled original is
16.924 dB. The app input pixels match that scaled source exactly. The earlier
app decode exceeded phone memory; the updated memory plan completed this run.
The 576-pixel best-effort memory requirement remains unverified on the phone.

A 128-pixel job was paused and cancelled: the kernel reported a stopped worker,
the worker was reaped, no PNG was returned, and active jobs returned to zero.
The 576-pixel worker was observed stopped and then running after resume. Its
successful completion reported clean `PROCESS_EXIT`, with no codec processes
or active jobs left. Benchmark provenance and files are in the
[AEIC phone examples](https://github.com/mikecarper/AEIC/tree/main/mobile/examples/pixnio).

All eight benchmark phone encodings match the original CPU codec byte for byte.
The CC0 river photograph produces files from 137 bytes at 128 pixels to 1,783
bytes at 576 pixels, including the header. Other photos can produce larger files;
the sender checks the 2,369-byte transport capacity before sending. Export
instructions and benchmark provenance are in the
[AEIC mobile port on main](https://github.com/mikecarper/AEIC/tree/main/mobile).

The source integration on `dev` was validated with 881 legacy Flutter tests,
37 modern wire/preview/recovery tests, two modern compatibility tests, and
three build-profile preparation/packaging tests. This compatibility-branch port
preserves its existing fleet/DFU/OTA/USB features, legacy dependency lock,
modern API28 minimum, and explicit signing safeguards. Build-tool checks require
the codec executable plus the existing firmware catalog and legacy CA assets.
The `--trial` option uses a separate application ID so an existing install can
retain its data.

The send preview measures actual compressed bytes and preparation time for
each tried size of the current photo, caches those choices, and estimates
local LoRa send time using encrypted origin packet framing, parity, scope,
and the sender's queue cadence. Routing and channel contention can add time.
The preview and estimator pass 84 focused Flutter tests. Paused time is
excluded from measured preparation and native recovery-stage deadlines.

Cancellation terminates the process and waits for completion before deleting
its workspace. Hard worker-isolate teardown must call `cancelAll()` first;
native processes are independent of the Dart isolate. Per-stage recovery
children die if their parent process exits.

License texts and attributions are packaged in Android assets under
`native_codec_licenses/`. Do not omit them when replacing prebuilts.
