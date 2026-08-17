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

# A checkout may be reused only when it is the ROOT of a real work tree whose
# HEAD is the commit tagged $2. A bare repo, an interrupted clone, a stray
# directory, and a checkout left at some other tag all read as false, so each
# gets replaced rather than silently built.
#
# Compare COMMITS, not `git describe --exact-match`: several tags can point at
# one commit, and describe would then report a name other than the one asked
# for. The requested tag is usually absent outright from a clone made at the
# previous pin (`--depth 1 --branch` fetches only that one tag), which is the
# ordinary bumped-pin case and is handled by the same rev-parse failing.
at_pin() { # dir tag
    local dir="$1" tag="$2" top head want
    [ "$(git -C "$dir" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] || return 1
    # --is-inside-work-tree is not sufficient on its own: Vendor/src lives
    # inside this repo's own work tree, so a plain `mkdir Vendor/src/SDL`
    # answers "true" and then reports Waddle's HEAD. Require the work tree's
    # root to be $dir itself. `pwd -P` matches the physical path git prints.
    top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || return 1
    [ "$top" = "$(cd "$dir" && pwd -P)" ] || return 1
    head="$(git -C "$dir" rev-parse HEAD 2>/dev/null)" || return 1
    want="$(git -C "$dir" rev-parse --verify --quiet "refs/tags/$tag^{commit}")" || return 1
    [ "$head" = "$want" ]
}

# Guarding the clone on directory existence alone let a bumped SDL_TAG or
# OPENAL_TAG rebuild the OLD sources on any machine that had built once --
# no error, no warning, and a framework that did not match the pin.
fetch() { # dir url tag
    local dir="$SRC/$1"
    if [ -e "$dir" ] && ! at_pin "$dir" "$3"; then
        echo "$1: checkout is not at $3 -- replacing it"
        rm -rf "$dir"
    fi
    if [ ! -d "$dir" ]; then
        git clone --depth 1 --branch "$3" "$2" "$dir"
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
    # SDL_TEST_LIBRARY (the SDL3_test helper lib) defaults ON independently
    # of SDL_TESTS; nothing here links it, so don't build or install it.
    # SDL_CAMERA=OFF: Waddle has no camera feature, but SDL's camera subsystem
    # links AVCaptureDevice, which makes App Store validation demand an
    # NSCameraUsageDescription purpose string (ITMS-90683). Disabling it drops
    # the API reference entirely so no unused-camera permission is declared.
    build "$SRC/SDL" "$platform" \
        -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
        -DSDL_TEST_LIBRARY=OFF -DSDL_CAMERA=OFF
    # Pre-seed the check_cxx_compiler_flag() cache variable that OpenAL Soft's
    # CMakeLists.txt (~line 276/409) uses to gate -Werror=function-effects.
    # Xcode 26.2's clang has a false positive in alc/backends/coreaudio.cpp
    # (lines 646, 824): "attribute 'nonblocking' should not be added via type
    # conversion" under -Wfunction-effects, which OpenAL Soft 1.25.2 promotes
    # to -Werror for Clang 17+. check_cxx_compiler_flag() only runs its probe
    # if the result variable isn't already defined, so seeding it to OFF here
    # skips the probe and disables both the warning and the -Werror escalation
    # without touching the vendored source.
    build "$SRC/openal-soft" "$platform" \
        -DLIBTYPE=STATIC -DALSOFT_REQUIRE_COREAUDIO=ON \
        -DALSOFT_UTILS=OFF -DALSOFT_EXAMPLES=OFF -DALSOFT_EMBED_HRTF_DATA=ON \
        -DHAVE_WFUNCTION_EFFECTS=OFF
done
echo "Deps installed under $OUT/{iphoneos,iphonesimulator}"
