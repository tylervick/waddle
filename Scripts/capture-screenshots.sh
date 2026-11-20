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
#   duo    -> "iPhone Duo", closed     (outer display; 2034x1398 landscape)
#
# The Duo leg (issue #409) is not part of `all`, for three reasons that are
# all in docs/learnings/iphone-duo-simulator-traps.md:
#   * The Duo exists only on the iOS 27.1 runtime, which runs no other device,
#     so one Xcode cannot be assumed to hold all three simulators. Where 27.1
#     is not installed (or its license not accepted), run the leg on CI:
#     .github/workflows/capture-duo-screenshots.yml.
#   * XCUIDevice does not rotate a Duo. This script rotates the device from
#     the host instead, with `devicectl device orientation set`: once before
#     the test, and again whenever the test finds its interface is not
#     landscape and asks (see the rotate-request loop in capture()).
#   * A simulator boots closed and nothing Apple ships opens it from a script,
#     so this leg photographs the OUTER display only. XCUIScreen always
#     returns the outer display, which is exactly right for a closed device
#     and silently wrong for an open one: an inner-display leg must not reuse
#     this path unchanged.
# Every Duo file must come out at one of the four sizes the store accepts for
# the device; the export refuses anything else rather than commit it.
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
#   Scripts/capture-screenshots.sh prepare duo  # build against the Duo instead
#   Scripts/capture-screenshots.sh capture duo
#
# Env:
#   WADDLE_TEST_WADS           directory holding the WADs, in the layout of
#                              ~/Downloads/doom-test-wads (the default)
#   WADDLE_DUO_SIMULATOR       name of the iPhone Duo simulator to use
#                              (default "iPhone Duo"); created if missing
#   WADDLE_SCREENSHOT_RESULTS  where the .xcresult bundles are written
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="com.tylervick.waddle"
WAD_SRC="${WADDLE_TEST_WADS:-$HOME/Downloads/doom-test-wads}"
DERIVED="App/build"
APP_PATH="$DERIVED/Build/Products/Debug-iphonesimulator/Waddle.app"
OUT_ROOT="docs/app-store/screenshots"
RESULTS_ROOT="${WADDLE_SCREENSHOT_RESULTS:-${TMPDIR:-/tmp}/waddle-screenshots}"

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

# The Duo's name is overridable so that a capture on a shared Mac can use a
# simulator of its own rather than one another session may be testing on.
DUO_NAME="${WADDLE_DUO_SIMULATOR:-iPhone Duo}"
# Landscape, like the other two sets: it is how the game is played. Which
# landscape matters to the export below, which has to know which way the
# pixel buffer comes back.
DUO_ORIENTATION="landscapeLeft"
# The store's four iPhone Duo sizes (metadata.md §12); a closed device can
# only produce the first two.
DUO_SIZES="1398x2034 2034x1398 2007x2853 2853x2007"

require_kind() {
    case "$1" in iphone|ipad|duo) ;; *) echo "unknown device '$1' (iphone, ipad or duo)" >&2; exit 1 ;; esac
}
device_name() {
    case "$1" in iphone) echo "$IPHONE_NAME" ;; ipad) echo "$IPAD_NAME" ;; duo) echo "$DUO_NAME" ;; esac
}
device_slug() {
    case "$1" in iphone) echo "iphone-6.9" ;; ipad) echo "ipad-13" ;; duo) echo "iphone-duo" ;; esac
}

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

ensure_duo() {
    [ -n "$(udid_for "$DUO_NAME")" ] && return
    # The device type's identifier is asked of this Xcode rather than written
    # down: only Xcode 27.1 and later have one, and an Xcode without it should
    # say so here instead of failing inside `simctl create`.
    local type
    type="$(xcrun simctl list devicetypes | sed -nE 's/^iPhone Duo \((com\.apple\.[^)]*)\)$/\1/p' | head -1)"
    if [ -z "$type" ]; then
        echo "error: this Xcode has no iPhone Duo device type (it needs 27.1 or later, with the iOS 27.1 runtime)." >&2
        echo "       Run the Duo leg on CI instead: gh workflow run capture-duo-screenshots.yml" >&2
        exit 1
    fi
    echo "== creating simulator: $DUO_NAME ($type)" >&2
    xcrun simctl create "$DUO_NAME" "$type" >/dev/null
    if [ -z "$(udid_for "$DUO_NAME")" ]; then
        echo "error: created $DUO_NAME but simctl does not list it" >&2
        exit 1
    fi
}

# Stops the rotate-on-request loop and leaves the Duo in portrait. Runs from
# the EXIT trap as well, so a failed test run does not leave either behind.
DUO_UDID=""; DUO_ROTATOR_PID=""
duo_cleanup() {
    if [ -n "$DUO_ROTATOR_PID" ]; then
        kill "$DUO_ROTATOR_PID" 2>/dev/null || true
        wait "$DUO_ROTATOR_PID" 2>/dev/null || true
        DUO_ROTATOR_PID=""
    fi
    if [ -n "$DUO_UDID" ]; then
        xcrun devicectl device orientation set --device "$DUO_UDID" portrait >/dev/null 2>&1 || true
    fi
}

prepare() {  # $1 = iphone (default) | duo -- the simulator the build names
    local kind="${1:-iphone}" name
    require_kind "$kind"
    echo "== prepare: xcodegen + build-for-testing"
    # The build below names a simulator as its destination, so it must exist.
    # On an Xcode whose only iOS runtime for the Duo is 27.1 (the CI image)
    # there may be no iPhone 17 Pro Max to name; `prepare duo` builds against
    # the Duo itself. The products are the same arm64 simulator binaries.
    case "$kind" in
        duo) ensure_duo ;;
        *) kind=iphone; ensure_iphone ;;
    esac
    name="$(device_name "$kind")"
    (cd App && xcodegen generate)
    # Concrete destination, not "generic/platform=iOS Simulator": the
    # generic one adds x86_64, which WoofEngine.xcframework doesn't ship.
    # The arm64 products run on every simulator on this Apple Silicon host.
    xcodebuild build-for-testing \
        -project App/Waddle.xcodeproj -scheme Waddle \
        -destination "platform=iOS Simulator,id=$(udid_for "$name")" \
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

capture() {  # $1 = iphone | ipad | duo
    local kind="$1" name udid slug result
    require_kind "$kind"
    name="$(device_name "$kind")"
    slug="$(device_slug "$kind")"
    echo "== capture: $name -> $OUT_ROOT/$slug"

    udid="$(udid_for "$name")"
    if [ -z "$udid" ] && [ "$kind" = ipad ]; then
        # Prints the UDID on stdout and its progress on stderr.
        udid="$(Scripts/ensure-ipad-simulator.sh)"
    fi
    if [ -z "$udid" ] && [ "$kind" = duo ]; then
        ensure_duo
        udid="$(udid_for "$name")"
    fi
    [ -n "$udid" ] || { echo "no simulator named $name" >&2; exit 1; }

    xcrun simctl boot "$udid" 2>/dev/null || true
    xcrun simctl bootstatus "$udid"
    if [ "$kind" = duo ]; then
        # XCUIDevice cannot rotate a Duo; devicectl can. Done here, before
        # anything is launched, and again on request from the test (below).
        # Put back to portrait on the way out: a simulator keeps its
        # orientation, and the next suite to use this one would start
        # sideways (issue #382).
        DUO_UDID="$udid"
        trap duo_cleanup EXIT
        xcrun devicectl device orientation set --device "$udid" "$DUO_ORIENTATION"
    fi
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
    if [ "$kind" = duo ]; then
        # A rotation made while no app is frontmost does not reliably reach
        # the app that launches next: two CI runs of this leg with the same
        # commands produced one landscape set and one portrait. So the test
        # checks its own interface after each launch and, if it is not
        # landscape, creates this file; the loop below then turns the device
        # away and back while the app is on screen, which is the case
        # docs/learnings/iphone-duo-simulator-traps.md measured as working.
        ROTATE_REQUEST="$RESULTS_ROOT/rotate-request"
        rm -f "$ROTATE_REQUEST"
        export TEST_RUNNER_WADDLE_SCREENSHOT_ROTATE_REQUEST="$ROTATE_REQUEST"
        xcrun devicectl device orientation set --device "$udid" "$DUO_ORIENTATION"
        (
            while :; do
                if [ -e "$ROTATE_REQUEST" ]; then
                    echo "== rotating $name on request from the test" >&2
                    xcrun devicectl device orientation set --device "$udid" portrait >&2 || true
                    sleep 1
                    xcrun devicectl device orientation set --device "$udid" "$DUO_ORIENTATION" >&2 || true
                    rm -f "$ROTATE_REQUEST"
                fi
                sleep 1
            done
        ) &
        DUO_ROTATOR_PID=$!
    fi
    # TEST_RUNNER_ is how xcodebuild hands a variable to the test process;
    # ScreenshotCaptureTests skips without WADDLE_SCREENSHOT_CAPTURE.
    TEST_RUNNER_WADDLE_SCREENSHOT_CAPTURE=1 \
    xcodebuild test-without-building \
        -project App/Waddle.xcodeproj -scheme Waddle \
        -destination "platform=iOS Simulator,id=$udid" \
        -only-testing:WaddleUITests/ScreenshotCaptureTests \
        -derivedDataPath "$DERIVED" \
        -resultBundlePath "$result" -quiet

    if [ "$kind" = duo ]; then
        duo_cleanup
        export_shots "$result" "$OUT_ROOT/$slug" "$DUO_SIZES"
    else
        export_shots "$result" "$OUT_ROOT/$slug"
    fi
}

export_shots() {  # $1 = xcresult, $2 = dest dir, $3 = accepted "WxH ..." sizes (optional)
    local tmp="$RESULTS_ROOT/export.$$"
    rm -rf "$tmp"; mkdir -p "$tmp" "$2"
    xcrun xcresulttool export attachments --path "$1" --output-path "$tmp"
    python3 - "$tmp" "$2" "${3:-}" <<'PYEOF'
import json, shutil, subprocess, sys, os, re
src, dst = sys.argv[1], sys.argv[2]
accepted = sys.argv[3].split()
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
# A set with exact store sizes (the Duo's) is checked here, at the source: a
# shot of any other size means the device was not in the pose this leg
# assumes, and the upload script would refuse it anyway.
if accepted:
    wrong = [f"{os.path.basename(p)} is {'x'.join(map(str, png_size(p)))}"
             for p in rotated if "x".join(map(str, png_size(p))) not in accepted]
    if wrong:
        sys.exit("not a store size (" + ", ".join(accepted) + "): " + "; ".join(wrong))
PYEOF
    rm -rf "$tmp"
}

case "${1:-all}" in
    prepare) prepare "${2:-iphone}" ;;
    capture) capture "${2:?usage: capture iphone|ipad|duo}" ;;
    all)
        prepare
        capture iphone
        capture ipad
        ;;
    *) echo "usage: $0 [prepare [iphone|duo] | capture iphone|ipad|duo]" >&2; exit 1 ;;
esac
