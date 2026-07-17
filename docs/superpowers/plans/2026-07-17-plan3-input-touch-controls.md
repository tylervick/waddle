# Plan 3: Input & Touch Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make BoomBox playable by touch: an on-screen overlay (virtual movement stick, drag-to-turn, fire/use/weapon/automap/menu buttons) that drives the engine through a virtual SDL gamepad, auto-hiding when a physical controller connects — plus the ledgered Plan-3 performance and test-hygiene items.

**Architecture:** A small C shim in the engine's iOS layer attaches an **SDL virtual gamepad** (`SDL_AttachVirtualJoystick`) and feeds it axis/button state; drag-to-turn is injected as relative `SDL_EVENT_MOUSE_MOTION`. Woof!'s existing, user-remappable gamepad/mouse paths do everything else — no keyboard hacks, no engine input-code changes. On the Swift side, a UIKit overlay view installs into SDL's own UIWindow (via `SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER`) once the engine session creates it, and a presenter auto-hides it when GameController reports a physical controller/keyboard.

**Tech Stack:** C (engine shim in `woof_ios.c`), Swift 6 / UIKit overlay + GameController framework, XCTest/XCUITest, existing build pipeline (Scripts/build-engine.sh regenerates the xcframework after engine edits).

**Specs/refs:** spec §3 (touch overlay, input passthrough), Plan-2 ledger's named Plan-3 items. Verified engine/SDL facts: SDL3 3.4.12 has `SDL_AttachVirtualJoystick`/`SDL_SetJoystickVirtualAxis`/`SDL_SetJoystickVirtualButton`/`SDL_DetachVirtualJoystick` (`SDL_joystick.h:539` etc.) and `SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER` (`SDL_video.h:1636`); Woof! reads `SDL_GAMEPAD_AXIS_LEFTX/LEFTY` for movement (`i_input.c:169-170`), triggers/buttons via `I_GetAxisState`/gamepad events, and hot-opens gamepads (`I_OpenGamepad`, `i_input.c:566`).

## Global Constraints

- Deployment target **iOS 26.0**, Xcode 26.2, simulator "iPhone 17 Pro" (iOS 26.2).
- Commit messages: plain conventional, **no Co-Authored-By, no Claude/AI mention**. 1Password signing may hang: retry loop (10 × 15s), NEVER `--no-gpg-sign`.
- Never commit: `Vendor/`, `App/Resources/GameData/`, `App/Resources/woof.pk3`, `App/*.xcodeproj`, `App/Info.plist`, test WADs.
- Engine edits: minimal, in `Engine/woof/src/woof_ios.{h,c}` only (already ours); any OTHER upstream file touched must be `WOOF_IOS`-guarded and documented in `Engine/WOOF_UPSTREAM.md`. **Every engine edit requires `Scripts/build-engine.sh` before the app sees it.**
- Engine facts (do not "fix"): `-save <dir>`; complevel `vanilla|boom|mbf|mbf21`; woof.pk3 at bundle root; `SDL_SetMainReady()` before first `SDL_Init`; SIGTERM SIG_IGN bracket; engine runs on the main thread and SDL pumps the UIKit run loop during sessions (so main-queue timers/UI updates DO run mid-session — this is what makes the overlay possible).
- UITest contracts (iOS 26): tab switching via `app.tabBars.buttons["Play"/"Library"]` labels; pane asserts via `app.otherElements["playTab"/"libraryTab"]`; existing ids `playFreedoom1`, `engineExitLabel` must keep working; EngineSmokeTests must stay green un-modified.
- Don't run two xcodebuild test sessions against one simulator concurrently.
- Full-suite gate command: `xcodebuild -project App/BoomBox.xcodeproj -scheme BoomBox -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:BoomBoxTests -only-testing:BoomBoxUITests/EngineSmokeTests test` (RealWADTests additionally needs provisioned WADs from `~/Downloads/doom-test-wads/` via `Scripts/provision-test-wads.sh`).

## File Structure

```
Engine/woof/src/woof_ios.h        (modify: touch-gamepad shim API + debug counter)
Engine/woof/src/woof_ios.c        (modify: shim impl + sigemptyset cleanup)
App/Sources/Touch/TouchStickModel.swift   (new: pure stick math — TDD)
App/Sources/Touch/TouchGamepad.swift      (new: Swift wrapper over the shim)
App/Sources/Touch/TouchOverlayView.swift  (new: UIKit overlay — stick, turn region, buttons)
App/Sources/Touch/OverlayPresenter.swift  (new: install/remove into SDL window, auto-hide)
App/Sources/EngineSession.swift   (modify: overlay lifecycle + autoquit generation fix)
App/Sources/WAD/WADStore.swift    (modify: streamed SHA-1, copy-not-Data, no rescan)
App/Sources/WAD/ZipExtractor.swift (modify: per-entry size cap)
App/Sources/Library/ImportService.swift (modify: async adoption off the launch path)
App/Sources/BoomBoxApp.swift      (modify: adoption via .task, not init)
App/Tests/…                       (new/extended unit tests per task)
App/UITests/TouchControlsTests.swift (new: overlay smoke gate)
docs/manual-testing.md            (new: on-device physical-input checklist)
```

---

### Task 1: Engine shim — virtual touch gamepad + turn injection + window pointer

**Files:**
- Modify: `Engine/woof/src/woof_ios.h`
- Modify: `Engine/woof/src/woof_ios.c`

**Interfaces:**
- Produces (exact C API, consumed by Tasks 3-6 via the WoofEngine module):
```c
bool WoofIOS_AttachTouchGamepad(void);      // attach + open virtual gamepad; true on success; idempotent
void WoofIOS_DetachTouchGamepad(void);      // close + detach; idempotent
void WoofIOS_SetTouchAxis(int sdl_axis, float value);      // SDL_GAMEPAD_AXIS_*, value -1..1
void WoofIOS_SetTouchButton(int sdl_button, bool down);    // SDL_GAMEPAD_BUTTON_*
void WoofIOS_InjectRelativeTurn(float dx_points);          // pushes relative mouse motion
void *WoofIOS_GetUIWindowPointer(void);     // SDL window's UIWindow*, NULL before video init
int  WoofIOS_DebugTouchEventCount(void);    // total shim calls that reached SDL (test telemetry)
```

- [ ] **Step 1: Extend woof_ios.h**

Append before the final `#endif` (keeping existing declarations untouched):
```c
// --- Touch-control shim (Plan 3) ---
// The native overlay drives a virtual SDL gamepad; the engine consumes it
// through its normal, user-remappable gamepad bindings. Turn is injected as
// relative mouse motion. All functions are main-thread-only (same thread as
// WoofIOS_Run; SDL pumps the run loop, so UIKit callbacks qualify).

#include <stdbool.h>

bool WoofIOS_AttachTouchGamepad(void);
void WoofIOS_DetachTouchGamepad(void);
void WoofIOS_SetTouchAxis(int sdl_axis, float value);
void WoofIOS_SetTouchButton(int sdl_button, bool down);
void WoofIOS_InjectRelativeTurn(float dx_points);
void *WoofIOS_GetUIWindowPointer(void);
int WoofIOS_DebugTouchEventCount(void);
```

- [ ] **Step 2: Implement in woof_ios.c**

Append:
```c
// --- Touch-control shim (Plan 3) ---

static SDL_JoystickID touch_joystick_id;
static SDL_Joystick *touch_joystick;
static int touch_event_count;

bool WoofIOS_AttachTouchGamepad(void)
{
    if (touch_joystick)
    {
        return true;
    }
    if (!SDL_WasInit(SDL_INIT_JOYSTICK))
    {
        return false; // engine hasn't initialized input yet; caller retries
    }

    SDL_VirtualJoystickDesc desc;
    SDL_INIT_INTERFACE(&desc);
    desc.type = SDL_JOYSTICK_TYPE_GAMEPAD;
    desc.naxes = SDL_GAMEPAD_AXIS_COUNT;
    desc.nbuttons = SDL_GAMEPAD_BUTTON_COUNT;
    desc.name = "BoomBox Touch Controls";

    touch_joystick_id = SDL_AttachVirtualJoystick(&desc);
    if (touch_joystick_id == 0)
    {
        return false;
    }
    touch_joystick = SDL_OpenJoystick(touch_joystick_id);
    if (!touch_joystick)
    {
        SDL_DetachVirtualJoystick(touch_joystick_id);
        touch_joystick_id = 0;
        return false;
    }
    return true;
}

void WoofIOS_DetachTouchGamepad(void)
{
    if (!touch_joystick)
    {
        return;
    }
    SDL_CloseJoystick(touch_joystick);
    SDL_DetachVirtualJoystick(touch_joystick_id);
    touch_joystick = NULL;
    touch_joystick_id = 0;
}

void WoofIOS_SetTouchAxis(int sdl_axis, float value)
{
    if (!touch_joystick)
    {
        return;
    }
    if (value > 1.0f) value = 1.0f;
    if (value < -1.0f) value = -1.0f;
    SDL_SetJoystickVirtualAxis(touch_joystick, sdl_axis,
                               (Sint16)(value * 32767.0f));
    touch_event_count++;
}

void WoofIOS_SetTouchButton(int sdl_button, bool down)
{
    if (!touch_joystick)
    {
        return;
    }
    SDL_SetJoystickVirtualButton(touch_joystick, sdl_button, down);
    touch_event_count++;
}

void WoofIOS_InjectRelativeTurn(float dx_points)
{
    SDL_Event event = {0};
    event.type = SDL_EVENT_MOUSE_MOTION;
    event.motion.xrel = dx_points;
    event.motion.yrel = 0.0f;
    if (SDL_PushEvent(&event))
    {
        touch_event_count++;
    }
}

void *WoofIOS_GetUIWindowPointer(void)
{
    int count = 0;
    SDL_Window **windows = SDL_GetWindows(&count);
    void *result = NULL;
    if (windows && count > 0)
    {
        result = SDL_GetPointerProperty(SDL_GetWindowProperties(windows[0]),
                                        SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER,
                                        NULL);
    }
    SDL_free(windows);
    return result;
}

int WoofIOS_DebugTouchEventCount(void)
{
    return touch_event_count;
}
```
Also apply the ledgered one-liner while in this file: replace the `memset`-zeroed `sa_mask` in the SIGTERM bracket with `sigemptyset(&sa.sa_mask);` (adjust to the actual variable name in the existing code).

- [ ] **Step 3: Verify Woof! picks up a hot-attached gamepad**

Read `Engine/woof/src/i_input.c` around the `SDL_EVENT_GAMEPAD_ADDED` handling (the device-selection logic near lines 490-520 and `I_OpenGamepad` at 566) and confirm: with the default `joy_device` config, a gamepad that appears mid-session generates `SDL_EVENT_GAMEPAD_ADDED` which the event loop routes to open it. Record the exact code path (file:line) in the commit message body or WOOF_UPSTREAM.md note. If hot-attach is NOT auto-opened (only enumerated at startup), the fallback is: attach the virtual gamepad in `WoofIOS_Run` right after `D_DoomMain`'s input init — in that case add `WoofIOS_AttachTouchGamepad()` behind an env check `getenv("BOOMBOX_TOUCH_GAMEPAD")` at a point you verify runs after `I_InitGamepad`, and document the deviation.

- [ ] **Step 4: Rebuild engine + verify symbols**

```bash
Scripts/build-engine.sh
for slice in $(find Vendor/out/WoofEngine.xcframework -name '*.a'); do
  nm -gU "$slice" | grep -c "WoofIOS_AttachTouchGamepad\|WoofIOS_SetTouchAxis\|WoofIOS_GetUIWindowPointer\|WoofIOS_DebugTouchEventCount"
done
```
Expected: each slice reports ≥ 4 matches. Then confirm the app still builds and the smoke gate passes:
```bash
cd App && xcodegen generate && cd ..
xcodebuild -project App/BoomBox.xcodeproj -scheme BoomBox \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BoomBoxUITests/EngineSmokeTests test
```
Expected: `TEST SUCCEEDED`.

- [ ] **Step 5: Update Engine/WOOF_UPSTREAM.md and commit**

Extend the `woof_ios.c` patch-list bullet with one line about the touch shim (+ the hot-attach verification result). Commit:
```bash
git add Engine/woof/src/woof_ios.h Engine/woof/src/woof_ios.c Engine/WOOF_UPSTREAM.md
git commit -m "engine: virtual touch gamepad shim with turn injection and window access"
```

---

### Task 2: TouchStickModel (pure math, TDD)

**Files:**
- Create: `App/Sources/Touch/TouchStickModel.swift`
- Create: `App/Tests/TouchStickModelTests.swift`

**Interfaces:**
- Produces:
```swift
struct TouchStickModel: Equatable {
    var center: CGPoint
    var radius: CGFloat            // full-deflection distance in points
    var deadZone: CGFloat = 0.2    // fraction of radius
    func axes(for touch: CGPoint) -> (x: Float, y: Float)  // each -1...1
    func knobPosition(for touch: CGPoint) -> CGPoint       // clamped to radius, for drawing
}
```
- Semantics: vector from `center` to `touch`; magnitude ≤ deadZone·radius → (0,0); magnitude ≥ radius → unit direction; in between → linearly rescaled from (deadZone·radius…radius) to (0…1). +y axis value means DOWN (SDL convention: positive LEFTY = down/backward).

- [ ] **Step 1: Write the failing tests**

`App/Tests/TouchStickModelTests.swift`:
```swift
import XCTest
@testable import BoomBox

final class TouchStickModelTests: XCTestCase {
    let stick = TouchStickModel(center: CGPoint(x: 100, y: 100), radius: 50)

    func testCenterIsNeutral() {
        let axes = stick.axes(for: CGPoint(x: 100, y: 100))
        XCTAssertEqual(axes.x, 0)
        XCTAssertEqual(axes.y, 0)
    }

    func testInsideDeadZoneIsNeutral() {
        // deadZone 0.2 * radius 50 = 10 points; 8 points right is inside
        let axes = stick.axes(for: CGPoint(x: 108, y: 100))
        XCTAssertEqual(axes.x, 0)
        XCTAssertEqual(axes.y, 0)
    }

    func testFullDeflectionRightClampsToOne() {
        let axes = stick.axes(for: CGPoint(x: 300, y: 100))
        XCTAssertEqual(axes.x, 1.0, accuracy: 0.001)
        XCTAssertEqual(axes.y, 0.0, accuracy: 0.001)
    }

    func testDownIsPositiveY() {
        let axes = stick.axes(for: CGPoint(x: 100, y: 200))
        XCTAssertEqual(axes.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(axes.y, 1.0, accuracy: 0.001)
    }

    func testMidwayRescalesLinearly() {
        // 30 points right: (30-10)/(50-10) = 0.5
        let axes = stick.axes(for: CGPoint(x: 130, y: 100))
        XCTAssertEqual(axes.x, 0.5, accuracy: 0.001)
    }

    func testDiagonalStaysInsideUnitCircle() {
        let axes = stick.axes(for: CGPoint(x: 200, y: 200))
        let magnitude = sqrt(Double(axes.x * axes.x + axes.y * axes.y))
        XCTAssertEqual(magnitude, 1.0, accuracy: 0.001)
    }

    func testKnobPositionClampsToRadius() {
        let knob = stick.knobPosition(for: CGPoint(x: 300, y: 100))
        XCTAssertEqual(knob.x, 150, accuracy: 0.001)  // center.x + radius
        XCTAssertEqual(knob.y, 100, accuracy: 0.001)
    }

    func testKnobPositionInsideRadiusFollowsTouch() {
        let knob = stick.knobPosition(for: CGPoint(x: 120, y: 110))
        XCTAssertEqual(knob.x, 120, accuracy: 0.001)
        XCTAssertEqual(knob.y, 110, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild -project App/BoomBox.xcodeproj -scheme BoomBox \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BoomBoxTests test
```
Expected: build FAILS ("cannot find 'TouchStickModel'").

- [ ] **Step 3: Implement**

`App/Sources/Touch/TouchStickModel.swift`:
```swift
import CoreGraphics

/// Pure geometry for a virtual thumbstick. No UIKit, no SDL — fully testable.
struct TouchStickModel: Equatable {
    var center: CGPoint
    var radius: CGFloat
    var deadZone: CGFloat = 0.2

    func axes(for touch: CGPoint) -> (x: Float, y: Float) {
        let dx = touch.x - center.x
        let dy = touch.y - center.y
        let distance = sqrt(dx * dx + dy * dy)
        let deadDistance = deadZone * radius
        guard distance > deadDistance else { return (0, 0) }

        let clamped = min(distance, radius)
        let scaled = (clamped - deadDistance) / (radius - deadDistance)
        return (Float(dx / distance * scaled), Float(dy / distance * scaled))
    }

    func knobPosition(for touch: CGPoint) -> CGPoint {
        let dx = touch.x - center.x
        let dy = touch.y - center.y
        let distance = sqrt(dx * dx + dy * dy)
        guard distance > radius else { return touch }
        return CGPoint(x: center.x + dx / distance * radius,
                       y: center.y + dy / distance * radius)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Same command. Expected: `TEST SUCCEEDED`, 8 new tests green.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Touch/TouchStickModel.swift App/Tests/TouchStickModelTests.swift
git commit -m "feat: virtual thumbstick geometry with dead zone and clamping"
```

---

### Task 3: TouchGamepad wrapper + EngineSession autoquit generation fix

**Files:**
- Create: `App/Sources/Touch/TouchGamepad.swift`
- Modify: `App/Sources/EngineSession.swift`
- Create: `App/Tests/EngineSessionGenerationTests.swift`

**Interfaces:**
- Produces:
```swift
@MainActor final class TouchGamepad {
    private(set) var isAttached: Bool
    func attachIfPossible() -> Bool          // WoofIOS_AttachTouchGamepad (retries OK)
    func detach()
    func setMovement(x: Float, y: Float)     // LEFTX/LEFTY
    func setButton(_ button: TouchButton, down: Bool)
    func turn(byPoints dx: CGFloat)          // sensitivity-scaled InjectRelativeTurn
    var turnSensitivity: Float               // default 1.5 (points → mouse counts)
}
enum TouchButton: Int32 {   // raw values = SDL_GamepadButton constants, verified in Step 1
    case south, east, leftShoulder, rightShoulder, back, start
}
// EngineSession additions:
//   static var sessionGeneration: Int  (increments per play() call)
```

- [ ] **Step 1: Verify SDL button/axis constant values**

The WoofEngine module exposes only woof_ios.h — SDL constants aren't importable. Hard-code their values in Swift, verified against the pinned SDL:
```bash
grep -n "SDL_GAMEPAD_BUTTON_SOUTH\|SDL_GAMEPAD_BUTTON_EAST\|SDL_GAMEPAD_BUTTON_BACK\|SDL_GAMEPAD_BUTTON_START\|SDL_GAMEPAD_BUTTON_LEFT_SHOULDER\|SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER" Vendor/src/SDL/include/SDL3/SDL_gamepad.h | head
grep -n "SDL_GAMEPAD_AXIS_LEFTX\|SDL_GAMEPAD_AXIS_LEFTY" Vendor/src/SDL/include/SDL3/SDL_gamepad.h | head
```
Record the enum ordinal values (they're a plain C enum starting at SOUTH=0, LEFTX=0 — confirm) and use them as the Swift raw values with a comment citing the header. If they differ from the enum stub above, adjust the Swift enum accordingly.

- [ ] **Step 2: Write the failing generation test**

`App/Tests/EngineSessionGenerationTests.swift`:
```swift
import XCTest
@testable import BoomBox

/// The autoquit timer must only fire for the session it was created for
/// (ledgered Plan-1 finding: a stale timer could quit the NEXT session).
@MainActor
final class EngineSessionGenerationTests: XCTestCase {
    func testGenerationIncrementsPerPlayCall() {
        let before = EngineSession.sessionGeneration
        // play() would block on a real engine; we only test the guard's
        // bookkeeping helper here.
        EngineSession.beginSessionForTesting()
        XCTAssertEqual(EngineSession.sessionGeneration, before + 1)
        EngineSession.beginSessionForTesting()
        XCTAssertEqual(EngineSession.sessionGeneration, before + 2)
    }

    func testStaleGenerationIsDetected() {
        EngineSession.beginSessionForTesting()
        let captured = EngineSession.sessionGeneration
        XCTAssertTrue(EngineSession.isCurrentGeneration(captured))
        EngineSession.beginSessionForTesting()
        XCTAssertFalse(EngineSession.isCurrentGeneration(captured))
    }
}
```

- [ ] **Step 3: Run to verify failure, then implement**

Run the unit suite (FAIL: no such members). Then modify `App/Sources/EngineSession.swift` — replace the autoquit block and add the generation API:
```swift
@MainActor
enum EngineSession {
    private(set) static var isRunning = false
    private(set) static var sessionGeneration = 0

    static func beginSessionForTesting() { sessionGeneration += 1 }
    static func isCurrentGeneration(_ generation: Int) -> Bool {
        generation == sessionGeneration
    }

    @discardableResult
    static func play(arguments: [String]) -> Int32 {
        precondition(!isRunning, "engine session already running")
        precondition(arguments.first == "woof", "argv[0] must be the program name")

        sessionGeneration += 1
        let generation = sessionGeneration

        // Autoquit (UI testing): only quit the session it was armed for.
        if let secondsString = ProcessInfo.processInfo
            .environment["BOOMBOX_AUTOQUIT_SECONDS"],
            let seconds = Double(secondsString)
        {
            Thread.detachNewThread {
                Thread.sleep(forTimeInterval: seconds)
                DispatchQueue.main.async {
                    if isCurrentGeneration(generation) && isRunning {
                        WoofIOS_RequestQuit()
                    }
                }
            }
        }

        isRunning = true
        defer { isRunning = false }

        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        defer { argv.forEach { free($0) } }
        return WoofIOS_Run(Int32(arguments.count), &argv)
    }
}
```
Note: the `DispatchQueue.main.async` hop works because SDL pumps the main run loop during sessions (established in Plan 1); the guard then runs on the same actor as the bookkeeping.

- [ ] **Step 4: Implement TouchGamepad**

`App/Sources/Touch/TouchGamepad.swift`:
```swift
import CoreGraphics
import WoofEngine

/// SDL gamepad button/axis ordinals, verified against the pinned SDL3
/// (Vendor/src/SDL/include/SDL3/SDL_gamepad.h) in Task 3 Step 1.
enum TouchButton: Int32 {
    case south = 0          // SDL_GAMEPAD_BUTTON_SOUTH  -> fire (Woof default)
    case east = 1           // SDL_GAMEPAD_BUTTON_EAST   -> use
    case back = 4           // SDL_GAMEPAD_BUTTON_BACK   -> automap
    case start = 6          // SDL_GAMEPAD_BUTTON_START  -> menu
    case leftShoulder = 9   // SDL_GAMEPAD_BUTTON_LEFT_SHOULDER  -> prev weapon
    case rightShoulder = 10 // SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER -> next weapon
}

private let sdlAxisLeftX: Int32 = 0   // SDL_GAMEPAD_AXIS_LEFTX
private let sdlAxisLeftY: Int32 = 1   // SDL_GAMEPAD_AXIS_LEFTY

@MainActor
final class TouchGamepad {
    private(set) var isAttached = false
    var turnSensitivity: Float = 1.5

    @discardableResult
    func attachIfPossible() -> Bool {
        isAttached = WoofIOS_AttachTouchGamepad()
        return isAttached
    }

    func detach() {
        WoofIOS_DetachTouchGamepad()
        isAttached = false
    }

    func setMovement(x: Float, y: Float) {
        WoofIOS_SetTouchAxis(sdlAxisLeftX, x)
        WoofIOS_SetTouchAxis(sdlAxisLeftY, y)
    }

    func setButton(_ button: TouchButton, down: Bool) {
        WoofIOS_SetTouchButton(button.rawValue, down)
    }

    func turn(byPoints dx: CGFloat) {
        WoofIOS_InjectRelativeTurn(Float(dx) * turnSensitivity)
    }
}
```
(Adjust the hard-coded ordinals to whatever Step 1's grep showed — the comment must cite the verified values.)

- [ ] **Step 5: Run unit suite green + full smoke gate, commit**

```bash
xcodebuild -project App/BoomBox.xcodeproj -scheme BoomBox \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BoomBoxTests -only-testing:BoomBoxUITests/EngineSmokeTests test
```
Expected: `TEST SUCCEEDED` (generation tests + all existing; smoke gate proves the autoquit refactor still quits its own session).
```bash
git add App/Sources/Touch/TouchGamepad.swift App/Sources/EngineSession.swift \
        App/Tests/EngineSessionGenerationTests.swift
git commit -m "feat: touch gamepad wrapper and session-scoped autoquit"
```

---

### Task 4: TouchOverlayView + OverlayPresenter

**Files:**
- Create: `App/Sources/Touch/TouchOverlayView.swift`
- Create: `App/Sources/Touch/OverlayPresenter.swift`
- Modify: `App/Sources/EngineSession.swift` (present/dismiss around the session)

**Interfaces:**
- Consumes: `TouchStickModel`, `TouchGamepad`, `WoofIOS_GetUIWindowPointer`.
- Produces: `OverlayPresenter.begin()` / `.end()` (called by EngineSession); overlay accessibility ids `touchOverlay`, `fireButton`, `useButton`, `weaponPrevButton`, `weaponNextButton`, `automapButton`, `menuButton` (Task 6 depends on these).

- [ ] **Step 1: TouchOverlayView**

`App/Sources/Touch/TouchOverlayView.swift`:
```swift
import UIKit

/// Transparent full-screen overlay: left region = movement stick,
/// right region = drag-to-turn, plus edge-anchored buttons. Pure UIKit —
/// SwiftUI can't live inside SDL's UIWindow without a hosting controller,
/// and we want zero interference with SDL's own event handling.
final class TouchOverlayView: UIView {
    private let gamepad: TouchGamepad

    private var stickTouch: UITouch?
    private var stickModel = TouchStickModel(center: .zero, radius: 60)
    private var turnTouch: UITouch?
    private var lastTurnX: CGFloat = 0

    private let stickBase = CAShapeLayer()
    private let stickKnob = CAShapeLayer()

    init(gamepad: TouchGamepad) {
        self.gamepad = gamepad
        super.init(frame: .zero)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        accessibilityIdentifier = "touchOverlay"

        for layer in [stickBase, stickKnob] {
            layer.fillColor = UIColor.white.withAlphaComponent(0.12).cgColor
            layer.strokeColor = UIColor.white.withAlphaComponent(0.35).cgColor
            layer.lineWidth = 2
            layer.isHidden = true
            self.layer.addSublayer(layer)
        }

        addButton("FIRE", id: "fireButton", button: .south, size: 84)
        addButton("USE", id: "useButton", button: .east, size: 64)
        addButton("◀", id: "weaponPrevButton", button: .leftShoulder, size: 48)
        addButton("▶", id: "weaponNextButton", button: .rightShoulder, size: 48)
        addButton("MAP", id: "automapButton", button: .back, size: 48)
        addButton("≡", id: "menuButton", button: .start, size: 48)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Buttons

    private var buttons: [OverlayButton] = []

    private func addButton(_ title: String, id: String, button: TouchButton,
                           size: CGFloat) {
        let control = OverlayButton(title: title, size: size) { [weak self] down in
            self?.gamepad.setButton(button, down: down)
        }
        control.accessibilityIdentifier = id
        buttons.append(control)
        addSubview(control)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = safeAreaInsets
        let b = bounds
        // Right-hand cluster: FIRE big, USE above it, shoulders top corners,
        // MAP + MENU at top edge.
        place("fireButton", x: b.maxX - inset.right - 70, y: b.maxY - inset.bottom - 90)
        place("useButton", x: b.maxX - inset.right - 160, y: b.maxY - inset.bottom - 60)
        place("weaponPrevButton", x: b.minX + inset.left + 40, y: b.minY + inset.top + 40)
        place("weaponNextButton", x: b.maxX - inset.right - 40, y: b.minY + inset.top + 40)
        place("automapButton", x: b.midX - 40, y: b.minY + inset.top + 32)
        place("menuButton", x: b.midX + 40, y: b.minY + inset.top + 32)
    }

    private func place(_ id: String, x: CGFloat, y: CGFloat) {
        buttons.first { $0.accessibilityIdentifier == id }?.center = CGPoint(x: x, y: y)
    }

    // MARK: Touches (stick + turn; buttons handle their own)

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let point = touch.location(in: self)
            if stickTouch == nil && point.x < bounds.width * 0.4 {
                stickTouch = touch
                stickModel = TouchStickModel(center: point, radius: 60)
                drawStick(at: point)
            } else if turnTouch == nil && point.x >= bounds.width * 0.4 {
                turnTouch = touch
                lastTurnX = point.x
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let point = touch.location(in: self)
            if touch == stickTouch {
                let axes = stickModel.axes(for: point)
                gamepad.setMovement(x: axes.x, y: axes.y)
                moveKnob(to: stickModel.knobPosition(for: point))
            } else if touch == turnTouch {
                gamepad.turn(byPoints: point.x - lastTurnX)
                lastTurnX = point.x
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouches(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouches(touches)
    }

    private func endTouches(_ touches: Set<UITouch>) {
        for touch in touches {
            if touch == stickTouch {
                stickTouch = nil
                gamepad.setMovement(x: 0, y: 0)
                stickBase.isHidden = true
                stickKnob.isHidden = true
            } else if touch == turnTouch {
                turnTouch = nil
            }
        }
    }

    // MARK: Stick drawing

    private func drawStick(at center: CGPoint) {
        stickBase.path = UIBezierPath(
            arcCenter: center, radius: 60, startAngle: 0,
            endAngle: .pi * 2, clockwise: true).cgPath
        moveKnob(to: center)
        stickBase.isHidden = false
        stickKnob.isHidden = false
    }

    private func moveKnob(to point: CGPoint) {
        stickKnob.path = UIBezierPath(
            arcCenter: point, radius: 26, startAngle: 0,
            endAngle: .pi * 2, clockwise: true).cgPath
    }
}

/// A press-and-hold control (UIButton's tap gesture adds latency; Doom fire
/// must be press=down / release=up).
final class OverlayButton: UIView {
    private let onPress: (Bool) -> Void

    init(title: String, size: CGFloat, onPress: @escaping (Bool) -> Void) {
        self.onPress = onPress
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        isMultipleTouchEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = title

        layer.cornerRadius = size / 2
        backgroundColor = UIColor.white.withAlphaComponent(0.12)
        layer.borderWidth = 2
        layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor

        let label = UILabel(frame: bounds)
        label.text = title
        label.font = .systemFont(ofSize: size * 0.28, weight: .bold)
        label.textColor = UIColor.white.withAlphaComponent(0.7)
        label.textAlignment = .center
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        backgroundColor = UIColor.white.withAlphaComponent(0.3)
        onPress(true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        backgroundColor = UIColor.white.withAlphaComponent(0.12)
        onPress(false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        backgroundColor = UIColor.white.withAlphaComponent(0.12)
        onPress(false)
    }
}
```

- [ ] **Step 2: OverlayPresenter**

`App/Sources/Touch/OverlayPresenter.swift`:
```swift
import UIKit
import WoofEngine

/// Installs the touch overlay into SDL's UIWindow once the engine session
/// creates it, and removes it when the session ends. Works because SDL pumps
/// the main run loop during sessions, so our Timer keeps firing while
/// WoofIOS_Run blocks.
@MainActor
final class OverlayPresenter {
    static let shared = OverlayPresenter()

    private let gamepad = TouchGamepad()
    private var overlay: TouchOverlayView?
    private var pollTimer: Timer?

    func begin() {
        end() // safety: never double-install
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tryInstall() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func end() {
        pollTimer?.invalidate()
        pollTimer = nil
        overlay?.removeFromSuperview()
        overlay = nil
        gamepad.detach()
    }

    private func tryInstall() {
        guard overlay == nil,
              let pointer = WoofIOS_GetUIWindowPointer()
        else { return }

        // Attach the virtual gamepad first; retries until SDL's joystick
        // subsystem is up. Don't install the overlay before input works.
        guard gamepad.attachIfPossible() else { return }

        let window = Unmanaged<UIWindow>.fromOpaque(pointer)
            .takeUnretainedValue()
        let view = TouchOverlayView(gamepad: gamepad)
        view.frame = window.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(view)
        overlay = view

        pollTimer?.invalidate()
        pollTimer = nil
    }
}
```

- [ ] **Step 3: Wire into EngineSession**

In `EngineSession.play(arguments:)`, around the run:
```swift
        isRunning = true
        OverlayPresenter.shared.begin()
        defer {
            OverlayPresenter.shared.end()
            isRunning = false
        }
```

- [ ] **Step 4: Build + manual sanity + smoke gate**

```bash
cd App && xcodegen generate && cd ..
xcodebuild -project App/BoomBox.xcodeproj -scheme BoomBox \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BoomBoxUITests/EngineSmokeTests test
```
Expected: `TEST SUCCEEDED`. Then launch the app manually, tap Play, and screenshot:
```bash
xcrun simctl launch "iPhone 17 Pro" com.tylervick.BoomBox && sleep 12
xcrun simctl io "iPhone 17 Pro" screenshot /tmp/plan3-overlay.png
```
Read the png: the Freedoom demo must be visible WITH the overlay buttons (FIRE, USE, MAP, ≡, ◀, ▶) drawn over it. A missing overlay means WoofIOS_GetUIWindowPointer or the timer path failed — debug before committing.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Touch/TouchOverlayView.swift App/Sources/Touch/OverlayPresenter.swift \
        App/Sources/EngineSession.swift
git commit -m "feat: touch overlay with virtual stick, turn region, and action buttons"
```

---

### Task 5: Auto-hide on physical input

**Files:**
- Modify: `App/Sources/Touch/OverlayPresenter.swift`
- Create: `App/Tests/PhysicalInputPolicyTests.swift`

**Interfaces:**
- Produces:
```swift
struct PhysicalInputPolicy: Equatable {
    var controllerConnected: Bool
    var hardwareKeyboardConnected: Bool
    var overlayShouldShow: Bool { !controllerConnected && !hardwareKeyboardConnected }
}
```
- OverlayPresenter observes `GCController` connect/disconnect and `GCKeyboard` coalesced notifications, recomputes the policy, and shows/hides the overlay (`overlay?.isHidden`). The virtual gamepad stays attached either way — Woof! follows the most recent input, and detaching on hide would churn device selection mid-session.

- [ ] **Step 1: Failing policy tests**

`App/Tests/PhysicalInputPolicyTests.swift`:
```swift
import XCTest
@testable import BoomBox

final class PhysicalInputPolicyTests: XCTestCase {
    func testNoPhysicalInputShowsOverlay() {
        let policy = PhysicalInputPolicy(controllerConnected: false,
                                         hardwareKeyboardConnected: false)
        XCTAssertTrue(policy.overlayShouldShow)
    }

    func testControllerHidesOverlay() {
        let policy = PhysicalInputPolicy(controllerConnected: true,
                                         hardwareKeyboardConnected: false)
        XCTAssertFalse(policy.overlayShouldShow)
    }

    func testKeyboardHidesOverlay() {
        let policy = PhysicalInputPolicy(controllerConnected: false,
                                         hardwareKeyboardConnected: true)
        XCTAssertFalse(policy.overlayShouldShow)
    }
}
```

- [ ] **Step 2: Implement (policy + presenter wiring)**

Add to `OverlayPresenter.swift`:
```swift
import GameController

struct PhysicalInputPolicy: Equatable {
    var controllerConnected: Bool
    var hardwareKeyboardConnected: Bool
    var overlayShouldShow: Bool { !controllerConnected && !hardwareKeyboardConnected }
}
```
In `OverlayPresenter`: register observers in `begin()` (NotificationCenter: `.GCControllerDidConnect`, `.GCControllerDidDisconnect`, `.GCKeyboardDidConnect`, `.GCKeyboardDidDisconnect`), remove them in `end()`, and apply:
```swift
    private func applyPolicy() {
        let policy = PhysicalInputPolicy(
            controllerConnected: !GCController.controllers().isEmpty,
            hardwareKeyboardConnected: GCKeyboard.coalesced != nil)
        overlay?.isHidden = !policy.overlayShouldShow
    }
```
Call `applyPolicy()` after installing the overlay and from each notification. (Note: the virtual SDL gamepad is not a `GCController`, so it never counts as "physical" — no feedback loop.)

- [ ] **Step 3: Run unit suite green, verify keyboard hide on simulator**

Unit suite green. Manual check: with the simulator's hardware-keyboard capture ON (I/O → Keyboard → Connect Hardware Keyboard), launch a session and screenshot — overlay hidden; with it off, overlay visible. Record which you observed in the commit body (simulator keyboard plumbing to GCKeyboard can be flaky — if GCKeyboard.coalesced never becomes non-nil in the simulator, note it and rely on the unit-tested policy + on-device checklist in Task 8).

- [ ] **Step 4: Commit**

```bash
git add App/Sources/Touch/OverlayPresenter.swift App/Tests/PhysicalInputPolicyTests.swift
git commit -m "feat: hide touch overlay when a physical controller or keyboard is present"
```

---

### Task 6: Touch-controls UITest gate

**Files:**
- Create: `App/UITests/TouchControlsTests.swift`
- Modify: `App/Sources/ContentView.swift` (debug input-count label, test-only)

**Interfaces:**
- Consumes: overlay accessibility ids (Task 4), `WoofIOS_DebugTouchEventCount` (Task 1), `BOOMBOX_AUTOQUIT_SECONDS`.

- [ ] **Step 1: Debug count surface**

In `App/Sources/ContentView.swift`, next to the exit-label overlay, add (shown only when the env var is present):
```swift
            if ProcessInfo.processInfo.environment["BOOMBOX_DEBUG_INPUT_COUNTS"] != nil,
               let code = lastExitCode {
                Text("touchEvents: \(WoofIOS_DebugTouchEventCount())")
                    .font(.footnote.monospaced())
                    .accessibilityIdentifier("touchEventCountLabel")
                    .padding(.bottom, 100)
            }
```
(Requires `import WoofEngine` in ContentView; `_ = code` if unused warnings appear — the label intentionally only renders post-session.)

- [ ] **Step 2: The UITest**

`App/UITests/TouchControlsTests.swift`:
```swift
import XCTest

/// Proves the touch overlay installs over a live engine session and that
/// stick/button/turn gestures actually reach SDL (via the shim's debug
/// counter, surfaced post-session when BOOMBOX_DEBUG_INPUT_COUNTS is set).
final class TouchControlsTests: XCTestCase {

    @MainActor
    func testOverlayInstallsAndInputsReachEngine() throws {
        let app = XCUIApplication()
        app.launchEnvironment["BOOMBOX_AUTOQUIT_SECONDS"] = "14"
        app.launchEnvironment["BOOMBOX_DEBUG_INPUT_COUNTS"] = "1"
        app.launch()

        let play = app.buttons["playFreedoom1"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()

        // Overlay appears once the engine window exists.
        let fire = app.buttons["fireButton"]
        XCTAssertTrue(fire.waitForExistence(timeout: 20), "overlay never installed")

        // Button press (down+up).
        fire.tap()
        app.buttons["useButton"].tap()

        // Movement stick: press in the left 40% and drag.
        let stickStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.7))
        let stickEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.28, dy: 0.55))
        stickStart.press(forDuration: 0.1, thenDragTo: stickEnd)

        // Turn drag on the right half.
        let turnStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
        let turnEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
        turnStart.press(forDuration: 0.05, thenDragTo: turnEnd)

        // Session ends via autoquit; overlay must be gone, launcher back.
        let exitLabel = app.staticTexts["engineExitLabel"]
        XCTAssertTrue(exitLabel.waitForExistence(timeout: 90))
        XCTAssertEqual(exitLabel.label, "Engine exited: 0")
        XCTAssertFalse(fire.exists, "overlay not torn down after session")

        // The shim must have seen our gestures.
        let countLabel = app.staticTexts["touchEventCountLabel"]
        XCTAssertTrue(countLabel.waitForExistence(timeout: 5))
        let count = Int(countLabel.label.replacingOccurrences(
            of: "touchEvents: ", with: "")) ?? 0
        XCTAssertGreaterThan(count, 0, "no touch input reached the SDL shim")
    }
}
```

- [ ] **Step 3: Run it (plus the standing gates)**

```bash
cd App && xcodegen generate && cd ..
xcodebuild -project App/BoomBox.xcodeproj -scheme BoomBox \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BoomBoxUITests/TouchControlsTests test
xcodebuild -project App/BoomBox.xcodeproj -scheme BoomBox \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BoomBoxTests -only-testing:BoomBoxUITests/EngineSmokeTests test
```
Expected: both `TEST SUCCEEDED`. Iteration is likely on the overlay-element hit-testing (XCUITest must see overlay elements inside SDL's UIWindow — if queries fail, check `isAccessibilityElement` on OverlayButton and that the overlay view itself is NOT an accessibility element swallowing children). Capture one mid-session screenshot as evidence the overlay renders over gameplay; also confirm via the screenshot that the two `simctl` coordinate drags visibly drew the stick (base+knob circles).

- [ ] **Step 4: Commit**

```bash
git add App/UITests/TouchControlsTests.swift App/Sources/ContentView.swift
git commit -m "test: touch overlay install/input/teardown gate on simulator"
```

---

### Task 7: Import performance — async adoption, streamed SHA-1, zip cap

**Files:**
- Modify: `App/Sources/WAD/WADStore.swift`
- Modify: `App/Sources/WAD/ZipExtractor.swift`
- Modify: `App/Sources/Library/ImportService.swift`
- Modify: `App/Sources/BoomBoxApp.swift`
- Modify/extend: `App/Tests/WADStoreTests.swift`, `App/Tests/ZipExtractorTests.swift`, `App/Tests/ImportServiceTests.swift`

**Interfaces:**
- Produces:
```swift
// WADStore additions/changes:
static func sha1(ofFileAt url: URL) throws -> String     // streamed, 1MB chunks
func store(fileAt: URL, preferredName: String, precomputedSHA1: String?) throws -> StoredWAD
// (the old 2-arg store() remains as a convenience calling the 3-arg one)
// ZipExtractor:
static var maxEntryBytes: Int64 { get }                  // 512 MB default
static func extractGameFiles(from: URL, maxEntryBytes: Int64) throws -> (dir: URL, files: [ExtractedFile], skippedOversize: [String])
// ImportService:
func adoptLooseFiles() async -> ImportOutcome            // hashing/copying off-main
```

- [ ] **Step 1: Failing tests first**

Add to `App/Tests/WADStoreTests.swift`:
```swift
    func testStreamedHashMatchesInMemoryHash() throws {
        let src = try writeSource("h.wad", "streamed hashing test payload")
        let streamed = try WADStore.sha1(ofFileAt: src)
        let inMemory = WADStore.sha1(of: try Data(contentsOf: src))
        XCTAssertEqual(streamed, inMemory)
    }

    func testUnreadableSourceThrows() {
        XCTAssertThrowsError(try WADStore.sha1(
            ofFileAt: tmp.appendingPathComponent("nope.wad")))
        XCTAssertThrowsError(try store.store(
            fileAt: tmp.appendingPathComponent("nope.wad"), preferredName: "nope.wad")) {
            XCTAssertEqual($0 as? WADStoreError, .unreadable)
        }
    }

    func testPrecomputedHashSkipsRehash() throws {
        let src = try writeSource("p.wad", "content")
        let expected = WADStore.sha1(of: Data("content".utf8))
        let stored = try store.store(fileAt: src, preferredName: "p.wad",
                                     precomputedSHA1: expected)
        XCTAssertEqual(stored.sha1, expected)
    }
```
Add to `App/Tests/ZipExtractorTests.swift`:
```swift
    func testOversizeEntriesAreSkippedAndReported() throws {
        let zip = try makeZip(entries: ["big.wad": "0123456789", "ok.wad": "PWAD"])
        let result = try ZipExtractor.extractGameFiles(from: zip, maxEntryBytes: 5)
        defer { try? FileManager.default.removeItem(at: result.dir) }
        XCTAssertEqual(result.files.map(\.name), ["ok.wad"])
        XCTAssertEqual(result.skippedOversize, ["big.wad"])
    }
```
Update `ImportServiceTests` adoption tests to `await importer.adoptLooseFiles()` (test methods become `async`).

- [ ] **Step 2: Implement**

`WADStore`:
```swift
    static func sha1(ofFileAt url: URL) throws -> String {
        guard let stream = InputStream(url: url) else { throw WADStoreError.unreadable }
        stream.open()
        defer { stream.close() }
        var hasher = Insecure.SHA1()
        let bufferSize = 1 << 20
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read < 0 { throw WADStoreError.unreadable }
            if read == 0 { break }
            hasher.update(data: Data(buffer[0..<read]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
```
Rework `store(fileAt:preferredName:precomputedSHA1:)`: existence check → hash via `precomputedSHA1 ?? sha1(ofFileAt:)` → **no directory rescan** (the DB is the dedupe source of truth since Plan 2's hash-first fix; document that in a comment) → name-collision suffixing as before → `FileManager.copyItem` (no `Data` round-trip). Keep the 2-arg overload delegating with `precomputedSHA1: nil`.

`ZipExtractor`: add `maxEntryBytes` (default `512 * 1024 * 1024`), check `entry.uncompressedSize`, collect `skippedOversize`, keep the 1-arg overload delegating.

`ImportService`: `adoptLooseFiles() async` — enumerate candidates on main, then for each: hash + store on a background task (`try await Task.detached { ... }.value` around the streamed hash + store call — WADStore is a value type with no shared state, safe off-main), then register on the MainActor as before. Zip case: reject-with-reason if `skippedOversize` non-empty and no files imported ("Contains an oversized entry (>512 MB)"). `importFiles(at:)` may stay synchronous (picker flow, user-initiated) — only the launch path must be async.

`BoomBoxApp`: remove `adoptLooseFiles()` from `init`; in the `WindowGroup` content add:
```swift
            ContentView(library: library, importer: importer)
                .task { _ = await importer.adoptLooseFiles() }
```

- [ ] **Step 3: Full verification**

```bash
xcodebuild -project App/BoomBox.xcodeproj -scheme BoomBox \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BoomBoxTests test
```
Expected: `TEST SUCCEEDED` (all reworked adoption/store/zip tests green). Then re-provision and run the real-WAD matrix — the 293MB Eviternity II adoption must still work through the async path:
```bash
Scripts/provision-test-wads.sh
xcodebuild -project App/BoomBox.xcodeproj -scheme BoomBox \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BoomBoxUITests/RealWADTests test
```
Expected: `TEST SUCCEEDED` (4 tests; adoption now happens post-first-frame, so the library may populate a few seconds after launch — if RealWADTests' loadout-creation step races the adoption, extend its wait for the PWAD to appear in the editor menu and document the adjustment).

- [ ] **Step 4: Commit**

```bash
git add App/Sources/WAD App/Sources/Library/ImportService.swift App/Sources/BoomBoxApp.swift App/Tests
git commit -m "perf: async loose-file adoption with streamed hashing and zip size cap"
```

---

### Task 8: Test hygiene, docs, manual checklist

**Files:**
- Modify: `App/Tests/LoadoutArgumentsTests.swift` (saves-dir cleanup)
- Modify: `App/Tests/LibraryServiceTests.swift` (allLoadouts sort test)
- Modify: `App/UITests/RealWADTests.swift` (rename negative test)
- Modify: `README.md` (Controls section)
- Create: `docs/manual-testing.md`

- [ ] **Step 1: Hygiene fixes**

1. `LoadoutArgumentsTests`: in each test that calls `build()` without cleanup, capture the loadout and add `addTeardownBlock { try? FileManager.default.removeItem(at: LibraryService.savesDirectory(forLoadoutID: loadout.id)) }`.
2. `LibraryServiceTests` — add:
```swift
    func testAllLoadoutsSortsMostRecentFirst() throws {
        let iwad = try service.registerImported(filename: "d.wad", sha1: "s1",
                                                kind: "IWAD", family: "doom2")
        let old = try service.createLoadout(name: "Old", iwadID: iwad.id, pwadIDs: [], dehIDs: [])
        let recent = try service.createLoadout(name: "Recent", iwadID: iwad.id, pwadIDs: [], dehIDs: [])
        old.lastPlayed = Date(timeIntervalSinceNow: -3600)
        recent.lastPlayed = Date()
        XCTAssertEqual(try service.allLoadouts().map(\.name), ["Recent", "Old"])
    }
```
3. `RealWADTests`: rename `testWrongIWADPairingFailsSoft` → `testUnrecognizedIWADFailsSoft` (keep the doc comment).

- [ ] **Step 2: Docs**

`README.md` — add after the WAD-library section:
```markdown
## Controls

- **Touch:** left side of the screen is a floating movement stick; dragging
  on the right side turns. On-screen buttons: FIRE, USE, weapon prev/next,
  automap (MAP), and menu (≡). The overlay drives a virtual gamepad, so all
  bindings are remappable in Woof!'s own setup menu.
- **Controllers:** Xbox/PlayStation/Switch/MFi via GameController — the
  touch overlay hides automatically while one is connected.
- **Keyboard & mouse:** hardware keyboards hide the overlay; mouse look
  works on iPad (indirect input events are enabled).
```
`docs/manual-testing.md`:
```markdown
# Manual on-device test checklist

Run before each release build (simulator can't cover physical input):

## Touch (iPhone + iPad)
- [ ] Movement stick appears where the left thumb lands; releases to neutral
- [ ] Drag-to-turn on the right half; sensitivity comfortable
- [ ] FIRE holds down (continuous fire with chaingun), USE opens doors
- [ ] Weapon prev/next cycles; MAP toggles automap; ≡ opens the menu and
      the stick + FIRE/USE navigate it
- [ ] Overlay hides/shows when a controller connects/disconnects mid-session

## Physical controller (Xbox/PS/Switch)
- [ ] Sticks move/turn, face buttons fire/use, shoulders cycle weapons
- [ ] Rumble (if enabled in Woof! setup)

## Keyboard & mouse (iPad)
- [ ] WASD + mouse look; overlay hidden while keyboard is connected

## Performance
- [ ] Cold launch with a 300MB WAD in Documents: first frame < 3s,
      adoption completes in the background without UI stalls
```

- [ ] **Step 3: Full suite + commit**

```bash
xcodebuild -project App/BoomBox.xcodeproj -scheme BoomBox \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BoomBoxTests -only-testing:BoomBoxUITests/EngineSmokeTests \
  -only-testing:BoomBoxUITests/TouchControlsTests test
```
Expected: `TEST SUCCEEDED`.
```bash
git add App/Tests App/UITests/RealWADTests.swift README.md docs/manual-testing.md
git commit -m "docs: controls documentation, manual test checklist, and test hygiene"
```

---

## Plan self-review notes

- **Spec §3 coverage:** touch overlay with stick/turn/fire/use/weapons/automap (Tasks 1-4, 6 — via virtual gamepad so bindings stay user-remappable, exceeding the spec's "injects synthetic input" sketch); controllers/keyboard/mouse passthrough already work via SDL (Plan 1) — Plan 3 adds the auto-hide policy (Task 5) and the on-device verification checklist (Task 8, honest about simulator limits). Touch-layout customization UI remains v2 per spec.
- **Ledgered Plan-3 items all present:** async adoption + streamed SHA-1 + no store rescan (Task 7), zip size cap (Task 7), saves-litter cleanup + sha1/.unreadable tests + sort test + negative-test rename (Tasks 7-8), autoquit session-scoping (Task 3), sigemptyset (Task 1). Deliberately NOT pulled in: I_AtSignal per-session growth and the unreachable post-D_DoomMain SIGTERM restore (Plan 4, engine-touching, unrelated to input).
- **Known uncertainties made explicit:** hot-attach gamepad pickup (Task 1 Step 3 verification with a documented fallback), XCUITest visibility of overlay elements inside SDL's window (Task 6 Step 3), GCKeyboard behavior on the simulator (Task 5 Step 3), RealWADTests racing async adoption (Task 7 Step 3).
- **Type consistency:** `TouchButton` raw values verified-then-cited (Task 3 Step 1); `WoofIOS_*` shim names identical across Tasks 1/3/4/6; accessibility ids identical between Tasks 4 and 6; 2-arg/3-arg store overloads keep Plan-2 call sites compiling.
