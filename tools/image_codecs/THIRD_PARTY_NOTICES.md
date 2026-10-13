# Native image codec sources and notices

This software is based in part on the work of the Independent JPEG Group.

The codec worker uses these upstream libraries. Source archives are checked
against SHA-256 values in `fetch_native_sources.py`; libaom is checked against
its exact Git commit. No remote source is fetched while compressing an image.
Complete license and patent grant notices are packaged in the APK under
`assets/image_codecs/licenses/`.

| Library | Pinned source | License |
| --- | --- | --- |
| libwebp | [1.5.0](https://chromium.googlesource.com/webm/libwebp/+/refs/tags/v1.5.0) | BSD-3-Clause; patent grant |
| libavif | [1.2.1](https://github.com/AOMediaCodec/libavif/tree/v1.2.1) | BSD-2-Clause |
| libaom | [3b624af45b86646a20b11a9ff803aeae588cdee6](https://aomedia.googlesource.com/aom/+/3b624af45b86646a20b11a9ff803aeae588cdee6) | BSD-2-Clause; patent grant |
| OpenJPEG | [2.5.3](https://github.com/uclouvain/openjpeg/tree/v2.5.3) | BSD-2-Clause |
| libjxl | [0.11.1](https://github.com/libjxl/libjxl/tree/v0.11.1) | BSD-3-Clause; patent grant |
| Highway | [457c891775a7397bdb0376bb1031e6e027af1c48](https://github.com/google/highway/tree/457c891775a7397bdb0376bb1031e6e027af1c48) | Apache-2.0 |
| Brotli | [36533a866ed1ca4b75cf049f4521e4ec5fe24727](https://github.com/google/brotli/tree/36533a866ed1ca4b75cf049f4521e4ec5fe24727) | MIT |
| skcms | [42030a771244ba67f86b1c1c76a6493f873c5f91](https://github.com/google/skcms/tree/42030a771244ba67f86b1c1c76a6493f873c5f91) | BSD-3-Clause |
| libjpeg-turbo | [3.1.0](https://github.com/libjpeg-turbo/libjpeg-turbo/tree/3.1.0) | IJG/BSD; SIMD and TurboJPEG API disabled |
| libpng | [1.6.47](https://github.com/pnggroup/libpng/tree/v1.6.47) | PNG Reference Library License |
| zlib | Android NDK/system zlib | zlib |
| Kvazaar | [2.3.2](https://github.com/ultravideo/kvazaar/tree/v2.3.2) | BSD-3-Clause |
| libheif | [1.23.6](https://github.com/strukturag/libheif/tree/v1.23.6) | LGPL-3.0-or-later; replaceable shared library |
| libde265 | [1.1.3](https://github.com/strukturag/libde265/tree/v1.1.3) | LGPL-3.0-or-later; replaceable shared library |
| VVenC | [1.14.0](https://github.com/fraunhoferhhi/vvenc/tree/v1.14.0) | Clear BSD; no patent license grant |
| VVdeC | [3.2.1](https://github.com/fraunhoferhhi/vvdec/tree/v3.2.1) | Clear BSD; no patent license grant |
| libbpg and bundled x265 | [libbpg 0.9.8](https://bellard.org/bpg/libbpg-0.9.8.tar.gz) | Separate GPL-2.0-or-later worker; FFmpeg decoder LGPL-2.1-or-later |

The source cache defaults to `~/.cache/meshcore-image-codecs-v1`. Set
`MESHCORE_IMAGE_CODEC_SOURCES` when a different cache is needed. To provision
an offline build, run the fetch script while online, then keep that verified
cache. CMake reuses its verified markers and checks the libaom checkout.

```sh
python3 tools/image_codecs/fetch_native_sources.py
cmake -S android/app/src/main/cpp/image -B .build/image-codec-native-host -DCMAKE_BUILD_TYPE=Release
cmake --build .build/image-codec-native-host --target mesh_image_worker -j 4
python3 tools/image_codecs/test_native_worker.py --worker .build/image-codec-native-host/worker/libmesh_image_worker.so
```

`NativeImageWorkerTest.java` exercises the JNI process owner with a host JVM.
Configure the host CMake build with `MESHCORE_IMAGE_CODEC_JNI_HOST_TESTS=ON`
and the appropriate `JAVA_HOME`, build `mesh_image_codec`, compile the Java
test, and pass it the absolute JNI library, real worker, and
`stalled_test_worker.py` paths. It checks a real roundtrip, cancellation before
a queued job starts, a deadline while the input pipe is full, active process
cancellation, and a successful next operation after the child is reaped.

On Android, CMake packages a PIE executable as `libmesh_image_worker.so` and a
small JNI bridge as `libmesh_image_codec.so`. The parent only forks to perform
an immediate `execve`; no image library, allocator, or Java call runs between
fork and exec. Each codec runs in a fresh process with a 192 MiB address-space
limit and 512 x 512 pixel limit. The parent enforces the supplied wall-clock
deadline, capped at 120 seconds, and kills and reaps the worker on cancellation.
It drains bounded pipe output while feeding input, so a full pipe cannot bypass
the deadline. The Kotlin cancellation result waits until that worker has been
reaped before allowing the next algorithm.

All encoders start from pixels. JPEG omits APP and comment markers; PNG retains
only critical chunks; WebP has no metadata chunks; AVIF has no EXIF, XMP, or ICC
payload; JPEG XL uses a raw codestream without metadata boxes; JPEG 2000 uses
a raw J2K codestream with the OpenJPEG comment removed. HEIC disables Kvazaar's
optional encoder-identification and decoded-picture-hash SEI payloads, and
does not add EXIF, XMP, or ICC properties. VVC removes SEI, filler, and AUD NALs.
RGB-only codecs require
transparent inputs to be flattened by the caller. Decoding produces RGBA for
the app's PNG preview and received-image display.

BPG uses a separate `libmesh_bpg_worker.so` executable, sharing only the bounded
pipe protocol with the main worker. It never links the main worker's LGPL3
HEIC libraries. See [BPG source and licensing](BPG_NOTICES.md) for the exact
upstream archive and deterministic build changes. The full GPL2 and LGPL2.1
texts and original wrapper notice are included in the APK.

A requested codec is never returned as available unless its encoder and decoder are packaged.
The existing AEIC model backend is independent of these native codecs and
cannot fit into the 32-bit phone process.

`heic_sources.cmake` builds a scalar Kvazaar library with generated files in a
per-ABI build directory. Its generated `cfg.c` disables optional SEI metadata,
picture hashes, and parallel frame workers. libde265's copied CMake build
renames its `dist` target to avoid a collision with libaom. VVenC's CMake module
path is corrected for use within this project. These downstream build changes
are deterministic and recorded in the supplied source/build scripts.

libheif and libde265 remain separate shared libraries. Their exact upstream
source URLs and digest checks above, plus the complete worker source and CMake
scripts in this repository, provide the material needed to rebuild and relink
the worker with modified libraries. Replace `libheif.so` and `libde265.so` in an
APK built from this source to use your rebuilt versions. This permission to
modify, rebuild, and replace the LGPL components is not restricted by the app.
