#!/bin/bash
# App Store screenshot pipeline (Plan 4 Task 7).
#
# Drives the app with a TEMPORARY XCUITest (ScreenshotCaptureTests.swift,
# written by this script into App/UITests, removed again by `cleanup`) —
# not manual pauses. The test navigates the launcher/library/editor and an
# in-game Freedoom session, attaching full-resolution XCUIScreen shots;
# the script then exports them from the .xcresult bundle into
# docs/app-store/screenshots/<device>/.
#
# Devices:
#   iphone -> "iPhone 17 Pro Max"      (6.9" class, REQUIRED size; 2868x1320)
#   ipad   -> "iPad Pro 13-inch (M4)"  (13" class, REQUIRED iPad size;
#             2752x2064; created on demand — the pre-provisioned
#             "iPad (A16)" is 11" class and can't produce 13" images)
#
# WAD provisioning: copies the same real test WADs as
# Scripts/provision-test-wads.sh but deliberately NOT the synthetic
# `badiwad.wad` negative-test fixture — it would show up as a bogus IWAD in
# the library list and IWAD picker in the marketing shots.
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
#   Scripts/capture-screenshots.sh prepare      # temp test + xcodegen + build
#   Scripts/capture-screenshots.sh capture iphone
#   Scripts/capture-screenshots.sh capture ipad
#   Scripts/capture-screenshots.sh cleanup      # remove temp test + xcodegen
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="com.tylervick.waddle"
WAD_SRC="$HOME/Downloads/doom-test-wads"
DERIVED="App/build"
APP_PATH="$DERIVED/Build/Products/Debug-iphonesimulator/WADdle.app"
TEST_FILE="App/UITests/ScreenshotCaptureTests.swift"
OUT_ROOT="docs/app-store/screenshots"
RESULTS_ROOT="${TMPDIR:-/tmp}/waddle-screenshots"

IPHONE_NAME="iPhone 17 Pro Max"
IPAD_NAME="iPad Pro 13-inch (M4)"
IPAD_DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB"
RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-26-2"

device_name() { [ "$1" = iphone ] && echo "$IPHONE_NAME" || echo "$IPAD_NAME"; }
device_slug() { [ "$1" = iphone ] && echo "iphone-6.9" || echo "ipad-13"; }

udid_for() {
    # `|| true`: no-match is a real case (the iPad gets created on demand),
    # and set -e would otherwise kill the script inside the substitution.
    xcrun simctl list devices available | { grep -F "$1 (" || true; } \
        | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/'
}

write_test() {
    cat > "$TEST_FILE" <<'EOF'
import XCTest

/// TEMPORARY — written by Scripts/capture-screenshots.sh, removed by its
/// `cleanup` step. Not part of the committed test suite. Attaches
/// full-resolution screenshots for the script to export from the xcresult.
final class ScreenshotCaptureTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The app is landscape-only but the simulator boots (and stays) in
    /// portrait, where the app draws sideways — letterboxed on iPad. The
    /// orientation set only sticks once the app is frontmost, so call this
    /// right after every launch().
    private func forceLandscape() {
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1.0)  // rotation animation
    }

    private func shoot(_ name: String) {
        Thread.sleep(forTimeInterval: 1.5)  // settle transitions/animations
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// iPhone renders a bottom UITabBar; iPad (iOS 26) may expose the
    /// floating top bar differently — fall back to a plain button query.
    private func tapTab(_ app: XCUIApplication, _ label: String) {
        let tab = app.tabBars.buttons[label]
        if tab.waitForExistence(timeout: 5) { tab.tap() }
        else { app.buttons[label].firstMatch.tap() }
    }

    /// iPadOS 26 defaults to the "Windowed Apps" multitasking style, which
    /// puts this landscape-only, fullscreen-only app sideways in a
    /// letterboxed portrait window. No public simctl/defaults switch
    /// exists, so flip Settings to "Full Screen Apps" the way a user
    /// would. Runs first (digits sort before letters in XCTest ordering);
    /// skipped on iPhone.
    @MainActor
    func test0_ConfigureIPadFullScreenMode() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()

        let candidates = ["Multitasking & Gestures", "Home Screen & Multitasking"]
        var pane: XCUIElement?
        for _ in 0..<6 {
            if let hit = candidates.map({ settings.staticTexts[$0] })
                .first(where: { $0.exists }) {
                pane = hit
                break
            }
            settings.swipeUp()
        }
        guard let pane else {
            XCTFail("multitasking settings pane not found")
            return
        }
        pane.tap()

        let fullScreen = settings.staticTexts["Full Screen Apps"]
        XCTAssertTrue(fullScreen.waitForExistence(timeout: 5),
                      "Full Screen Apps option not found")
        fullScreen.tap()
        Thread.sleep(forTimeInterval: 1.0)
        settings.terminate()
    }

    @MainActor
    func testA_MenuScreens() throws {
        let app = XCUIApplication()
        app.launch()  // no env vars: no debug HUD, no test seams
        forceLandscape()

        XCTAssertTrue(app.buttons["playFreedoom1"].waitForExistence(timeout: 20))
        // Checked here, on the Play tab: elements on a background tab don't
        // exist in the hierarchy, so checking after switching to Library
        // would always create a duplicate loadout on a re-run.
        let scytheLoadoutExists = app.buttons["loadout-SCYTHE"].exists

        // Library (before creating the loadout, so no notice banner in shot).
        tapTab(app, "Library")
        XCTAssertTrue(app.staticTexts["SCYTHE"].waitForExistence(timeout: 30),
                      "provisioned WADs not adopted — run the warm-up launch first")
        shoot("02-library")

        // One-tap loadout from the SCYTHE PWAD row (context menu), so the
        // Play grid has a third tile.
        if !scytheLoadoutExists {
            app.staticTexts["SCYTHE"].press(forDuration: 1.2)
            let create = app.buttons["newLoadoutFromPWAD-SCYTHE"]
            XCTAssertTrue(create.waitForExistence(timeout: 5))
            create.tap()
            Thread.sleep(forTimeInterval: 6.5)  // notice banner auto-dismiss
        }

        // Loadout grid.
        tapTab(app, "Play")
        let scytheTile = app.buttons["loadout-SCYTHE"]
        XCTAssertTrue(scytheTile.waitForExistence(timeout: 10))
        shoot("01-loadout-grid")

        // Loadout editor (Edit on the SCYTHE tile: shows suggested IWAD +
        // PWAD list + complevel, richer than an empty New Loadout form).
        scytheTile.press(forDuration: 1.2)
        let edit = app.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        XCTAssertTrue(app.textFields["loadoutNameField"].waitForExistence(timeout: 5))
        shoot("03-loadout-editor")
        app.buttons["Cancel"].tap()

        // Control Feel sheet (gear menu).
        let menu = app.buttons["touchSchemeMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let controlFeel = app.buttons["controlFeelButton"]
        XCTAssertTrue(controlFeel.waitForExistence(timeout: 5))
        controlFeel.tap()
        XCTAssertTrue(app.buttons["controlFeelDoneButton"].waitForExistence(timeout: 5))
        shoot("04-control-feel")
        app.buttons["controlFeelDoneButton"].tap()
    }

    @MainActor
    func testB_InGameScreens() throws {
        let app = XCUIApplication()
        // Menu-free path in-game + overlay visible under XCUITest's phantom
        // controller; neither adds any on-screen debug chrome.
        app.launchEnvironment["WADDLE_TEST_WARP"] = "1"
        app.launchEnvironment["WADDLE_FORCE_TOUCH_OVERLAY"] = "1"
        app.launch()
        forceLandscape()

        let play = app.buttons["playFreedoom1"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        play.tap()

        let fire = app.buttons["fireButton"]
        XCTAssertTrue(fire.waitForExistence(timeout: 30), "overlay never installed")
        Thread.sleep(forTimeInterval: 5)  // level load + screen wipe
        shoot("05-ingame")

        app.buttons["automapButton"].tap()
        shoot("06-automap")

        app.terminate()  // don't leave the engine session running
    }
}
EOF
}

prepare() {
    echo "== prepare: temp UITest + xcodegen + build-for-testing"
    write_test
    (cd App && xcodegen generate)
    # Concrete destination, not "generic/platform=iOS Simulator": the
    # generic one adds x86_64, which WoofEngine.xcframework doesn't ship.
    # The arm64 products run on every simulator on this Apple Silicon host.
    xcodebuild build-for-testing \
        -project App/WADdle.xcodeproj -scheme WADdle \
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
        echo "creating $IPAD_NAME simulator"
        udid="$(xcrun simctl create "$IPAD_NAME" "$IPAD_DEVICE_TYPE" "$RUNTIME")"
    fi
    [ -n "$udid" ] || { echo "no simulator named $name" >&2; exit 1; }

    xcrun simctl boot "$udid" 2>/dev/null || true
    xcrun simctl bootstatus "$udid"
    # Marketing-clean status bar (Apple's own screenshot convention).
    xcrun simctl status_bar "$udid" override --time "9:41" \
        --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
    # Fresh container each run: no stale loadouts/config from prior captures.
    xcrun simctl uninstall "$udid" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl install "$udid" "$APP_PATH"
    provision "$udid"
    seed_engine_config "$udid"
    warm_up "$udid"

    result="$RESULTS_ROOT/$slug.xcresult"
    rm -rf "$result"; mkdir -p "$RESULTS_ROOT"
    xcodebuild test-without-building \
        -project App/WADdle.xcodeproj -scheme WADdle \
        -destination "platform=iOS Simulator,id=$udid" \
        -only-testing:WADdleUITests/ScreenshotCaptureTests \
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
# XCUIScreen returns a portrait pixel buffer with the landscape-only app's
# content rotated 90° CW; 270° puts it upright at the App Store's expected
# landscape dimensions. Shots taken while the device was already landscape
# (the test rotates it in setUp) come out upright and are left alone.
def png_size(path):
    with open(path, "rb") as f:
        header = f.read(24)
    return int.from_bytes(header[16:20], "big"), int.from_bytes(header[20:24], "big")
for path in rotated:
    w, h = png_size(path)
    if h > w:
        subprocess.run(["sips", "--rotate", "270", path],
                       check=True, capture_output=True)
print(f"exported {count} screenshots -> {dst}")
if count < 6:
    sys.exit(f"expected 6 screenshots, got {count}")
PYEOF
    rm -rf "$tmp"
}

cleanup() {
    echo "== cleanup: remove temp UITest + regenerate project"
    rm -f "$TEST_FILE"
    (cd App && xcodegen generate)
}

case "${1:-all}" in
    prepare) prepare ;;
    capture) capture "${2:?usage: capture iphone|ipad}" ;;
    cleanup) cleanup ;;
    all)
        trap cleanup EXIT
        prepare
        capture iphone
        capture ipad
        ;;
    *) echo "usage: $0 [prepare | capture iphone|ipad | cleanup]" >&2; exit 1 ;;
esac
