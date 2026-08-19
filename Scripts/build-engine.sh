#!/bin/bash
# Builds the Woof! engine static lib for iOS device + simulator,
# then assembles WoofEngine.xcframework and stages woof.pk3.
set -euo pipefail
IOS_DEPLOYMENT_TARGET="26.0"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Vendor/out"

# Capture the source fingerprint BEFORE building. It is compared against a
# fresh one after assembly, so that sources changing mid-build (an edit, a
# branch switch, a rebase landing during a multi-minute build) cannot produce
# a stamp certifying a framework that was built from different bytes.
#
# Note the limit: this compares NET source state across the build, not
# transient state. A source edited during the build and reverted before the
# post-build fingerprint runs would still match. Closing that would mean
# building from an isolated immutable snapshot (a throwaway worktree per
# build); the residual risk -- an edit reverted inside the same build window
# -- is far narrower than the case this does catch, which is an edit that
# simply stays.
FP_BEFORE="$("$ROOT/Scripts/engine-fingerprint.sh")"

# pkg-config is not restricted by CMAKE_FIND_ROOT_PATH the way
# find_package/find_library are (that's a CMake-level mechanism;
# FindPkgConfig.cmake shells out to the system pkg-config with its own
# search path). Without this, Woof!'s third-party/CMakeLists.txt
# `find_package(libebur128 QUIET)` happily resolves to a Homebrew-installed
# macOS arm64 dylib (this machine has one via some other formula's
# dependency) instead of falling back to the vendored
# third-party/libebur128 source, silently skipping the static archive our
# xcframework assembly below expects to find and merge — the eventual
# symptom is "symbol(s) not found for architecture arm64" for ebur128_*
# at the app's final link, far downstream of this configure step.
export PKG_CONFIG_LIBDIR=""
export PKG_CONFIG_PATH=""

for platform in iphoneos iphonesimulator; do
    bdir="$ROOT/Vendor/build/woof-$platform"
    cmake -S "$ROOT/Engine/woof" -B "$bdir" -G Ninja \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="$platform" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_PREFIX_PATH="$OUT/$platform" \
        -DCMAKE_FIND_ROOT_PATH="$OUT/$platform" \
        -DWITH_SNDFILE=ON -DWITH_FLUIDSYNTH=OFF -DWITH_XMP=OFF \
        -DWITH_SONIVOX=ON \
        -DWITH_DISCORD_RPC=OFF
    cmake --build "$bdir" --target woof
done

# --- Stage 2: build resource pk3 (platform-independent zip) ---
# The pk3 is produced by a custom command, not a conventionally-named
# target, so discover the actual identifier from `--target help` rather
# than hardcoding a guess (it may be a bare name or a full output path
# depending on the CMake/Ninja version).
PK3_TARGET="$(cmake --build "$ROOT/Vendor/build/woof-iphonesimulator" --target help \
    | grep -i 'pk3' | head -1 | sed 's/:.*//')"
if [ -z "$PK3_TARGET" ]; then
    echo "error: could not find a pk3 build target in woof-iphonesimulator" >&2
    exit 1
fi
cmake --build "$ROOT/Vendor/build/woof-iphonesimulator" --target "$PK3_TARGET"
# Staged at App/Resources root (NOT under GameData/): Woof! locates its
# woof.pk3 via SDL_GetBasePath(), which on iOS resolves to the app bundle
# root, and there is no command-line override for that search (only for
# the IWAD, via an absolute -iwad path — see EngineSession.swift). GameData/
# stays a separate folder reference for the IWADs (see project.yml's
# comment on the codesign quirk that requires it).
PK3_FILE="$(find "$ROOT/Vendor/build/woof-iphonesimulator" -name 'woof.pk3' | head -1)"
mkdir -p "$ROOT/App/Resources"
cp "$PK3_FILE" "$ROOT/App/Resources/woof.pk3"

# --- Stage 3: merge static libs and create the xcframework ---
STAGE="$ROOT/Vendor/stage"
# The stamp is removed together with the framework it describes -- they must
# live and die as a unit. Otherwise any failure below (a cmake/libtool error,
# an interrupt, or the FP_BEFORE/FP_AFTER mismatch check) would leave the
# PREVIOUS build's stamp sitting beside a newly assembled framework, and
# check-engine-fresh.sh would validate bytes that stamp never described.
rm -rf "$STAGE" "$OUT/WoofEngine.xcframework" "$OUT/WoofEngine.xcframework.fingerprint"
mkdir -p "$STAGE/include"

# Public header + module map so Swift can `import WoofEngine`.
cp "$ROOT/Engine/woof/src/woof_ios.h" "$STAGE/include/"
cat > "$STAGE/include/module.modulemap" <<'EOF'
module WoofEngine {
    header "woof_ios.h"
    export *
}
EOF

for platform in iphoneos iphonesimulator; do
    mkdir -p "$STAGE/$platform"
    # All Woof-built static libs (engine + vendored third-party + opl,
    # textscreen, netlib, md5, sha1 ...) plus SDL3, OpenAL Soft and SONiVOX.
    #
    # libsonivox.a must be merged here for the same reason the other two are:
    # the app links only this xcframework, so anything left out shows up as an
    # undefined symbol at the app's final link. i_easmusic.c references
    # EAS_Init/EAS_Render/EAS_OpenFile/EAS_SetRepeat, and without this line
    # they stay `U` in libWoofEngine.a -- the engine builds green and the app
    # fails to link, a long way from the cause.
    libtool -static -o "$STAGE/$platform/libWoofEngine.a" \
        $(find "$ROOT/Vendor/build/woof-$platform" -name '*.a') \
        "$OUT/$platform/lib/libSDL3.a" \
        "$OUT/$platform/lib/libopenal.a" \
        "$OUT/$platform/lib/libsonivox.a" \
        "$OUT/$platform/lib/libsndfile.a" \
        "$OUT/$platform/lib/libFLAC.a" \
        "$OUT/$platform/lib/libopus.a" \
        "$OUT/$platform/lib/libvorbisenc.a" \
        "$OUT/$platform/lib/libvorbis.a" \
        "$OUT/$platform/lib/libogg.a"
done

xcodebuild -create-xcframework \
    -library "$STAGE/iphoneos/libWoofEngine.a" -headers "$STAGE/include" \
    -library "$STAGE/iphonesimulator/libWoofEngine.a" -headers "$STAGE/include" \
    -output "$OUT/WoofEngine.xcframework"
# Stamp the framework with a fingerprint of the sources that produced it.
# Scripts/check-engine-fresh.sh compares against this to refuse shipping a
# stale engine, and CI uses the same value as its cache key. Written LAST,
# only after -create-xcframework succeeded, so a failed build never leaves a
# stamp claiming the framework is current.
FP_AFTER="$("$ROOT/Scripts/engine-fingerprint.sh")"
if [ "$FP_BEFORE" != "$FP_AFTER" ]; then
    echo "error: engine sources changed while the build was running." >&2
    echo "       refusing to stamp -- the framework may mix old and new bytes." >&2
    echo "       re-run: Scripts/build-engine.sh" >&2
    exit 1
fi
printf '%s\n' "$FP_AFTER" > "$OUT/WoofEngine.xcframework.fingerprint"
echo "Built $OUT/WoofEngine.xcframework and staged App/Resources/woof.pk3"
