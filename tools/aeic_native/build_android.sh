#!/usr/bin/env bash
set -euo pipefail

# Usage: build_android.sh NDK_DIRECTORY JNILIBS_DIRECTORY [BUILD_DIRECTORY]
native_src=$(cd -- "$(dirname -- "$0")" && pwd)
ndk_dir=${1:?Pass Android NDK29.0.14206865 directory}
jni_dir=${2:?Pass app android/app/src/main/jniLibs directory}
build_dir=${3:-"$native_src/.android-build"}
ncnn_commit=b0f97f43f266617ff5e5096d440dbe3f9a4c35b8
test -f "$ndk_dir/source.properties"
rg -q 'Pkg.Revision = 29.0.14206865' "$ndk_dir/source.properties"
mkdir -p "$build_dir" "$jni_dir"
ncnn_src=${NCNN_SOURCE_DIR:-"$build_dir/ncnn-source"}
if ! test -d "$ncnn_src/.git"; then
    git clone https://github.com/Tencent/ncnn.git "$ncnn_src"
    git -C "$ncnn_src" checkout --detach "$ncnn_commit"
fi
test "$(git -C "$ncnn_src" rev-parse HEAD)" = "$ncnn_commit"
git -C "$ncnn_src" diff --exit-code --quiet
toolchain="$ndk_dir/build/cmake/android.toolchain.cmake"
strip_bin="$ndk_dir/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"

for abi in armeabi-v7a arm64-v8a; do
    cmake -S "$ncnn_src" -B "$build_dir/ncnn-$abi" \
        -DCMAKE_TOOLCHAIN_FILE="$toolchain" -DANDROID_ABI="$abi" \
        -DANDROID_PLATFORM=android-21 -DANDROID_STL=c++_static \
        -DANDROID_ARM_NEON=ON -DCMAKE_BUILD_TYPE=Release -DNCNN_VERSION=20261013 \
        -DNCNN_VULKAN=OFF -DNCNN_BUILD_TOOLS=OFF -DNCNN_BUILD_EXAMPLES=OFF \
        -DNCNN_BUILD_BENCHMARK=OFF -DNCNN_BUILD_TESTS=OFF \
        -DNCNN_ARM82=OFF -DNCNN_ARM82DOT=OFF -DNCNN_ARM82FP16FML=OFF \
        -DNCNN_ARM84BF16=OFF -DNCNN_ARM84I8MM=OFF \
        -DNCNN_ARM86SVE=OFF -DNCNN_ARM86SVE2=OFF \
        -DCMAKE_INSTALL_PREFIX="$build_dir/ncnn-install-$abi"
    cmake --build "$build_dir/ncnn-$abi" -j "${BUILD_JOBS:-4}"
    cmake --install "$build_dir/ncnn-$abi"
    cmake -S "$native_src" -B "$build_dir/codec-$abi" \
        -DCMAKE_TOOLCHAIN_FILE="$toolchain" -DANDROID_ABI="$abi" \
        -DANDROID_PLATFORM=android-21 -DANDROID_STL=c++_static \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
        -Dncnn_DIR="$build_dir/ncnn-install-$abi/lib/cmake/ncnn"
    cmake --build "$build_dir/codec-$abi" -j "${BUILD_JOBS:-4}"
    mkdir -p "$jni_dir/$abi"
    cp "$build_dir/codec-$abi/aeic_decode" "$jni_dir/$abi/libaeic_codec_exec.so"
    "$strip_bin" --strip-unneeded "$jni_dir/$abi/libaeic_codec_exec.so"
    sha256sum "$jni_dir/$abi/libaeic_codec_exec.so"
done
