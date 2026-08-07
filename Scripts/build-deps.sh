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

# A directory that already exists proves nothing about WHICH pin is inside it:
# the tags above may have moved since it was cloned. Guarding on existence
# alone meant a bumped pin silently rebuilt the old source -- no error, no
# warning, and a framework that did not match the pin. CI never caught it
# because runners start clean, so it only ever bit local checkouts.
#
# Compare the requested tag against what is actually checked out, by commit
# rather than by `git describe`: several tags can point at one commit, and
# describe would then report a name other than the one asked for. An unknown
# tag, a detached-but-different HEAD, and a directory that is not a git
# checkout at all each resolve to a mismatch and re-clone, so this also
# self-heals a half-written clone left by an interrupted run.
fetch() { # dir url tag
    local dir="$SRC/$1" want have
    if [ -d "$dir" ]; then
        want="$(git -C "$dir" rev-parse -q --verify "refs/tags/$3^{commit}" 2>/dev/null || true)"
        have="$(git -C "$dir" rev-parse -q --verify HEAD 2>/dev/null || true)"
        if [ -n "$want" ] && [ "$want" = "$have" ]; then
            return 0
        fi
        echo "$1: checkout does not match $3 -- re-cloning" >&2
        rm -rf "$dir"
    fi
    git clone --depth 1 --branch "$3" "$2" "$dir"
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
    # SDL_CAMERA=OFF: WADdle has no camera feature, but SDL's camera subsystem
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
