#!/usr/bin/env bash
set -euo pipefail

# Usage: test_fp16_model_buffer.sh NCNN_HOST_PREFIX OUTPUT_DIRECTORY
# Use a host ncnn build at the pinned revision with patches/ncnn-fp16-buffer.patch.
native_src=$(cd -- "$(dirname -- "$0")" && pwd)
ncnn_prefix=${1:?Pass the host ncnn installation prefix}
test_dir=${2:?Pass a directory for test executables}
cxx=${CXX:-c++}
test -f "$ncnn_prefix/lib/libncnn.a"
mkdir -p "$test_dir"

common=(-std=c++14 -fopenmp "$native_src/fp16_model_buffer_test.cpp"
    -I "$ncnn_prefix/include/ncnn" "$ncnn_prefix/lib/libncnn.a"
    -lpthread -ldl -lm)
"$cxx" -O2 "${common[@]}" -o "$test_dir/fp16-model-buffer-test"
"$test_dir/fp16-model-buffer-test"
"$cxx" -O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined \
    "${common[@]}" -o "$test_dir/fp16-model-buffer-test-sanitized"
"$test_dir/fp16-model-buffer-test-sanitized"
