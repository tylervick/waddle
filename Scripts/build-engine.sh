#!/bin/bash
# Builds the Woof! engine static lib for iOS device + simulator,
# then assembles WoofEngine.xcframework and stages woof.pk3.
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
PK3_FILE="$(find "$ROOT/Vendor/build/woof-iphonesimulator" -name 'woof.pk3' | head -1)"
mkdir -p "$ROOT/App/Resources/GameData"
cp "$PK3_FILE" "$ROOT/App/Resources/GameData/woof.pk3"

# --- Stage 3: merge static libs and create the xcframework ---
STAGE="$ROOT/Vendor/stage"
rm -rf "$STAGE" "$OUT/WoofEngine.xcframework"
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
    # textscreen, netlib, md5, sha1 ...) plus SDL3 and OpenAL Soft.
    libtool -static -o "$STAGE/$platform/libWoofEngine.a" \
        $(find "$ROOT/Vendor/build/woof-$platform" -name '*.a') \
        "$OUT/$platform/lib/libSDL3.a" \
        "$OUT/$platform/lib/libopenal.a"
done

xcodebuild -create-xcframework \
    -library "$STAGE/iphoneos/libWoofEngine.a" -headers "$STAGE/include" \
    -library "$STAGE/iphonesimulator/libWoofEngine.a" -headers "$STAGE/include" \
    -output "$OUT/WoofEngine.xcframework"
echo "Built $OUT/WoofEngine.xcframework and staged App/Resources/GameData/woof.pk3"
