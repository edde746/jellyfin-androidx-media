#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

detect_host_platform() {
    local ndk_prebuilt_root="${ANDROID_NDK_PATH}/toolchains/llvm/prebuilt"
    local candidates=()

    case "$(uname -s)-$(uname -m)" in
        Linux-x86_64) candidates+=(linux-x86_64) ;;
        Darwin-x86_64) candidates+=(darwin-x86_64) ;;
        Darwin-arm64) candidates+=(darwin-arm64 darwin-x86_64) ;;
        *)
            echo "Unsupported host platform: $(uname -s)-$(uname -m)" >&2
            exit 1
            ;;
    esac

    for candidate in "${candidates[@]}"
    do
        if [[ -d "${ndk_prebuilt_root}/${candidate}" ]]
        then
            echo "${candidate}"
            return
        fi
    done

    echo "No matching NDK prebuilt toolchain found under ${ndk_prebuilt_root}" >&2
    exit 1
}

ANDROID_SDK_PATH="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [[ -z "${ANDROID_SDK_PATH}" ]]; then
    echo "ANDROID_HOME or ANDROID_SDK_ROOT must be set." >&2
    exit 1
fi

export ANDROID_NDK_PATH="${ANDROID_SDK_PATH}/ndk/26.1.10909125"
[[ ! -d "${ANDROID_NDK_PATH}" ]] && echo "No NDK found, quitting…" >&2 && exit 1

export ANDROIDX_MEDIA_ROOT="${ROOT_DIR}/media"
export FFMPEG_MOD_PATH="${ANDROIDX_MEDIA_ROOT}/libraries/decoder_ffmpeg/src/main"
export FFMPEG_PATH="${ROOT_DIR}/ffmpeg"
export OPUS_PATH="${ROOT_DIR}/opus"
export ENABLED_DECODERS=(flac alac pcm_mulaw pcm_alaw mp3 aac ac3 eac3 dca mlp truehd)

PATCH_ROOT="${ROOT_DIR}/patches/media3-libopus"

[[ ! -d "${FFMPEG_MOD_PATH}" ]] && echo "Missing Media3 decoder_ffmpeg sources. Run submodule checkout first." >&2 && exit 1
[[ ! -d "${OPUS_PATH}" ]] && echo "Missing Opus submodule checkout." >&2 && exit 1

install -m 0644 "${PATCH_ROOT}/CMakeLists.txt" "${FFMPEG_MOD_PATH}/jni/CMakeLists.txt"
install -m 0755 "${PATCH_ROOT}/build_ffmpeg.sh" "${FFMPEG_MOD_PATH}/jni/build_ffmpeg.sh"
install -m 0644 "${PATCH_ROOT}/ffmpeg_jni.cc" "${FFMPEG_MOD_PATH}/jni/ffmpeg_jni.cc"
install -m 0644 "${PATCH_ROOT}/FfmpegLibrary.java" \
    "${FFMPEG_MOD_PATH}/java/androidx/media3/decoder/ffmpeg/FfmpegLibrary.java"

ln -sfn "${FFMPEG_PATH}" "${FFMPEG_MOD_PATH}/jni/ffmpeg"
ln -sfn "${OPUS_PATH}" "${FFMPEG_MOD_PATH}/jni/opus"

cd "${FFMPEG_MOD_PATH}/jni"
./build_ffmpeg.sh "${FFMPEG_MOD_PATH}" "${ANDROID_NDK_PATH}" "$(detect_host_platform)" 23 "${ENABLED_DECODERS[@]}"
