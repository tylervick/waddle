#!/bin/bash
# App Store screenshot pipeline (Plan 4 Task 7).
#
# Drives the app with a committed XCUITest, App/UITests/ScreenshotCaptureTests.swift
# -- not manual pauses. The test is compiled with every build of the UI suite
# and skips unless WADDLE_SCREENSHOT_CAPTURE is in its environment, which
# only this script sets (issue #158: while it was generated here from a
# heredoc, the compiler never saw it drift). It plays an in-game Freedoom session first, then
# navigates the shelf / Files screen / game page, attaching
# full-resolution XCUIScreen shots; the script then exports them from the
# .xcresult bundle into docs/app-store/screenshots/<device>/.
#
# Devices:
#   iphone -> "iPhone 17 Pro Max"      (6.9" class, REQUIRED size; 2868x1320)
#   ipad   -> "iPad Pro 13-inch (M4)"  (13" class, REQUIRED iPad size;
#             2752x2064; created on demand by
#             Scripts/ensure-ipad-simulator.sh, which owns that name and its
#             device type — the pre-provisioned "iPad (A16)" is 11" class and
#             can't produce 13" images)
#
# WAD provisioning: copies the same real test WADs as
# Scripts/provision-test-wads.sh but deliberately NOT the synthetic
# `badiwad.wad` negative-test fixture — it would show up as a bogus base game
# tile on the shelf and in the Files screen in the marketing shots.
#
# In-game shots launch with WADDLE_TEST_WARP (menu-free path into a level;
# Woof never auto-warps otherwise) and WADDLE_FORCE_TOUCH_OVERLAY (the
# XCUITest automation session registers a phantom game controller that
# would hide the touch overlay; on a real device with no controller the
# overlay is visible, so forcing it reproduces the shipping UX). No debug
# HUD/label env vars (WADDLE_DEBUG_INPUT_COUNTS etc.) are set.
#
# Usage:
#   Scripts/capture-screenshots.sh              # everything, in order
#   Scripts/capture-screenshots.sh prepare      # xcodegen + build-for-testing
#   Scripts/capture-screenshots.sh capture iphone
#   Scripts/capture-screenshots.sh capture ipad
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="com.tylervick.waddle"
WAD_SRC="$HOME/Downloads/doom-test-wads"
DERIVED="App/build"
APP_PATH="$DERIVED/Build/Products/Debug-iphonesimulator/Waddle.app"
OUT_ROOT="docs/app-store/screenshots"
RESULTS_ROOT="${TMPDIR:-/tmp}/waddle-screenshots"

IPHONE_NAME="iPhone 17 Pro Max"
# The device TYPE is what fixes the 6.9" size class (2868x1320). A new Xcode
# ships simulators for its own generation only, so after an upgrade the named
# device can be gone while its type is still installed -- create it on demand,
# as ensure-ipad-simulator.sh does for the iPad.
IPHONE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max"
# The iPad name and its CoreSimulator device type both live in
# Scripts/ensure-ipad-simulator.sh, which also creates the device on demand.
# Asking it rather than repeating the pair here is what keeps the device these
# marketing shots are taken on identical to the one ci.yml and `mise run test`
# run the suite on -- two copies of that device type is exactly how a
# screenshot of one size class and a test of another would drift apart.
IPAD_NAME="$(Scripts/ensure-ipad-simulator.sh --name)"

device_name() { [ "$1" = iphone ] && echo "$IPHONE_NAME" || echo "$IPAD_NAME"; }
device_slug() { [ "$1" = iphone ] && echo "iphone-6.9" || echo "ipad-13"; }

udid_for() {
    # `|| true`: no-match is a real case (the iPad gets created on demand),
    # and set -e would otherwise kill the script inside the substitution.
    xcrun simctl list devices available | { grep -F "$1 (" || true; } \
        | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/'
}

ensure_iphone() {
    [ -n "$(udid_for "$IPHONE_NAME")" ] && return
    echo "== creating simulator: $IPHONE_NAME ($IPHONE_TYPE)" >&2
    xcrun simctl create "$IPHONE_NAME" "$IPHONE_TYPE" >/dev/null
    # Everything downstream finds the device by name, so prove it can.
    if [ -z "$(udid_for "$IPHONE_NAME")" ]; then
        echo "error: created $IPHONE_NAME but simctl does not list it" >&2
        exit 1
    fi
}

prepare() {
    echo "== prepare: xcodegen + build-for-testing"
    ensure_iphone  # the build below names it as its destination
    (cd App && xcodegen generate)
    # Concrete destination, not "generic/platform=iOS Simulator": the
    # generic one adds x86_64, which WoofEngine.xcframework doesn't ship.
    # The arm64 products run on every simulator on this Apple Silicon host.
    xcodebuild build-for-testing \
        -project App/Waddle.xcodeproj -scheme Waddle \
        -destination "platform=iOS Simulator,name=$IPHONE_NAME" \
        -derivedDataPath "$DERIVED" -quiet
}

provision() {  # $1 = udid
    local docs
    docs="$(xcrun simctl get_app_container "$1" "$BUNDLE_ID" data)/Documents"
    mkdir -p "$docs"
    cp "$WAD_SRC/scythe/SCYTHE.WAD" "$docs/"
    cp "$WAD_SRC/sunlust/sunlust/sunlust.wad" "$docs/"
    cp "$WAD_SRC/eviternityii/Eviternity II.wad" "$docs/"
}

seed_engine_config() {  # $1 = udid
    # Woof's automap shows an X/Y/Z player-coordinates widget by default
    # (hud_player_coords=1, "on automap") — engine-authentic, but it reads
    # as debug telemetry in a marketing shot. Seed the engine config
    # (SDL_GetPrefPath -> Library/Application Support/woof/woof.cfg;
    # missing keys keep their defaults) with it off before first engine run.
    local dir
    dir="$(xcrun simctl get_app_container "$1" "$BUNDLE_ID" data)/Library/Application Support/woof"
    mkdir -p "$dir"
    if [ ! -f "$dir/woof.cfg" ]; then
        echo "hud_player_coords 0" > "$dir/woof.cfg"
    elif ! grep -q "^hud_player_coords" "$dir/woof.cfg"; then
        echo "hud_player_coords 0" >> "$dir/woof.cfg"
    else
        sed -i '' 's/^hud_player_coords.*/hud_player_coords 0/' "$dir/woof.cfg"
    fi
}

warm_up() {  # $1 = udid — launch once so loose-file adoption imports the WADs
    local docs
    docs="$(xcrun simctl get_app_container "$1" "$BUNDLE_ID" data)/Documents"
    xcrun simctl launch "$1" "$BUNDLE_ID" >/dev/null
    local deadline=$((SECONDS + 240))
    while [ -e "$docs/SCYTHE.WAD" ] || [ -e "$docs/sunlust.wad" ] \
          || [ -e "$docs/Eviternity II.wad" ]; do
        if [ $SECONDS -ge $deadline ]; then
            echo "adoption never finished; leftover files in $docs" >&2
            exit 1
        fi
        sleep 3
    done
    sleep 3  # let the library DB save settle
    xcrun simctl terminate "$1" "$BUNDLE_ID" 2>/dev/null || true
}

capture() {  # $1 = iphone | ipad
    local kind="$1" name udid slug result
    name="$(device_name "$kind")"
    slug="$(device_slug "$kind")"
    echo "== capture: $name -> $OUT_ROOT/$slug"

    udid="$(udid_for "$name")"
    if [ -z "$udid" ] && [ "$kind" = ipad ]; then
        # Prints the UDID on stdout and its progress on stderr.
        udid="$(Scripts/ensure-ipad-simulator.sh)"
    fi
    [ -n "$udid" ] || { echo "no simulator named $name" >&2; exit 1; }

    xcrun simctl boot "$udid" 2>/dev/null || true
    xcrun simctl bootstatus "$udid"
    # Marketing-clean status bar (Apple's own screenshot convention).
    xcrun simctl status_bar "$udid" override --time "9:41" \
        --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
    # Fresh container each run: no stale games/config from prior captures.
    xcrun simctl uninstall "$udid" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl install "$udid" "$APP_PATH"
    provision "$udid"
    seed_engine_config "$udid"
    warm_up "$udid"

    result="$RESULTS_ROOT/$slug.xcresult"
    rm -rf "$result"; mkdir -p "$RESULTS_ROOT"
    # TEST_RUNNER_ is how xcodebuild hands a variable to the test process;
    # ScreenshotCaptureTests skips without WADDLE_SCREENSHOT_CAPTURE.
    TEST_RUNNER_WADDLE_SCREENSHOT_CAPTURE=1 \
    xcodebuild test-without-building \
        -project App/Waddle.xcodeproj -scheme Waddle \
        -destination "platform=iOS Simulator,id=$udid" \
        -only-testing:WaddleUITests/ScreenshotCaptureTests \
        -derivedDataPath "$DERIVED" \
        -resultBundlePath "$result" -quiet

    export_shots "$result" "$OUT_ROOT/$slug"
}

export_shots() {  # $1 = xcresult, $2 = dest dir
    local tmp="$RESULTS_ROOT/export.$$"
    rm -rf "$tmp"; mkdir -p "$tmp" "$2"
    xcrun xcresulttool export attachments --path "$1" --output-path "$tmp"
    python3 - "$tmp" "$2" <<'PYEOF'
import json, shutil, subprocess, sys, os, re
src, dst = sys.argv[1], sys.argv[2]
manifest = json.load(open(os.path.join(src, "manifest.json")))
count = 0
rotated = []
for test in manifest:
    for att in test.get("attachments", []):
        name = att.get("suggestedHumanReadableName", "")
        m = re.match(r"^(\d\d-[a-z-]+)", name)
        if not m:
            continue  # skip auto-captured failure screenshots etc.
        shutil.copy(os.path.join(src, att["exportedFileName"]),
                    os.path.join(dst, m.group(1) + ".png"))
        count += 1
        rotated.append(os.path.join(dst, m.group(1) + ".png"))
# If the simulated device was still portrait when a shot was taken,
# XCUIScreen returns a portrait pixel buffer with the app's content rotated
# 90° CW; 270° puts it upright at the App Store's expected landscape
# dimensions. Shots taken while the device was already landscape (the test
# rotates it after launch) come out upright and are left alone.
def png_size(path):
    with open(path, "rb") as f:
        header = f.read(24)
    return int.from_bytes(header[16:20], "big"), int.from_bytes(header[20:24], "big")


def png_chunks(data):
    i = 8
    while i < len(data):
        length = int.from_bytes(data[i:i + 4], "big")
        kind = data[i + 4:i + 8]
        yield kind, data[i:i + 12 + length]
        i += 12 + length
        if kind == b"IEND":
            break


def strip_exif(path):
    """Drop any eXIf chunk. `sips --rotate` rewrites the raster AND leaves an
    EXIF Orientation tag (8, "rotate 90° CCW") behind, so the pixels are
    upright but the metadata still asks for a rotation. Consumers that honour
    EXIF apply it a second time -- App Store Connect does exactly that and
    stores the shot sideways, while git, GitHub and Preview ignore the chunk
    and look correct, which is how this survived the first capture in July.
    Removing a chunk is lossless: IDAT and IHDR are untouched."""
    with open(path, "rb") as f:
        data = f.read()
    if not any(kind == b"eXIf" for kind, _ in png_chunks(data)):
        return
    out = bytearray(data[:8])
    for kind, blob in png_chunks(data):
        if kind != b"eXIf":
            out += blob
    with open(path, "wb") as f:
        f.write(bytes(out))


for path in rotated:
    w, h = png_size(path)
    if h > w:
        subprocess.run(["sips", "--rotate", "270", path],
                       check=True, capture_output=True)
    strip_exif(path)
print(f"exported {count} screenshots -> {dst}")
if count < 6:
    sys.exit(f"expected 6 screenshots, got {count}")
PYEOF
    rm -rf "$tmp"
}

case "${1:-all}" in
    prepare) prepare ;;
    capture) capture "${2:?usage: capture iphone|ipad}" ;;
    all)
        prepare
        capture iphone
        capture ipad
        ;;
    *) echo "usage: $0 [prepare | capture iphone|ipad]" >&2; exit 1 ;;
esac
