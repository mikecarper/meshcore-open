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
ncnn local-pool output clone. Tiled attention considers all keys.

Current prebuilts:

| ABI | SHA256 | Validation |
|---|---|---|
| armeabi-v7a | `959ad2ea21a640347333725cab1345d52f78783936133e7c12f199d349dd635d` | Android5.1 native encode/decode and host checks |
| arm64-v8a | `a7e75f644c633859ab9f3bb696c6004c98b7970dcff604bf0c81d2f675fb9111` | Cross-compiled; hardware interoperability still needs a device |

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
Decoding loads and releases individual graphs; it can take several minutes on the
1 GB Android 5.1 handset. Full native CLI reconstruction has passed at:

| Image size | Phone-generated file | Full CLI decode time | Peak RSS |
| --- | ---: | ---: | ---: |
| 128 × 128 | 137 bytes | 114.477 seconds | 236.5 MiB |
| 256 × 256 | 407 bytes | 367.101 seconds | 242.7 MiB |
| 512 × 512 | 1,363 bytes | 1,664.579 seconds | 550.5 MiB |

These are native CLI measurements. The real Android 5.1 app-service cycle at
128 pixels has also passed: encoding produced the original CPU codec's exact
137-byte stream, and decoding produced a 41,372-byte PNG with 49,152 RGB bytes
and `degraded=false`.

| 128-pixel app operation | Service wall time | Native process time | Native process peak RSS |
| --- | ---: | ---: | ---: |
| Encode | 3,565 ms | 2.474 seconds | 119,252 KiB (116.5 MiB) |
| Decode | 124,263 ms | 123.770 seconds | 242,384 KiB (236.7 MiB) |

The actual Dart installer validated all 2 GB of shared assets and all 4,192
controlled links. The app's 576-pixel encoding is complete and matches the
original 1,783-byte CPU file; native encoding took 12.754 seconds with
118,768 KiB peak RSS. Its app-service decode is running; the final 576-pixel
phone PNG remains pending.

All eight benchmark phone encodings match the original CPU codec byte for byte.
The CC0 river photograph produces files from 137 bytes at 128 pixels to 1,783
bytes at 576 pixels, including the header. Other photos can produce larger files;
the sender checks the 2,369-byte transport capacity before sending. Export
instructions and benchmark provenance are in the
[AEIC mobile port on main](https://github.com/mikecarper/AEIC/tree/main/mobile),
published through [b0dba0b](https://github.com/mikecarper/AEIC/commit/b0dba0b).

Automated validation: all 881 legacy Flutter tests pass,
37 modern wire/preview/recovery tests and two modern compatibility tests pass,
and all three build-profile preparation/packaging tests pass. The normal trial
release APK was built with Flutter 3.32.8, verified as API21/ARMv7, and uses a
separate application ID so an existing install can retain its data.

Cancellation terminates the process and waits for completion before deleting
its workspace. Hard worker-isolate teardown must call `cancelAll()` first;
native processes are independent of the Dart isolate. Per-stage recovery
children die if their parent process exits.

License texts and attributions are packaged in Android assets under
`native_codec_licenses/`. Do not omit them when replacing prebuilts.
