#!/bin/bash
#
# Copyright (C) 2019 The Android Open Source Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
set -eu

FFMPEG_MODULE_PATH="$1"
echo "FFMPEG_MODULE_PATH is ${FFMPEG_MODULE_PATH}"
NDK_PATH="$2"
echo "NDK path is ${NDK_PATH}"
HOST_PLATFORM="$3"
echo "Host platform is ${HOST_PLATFORM}"
ANDROID_ABI="$4"
echo "ANDROID_ABI is ${ANDROID_ABI}"
ENABLED_DECODERS=("${@:5}")
echo "Enabled decoders are ${ENABLED_DECODERS[@]}"
JOBS="$(nproc 2> /dev/null || sysctl -n hw.ncpu 2> /dev/null || echo 4)"
echo "Using $JOBS jobs for make"
COMMON_OPTIONS="
    --target-os=android
    --enable-static
    --disable-shared
    --disable-doc
    --disable-programs
    --disable-everything
    --disable-avdevice
    --disable-avformat
    --disable-swscale
    --disable-postproc
    --disable-avfilter
    --disable-symver
    --enable-swresample
    --enable-libopus
    --enable-decoder=libopus
    --disable-decoder=opus
    --pkg-config=pkg-config
    --pkg-config-flags=--static
    --extra-ldexeflags=-pie
    --disable-v4l2-m2m
    --disable-vulkan
    "
TOOLCHAIN_PREFIX="${NDK_PATH}/toolchains/llvm/prebuilt/${HOST_PLATFORM}/bin"
OPUS_SOURCE_PATH="${FFMPEG_MODULE_PATH}/jni/opus"
LIBOPUS_BUILD_ROOT="${FFMPEG_MODULE_PATH}/jni/libopus-build"
LIBOPUS_INSTALL_ROOT="${FFMPEG_MODULE_PATH}/jni/libopus"

if [[ ! -d "${TOOLCHAIN_PREFIX}" ]]
then
    echo "Please set correct NDK_PATH, $NDK_PATH is incorrect"
    exit 1
fi

if [[ ! -d "${OPUS_SOURCE_PATH}" ]]
then
    echo "Missing Opus source at ${OPUS_SOURCE_PATH}"
    exit 1
fi

for tool in cmake make pkg-config
do
    if ! command -v "${tool}" >/dev/null 2>&1
    then
        echo "Missing required tool: ${tool}"
        exit 1
    fi
done

for decoder in "${ENABLED_DECODERS[@]}"
do
    COMMON_OPTIONS="${COMMON_OPTIONS} --enable-decoder=${decoder}"
done

ARMV7_CLANG="${TOOLCHAIN_PREFIX}/armv7a-linux-androideabi${ANDROID_ABI}-clang"
if [[ ! -e "$ARMV7_CLANG" ]]
then
    echo "AVMv7 Clang compiler with path $ARMV7_CLANG does not exist"
    echo "It's likely your NDK version doesn't support ANDROID_ABI $ANDROID_ABI"
    echo "Either use older version of NDK or raise ANDROID_ABI (be aware that ANDROID_ABI must not be greater than your application's minSdk)"
    exit 1
fi
ANDROID_ABI_64BIT="$ANDROID_ABI"
if [[ "$ANDROID_ABI_64BIT" -lt 21 ]]
then
    echo "Using ANDROID_ABI 21 for 64-bit architectures"
    ANDROID_ABI_64BIT=21
fi

build_opus() {
    local cmake_abi="$1"
    local api_level="$2"
    local build_dir="${LIBOPUS_BUILD_ROOT}/${cmake_abi}"
    local install_dir="${LIBOPUS_INSTALL_ROOT}/${cmake_abi}"

    cmake -S "${OPUS_SOURCE_PATH}" -B "${build_dir}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${install_dir}" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DCMAKE_TOOLCHAIN_FILE="${NDK_PATH}/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI="${cmake_abi}" \
        -DANDROID_PLATFORM="android-${api_level}" \
        -DOPUS_BUILD_PROGRAMS=OFF \
        -DOPUS_BUILD_SHARED_LIBRARY=OFF \
        -DOPUS_BUILD_TESTING=OFF \
        -DOPUS_INSTALL_CMAKE_CONFIG_MODULE=OFF \
        -DOPUS_INSTALL_PKG_CONFIG_MODULE=ON
    cmake --build "${build_dir}" --target install --parallel "${JOBS}"
}

build_ffmpeg() {
    local ffmpeg_abi="$1"
    local arch="$2"
    local cpu="$3"
    local cross_prefix="$4"
    local api_level="$5"
    local opus_abi="$6"
    local extra_cflags="$7"
    local extra_ldflags="$8"
    local disable_asm="$9"
    local opus_prefix="${LIBOPUS_INSTALL_ROOT}/${opus_abi}"
    local pkg_config_dir="${opus_prefix}/lib/pkgconfig"
    local configure_args=(
        --libdir="android-libs/${ffmpeg_abi}"
        --arch="${arch}"
        --cpu="${cpu}"
        --cross-prefix="${TOOLCHAIN_PREFIX}/${cross_prefix}${api_level}-"
        --nm="${TOOLCHAIN_PREFIX}/llvm-nm"
        --ar="${TOOLCHAIN_PREFIX}/llvm-ar"
        --ranlib="${TOOLCHAIN_PREFIX}/llvm-ranlib"
        --strip="${TOOLCHAIN_PREFIX}/llvm-strip"
    )

    if [[ -n "${extra_cflags}" ]]
    then
        configure_args+=("--extra-cflags=${extra_cflags}")
    fi

    if [[ -n "${extra_ldflags}" ]]
    then
        configure_args+=("--extra-ldflags=${extra_ldflags}")
    fi

    if [[ "${disable_asm}" == "yes" ]]
    then
        configure_args+=(--disable-asm)
    fi

    PKG_CONFIG_PATH="${pkg_config_dir}" \
    PKG_CONFIG_LIBDIR="${pkg_config_dir}" \
    ./configure \
        "${configure_args[@]}" \
        ${COMMON_OPTIONS}
    make -j"${JOBS}"
    make install-libs
    cp "${opus_prefix}/lib/libopus.a" "android-libs/${ffmpeg_abi}/libopus.a"
    make clean
}

build_opus "armeabi-v7a" "${ANDROID_ABI}"
build_opus "arm64-v8a" "${ANDROID_ABI_64BIT}"
build_opus "x86" "${ANDROID_ABI}"
build_opus "x86_64" "${ANDROID_ABI_64BIT}"

cd "${FFMPEG_MODULE_PATH}/jni/ffmpeg"
build_ffmpeg \
    "armeabi-v7a" \
    "arm" \
    "armv7-a" \
    "armv7a-linux-androideabi" \
    "${ANDROID_ABI}" \
    "armeabi-v7a" \
    "-march=armv7-a -mfloat-abi=softfp" \
    "-Wl,--fix-cortex-a8 -L${LIBOPUS_INSTALL_ROOT}/armeabi-v7a/lib" \
    "no"
build_ffmpeg \
    "arm64-v8a" \
    "aarch64" \
    "armv8-a" \
    "aarch64-linux-android" \
    "${ANDROID_ABI_64BIT}" \
    "arm64-v8a" \
    "-I${LIBOPUS_INSTALL_ROOT}/arm64-v8a/include" \
    "-L${LIBOPUS_INSTALL_ROOT}/arm64-v8a/lib" \
    "no"
build_ffmpeg \
    "x86" \
    "x86" \
    "i686" \
    "i686-linux-android" \
    "${ANDROID_ABI}" \
    "x86" \
    "-I${LIBOPUS_INSTALL_ROOT}/x86/include" \
    "-L${LIBOPUS_INSTALL_ROOT}/x86/lib" \
    "yes"
build_ffmpeg \
    "x86_64" \
    "x86_64" \
    "x86-64" \
    "x86_64-linux-android" \
    "${ANDROID_ABI_64BIT}" \
    "x86_64" \
    "-I${LIBOPUS_INSTALL_ROOT}/x86_64/include" \
    "-L${LIBOPUS_INSTALL_ROOT}/x86_64/lib" \
    "yes"
