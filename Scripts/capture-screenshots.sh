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
#   duo-inner -> "iPhone Duo", open    (inner display; 2853x2007 landscape,
#             and one 2007x2853 shot of the device standing half open)
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
# The inner-display leg (`capture duo-inner`, issue #409) is the same test on
# the same simulator, opened. Three things about it are not like any other leg:
#   * SOMETHING ELSE HAS TO WORK THE HINGE. The hinge and the rotate button
#     exist only in Device Hub's window. This script says which pose it needs
#     and waits until the device is in it; WADDLE_DUO_POSE_HOOK names a
#     program that puts it there (Scripts/duo-pose-device-hub.sh presses
#     Device Hub's buttons through Orca's desktop control), and without one
#     the script prints the request and a person presses the button.
#     Either way the pose is then checked, not trusted: `open` by a host
#     shot of the inner display, lit and wide, and `half-open` by the app
#     itself, in the test.
#   * The shots are taken from the HOST. The test writes each shot's name to
#     a request file and this script photographs the inner display with
#     `simctl io screenshot --display=LCD-1`, because XCUIScreen would return
#     the outer display, switched off, at a valid store size.
#   * A host shot of the inner display comes back upright in both poses
#     (measured 2026-11-20), unlike one of the outer display, which is the
#     panel's own way up. So the export turns nothing; it only removes the
#     alpha channel every host shot has.
# Synthesized drags do nothing on an open Duo, so the test's scrolling steps
# must not be needed there; taps land.
#
# WAD provisioning: copies the same real test WADs as
# Scripts/provision-test-wads.sh. Never a synthetic `badiwad.wad` (the
# UnrecognizedIWADTests fixture): it would show up as a bogus base game tile
# on the shelf and in the Files screen in the marketing shots.
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
#   Scripts/capture-screenshots.sh capture duo-inner   # needs Device Hub; see above
#   Scripts/capture-screenshots.sh export duo-inner    # re-export the last run's host shots
#
# Env:
#   WADDLE_TEST_WADS           directory holding the WADs, in the layout of
#                              ~/Downloads/doom-test-wads (the default)
#   WADDLE_DUO_SIMULATOR       name of the iPhone Duo simulator to use
#                              (default "iPhone Duo"); created if missing
#   WADDLE_SCREENSHOT_RESULTS  where the .xcresult bundles are written
#   WADDLE_SCREENSHOT_OUT      where the sets are written, in place of
#                              docs/app-store/screenshots (the tests use this)
#   WADDLE_DUO_POSE_HOOK       duo-inner: program run as `<hook> <pose> <udid>
#                              <simulator name>` to put the device in a pose
#                              (open | half-open | closed)
#   WADDLE_DUO_POSE_WAIT       duo-inner: seconds to wait for the device to be
#                              opened (default 300)
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="com.tylervick.waddle"
WAD_SRC="${WADDLE_TEST_WADS:-$HOME/Downloads/doom-test-wads}"
DERIVED="App/build"
APP_PATH="$DERIVED/Build/Products/Debug-iphonesimulator/Waddle.app"
OUT_ROOT="${WADDLE_SCREENSHOT_OUT:-docs/app-store/screenshots}"
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
# What the inner-display leg must produce: each shot's name and its exact
# size. The six slots are the open device held so its window is wide, which
# is how the game is played; the seventh is the half-open play layout, where
# the fold has to run across the window, so the window is tall.
DUO_INNER_SHOTS="01-play-tab=2853x2007 02-library=2853x2007 03-preset-editor=2853x2007 04-control-feel=2853x2007 05-ingame=2853x2007 06-automap=2853x2007 07-ingame-half-open=2007x2853"
# The inner display's name to `simctl io` (`simctl io <udid> enumerate`).
DUO_INNER_DISPLAY="LCD-1"
DUO_POSE_HOOK="${WADDLE_DUO_POSE_HOOK:-}"
DUO_POSE_WAIT="${WADDLE_DUO_POSE_WAIT:-300}"
case "$DUO_POSE_WAIT" in
    ''|*[!0-9]*) echo "error: WADDLE_DUO_POSE_WAIT must be a non-negative integer, got '$DUO_POSE_WAIT'" >&2; exit 2 ;;
esac

require_kind() {
    case "$1" in iphone|ipad|duo|duo-inner) ;; *) echo "unknown device '$1' (iphone, ipad, duo or duo-inner)" >&2; exit 1 ;; esac
}
device_name() {
    case "$1" in iphone) echo "$IPHONE_NAME" ;; ipad) echo "$IPAD_NAME" ;; duo|duo-inner) echo "$DUO_NAME" ;; esac
}
device_slug() {
    case "$1" in iphone) echo "iphone-6.9" ;; ipad) echo "ipad-13" ;; duo) echo "iphone-duo" ;; duo-inner) echo "iphone-duo-inner" ;; esac
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

# Stops the background loop that serves the test's requests (a rotation on
# the closed leg; shots and poses on the inner one) and leaves the Duo in
# portrait. Runs from
# the EXIT trap as well, so a failed test run does not leave either behind.
DUO_UDID=""; DUO_HELPER_PID=""
duo_cleanup() {
    if [ -n "$DUO_HELPER_PID" ]; then
        kill "$DUO_HELPER_PID" 2>/dev/null || true
        wait "$DUO_HELPER_PID" 2>/dev/null || true
        DUO_HELPER_PID=""
    fi
    if [ -n "$DUO_UDID" ]; then
        xcrun devicectl device orientation set --device "$DUO_UDID" portrait >/dev/null 2>&1 || true
    fi
}

# ---- the inner-display leg's dealings with the hinge and the host ----------

png_dims() {  # path -> "WxH"
    python3 -c 'import sys; d = open(sys.argv[1], "rb").read(24); print("%dx%d" % (int.from_bytes(d[16:20], "big"), int.from_bytes(d[20:24], "big")))' "$1"
}

# True if the picture is one flat colour, which is what a display that is
# switched off photographs as. Sixteen by sixteen is enough to tell.
png_is_blank() {  # path
    local small="$RESULTS_ROOT/blank-probe.$$.bmp"
    sips -s format bmp -z 16 16 "$1" --out "$small" >/dev/null 2>&1 || return 2
    python3 - "$small" <<'PYEOF'
import sys
raw = open(sys.argv[1], "rb").read()
step = int.from_bytes(raw[28:30], "little") // 8      # 4 when sips keeps an alpha byte
pixels = raw[int.from_bytes(raw[10:14], "little"):]
colour = bytes(b for i, b in enumerate(pixels) if step != 4 or i % 4 != 3)
sys.exit(0 if max(colour) - min(colour) < 8 else 1)
PYEOF
    local rc=$?
    rm -f "$small"
    return $rc
}

# Photographs the Duo's INNER display, whatever the device is doing. `simctl
# io screenshot` does not follow the active display: with no `--display` it
# takes the outer one ("LCD") even while the device is open, and asked for
# the inner one ("LCD-1") on a closed device it returns 2007x2853 px of black.
# So the size of a host shot says nothing about the pose, and every shot is
# checked for being blank instead. `--mask=ignored` keeps the corners square,
# as XCUIScreen's shots of the other sets are.
duo_host_shot() {  # udid, path
    xcrun simctl io "$1" screenshot --type=png --display="$DUO_INNER_DISPLAY" --mask=ignored "$2" >/dev/null 2>&1
}

# Asks for a pose. A hook is told and expected to act; with no hook the
# request goes to whoever is watching the terminal. Neither is believed:
# every caller goes on to check the pose some other way.
duo_ask_pose() {  # pose, udid, simulator name
    if [ -n "$DUO_POSE_HOOK" ]; then
        echo "== pose '$1': running $DUO_POSE_HOOK" >&2
        "$DUO_POSE_HOOK" "$1" "$2" "$3" >&2 || echo "warning: the pose hook failed for '$1' (exit $?)" >&2
        return 0
    fi
    case "$1" in
        open) echo "== ACTION NEEDED: in Device Hub, select '$3', hold it upright (portrait) and press Open." >&2 ;;
        half-open) echo "== ACTION NEEDED: in Device Hub, press Rotate Right once on '$3', then Partially Open." >&2 ;;
        closed) echo "== ACTION NEEDED (optional): in Device Hub, turn '$3' upright again and press Closed." >&2 ;;
    esac
}

# Blocks until the device is open and held so the app's window is wide: the
# inner display is lit, and a host shot of it comes back 2853x2007. (A host
# shot of the open inner display is the way up the picture is, so its shape
# is the window's. The test cannot check this itself: XCUITest reports the
# open Duo's wide window as 669x951.)
duo_wait_open() {  # udid, simulator name
    local probe="$RESULTS_ROOT/pose-probe.png" why="" deadline=$((SECONDS + DUO_POSE_WAIT))
    while :; do
        if ! duo_host_shot "$1" "$probe"; then
            why="its inner display ($DUO_INNER_DISPLAY) cannot be photographed"
        elif png_is_blank "$probe"; then
            why="its inner display is dark (the device is closed)"
        elif [ "$(png_dims "$probe")" != 2853x2007 ]; then
            why="its inner display reads $(png_dims "$probe"), not 2853x2007 (the device is turned on its side)"
        else
            rm -f "$probe"
            return 0
        fi
        if [ $SECONDS -ge $deadline ]; then
            echo "error: '$2' is not open and upright after ${DUO_POSE_WAIT}s: $why." >&2
            echo "       Nothing Apple ships opens the simulator from a script: docs/learnings/driving-device-hub-by-desktop-control.md" >&2
            exit 1
        fi
        sleep 2
    done
}

# Serves the test's two kinds of request until killed. A shot that cannot be
# taken leaves its request in place, so the test fails by name on its own
# timeout instead of going on without the picture.
duo_serve_requests() {  # udid, simulator name, shots dir
    local word
    while :; do
        if [ -e "$DUO_SHOT_REQUEST" ]; then
            word="$(cat "$DUO_SHOT_REQUEST")"
            case "$word" in
                *[!0-9a-z-]*|'') echo "error: refusing a shot request that is not a shot name: '$word'" >&2 ;;
                *)
                    if duo_host_shot "$1" "$3/$word.png"; then
                        echo "== shot $word" >&2
                        rm -f "$DUO_SHOT_REQUEST"
                    else
                        echo "warning: could not photograph $word; will try again" >&2
                        sleep 1
                    fi
                    ;;
            esac
        fi
        if [ -e "$DUO_POSE_REQUEST" ]; then
            word="$(cat "$DUO_POSE_REQUEST")"
            case "$word" in
                open|half-open|closed) duo_ask_pose "$word" "$1" "$2" ;;
                *) echo "error: ignoring an unknown pose request: '$word'" >&2 ;;
            esac
            rm -f "$DUO_POSE_REQUEST"
        fi
        sleep 0.2
    done
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
        duo|duo-inner) kind=duo; ensure_duo ;;
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

capture() {  # $1 = iphone | ipad | duo | duo-inner
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
    if [ -z "$udid" ] && { [ "$kind" = duo ] || [ "$kind" = duo-inner ]; }; then
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
    if [ "$kind" = duo-inner ]; then
        # Upright: opened from portrait, the inner display gives the app a
        # wide window (951x669 pt) with no rotation at all.
        DUO_UDID="$udid"
        trap duo_cleanup EXIT
        xcrun devicectl device orientation set --device "$udid" portrait >/dev/null 2>&1 || true
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
        DUO_HELPER_PID=$!
    fi
    if [ "$kind" = duo-inner ]; then
        local shots="$RESULTS_ROOT/$slug-host-shots"
        rm -rf "$shots"; mkdir -p "$shots"
        duo_ask_pose open "$udid" "$name"
        duo_wait_open "$udid" "$name"
        DUO_SHOT_REQUEST="$RESULTS_ROOT/shot-request"
        DUO_POSE_REQUEST="$RESULTS_ROOT/pose-request"
        rm -f "$DUO_SHOT_REQUEST" "$DUO_POSE_REQUEST" "$DUO_SHOT_REQUEST.staged" "$DUO_POSE_REQUEST.staged"
        export TEST_RUNNER_WADDLE_SCREENSHOT_HOST_SHOT_REQUEST="$DUO_SHOT_REQUEST"
        export TEST_RUNNER_WADDLE_SCREENSHOT_POSE_REQUEST="$DUO_POSE_REQUEST"
        duo_serve_requests "$udid" "$name" "$shots" &
        DUO_HELPER_PID=$!
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
    elif [ "$kind" = duo-inner ]; then
        duo_cleanup
        # Back to the pose a simulator boots in, for whoever uses it next.
        duo_ask_pose closed "$udid" "$name"
        export_host_shots "$RESULTS_ROOT/$slug-host-shots" "$OUT_ROOT/$slug" "$DUO_INNER_SHOTS"
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
    """Drop every chunk that states an orientation: eXIf, and the XMP packet
    (an iTXt chunk keyed XML:com.adobe.xmp) that carries the same tag as
    tiff:Orientation.

    `sips --rotate` rewrites the raster AND leaves an EXIF Orientation tag
    (8, "rotate 90° CCW") behind, so the pixels are upright but the metadata
    still asks for a rotation. Consumers that honour EXIF apply it a second
    time -- App Store Connect does exactly that and stores the shot sideways,
    while git, GitHub and Preview ignore the chunk and look correct, which is
    how this survived the first capture in July.

    The XMP copy was found on the iPhone Duo set (issue #409): with eXIf gone
    and the XMP left, `sips` itself still turned the file a quarter turn on
    every conversion, and so did the image viewer used to check the shots.
    App Store Connect has stored files carrying it the right way up, but that
    is one consumer's behaviour on one path, and the Duo set goes up by
    another. Removing a chunk is lossless: IDAT and IHDR are untouched."""
    with open(path, "rb") as f:
        data = f.read()

    def states_orientation(kind, blob):
        return kind == b"eXIf" or (kind == b"iTXt" and blob[8:].startswith(b"XML:com.adobe.xmp\0"))

    if not any(states_orientation(kind, blob) for kind, blob in png_chunks(data)):
        return
    out = bytearray(data[:8])
    for kind, blob in png_chunks(data):
        if not states_orientation(kind, blob):
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

# The inner-display leg's export. A host shot of the open device is upright
# already, but it is RGBA, which the store refuses. Each shot is rewritten
# opaque (Scripts/opaque-png.swift, pixel for pixel), then held to its exact
# size, to not being blank, and to having no alpha channel. The size is the
# check on the pose: a wide window gives 2853x2007 and a tall one 2007x2853.
#
# All or nothing: the shots are rewritten into a staging directory and moved
# into the set only when every one has passed. A refused export leaves the
# committed set exactly as it was, not some new files beside some old ones
# that `git status` would show as a half-finished re-capture.
export_host_shots() {  # $1 = dir of host shots, $2 = dest dir, $3 = "name=WxH ..."
    local entry name size raw out problems="" stage="$RESULTS_ROOT/export-stage.$$"
    rm -rf "$stage"; mkdir -p "$stage"
    for entry in $3; do
        name="${entry%%=*}"; size="${entry#*=}"
        raw="$1/$name.png"; out="$stage/$name.png"
        if [ ! -f "$raw" ]; then
            problems="$problems
  $name: the test never asked for it"
            continue
        fi
        if png_is_blank "$raw"; then
            problems="$problems
  $name is one flat colour: the inner display was switched off (the device was closed)"
            continue
        fi
        if ! xcrun swift Scripts/opaque-png.swift "$raw" "$out.tmp"; then
            rm -f "$out.tmp"
            problems="$problems
  $name could not be rewritten without its alpha channel (see above)"
            continue
        fi
        python3 - "$out.tmp" "$out" "$size" <<'PYEOF' || { rm -f "$out.tmp"; problems="$problems
  $name is not ${size} without alpha: the device was not in the pose this shot needs"; continue; }
import sys
data = open(sys.argv[1], "rb").read()
got = "%dx%d" % (int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big"))
# Colour type 2 is RGB with no alpha channel.
if got != sys.argv[3] or data[25] != 2:
    sys.exit(1)
out, i = bytearray(data[:8]), 8
while i < len(data):
    length = int.from_bytes(data[i:i + 4], "big")
    kind, blob = data[i + 4:i + 8], data[i:i + 12 + length]
    if not (kind == b"eXIf" or (kind == b"iTXt" and blob[8:].startswith(b"XML:com.adobe.xmp\0"))):
        out += blob
    i += 12 + length
    if kind == b"IEND":
        break
open(sys.argv[2], "wb").write(bytes(out))
PYEOF
        rm -f "$out.tmp"
    done
    if [ -n "$problems" ]; then
        rm -rf "$stage"
        echo "error: inner-display capture refused; $2 is unchanged:$problems" >&2
        exit 1
    fi
    mkdir -p "$2"
    for entry in $3; do
        mv -f "$stage/${entry%%=*}.png" "$2/${entry%%=*}.png"
    done
    rm -rf "$stage"
    echo "exported $(echo $3 | wc -w | tr -d ' ') screenshots -> $2"
}

case "${1:-all}" in
    prepare) prepare "${2:-iphone}" ;;
    capture) capture "${2:?usage: capture iphone|ipad|duo|duo-inner}" ;;
    export)
        [ "${2:-}" = duo-inner ] || { echo "usage: $0 export duo-inner" >&2; exit 1; }
        export_host_shots "$RESULTS_ROOT/iphone-duo-inner-host-shots" "$OUT_ROOT/iphone-duo-inner" "$DUO_INNER_SHOTS"
        ;;
    all)
        prepare
        capture iphone
        capture ipad
        ;;
    *) echo "usage: $0 [prepare [iphone|duo] | capture iphone|ipad|duo|duo-inner | export duo-inner]" >&2; exit 1 ;;
esac
