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
tensor hashes and final PNG bytes. All twelve native CTests pass, including FP16 weight-reader patterns and
truncation, paused-time deadline accounting, and app-process supervision.
The earlier ARMv7 supervisor build completed the 576-pixel app cycle.
The final ARMv7 decoder-mode binary passed the phone CLI and app-service
checks recorded below. Historical measurements retain their build distinction.

The decoder accepts `--decoder-mode fast|accurate`. The CPU-only native
backend defaults to Fast; the app resolves an unset preference from usable
backend GPU capability and persists an explicit selection. Fast enables
renderer-only FP32 packing and bounded Winograd F(2,3) up to 256 pixels,
with full phone validation at 128 and 256. Larger sizes fall back to conservative renderer kernels. Accurate keeps
the conservative kernels; entropy and encoding remain unchanged in either
mode. OpenMP attention is explicitly compiled. The pinned ncnn patch fixes a
weight-reader buffer whose byte count had been treated as a float count;
host checks preserve the FP32 tensors for each decoder mode. The paired phone
speed measurements in the root README predate that buffer fix.

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
| armeabi-v7a | `7a1e593042f2352a825ad68d37f78f338fc82352866becf8acbb6ac22ededd8b` | Final 128-pixel Fast app-service/controls, 256-pixel Fast CLI, and normal UI verified |
| arm64-v8a | `75785ce96bf7586cb8e8a380f8c62239cda859be80bdcbdb4fbe359c7293274a` | Cross-compiled; hardware interoperability still needs a device |

## Final decoder-mode phone verification

The final ARMv7 ELF above passed full 256-pixel Fast CLI encoding and decoding:
407 bytes matched the original CPU stream, all 19 integer checks passed, native
decoding took 258.846 seconds with 244,016 KiB (238.3 MiB) peak RSS, and its PNG
was byte-identical to the preceding v2 Fast output.

A real production-service 128-pixel cycle in a release-AOT test entry point
encoded 137 bytes with SHA256
`49dc462cb8fddccb3e775f288a75756eb408375eb1432521f9531a51aecde1c7` and reconstructed
49,152 RGB bytes into a 41,372-byte PNG, with `degraded=false`. Service encoding
took 2,024 ms and decoding took 89,325 ms; native decoding took 88.928 seconds
and peaked at 238,280 KiB (232.7 MiB). The decode includes a deliberate test pause.
The temporary fixture used four threads and restored preferences; the normal
app retains its two-thread default. Accurate pause/cancel observed a stopped
worker, returned no PNG, and reaped it. Fast pause/resume observed stopped and
running kernel states, completed, and left no active jobs.

The non-debuggable normal `lib/main.dart` APK was then installed. Its image
settings showed Fast by default, accepted and saved Accurate, and were restored
to Fast. Both APKs used the same final native ELF and signer; the temporary
fixture did not replace the production entry point in Git. The historical
576-pixel app cycle below used the earlier supervisor build; final accelerated
576-pixel execution and 576-pixel best-effort memory remain unverified.

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
