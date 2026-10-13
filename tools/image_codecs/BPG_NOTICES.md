# BPG source and licensing

The BPG encoder and decoder are real libbpg 0.9.8 from
[Fabrice Bellard's distribution](https://bellard.org/bpg/).
The complete corresponding source archive is
[`libbpg-0.9.8.tar.gz`](https://bellard.org/bpg/libbpg-0.9.8.tar.gz), pinned to
SHA-256 `c0788e23bdf1a7d36cb4424ccb2fae4c7789ac94949563c4ad0e2569d3bf0095`.
The archive includes the exact x265 sources used by this build.

The x265 source headers permit GPL version 2 or later. Its full GPL version 2
license is in the archive at `x265/COPYING`. The modified FFmpeg decoding
sources retain their LGPL version 2.1 or later notices. Bellard's encoder and
decoder wrappers retain their original permissive copyright/license notices.
All those notices remain in the generated build source. The bundled BPG
executable is distributed under GPL version 2 or later; the application's
existing license is unchanged.

`libmesh_bpg_worker.so` is a separate executable using the image-worker pipe
protocol. It does not link the main worker's libheif library. It contains a
scalar 8-bit encoder and one-image decoder. The parent controls its lifetime
and kills/reaps it at the compression deadline, with a maximum of 120 seconds.
The child enforces the same 192 MiB address-space, 512-pixel-axis and bounded
input/output limits as the other codecs.

The deterministic source modifications in `bpg_sources.py` remove camera-file
loaders and the unused CLI, disable thread pools and encoder-information SEI,
select small coding units for 16/32-pixel images, and bound NAL accumulation.
The memory bridge passes no EXIF, ICC, XMP, thumbnails or animation extension.
Encoding uses YCbCr 4:2:0 and keeps an alpha plane when needed. Only 8-bit still
BPG images are accepted for decode.

To fetch/build corresponding source, including all modifications:

```sh
python3 tools/image_codecs/bpg_sources.py --destination /path/to/codec-source-cache
cmake -S tools/image_codecs/bpg_test -B .build/bpg-host -DMESHCORE_IMAGE_CODEC_SOURCES=/path/to/codec-source-cache
cmake --build .build/bpg-host --target mesh_bpg_worker -j 2
```

Android builds use the same CMake inputs with the Android NDK toolchain and
`ANDROID_ABI=armeabi-v7a`, `ANDROID_PLATFORM=android-21`. Original upstream
sources stay in the cache; modified/generated sources are emitted into each
build directory. There is no source or binary download during image compression.
