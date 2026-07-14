#!/bin/bash
# Builds the Woof! engine static lib for iOS device + simulator,
# then (Task 6) assembles WoofEngine.xcframework and stages woof.pk3.
set -euo pipefail
IOS_DEPLOYMENT_TARGET="26.0"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Vendor/out"

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
        -DWITH_SNDFILE=OFF -DWITH_FLUIDSYNTH=OFF -DWITH_XMP=OFF \
        -DWITH_DISCORD_RPC=OFF
    cmake --build "$bdir" --target woof
done
echo "Engine libs built."
