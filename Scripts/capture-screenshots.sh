#!/bin/bash
# App Store screenshot pipeline (Plan 4 Task 7).
#
# Drives the app with a TEMPORARY XCUITest (ScreenshotCaptureTests.swift,
# written by this script into App/UITests, removed again by `cleanup`) —
# not manual pauses. The test plays an in-game Freedoom session first, then
# navigates the Play tab / Library / preset editor, attaching
# full-resolution XCUIScreen shots; the script then exports them from the
# .xcresult bundle into docs/app-store/screenshots/<device>/.
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
///
/// The two tests are ordered deliberately (XCTest runs methods in selector
/// order): the in-game one runs FIRST because playing a base game stamps
/// `lastPlayed` (LibraryService.markPlayed saves synchronously, before the
/// blocking engine session starts), and that is what gives the menu test's
/// Play-tab shot a populated "Recently Played" section.
final class ScreenshotCaptureTests: XCTestCase {

    /// The preset built for the marketing shots. SCYTHE is a Doom-2-format
    /// megawad, so it belongs on Freedoom Phase 2; the name is the one
    /// `PresetName.suggested` auto-generates from that pairing, which is in
    /// turn what the Play tile's "loadout-<name>" identifier is built from.
    private let presetBase = "Freedoom Phase 2"
    private let presetPWAD = "SCYTHE"
    private var presetName: String { "\(presetBase) + \(presetPWAD)" }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The simulator boots (and stays) in portrait. Since the orientation fix
    /// (a9acd51) the app supports portrait too, so a portrait device now
    /// yields a genuinely portrait screenshot — still the wrong aspect for
    /// the App Store's landscape slots, just no longer a sideways one. The
    /// orientation only sticks once the app is frontmost, so call this right
    /// after every launch().
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

    /// Navigation MUST fail loudly. The predecessor of these two helpers tapped
    /// the tab bar behind a bare `if tab.waitForExistence(...)`, with no
    /// assertion. When the shelf (PR #144) deleted that tab bar the helper
    /// stopped navigating and stopped complaining: every subsequent `shoot(...)`
    /// photographed whatever happened to be on screen, so a capture run emitted
    /// six correctly-named images of the wrong screens and exited 0 — straight
    /// into docs/app-store/screenshots/, which is what the App Store submission
    /// and README.md both read from. A silent miss is the worst outcome
    /// available to this script, strictly worse than a crash, because nothing
    /// downstream re-checks the pixels. Assert every step.

    /// `openManage` and `returnToShelf` are NOT defined here. They live in
    /// App/UITests/XCTestCase+UIHelpers.swift, which compiles into this same UI
    /// test target, and both already assert. Redeclaring them as private
    /// methods on this subclass does not shadow the extension — it is a compile
    /// error ("overriding declaration requires an 'override' keyword"), which
    /// is how the duplication was caught. Use the shared ones.

    /// Scrolls `element` into the hierarchy. Restored after being deleted as
    /// dead code in the shelf migration — it is needed again, for a new reason.
    /// SwiftUI's lazy containers (LazyVGrid on the shelf, List in Manage) omit
    /// off-screen cells from the accessibility hierarchy entirely, so `exists`
    /// is false and no `waitForExistence` will ever change it. The seeded
    /// Continue hero made this bite again by pushing the shelf grid below the
    /// fold, and Manage's preset rows sit under three WAD groups.
    @discardableResult
    @MainActor
    private func scrollIntoView(_ app: XCUIApplication, _ element: XCUIElement) -> Bool {
        for _ in 0..<6 {
            if element.exists { return true }
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.5)
        }
        return element.exists
    }

    /// Opens the player-settings sheet from the shelf's gear. The identifier is
    /// still `touchSchemeMenu` — deliberately kept across the Menu-to-sheet
    /// conversion so existing tests kept working.
    ///
    /// `@MainActor` to match the test methods below: without it, referencing
    /// `app.navigationBars` inside `XCTAssertTrue`'s autoclosure warns about
    /// main-actor isolation.
    @MainActor
    private func openPlayerSettings(_ app: XCUIApplication) {
        let gear = app.buttons["touchSchemeMenu"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "gear missing from the shelf")
        gear.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10),
                      "tapped the gear but the Settings sheet never appeared")
    }

    /// iPadOS 26 defaults to the "Windowed Apps" multitasking style. Since
    /// the orientation fix (a9acd51) the app no longer lands sideways in a
    /// letterboxed portrait window there — it opens upright and fills the
    /// screen — but the system still draws a window-resize grabber over the
    /// app's bottom-right corner, and it does not fade (still in frame
    /// minutes after launch). That belongs in no marketing shot, so this
    /// step survives the fix. No public simctl/defaults switch exists for
    /// the multitasking style, so flip Settings to "Full Screen Apps" the
    /// way a user would. Runs first (digits sort before letters in XCTest
    /// ordering); skipped on iPhone.
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

    /// 05-ingame, 06-automap. Runs first of the two capture tests — see the
    /// class note on ordering.
    @MainActor
    func testA_InGameScreens() throws {
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

        let automap = app.buttons["automapButton"]
        XCTAssertTrue(automap.waitForExistence(timeout: 5),
                      "automap button missing from the overlay")
        automap.tap()
        shoot("06-automap")

        app.terminate()  // don't leave the engine session running
    }

    /// 02-library, 03-preset-editor, 01-play-tab, 04-control-feel.
    @MainActor
    func testB_MenuScreens() throws {
        let app = XCUIApplication()
        // The one seam this test needs. Woof autosaves only from
        // `G_DoWorldDone` (level completion); testA warps in via `G_InitNew`
        // and never finishes the level, so it leaves no save and the shelf
        // draws no Continue hero — the shelf's headline affordance, missing
        // from the marketing shot. This gives the item testA played a save so
        // the hero renders. No debug HUD or other seams.
        app.launchEnvironment["WADDLE_SEED_CONTINUE_SAVE"] = "1"
        app.launch()
        forceLandscape()

        // Probe the shelf by its chrome, not by a tile. With the Continue hero
        // seeded above it, the LazyVGrid starts below the fold on a landscape
        // phone — and a LazyVGrid cell below the fold is absent from the
        // accessibility hierarchy entirely, not merely non-hittable, so
        // `app.buttons["playFreedoom1"]` does not exist and no wait will change
        // that. `manageButton` is toolbar chrome and always present.
        XCTAssertTrue(app.buttons["manageButton"].waitForExistence(timeout: 20),
                      "shelf never came up")

        // Manage: the grouped file manager (Base Games / Mods / Patches), shot
        // before the preset exists so no notice banner or in-use warning is on
        // screen. Everything below happens here rather than on the shelf —
        // preset creation and editing both moved into Manage with the shelf
        // rework, and so did the only reliable place to ask whether the preset
        // already exists.
        openManage(app)
        let scytheRow = app.descendants(matching: .any)
            .matching(identifier: "libraryRow-SCYTHE.WAD").firstMatch
        XCTAssertTrue(scytheRow.waitForExistence(timeout: 30),
                      "provisioned WADs not adopted — run the warm-up launch first")
        shoot("02-library")

        // The re-run probe. It used to be the shelf's "Presets" section header,
        // which the shelf deleted along with every other section header (spec
        // §3: one grid, no headers) — so that check would have read "no preset"
        // forever and created a duplicate on every run. Manage lists presets
        // under a stable per-name identifier, and we are already standing in it.
        // Scroll to decide, not just to assert. Manage's preset rows sit under
        // three WAD groups in a lazy List, so a bare `waitForExistence` reports
        // "no preset" whenever one merely sits below the fold — and this run
        // would then try to create a duplicate, the exact re-run hazard this
        // probe exists to prevent.
        let presetRow = app.descendants(matching: .any)
            .matching(identifier: "managePreset-\(presetName)").firstMatch
        let presetExists = scrollIntoView(app, presetRow)

        if presetExists {
            // Re-run against a container that already has the preset: edit it
            // instead of creating a second one.
            presetRow.tap()
            XCTAssertTrue(app.textFields["loadoutNameField"].waitForExistence(timeout: 10),
                          "tapped the existing preset but the editor never opened")
            shoot("03-preset-editor")
            app.buttons["Cancel"].tap()
        } else {
            // Preset creation has exactly one door since the rework: the +
            // button opens PresetCreationFlow's base-game picker, and picking
            // a row pushes into the editor already seeded with that base.
            let newPreset = app.buttons["newLoadoutButton"]
            XCTAssertTrue(newPreset.waitForExistence(timeout: 5),
                          "New Preset toolbar button missing")
            newPreset.tap()
            let baseRow = app.buttons["createPresetBase-\(presetBase)"]
            XCTAssertTrue(baseRow.waitForExistence(timeout: 10))
            baseRow.tap()
            XCTAssertTrue(app.textFields["loadoutNameField"].waitForExistence(timeout: 10))
            // Add the mod before shooting: a seeded-but-empty editor has no
            // load-order list, which is the part worth photographing.
            let addPWADMenu = app.buttons["addPWADMenu"]
            XCTAssertTrue(addPWADMenu.waitForExistence(timeout: 5),
                          "Add PWAD menu missing from the editor")
            addPWADMenu.tap()
            let addPWAD = app.buttons["addPWADButton-\(presetPWAD)"]
            XCTAssertTrue(addPWAD.waitForExistence(timeout: 5))
            addPWAD.tap()
            shoot("03-preset-editor")
            app.buttons["saveLoadoutButton"].tap()
            XCTAssertTrue(app.buttons["newLoadoutButton"].waitForExistence(timeout: 10),
                          "creation sheet never dismissed back to Manage")
        }

        // Back to the shelf for the home shot: one grid of base games and
        // presets, tiles carrying extracted TITLEPIC art. This is what a user
        // sees on launch.
        //
        // The Continue hero is asserted, not hoped for. It renders only because
        // WADDLE_SEED_CONTINUE_SAVE gave testA's item a save (see the launch
        // above), and what `ShelfView.hasResumableSave` ultimately consults is
        // `EngineSaveSlot`'s filename-based resolution. If that ever becomes
        // content-aware, the seeded marker stops resolving and the hero quietly
        // vanishes from the marketing shot — the precise silent-wrong-image
        // failure this script was rewritten to eliminate (#156). Assert it.
        //
        // The filename stays `01-play-tab` on purpose. Renaming it here would
        // orphan the image that file currently holds and break README.md's
        // <img src>, while the replacement image does not exist yet — the
        // rename belongs with the re-capture, where the files are being
        // replaced anyway. See issue #127.
        returnToShelf(app)
        XCTAssertTrue(app.buttons["continueHero"].waitForExistence(timeout: 10),
                      "no Continue hero on the shelf — WADDLE_SEED_CONTINUE_SAVE did not take, "
                      + "and this shot would ship without the shelf's headline affordance")

        // Preset creation is deliberately NOT asserted from a shelf tile here.
        // Issue #159: the hero has no height cap, so on a landscape phone it
        // fills the viewport and the LazyVGrid below it holds no cells in the
        // accessibility hierarchy at all — scrolling does not recover them
        // reliably. Once #159 lands and the grid is visible beside the hero,
        // add `XCTAssertTrue(app.buttons["loadout-\(presetName)"].waitFor...)`
        // back here, after the shot. Until then this shot is known to show the
        // hero and nothing else, which is why #159 blocks the re-capture.
        shoot("01-play-tab")


        // Control Feel, now two levels deep: the gear opens the Settings sheet
        // (a sheet since the rework, not a Menu), and Control Feel… opens its
        // own sheet on top of that. Both are dismissed so the run ends on the
        // shelf rather than leaving a sheet stacked over it.
        openPlayerSettings(app)
        let controlFeel = app.buttons["controlFeelButton"]
        XCTAssertTrue(controlFeel.waitForExistence(timeout: 5),
                      "Control Feel button missing from the Settings sheet")
        controlFeel.tap()
        XCTAssertTrue(app.buttons["controlFeelDoneButton"].waitForExistence(timeout: 5),
                      "Control Feel sheet never opened")
        shoot("04-control-feel")
        app.buttons["controlFeelDoneButton"].tap()
        let settingsDone = app.navigationBars["Settings"].buttons["Done"]
        XCTAssertTrue(settingsDone.waitForExistence(timeout: 5),
                      "Settings sheet did not survive dismissing Control Feel")
        settingsDone.tap()
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
