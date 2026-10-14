#!/usr/bin/env bash
set -euo pipefail
# Usage: build_cpu_avx2.sh NCNN_SOURCE FRONTEND_SOURCE OUTPUT_DIR
ncnn_source=$(realpath "$1")
frontend_source=$(realpath "$2")
task_build=$(realpath -m "$3")
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
expected_commit=b0f97f43f266617ff5e5096d440dbe3f9a4c35b8
[[ $(git -C "$ncnn_source" rev-parse HEAD) == "$expected_commit" ]] || { echo 'Unexpected ncnn commit' >&2; exit 1; }
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || { echo 'Requires Linux x86_64' >&2; exit 1; }
for feature in avx2 fma f16c; do
  rg -q "\b${feature}\b" /proc/cpuinfo || { echo "Missing CPU feature: $feature" >&2; exit 1; }
done
patch_file="$script_dir/patches/ncnn-fp16-buffer.patch"
printf '%s  %s\n' a5917f6be1996caf7756b548459f8db6f4d8d980d9a00e2e225c1dbea5d0effa "$patch_file" | sha256sum --check --status
git -C "$ncnn_source" diff --cached --exit-code --quiet
if git -C "$ncnn_source" apply --reverse --check "$patch_file" >/dev/null 2>&1; then
  :
elif git -C "$ncnn_source" diff --exit-code --quiet && git -C "$ncnn_source" apply --check "$patch_file"; then
  git -C "$ncnn_source" apply "$patch_file"
else
  echo 'Cannot apply pinned allocation correction cleanly' >&2
  exit 1
fi
git -C "$ncnn_source" diff --exit-code --quiet -- . ':!src/modelbin.cpp'
git -C "$ncnn_source" diff --no-ext-diff --no-color --src-prefix=a/ --dst-prefix=b/ --unified=3 -- src/modelbin.cpp | sed '1,2d; s/^\(@@.*@@\).*$/\1/' | cmp --silent - "$patch_file"
mkdir -p "$task_build"
ncnn_options=(
  -DCMAKE_BUILD_TYPE=Release
  -DNCNN_VERSION=20261013
  -DNCNN_BUILD_TOOLS=OFF
  -DNCNN_BUILD_EXAMPLES=OFF
  -DNCNN_BUILD_BENCHMARK=OFF
  -DNCNN_BUILD_TESTS=OFF
  -DNCNN_VULKAN=OFF
  -DNCNN_OPENMP=ON
  -DNCNN_SIMPLEOMP=OFF
  -DNCNN_RUNTIME_CPU=OFF
  -DNCNN_SSE2=ON
  -DNCNN_AVX=ON
  -DNCNN_AVX2=ON
  -DNCNN_FMA=ON
  -DNCNN_F16C=ON
  -DNCNN_FMA4=OFF
  -DNCNN_XOP=OFF
  -DNCNN_AVX512=OFF
  -DNCNN_AVX512VNNI=OFF
  -DNCNN_AVX512BF16=OFF
  -DNCNN_AVX512FP16=OFF
  -DNCNN_AVXVNNI=OFF
  -DNCNN_AVXVNNIINT8=OFF
  -DNCNN_AVXVNNIINT16=OFF
  -DNCNN_INT8=OFF
  -DNCNN_BF16=OFF
  -DWITH_LAYER_absval=OFF
  -DWITH_LAYER_argmax=OFF
  -DWITH_LAYER_batchnorm=ON
  -DWITH_LAYER_bias=OFF
  -DWITH_LAYER_bnll=ON
  -DWITH_LAYER_concat=ON
  -DWITH_LAYER_convolution=ON
  -DWITH_LAYER_crop=ON
  -DWITH_LAYER_deconvolution=OFF
  -DWITH_LAYER_dropout=OFF
  -DWITH_LAYER_eltwise=OFF
  -DWITH_LAYER_elu=ON
  -DWITH_LAYER_embed=OFF
  -DWITH_LAYER_exp=OFF
  -DWITH_LAYER_flatten=ON
  -DWITH_LAYER_innerproduct=ON
  -DWITH_LAYER_input=ON
  -DWITH_LAYER_log=OFF
  -DWITH_LAYER_lrn=OFF
  -DWITH_LAYER_memorydata=ON
  -DWITH_LAYER_mvn=OFF
  -DWITH_LAYER_pooling=OFF
  -DWITH_LAYER_power=OFF
  -DWITH_LAYER_prelu=ON
  -DWITH_LAYER_proposal=OFF
  -DWITH_LAYER_reduction=ON
  -DWITH_LAYER_relu=ON
  -DWITH_LAYER_reshape=ON
  -DWITH_LAYER_roipooling=OFF
  -DWITH_LAYER_scale=ON
  -DWITH_LAYER_sigmoid=ON
  -DWITH_LAYER_slice=ON
  -DWITH_LAYER_softmax=ON
  -DWITH_LAYER_split=ON
  -DWITH_LAYER_spp=OFF
  -DWITH_LAYER_tanh=ON
  -DWITH_LAYER_threshold=OFF
  -DWITH_LAYER_tile=OFF
  -DWITH_LAYER_rnn=OFF
  -DWITH_LAYER_lstm=OFF
  -DWITH_LAYER_binaryop=ON
  -DWITH_LAYER_unaryop=OFF
  -DWITH_LAYER_convolutiondepthwise=ON
  -DWITH_LAYER_padding=ON
  -DWITH_LAYER_squeeze=ON
  -DWITH_LAYER_expanddims=ON
  -DWITH_LAYER_normalize=OFF
  -DWITH_LAYER_permute=ON
  -DWITH_LAYER_priorbox=OFF
  -DWITH_LAYER_detectionoutput=OFF
  -DWITH_LAYER_interp=ON
  -DWITH_LAYER_deconvolutiondepthwise=OFF
  -DWITH_LAYER_shufflechannel=OFF
  -DWITH_LAYER_instancenorm=OFF
  -DWITH_LAYER_clip=ON
  -DWITH_LAYER_reorg=ON
  -DWITH_LAYER_yolodetectionoutput=OFF
  -DWITH_LAYER_quantize=OFF
  -DWITH_LAYER_dequantize=OFF
  -DWITH_LAYER_yolov3detectionoutput=OFF
  -DWITH_LAYER_psroipooling=OFF
  -DWITH_LAYER_roialign=OFF
  -DWITH_LAYER_packing=ON
  -DWITH_LAYER_requantize=OFF
  -DWITH_LAYER_cast=ON
  -DWITH_LAYER_hardsigmoid=OFF
  -DWITH_LAYER_selu=OFF
  -DWITH_LAYER_hardswish=ON
  -DWITH_LAYER_noop=OFF
  -DWITH_LAYER_pixelshuffle=ON
  -DWITH_LAYER_deepcopy=OFF
  -DWITH_LAYER_mish=ON
  -DWITH_LAYER_statisticspooling=OFF
  -DWITH_LAYER_swish=ON
  -DWITH_LAYER_gemm=ON
  -DWITH_LAYER_groupnorm=ON
  -DWITH_LAYER_layernorm=ON
  -DWITH_LAYER_softplus=ON
  -DWITH_LAYER_gru=OFF
  -DWITH_LAYER_multiheadattention=ON
  -DWITH_LAYER_gelu=ON
  -DWITH_LAYER_convolution1d=OFF
  -DWITH_LAYER_pooling1d=OFF
  -DWITH_LAYER_convolutiondepthwise1d=OFF
  -DWITH_LAYER_convolution3d=OFF
  -DWITH_LAYER_convolutiondepthwise3d=OFF
  -DWITH_LAYER_pooling3d=OFF
  -DWITH_LAYER_matmul=OFF
  -DWITH_LAYER_deconvolution1d=OFF
  -DWITH_LAYER_deconvolutiondepthwise1d=OFF
  -DWITH_LAYER_deconvolution3d=OFF
  -DWITH_LAYER_deconvolutiondepthwise3d=OFF
  -DWITH_LAYER_einsum=OFF
  -DWITH_LAYER_deformableconv2d=OFF
  -DWITH_LAYER_glu=OFF
  -DWITH_LAYER_fold=OFF
  -DWITH_LAYER_unfold=OFF
  -DWITH_LAYER_gridsample=OFF
  -DWITH_LAYER_cumulativesum=OFF
  -DWITH_LAYER_copyto=OFF
  -DWITH_LAYER_erf=OFF
  -DWITH_LAYER_diag=OFF
  -DWITH_LAYER_celu=OFF
  -DWITH_LAYER_shrink=OFF
  -DWITH_LAYER_rmsnorm=OFF
  -DWITH_LAYER_spectrogram=OFF
  -DWITH_LAYER_inversespectrogram=OFF
  -DWITH_LAYER_flip=OFF
  -DWITH_LAYER_sdpa=OFF
  -DWITH_LAYER_rotaryembed=OFF
  -DNCNN_AVXNECONVERT=OFF
)
cmake -S "$ncnn_source" -B "$task_build/ncnn-build" -DCMAKE_INSTALL_PREFIX="$task_build/ncnn-install" "${ncnn_options[@]}"
cmake --build "$task_build/ncnn-build" -j "${JOBS:-2}"
cmake --install "$task_build/ncnn-build"
cmake -S "$frontend_source" -B "$task_build/frontend-build" -DCMAKE_BUILD_TYPE=Release -Dncnn_DIR="$task_build/ncnn-install/lib/cmake/ncnn"
cmake --build "$task_build/frontend-build" -j "${JOBS:-2}"
ctest --test-dir "$task_build/frontend-build" --output-on-failure
