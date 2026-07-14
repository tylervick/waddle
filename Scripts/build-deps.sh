#!/bin/bash
# Builds SDL3 and OpenAL Soft as static libs for iOS device + simulator.
set -euo pipefail
SDL_TAG="release-3.4.12"
OPENAL_TAG="1.25.2"
IOS_DEPLOYMENT_TARGET="26.0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Vendor/src"
OUT="$ROOT/Vendor/out"
mkdir -p "$SRC"

fetch() { # dir url tag
    if [ ! -d "$SRC/$1" ]; then
        git clone --depth 1 --branch "$3" "$2" "$SRC/$1"
    fi
}
fetch SDL https://github.com/libsdl-org/SDL.git "$SDL_TAG"
fetch openal-soft https://github.com/kcat/openal-soft.git "$OPENAL_TAG"

build() { # srcdir platform extra-cmake-args...
    local src="$1" platform="$2"
    shift 2
    local bdir="$ROOT/Vendor/build/$(basename "$src")-$platform"
    cmake -S "$src" -B "$bdir" -G Ninja \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="$platform" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$OUT/$platform" \
        "$@"
    cmake --build "$bdir"
    cmake --install "$bdir"
}

for platform in iphoneos iphonesimulator; do
    build "$SRC/SDL" "$platform" \
        -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF
    build "$SRC/openal-soft" "$platform" \
        -DLIBTYPE=STATIC -DALSOFT_REQUIRE_COREAUDIO=ON \
        -DALSOFT_UTILS=OFF -DALSOFT_EXAMPLES=OFF -DALSOFT_EMBED_HRTF_DATA=ON \
        -DCMAKE_CXX_FLAGS_INIT="-Wno-function-effects"
done
echo "Deps installed under $OUT/{iphoneos,iphonesimulator}"
