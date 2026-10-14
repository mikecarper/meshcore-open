# Native AEIC-SE encoder and decoder prototype

This native command line codec is intended for Android API 21 or later,
ARMv7 NEON, and fixed image-size exports produced by the sibling
export scripts. It requires ncnn CPU inference. It loads, runs, and destroys
one graph at a time. Float16 disk weights may reduce storage; graph weights
and arithmetic are float32 at runtime. Context graphs must retain float32
weights to preserve entropy indexes.

The encoder reads an 8-bit RGB P6 PPM, normalizes it using the original
ToTensor/Normalize float32 operation order, runs the learned analysis and
hyper analysis graphs, then uses the same four context rounds and entropy
tables to produce a regular AEIC practical bitstream. Rounding is nearest
with ties to even. It accepts dimensions from 128 through 576 in steps of 64.

The decoder reads an actual AEIC practical bitstream, decodes the original
two rANS streams with the repository's entropy arithmetic, runs four spatial
context rounds, runs codec synthesis and the complete renderer on the device,
and saves a RGB PNG or PPM. PNG compression and chunk checksums run natively
on the phone through Android's zlib. Both formats use the same RGB8 pixels.
It reports stage times, current RSS, process peak RSS,
tensor hashes, and entropy terminal-state checks. No successful decode should
be claimed until `DECODE_COMPLETE` appears and the output is inspected.

## Build

The CPU decoder defaults to `--decoder-mode fast`. Use `--decoder-mode accurate`
to retain conservative FP32 renderer kernels. Fast keeps encoder and entropy
arithmetic unchanged and uses FP32 packing plus memory-bounded F(2,3) Winograd
only in renderer graphs. Complete phone trials cover 128 and 256 pixels;
192 pixels uses the same bounded policy. Larger images automatically retain
conservative renderer kernels. The native backend currently has no usable GPU
decoder, so its CPU default is Fast.

Fast may use 16-row convolution sections when that keeps transformed weights,
padding, and temporary buffers within the checked budget. Accurate keeps the
existing 64-row memory profile. Neither mode changes transmitted file sizes.
See [the measured phone comparison](https://github.com/mikecarper/AEIC/blob/main/mobile/examples/pixnio/cpu-decoder-results.json).

`build_android.sh` pins ncnn and applies
`patches/ncnn-fp16-buffer.patch`, which corrects a byte count used to size a
float16 input buffer. Weights remain FP32 at runtime. The patch reduces loading
work without changing any weight or intermediate tensor value; the builder
rejects other tracked ncnn changes. Android links OpenMP statically, including
the custom attention head loop.

Configure ncnn for the same Android ABI, API, and static C++ runtime.

For the measured Linux x86-64 desktop profile, use
`build_cpu_avx2.sh NCNN_SOURCE mobile/native OUTPUT_DIR`. It checks AVX2,
FMA and F16C support, pins the same ncnn allocation patch, enables OpenMP,
and excludes unsupported AVX-512/AVX-NE-CONVERT kernels. The full decoder
and native tests are built together. This is a separate CPU build from the
Android ABI binaries.

A typical Android runner build after installing ncnn is:

```sh
cmake -S mobile/native -B build-android \
  -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=armeabi-v7a -DANDROID_PLATFORM=android-21 \
  -DANDROID_STL=c++_static -DCMAKE_BUILD_TYPE=Release \
  -Dncnn_DIR=/path/to/ncnn-install/lib/cmake/ncnn -DBUILD_TESTING=OFF
cmake --build build-android -j4
```

For host entropy checks without ncnn:

```sh
cmake -S mobile/native -B build-entropy -DAEIC_ENTROPY_TEST_ONLY=ON
cmake --build build-entropy
ctest --test-dir build-entropy --output-on-failure
```

## Model interface

`codec.tsv` and `renderer.tsv` contain tab-separated rows:

```text
stage<TAB>name<TAB>relative.ncnn.param<TAB>relative.ncnn.bin<TAB>slot=in0,...<TAB>slot=out0,...
set<TAB>key<TAB>value
tensor<TAB>slot<TAB>C<TAB>H<TAB>W
stage_shape<TAB>stage_name<TAB>output_slot<TAB>C<TAB>H<TAB>W
```

All persistent slots are batch-one NCHW tensors mapped to float32 CHW ncnn
Mats. Rank-three sequence tensors stay inside individual graphs. `tensor`
rows enforce stage input and output shapes; `stage_shape` overrides the output
shape for slots reused at different sizes. The runner computes slot lifetimes
from future consumers. It rejects known rank-three batch-axis Gemm exports
before inference, and normalizes retained batch-one rank-four image outputs.

Codec stages are `h_s` (`z_hat` to `base`), `ctx0` through `ctx3` (`base` to
`means_scales`, 512 channels), and ordered `g_s*` synthesis stages (`y_hat`
to intermediate `synth`, then `synthesis`, 576 channels). Native owning copies
split the final synthesis into `l_T` (320 channels) and `residual` (256 channels).
Renderer initial slots are `l_T` and `residual`, and the output slot defaults
to `rgb`. Renderer settings can change `output_slot` and `rgb_range` (either
`-1,1` or `0,1`). `metadata.tsv` uses key/value tab-separated rows for
`y_channels`, `input_height`, and `input_width`.

`encoder.tsv` uses the same stage format. Ordered `g_a*` stages run `x`
through intermediate `analysis` to final `y`. Ordered `h_a*` stages run
`y` through intermediate `hyper` to final `z`. Encoding shares the `h_s`
and `ctx0` through `ctx3` graphs in `codec.tsv` with decoding.

Entropy files are `z_cdf.bin`, `y_cdf.bin`, and `z_medians.f32` (128 floats).
Each CDF file contains the eight-byte ASCII magic `AEICCDF1`, uint32 little
endian row and column counts, int32 row lengths, int32 offsets, then the
padded row-major int32 CDF matrix. Raw float and int16 debug files are little
endian CHW arrays without headers.

## Run and verify

Encode on the phone:

```sh
./aeic_decode --encode --model-dir /data/local/tmp/aeic/model256 \
  --input /data/local/tmp/aeic/input.ppm \
  --bitstream-output /data/local/tmp/aeic/phone-encoded.aeic --threads 2
```

The current codec analysis, hyperprior, context, and synthesis graph exports
are byte-identical at both resolutions. `--model-size 512` overrides 256
pixel metadata when reusing those graphs for 512 pixel encoding or an
entropy-only decoding test. A full decode still needs the renderer graph
parameters exported for its actual image size.

The regular encoder/decoder accepts 128, 192, 256, 320, 384, 448, 512, and 576 pixel
dimensions. `--model-size N` selects those dimensions when reusing codec
graphs. Full image decoding requires renderer parameter files exported for
the selected size and enough memory; accepting a size does not establish
that the phone can complete it. Hyperprior alignment uses original reflect
padding, and native contexts crop hyper synthesis to the actual latent size.

Decode that phone-generated bitstream:

```sh
./aeic_decode --model-dir /data/local/tmp/aeic/model256 \
  --bitstream /data/local/tmp/aeic/phone-encoded.aeic \
  --output /data/local/tmp/aeic/sample.png --threads 2 \
  --verify-dir /data/local/tmp/aeic/model256/references
```

Use `--spill-dir /path/to/job/scratch` for the app memory profile. The directory
must belong to the codec process. Each run creates a fresh private child
directory and removes only its own files on normal exit or exceptions. The app
also removes its job workspace after cancellation. Retained renderer tensors
are stored as exact FP32 CHW bytes with streamed checksums, bounded I/O, and
page-cache release advice. Current tensors stay in memory; restoring a skip
does not alter its values. Large 1x1 and same-padding 3x3 convolutions, including
nearest-neighbor upsampling graphs, run in 64-row sections with valid halos.
Consumed inputs may reuse uniquely owned storage. Shared aliases are preserved.
Encoder and entropy arithmetic are unchanged by this option.

Linux and Android jobs create their own process group and emit
`PROCESS_INFO pid=N group=N` before model work. The app can pause/resume that
group and must resume it before termination. A parent-death guard prevents
an app death from leaving a stopped native process behind.
App launches must add `--supervise`: Android 5's Java process reaper uses
`waitpid(0)`, so its direct launcher must remain in the app's inherited group.
The launcher forks a guarded worker, creates only that worker's signal group,
and emits the handshake before opening its inference startup gate. It waits
for the worker, terminates any remaining group members while the leader PID
is still reserved, reaps the leader, then emits `PROCESS_EXIT pid=N group=N`
before returning the worker's exit status. The app retires that group and still
waits for the Java launcher to finish before deleting the job workspace.
`--pause-time-file FILE` reads the app's cumulative paused milliseconds. Its
bounded monotonic counter excludes paused intervals from best-effort stage
deadlines; ordinary strict inference has no per-stage recovery timeout.

`validate_tensor_memory.py BASELINE_RUN CANDIDATE_RUN` verifies that completed
host runs have identical hashes for every FP32 tensor and identical saved image
bytes. Each run directory must contain `decode.log` with `DECODE_COMPLETE`.

Float references use `stage.slot.f32`, plus `z_hat.f32`, `y_hat.f32`,
`l_T.f32`, and `residual.f32`. Float differences are logged; add
`--strict-verify --verify-tolerance 0.001` to make them fatal.
Entropy references use `y0_indices.i16` through `y3_indices.i16`; any index
change is fatal, because even tiny context numerical differences can change
bitstream decoding. Optional `z_symbols.i16` and `yN_symbols.i16` check the
decoded integers exactly. `--dump-dir` saves each observed tensor and index
array to an existing directory for comparison.

The output extension selects native PNG (`.png`) or RGB PPM (otherwise).
`--verify-integers-only` keeps exact entropy index/symbol comparisons and
skips optional float reference files. Dump and verification directories must
resolve to different canonical paths, to keep generated values from replacing
the reference data.

Encoder integer references use `encode_z_indices.i16`,
`encode_z_symbols.i16`, and `encode_yN_indices.i16` /
`encode_yN_symbols.i16` for rounds zero through three. These compare
exactly against original host compression. Small floating point differences
between CPU implementations can change quantized symbols or indexes; encode
and decode must also be tested together on the phone. If an encoder context
produces a nonzero symbol at an index that the original rANS implementation
skips, this frontend rejects the image instead of writing a bitstream whose
later context rounds would disagree with decoding.

`--stop-after y_hat` tests entropy decoding alone; `--stop-after STAGE` tests
a prefix. These print `PARTIAL_TEST` and never claim a complete image decode.
Individual graph diagnostics can use `--stage-only NAME --tensor
SLOT=C,H,W:FILE.f32`, with multiple `--tensor` inputs if needed. Raw tensor
injection is disabled for full decoding.

## Optional recovery

Add `--best-effort` to try to produce an image from damaged data, reference
differences, or failed model stages. Normal behavior remains strict. Every
recovery emits `DEGRADED`; final `RESULT_STATUS` records `degraded=true` and
the event count. A recovered image is an approximation. This format has no
checksum, so some corruptions may escape entropy terminal-state checks.

Recovery uses the exported model dimensions, salvages framed stream bytes
when their boundaries remain known, and substitutes zero symbols for a
failed stream's current and later groups. A healthy stream still decodes
normally. Missing entropy tables disable entropy reconstruction; missing
hyperprior medians become zeros. Reference mismatches are reported while
the actual calculated values continue through the pipeline.

Every model loads, runs, and unloads inside a separate child process, with
shared output bounded to 256MiB and exact shape/finite-value checks before commit.
Exceptions, signals, and timeouts produce a known-shape fallback: preserve
an exact-shaped input, nearest-resize a matching-channel input, or use zeros.
Set `--stage-timeout-ms N` for a per-stage deadline (default 300000).
The parent never runs ncnn inference before forking. Logs report parent RSS
and each child's peak RSS; the overall peak includes reaped children.
This is the maximum per-process RSS, rather than the sum of simultaneous
parent and child memory.
Output transfer copies logical planes directly after the graph is destroyed;
IPC pages stay untouched during inference. The parent copies them once into
an owning Mat, then releases IPC. Parent inputs remain private, so a child's
in-place operation cannot corrupt activations retained for later stages.
This can still require extra activation memory compared with normal decoding.
Essential output-write errors fail, and encoding requires valid entropy
tables. Encoder model fallbacks may prevent interoperability with a clean
decoder even when the resulting file has valid framing.

576 exports can replace `MultiHeadAttention` with `AEICTiledAttention`.
The custom layer uses the same learned projections and considers every key,
while processing heads and query rows in bounded tiles. It reduces score
storage without changing the attention calculation. Other exports retain
the built-in layer; the frontend registers the custom type before graph load.

`--hash-file FILE` streams through a fixed 64 KiB buffer and reports byte length
and hexadecimal FNV-1a for transport checks. Add `--hash-decimal` for an unsigned
decimal FNV field. No models are loaded. Keep dump files in a different directory
from golden references.

The copies under `rans/` retain the upstream license headers. Their decoder
adds checked byte reads, index validation, and terminal-state diagnostics;
the rANS arithmetic and two-stream splitting match upstream. The encoder
also validates indexes and reserves enough space for short/high-entropy
streams; these changes preserve the emitted bytes.
