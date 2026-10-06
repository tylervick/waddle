# Touch-Driven Engine Menus Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A player can tap Woof's in-game menu items (and drag its sliders) on the touch overlay, answer Y/N prompts with Yes/No buttons, and later open the menu by tapping the title screen.

**Architecture:** Woof 16's menus already take an absolute pointer (`ev_mouse_state` + `ev_mouseb_down/up`). The iOS shim (`woof_ios.c`) gains calls that post those events; the overlay routes a free-area touch to them while a menu is up, with one carve-out: a touch that begins in the stick column stays *pending* until it either travels (then it is the movement stick, as today) or lifts in place (then it is a tap). Prompts get two overlay buttons that inject `'y'`/`'n'`.

**Tech Stack:** C (Woof engine, SDL3), Swift/UIKit (overlay), XCTest (`WaddleTests` unit, `WaddleUITests` on the simulator), CMake/Ninja via `Scripts/build-engine.sh`.

**Spec:** `docs/superpowers/specs/2026-10-05-touch-menus-design.md`

## Global Constraints

- Engine edits live inside `#ifdef WOOF_IOS` blocks only; every new patch gets an entry in `Engine/WOOF_UPSTREAM.md` under "iOS patch set".
- After any engine edit: `Scripts/build-engine.sh`, then `Scripts/check-engine-fresh.sh` must print nothing and exit 0. The app links `Vendor/out/WoofEngine.xcframework`; stale frameworks are refused.
- Never two `xcodebuild test` sessions against one simulator. Use a dedicated simulator created with `xcrun simctl create` and delete it at the end.
- Conventional commits, signed (SSH signing is configured; never pass `-c commit.gpgsign=false`). Work lands through pull requests, never on `main`.
- Never edit or delete a test to make it pass. `DebugHUDInputTelemetryTests` and `.revyl/tests/menu-input-telemetry.yaml` drag the stick in the lower-left quarter while the main menu is open and expect menu moves; the pending-touch rule keeps that true.
- Every injected keydown is paired with a keyup (`docs/learnings/soft-keyboard-keydown-keyup-pairing.md`).
- A new test file is invisible until `cd App && xcodegen generate` (`docs/learnings/xcodegen-source-snapshot-hides-new-tests.md`).
- New learning files need an `INDEX.md` line in the same commit; `Scripts/check-substrate.sh` enforces it.

## Review Focus

1. **A menu that closes under a held finger** (the item tapped closes the menu, or the app is backgrounded): the engine must not keep a mouse button held. Pinned by `WoofIOS_InjectMenuTap(false)` posting the release whenever a press was posted, regardless of `menuactive` (Task 2, by reading; no engine unit harness exists).
2. **Save-name entry after tapping a Save slot**: the soft keyboard comes up through the existing 0.25 s poll and `touchesBegan`'s keyboard guard (`if wasKeyboardActive || keyboardActive { return }`) runs before any menu routing, so no tap can reach the pointer while typing. Not newly tested: the guard precedes the router in Task 5's code, and `SoftKeyboardTests` already covers the keyboard's own flow; Task 8 runs it.
3. **A second finger while one already drives the pointer** must do nothing. Pinned by `MenuTouchRouterTests.testSecondFingerIsIgnoredWhilePointerOwned` (Task 3).
4. **A small iPadOS window**: the Yes/No buttons must stay inside the usable rect and off MAP and ≡. Pinned by `TouchOverlayLayoutTests` prompt-frame cases over the tiny window (Task 4).
5. **A tap on empty menu space** (above the first item) must change nothing. Pinned by `TouchMenuTests` step "tap above New Game keeps cm=main" (Task 6).

---

## PR 1: engine pointer, overlay routing, prompt buttons

### Task 1: Engine coordinate helpers and menu seams

**Files:**
- Modify: `Engine/woof/src/i_video.c` (the `WOOF_IOS` block that holds `I_DebugWindowSize`, around line 1653)
- Modify: `Engine/woof/src/mn_menu.c` (the `WOOF_IOS` block that holds `MN_DebugMenuCursor`, around line 2309)

**Interfaces:**
- Produces (C, `WOOF_IOS` only):
  - `boolean I_MenuPointFromWindow(float x, float y, float *out_x, float *out_y);`
  - `boolean I_WindowPointFromMenu(float mx, float my, float *out_x, float *out_y);`
  - `boolean MN_MenuMessageShowing(void);`
  - `const char *MN_DebugCurrentMenuName(void);`
  - `boolean MN_DebugMenuItemCenter(int index, float *x, float *y);`

The worktree already carries a probe version of these, marked `PROBE`. Replace those blocks with the final text below (the maths is unchanged; the comments and the message seam's name are not).

- [ ] **Step 1: Replace the probe helpers in `i_video.c`**

Find the two `// PROBE (touch menus)` functions above `// The app is leaving the screen (issue #111)` and replace them with:

```c
// Touch menus: the overlay's touch, in the SDL window's own coordinate
// space (UIKit points), mapped onto the menu's unscaled video space with
// exactly the math UpdateMouseMenu applies to SDL_GetMouseState, so the
// pointer the overlay posts lands where the finger is. False before the
// window exists.
boolean I_MenuPointFromWindow(float x, float y, float *out_x, float *out_y)
{
    if (!screen || !renderer)
    {
        return false;
    }
    SDL_FRect mouse_rect;
    SDL_GetRenderLogicalPresentationRect(renderer, &mouse_rect);
    const float scale = SDL_GetWindowPixelDensity(screen);
    *out_x = clampf((x * scale - mouse_rect.x) / mouse_rect.w, 0.0f, 1.0f) * video.unscaledw;
    *out_y = clampf((y * scale - mouse_rect.y) / mouse_rect.h, 0.0f, 1.0f) * SCREENHEIGHT;
    return true;
}

// The inverse, for the debug HUD: a menu-space point as the window point a
// UI test can tap (WoofIOS_DebugMenuState's tgt= field).
boolean I_WindowPointFromMenu(float mx, float my, float *out_x, float *out_y)
{
    if (!screen || !renderer)
    {
        return false;
    }
    SDL_FRect mouse_rect;
    SDL_GetRenderLogicalPresentationRect(renderer, &mouse_rect);
    const float scale = SDL_GetWindowPixelDensity(screen);
    *out_x = (mx / video.unscaledw * mouse_rect.w + mouse_rect.x) / scale;
    *out_y = (my / SCREENHEIGHT * mouse_rect.h + mouse_rect.y) / scale;
    return true;
}
```

- [ ] **Step 2: Replace the probe seams in `mn_menu.c`**

Find the three `// PROBE (touch menus)` functions above `const char *MN_DebugMenuGeometry(void)` and replace them with:

```c
// Touch menus (iOS): a pointer press while a Y/N prompt or the Load/Save
// delete confirmation is up is turned into 'y' by M_Responder (a mouse
// button is input_menu_enter, and MENU_ENTER becomes ch = 'y' in the
// messageToPrint branch; delete_verify accepts MENU_ENTER outright), so the
// host drops presses while this is true and answers through the letters
// instead (WoofIOS_InjectMenuAnswer). See
// docs/learnings/menu-click-answers-prompt-yes.md.
boolean MN_MenuMessageShowing(void)
{
    return menuactive && (messageToPrint || delete_verify);
}

// Debug/test telemetry (WoofIOS_DebugMenuState): which menu table is
// current, by name, so a UI test can say "Load Game opened".
const char *MN_DebugCurrentMenuName(void)
{
    if (!menuactive) return "off";
    if (messageToPrint) return "msg";
    if (setup_active) return "setup";
    if (currentMenu == &MainDef) return "main";
    if (currentMenu == &LoadDef) return "load";
    if (currentMenu == &SaveDef) return "save";
    if (currentMenu == &EpiDef) return "epi";
    if (currentMenu == &NewDef) return "skill";
    if (currentMenu == &SetupDef) return "options";
    return "other";
}

// Debug/test telemetry (WoofIOS_DebugMenuState): centre of item `index` of
// the current big-font menu in menu space (video.deltaw folded in, as
// MN_PointInsideRect expects). False for the setup screens, prompts, and
// out-of-range indices. Rects are set as the menu draws, so this is only
// meaningful after the menu has been on screen for a frame.
boolean MN_DebugMenuItemCenter(int index, float *x, float *y)
{
    if (!menuactive || setup_active || messageToPrint || !currentMenu
        || index < 0 || index >= currentMenu->numitems)
    {
        return false;
    }
    mrect_t *rect = &currentMenu->menuitems[index].rect;
    *x = rect->x + video.deltaw + rect->w / 2.0f;
    *y = rect->y + rect->h / 2.0f;
    return true;
}
```

- [ ] **Step 3: Confirm no `PROBE` marker remains in these two files**

Run: `grep -n PROBE Engine/woof/src/i_video.c Engine/woof/src/mn_menu.c`
Expected: no output.

- [ ] **Step 4: Build the engine**

Run: `Scripts/build-engine.sh 2>&1 | tail -3 && Scripts/check-engine-fresh.sh && echo FRESH`
Expected: `Built ... WoofEngine.xcframework`, then `FRESH`. (Task 2 edits `woof_ios.c`, which still calls the probe's `MN_DebugMenuMessage`; if the link fails on that name, do Task 2's Step 1 first and build once for both tasks.)

- [ ] **Step 5: Commit**

```bash
git add Engine/woof/src/i_video.c Engine/woof/src/mn_menu.c
git commit -m "feat(engine): map window points to menu space and expose the prompt state

Woof 16's menus already take an absolute pointer; these are the seams
the iOS host needs to feed one from touches, plus the telemetry a UI
test reads to say which menu opened."
```

### Task 2: Shim entry points and telemetry

**Files:**
- Modify: `Engine/woof/src/woof_ios.c` (the `PROBE` block above `WoofIOS_DebugTouchEventCount`, the counter reset in `WoofIOS_Run` around line 350, and the `PROBE` tail of `WoofIOS_DebugInputState`)
- Modify: `Engine/woof/src/woof_ios.h` (the `PROBE` block at the end)
- Modify: `Engine/WOOF_UPSTREAM.md` (append to "iOS patch set", after the `WoofIOS_InjectKey` entry)

**Interfaces:**
- Consumes: Task 1's five functions.
- Produces (declared in `woof_ios.h`, callable from Swift as `WoofIOS_*`):
  - `void WoofIOS_InjectMenuPointer(float x_points, float y_points);`
  - `bool WoofIOS_InjectMenuTap(bool down);`
  - `void WoofIOS_InjectMenuAnswer(bool yes);`
  - `bool WoofIOS_IsMenuMessageShowing(void);`
  - `const char *WoofIOS_DebugMenuState(void);`

- [ ] **Step 1: Replace the probe block in `woof_ios.c`**

Replace everything from `// --- PROBE (touch menus): touch as the menu's pointer ---` down to (not including) `int WoofIOS_DebugTouchEventCount(void)` with:

```c
// --- Touch menus: a touch as the menu's pointer (see woof_ios.h) ---
// Woof's menus already take an absolute pointer: mn_menu.c highlights the
// item under an ev_mouse_state and activates it on an ev_mouseb_down
// (MouseResponder/CursorPosition; MOUSE_BUTTON_LEFT is input_menu_enter by
// default). Nothing fed one on iOS because the overlay consumes every touch
// before SDL's touch-to-mouse synthesis sees it. These post the same events
// the SDL mouse path would. The host posts position BEFORE the press: a
// press is checked against the item highlighted by the most recent
// position, so the other order lands on the previously highlighted item.
static int touch_menu_pointer_writes;
static int touch_menu_tap_writes;
static int touch_menu_tap_dropped;
static bool touch_menu_tap_held;

void WoofIOS_InjectMenuPointer(float x_points, float y_points)
{
    extern boolean I_MenuPointFromWindow(float, float, float *, float *);
    float mx, my;
    if (!menuactive || !I_MenuPointFromWindow(x_points, y_points, &mx, &my))
    {
        return;
    }
    event_t ev = {0};
    ev.type = ev_mouse_state;
    ev.data1.i = 0; // not EV_RESIZE_VIEWPORT
    ev.data2.f = mx;
    ev.data3.f = my;
    D_PostEvent(&ev);
    touch_menu_pointer_writes++;
    touch_event_count++;
}

bool WoofIOS_InjectMenuTap(bool down)
{
    extern boolean MN_MenuMessageShowing(void);
    if (down)
    {
        // A press on a Y/N prompt or a delete confirmation is "yes"
        // (docs/learnings/menu-click-answers-prompt-yes.md); the overlay's
        // Yes/No buttons are the only way to answer those.
        if (!menuactive || MN_MenuMessageShowing())
        {
            touch_menu_tap_dropped++;
            return false;
        }
        touch_menu_tap_held = true;
    }
    else
    {
        // Always release a press that was posted, even if the item it
        // activated closed the menu: G_Responder clears the button, and a
        // button left held would otherwise fire on the first tic of play.
        if (!touch_menu_tap_held)
        {
            return false;
        }
        touch_menu_tap_held = false;
    }
    event_t ev = {0};
    ev.type = down ? ev_mouseb_down : ev_mouseb_up;
    ev.data1.i = MOUSE_BUTTON_LEFT;
    ev.data2.i = down ? 1 : 0; // click count, read only by G_Responder
    D_PostEvent(&ev);
    touch_menu_tap_writes++;
    touch_event_count++;
    return true;
}

void WoofIOS_InjectMenuAnswer(bool yes)
{
    extern boolean MN_MenuMessageShowing(void);
    // Synchronous gate, like WoofIOS_InjectMenuConfirm: the overlay shows
    // the Yes/No buttons from a 0.25 s poll, so a press can land after the
    // prompt has gone, and a stray 'y' or 'n' in an ordinary menu is a
    // hotkey.
    if (!MN_MenuMessageShowing())
    {
        return;
    }
    int key = yes ? 'y' : 'n'; // the message responder and delete_verify read these
    event_t down = {0};
    down.type = ev_keydown;
    down.data1.i = key;
    D_PostEvent(&down);
    event_t up = {0};
    up.type = ev_keyup;
    up.data1.i = key;
    D_PostEvent(&up);
    touch_event_count++;
}

bool WoofIOS_IsMenuMessageShowing(void)
{
    extern boolean MN_MenuMessageShowing(void);
    return MN_MenuMessageShowing() != 0;
}

const char *WoofIOS_DebugMenuState(void)
{
    extern const char *MN_DebugCurrentMenuName(void);
    extern boolean MN_MenuMessageShowing(void);
    extern boolean MN_DebugMenuItemCenter(int, float *, float *);
    extern boolean I_WindowPointFromMenu(float, float, float *, float *);

    static char buf[256];
    size_t len = snprintf(buf, sizeof(buf), "cm=%s msg=%d mp=%d mt=%d md=%d tgt=",
                          MN_DebugCurrentMenuName(), MN_MenuMessageShowing() ? 1 : 0,
                          touch_menu_pointer_writes, touch_menu_tap_writes,
                          touch_menu_tap_dropped);
    for (int i = 0; i < 12 && len < sizeof(buf) - 16; i++)
    {
        float mx, my, wx, wy;
        if (!MN_DebugMenuItemCenter(i, &mx, &my) || !I_WindowPointFromMenu(mx, my, &wx, &wy))
        {
            break;
        }
        len += snprintf(buf + len, sizeof(buf) - len, "%s%d,%d", i ? "|" : "", (int)wx, (int)wy);
    }
    return buf;
}

```

- [ ] **Step 2: Remove the probe tail from `WoofIOS_DebugInputState`**

In `WoofIOS_DebugInputState`, delete the four `extern` lines that begin `extern const char *MN_DebugCurrentMenuName`, `extern int MN_DebugMenuMessage`, `extern boolean MN_DebugMenuItemCenter`, `extern boolean I_WindowPointFromMenu`; restore `static char buf[320];`; and delete everything from `// PROBE (touch menus): current menu, prompt flag` down to the loop's closing `}` so the function ends with `return buf;` right after the `if/else` that formats the strip.

- [ ] **Step 3: Reset the counters at session start**

In `WoofIOS_Run`, after the line `touch_turn_writes = 0;`, add:

```c
    touch_menu_pointer_writes = 0;
    touch_menu_tap_writes = 0;
    touch_menu_tap_dropped = 0;
    touch_menu_tap_held = false;
```

- [ ] **Step 4: Replace the probe declarations in `woof_ios.h`**

Replace the block from `// --- PROBE (touch menus) ---` to just before `#endif` with:

```c
// --- Touch menus: a touch as the engine menu's pointer ---
// Woof's menus take an absolute pointer; the overlay feeds one from touches
// through these. Main-thread-only, same contract as the touch-control
// functions above.

// Move the menu pointer to a point in the SDL window's coordinate space
// (UIKit points, as the overlay reads a touch). Posts ev_mouse_state; no-op
// when no menu is up or before the window exists. Post this BEFORE a press.
void WoofIOS_InjectMenuPointer(float x_points, float y_points);

// Press (`down`) or release the pointer as the left mouse button, which is
// menu-enter. A press is dropped, returning false, when no menu is up or
// while a Y/N prompt or a save-delete confirmation is showing (a click
// there answers "yes"). A release is posted whenever a press was, even if
// the menu has since closed, so the button never stays held.
bool WoofIOS_InjectMenuTap(bool down);

// Answer the Y/N prompt or save-delete confirmation on screen: a paired
// keydown/keyup of 'y' or 'n'. Dropped unless one is showing.
void WoofIOS_InjectMenuAnswer(bool yes);

// True while a Y/N prompt ("Quit?", "Load game?", ...) or the Load/Save
// delete confirmation is up, so the overlay can show its Yes/No buttons.
bool WoofIOS_IsMenuMessageShowing(void);

// Debug/test telemetry only, its own debug-HUD segment:
//   "cm=<off|msg|setup|main|load|save|epi|skill|options|other> msg=<0|1>
//    mp=<pointer writes> mt=<press+release writes> md=<presses dropped>
//    tgt=<x,y|x,y|...>"
// where tgt lists the current big-font menu's item centres as window
// points, so a UI test taps real screen positions. Counters reset at
// session start.
const char *WoofIOS_DebugMenuState(void);

```

- [ ] **Step 5: Document the patch in `Engine/WOOF_UPSTREAM.md`**

After the `WoofIOS_InjectKey` entry (the bullet that begins `` - `src/woof_ios.c` / `src/woof_ios.h` (issue #113) ``) and before the `` - `src/i_video.c`, `src/g_game.c` `` lifecycle entry, insert:

```markdown
- `src/i_video.c`, `src/mn_menu.c`, `src/woof_ios.c` / `src/woof_ios.h` --
  touch-driven menus. Upstream's menus already take an absolute pointer
  (`ev_mouse_state` + `ev_mouseb_down/up`; `MouseResponder`,
  `CursorPosition`), fed on desktop from `SDL_GetMouseState` in
  `UpdateMouseMenu`. The overlay consumes every touch, so nothing fed one on
  iOS. `I_MenuPointFromWindow` maps a window point onto menu space with
  `UpdateMouseMenu`'s own math; `WoofIOS_InjectMenuPointer` and
  `WoofIOS_InjectMenuTap` post the position and the left-button press/release
  through `D_PostEvent`, position first (a press is checked against the item
  the most recent position highlighted). `MN_MenuMessageShowing` exposes
  `messageToPrint || delete_verify`: a press there is answered "yes" by
  `M_Responder`, so the shim drops it and `WoofIOS_InjectMenuAnswer` types
  'y' or 'n' from the overlay's Yes/No buttons instead
  (`docs/learnings/menu-click-answers-prompt-yes.md`).
  `WoofIOS_DebugMenuState` (current menu name, prompt flag, counters, item
  centres as window points via `I_WindowPointFromMenu`) is the HUD segment
  `TouchMenuTests` reads.

```

- [ ] **Step 6: Build the engine and confirm the header exports the calls**

Run: `grep -n PROBE Engine/woof/src/*.c Engine/woof/src/*.h; Scripts/build-engine.sh 2>&1 | tail -2 && Scripts/check-engine-fresh.sh && grep -c "WoofIOS_InjectMenuAnswer" Vendor/out/WoofEngine.xcframework/ios-arm64-simulator/Headers/woof_ios.h`
Expected: no `PROBE` lines, `Built ...`, then `1`.

- [ ] **Step 7: Commit**

```bash
git add Engine/woof/src/woof_ios.c Engine/woof/src/woof_ios.h Engine/WOOF_UPSTREAM.md
git commit -m "feat(engine): let the iOS host drive the menu pointer and answer prompts

WoofIOS_InjectMenuPointer/InjectMenuTap post the position and left-button
events the menu already understands, position first. A press during a
Y/N prompt would be 'yes', so it is dropped and WoofIOS_InjectMenuAnswer
types the letter instead. WoofIOS_DebugMenuState is the HUD segment the
UI test reads."
```

### Task 3: `MenuTouchRouter`, the pure routing rule

**Files:**
- Create: `App/Sources/Touch/MenuTouchRouter.swift`
- Create: `App/Tests/MenuTouchRouterTests.swift`

**Interfaces:**
- Consumes: `TouchTrackRoute` (`.stick`, `.turn`, `.ignore`) from `App/Sources/Touch/TouchTrackRouter.swift`.
- Produces:
  ```swift
  struct MenuTouchRouter {
      static let tapSlop: CGFloat
      enum Began: Equatable { case pointer, pending, ignore, passThrough }
      enum Ended: Equatable { case tap, none }
      func began(menuActive: Bool, trackRoute: TouchTrackRoute,
                 nearButton: Bool, pointerOwned: Bool) -> Began
      func pendingBecameStick(from start: CGPoint, to point: CGPoint) -> Bool
      func ended(pendingFrom start: CGPoint, at point: CGPoint) -> Ended
  }
  ```

- [ ] **Step 1: Write the failing tests**

Create `App/Tests/MenuTouchRouterTests.swift`:

```swift
import XCTest
@testable import Waddle

/// The decision `TouchOverlayView.touchesBegan` makes while the engine's
/// menu is up: drive the menu pointer, wait and see (stick column), or
/// leave the touch alone. Pure, so the rule that keeps the stick usable for
/// menu navigation (DebugHUDInputTelemetryTests and the Revyl
/// menu-input-telemetry test drag it with the main menu open) is pinned
/// without UIKit.
final class MenuTouchRouterTests: XCTestCase {
    private let router = MenuTouchRouter()

    func testMenuTouchOutsideStickColumnDrivesThePointer() {
        XCTAssertEqual(router.began(menuActive: true, trackRoute: .ignore,
                                    nearButton: false, pointerOwned: false), .pointer)
        XCTAssertEqual(router.began(menuActive: true, trackRoute: .turn,
                                    nearButton: false, pointerOwned: false), .pointer)
    }

    func testMenuTouchInStickColumnIsPending() {
        XCTAssertEqual(router.began(menuActive: true, trackRoute: .stick,
                                    nearButton: false, pointerOwned: false), .pending)
    }

    func testSecondFingerIsIgnoredWhilePointerOwned() {
        XCTAssertEqual(router.began(menuActive: true, trackRoute: .ignore,
                                    nearButton: false, pointerOwned: true), .ignore)
    }

    func testNearMissOnAButtonIsIgnoredInMenus() {
        XCTAssertEqual(router.began(menuActive: true, trackRoute: .ignore,
                                    nearButton: true, pointerOwned: false), .ignore)
    }

    func testNoMenuPassesThroughToStickAndTurnRouting() {
        for route in [TouchTrackRoute.stick, .turn, .ignore] {
            XCTAssertEqual(router.began(menuActive: false, trackRoute: route,
                                        nearButton: false, pointerOwned: false), .passThrough)
        }
    }

    func testPendingTouchBecomesTheStickOnceItTravels() {
        let start = CGPoint(x: 80, y: 600)
        XCTAssertFalse(router.pendingBecameStick(from: start, to: CGPoint(x: 86, y: 606)))
        XCTAssertTrue(router.pendingBecameStick(from: start, to: CGPoint(x: 80, y: 600 + MenuTouchRouter.tapSlop + 1)))
    }

    func testPendingTouchLiftedInPlaceIsATap() {
        let start = CGPoint(x: 80, y: 600)
        XCTAssertEqual(router.ended(pendingFrom: start, at: CGPoint(x: 84, y: 597)), .tap)
        XCTAssertEqual(router.ended(pendingFrom: start, at: CGPoint(x: 80, y: 640)), .none)
    }
}
```

- [ ] **Step 2: Create the router**

Create `App/Sources/Touch/MenuTouchRouter.swift`:

```swift
import CoreGraphics

/// What a free-area touch means while the engine's menu is up. Pure, like
/// `TouchTrackRouter`, so `WaddleTests` pins the rule without UIKit.
///
/// The one subtlety is the stick column. The movement stick navigates the
/// menu through the virtual pad (a held deflection auto-repeats MENU_DOWN),
/// and a drag there must keep doing that. A touch that begins in the column
/// is therefore *pending*: if it travels past `tapSlop` it is the stick, as
/// it always was; if it lifts in place it is a tap on whatever item is
/// under it. Everywhere else a touch drives the pointer from the moment it
/// lands, so an item highlights on touch-down and a slider drags.
struct MenuTouchRouter {
    /// Travel allowed before a pending touch stops being a tap, in overlay
    /// points: a fingertip's wobble, well under the stick's dead zone.
    static let tapSlop: CGFloat = 10

    enum Began: Equatable {
        /// Drive the engine's menu pointer: post the position, then a press.
        case pointer
        /// Stick column: decide on move (stick) or on lift (tap).
        case pending
        /// A second finger, or a near-miss on a button. Do nothing.
        case ignore
        /// No menu is up: the caller's stick/turn routing applies.
        case passThrough
    }

    enum Ended: Equatable {
        case tap
        case none
    }

    func began(menuActive: Bool, trackRoute: TouchTrackRoute,
               nearButton: Bool, pointerOwned: Bool) -> Began {
        guard menuActive else { return .passThrough }
        if nearButton { return .ignore }
        if trackRoute == .stick { return .pending }
        return pointerOwned ? .ignore : .pointer
    }

    func pendingBecameStick(from start: CGPoint, to point: CGPoint) -> Bool {
        hypot(point.x - start.x, point.y - start.y) > Self.tapSlop
    }

    func ended(pendingFrom start: CGPoint, at point: CGPoint) -> Ended {
        pendingBecameStick(from: start, to: point) ? .none : .tap
    }
}
```

- [ ] **Step 3: Regenerate the project and run the tests**

Run:
```bash
(cd App && xcodegen generate >/dev/null) && xcodebuild -project App/Waddle.xcodeproj -scheme Waddle -derivedDataPath App/build-cli -destination 'platform=iOS Simulator,name=iPhone 17 Pro' ARCHS=arm64 -only-testing:WaddleTests/MenuTouchRouterTests test 2>&1 | grep -E "Test Case.*(passed|failed)|error:|\*\* TEST" | tail -12
```
Expected: 7 `passed`, `** TEST SUCCEEDED **`. (Run the test step once before Step 2 too, to see the compile failure that proves the test exercises new code.)

- [ ] **Step 4: Commit**

```bash
git add App/Sources/Touch/MenuTouchRouter.swift App/Tests/MenuTouchRouterTests.swift
git commit -m "feat(touch): decide what a touch means while a menu is up

Pointer outside the stick column; pending inside it, so a drag there is
still the stick that navigates the menu and a lift in place is a tap."
```

### Task 4: Yes/No button geometry

**Files:**
- Modify: `App/Sources/Touch/TouchOverlayLayout.swift` (add after `defaultFrame(for:)`)
- Modify: `App/Tests/TouchOverlayLayoutTests.swift` (append a new test class)

**Interfaces:**
- Produces:
  ```swift
  struct PromptButtonFrames: Equatable { let no: CGRect; let yes: CGRect }
  extension TouchOverlayLayout {
      static let promptButtonBaseDiameter: CGFloat   // 64
      func promptButtonFrames() -> PromptButtonFrames
  }
  ```

- [ ] **Step 1: Write the failing tests**

Append to `App/Tests/TouchOverlayLayoutTests.swift`:

```swift
/// The Yes/No buttons that answer an engine prompt ("Quit?", "Load game?",
/// delete this save?). They sit in the top band between MAP and ≡, not the
/// bottom band: in portrait USE's default centre is 160 pt in from the
/// right edge, which is where a centred bottom pair would land.
final class TouchOverlayLayoutPromptButtonTests: XCTestCase {
    private let allBounds: [CGRect] = [
        Bounds.iPhone17ProPortrait, Bounds.iPhone17ProLandscape, Bounds.iPhone16eLandscape,
        Bounds.iPadPro13Landscape, Bounds.iPadPro13Portrait, Bounds.iPadPro11Landscape,
        Bounds.tinyWindow,
    ]

    private func layouts(_ bounds: CGRect) -> [(TouchOverlayLayout, CGRect)] {
        let insets = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        return [
            (TouchOverlayLayout(bounds: bounds, safeAreaInsets: .zero, hudReserve: 0), bounds),
            (TouchOverlayLayout(bounds: bounds, safeAreaInsets: insets, hudReserve: 60),
             bounds.inset(by: insets)),
        ]
    }

    func testPromptButtonsStayInsideTheUsableRect() {
        for bounds in allBounds {
            for (layout, usable) in layouts(bounds) {
                let frames = layout.promptButtonFrames()
                XCTAssertTrue(usable.contains(frames.no), "No outside usable at \(bounds)")
                XCTAssertTrue(usable.contains(frames.yes), "Yes outside usable at \(bounds)")
            }
        }
    }

    func testPromptButtonsSitBelowTheHUDReserve() {
        for bounds in allBounds {
            let layout = TouchOverlayLayout(bounds: bounds, safeAreaInsets: .zero, hudReserve: 60)
            XCTAssertGreaterThanOrEqual(layout.promptButtonFrames().no.minY, 60, "\(bounds)")
        }
    }

    func testYesIsRightOfNoAndTheyDoNotTouch() {
        for bounds in allBounds {
            for (layout, _) in layouts(bounds) {
                let frames = layout.promptButtonFrames()
                XCTAssertGreaterThan(frames.yes.minX, frames.no.maxX, "\(bounds)")
                XCTAssertEqual(frames.yes.midY, frames.no.midY, accuracy: 0.001)
                XCTAssertEqual(frames.yes.width, TouchOverlayLayout.promptButtonBaseDiameter * layout.scale,
                               accuracy: 0.001)
            }
        }
    }

    func testPromptButtonsOverlapNoDefaultControl() {
        for bounds in allBounds {
            for (layout, _) in layouts(bounds) {
                let frames = layout.promptButtonFrames()
                for control in TouchOverlayControl.allCases {
                    let other = layout.defaultFrame(for: control)
                    XCTAssertFalse(other.intersects(frames.no), "No overlaps \(control) at \(bounds)")
                    XCTAssertFalse(other.intersects(frames.yes), "Yes overlaps \(control) at \(bounds)")
                }
            }
        }
    }
}
```

- [ ] **Step 2: Run them to see the compile failure**

Run the Task 3 Step 3 command with `-only-testing:WaddleTests/TouchOverlayLayoutPromptButtonTests`.
Expected: build error, `promptButtonFrames` not found.

- [ ] **Step 3: Add the geometry**

In `App/Sources/Touch/TouchOverlayLayout.swift`, after the closing brace of `defaultFrame(for:)` and before the struct's closing brace, add:

```swift
    /// Diameter of the Yes/No prompt buttons at scale 1.0: USE's, since
    /// they answer the same kind of one-shot question USE confirms.
    static let promptButtonBaseDiameter: CGFloat = 64

    /// Where the Yes/No buttons go while the engine shows a Y/N prompt:
    /// side by side in the top band, centred between MAP and ≡, No on the
    /// left and Yes on the right as iOS orders them. The top band rather
    /// than the bottom one because USE's default centre is 160 pt in from
    /// the right edge, which in portrait is exactly where a centred bottom
    /// pair would sit. Not a `TouchOverlayControl`: they are transient, and
    /// the layout editor must not offer to move them.
    func promptButtonFrames() -> PromptButtonFrames {
        let s = scale
        let diameter = Self.promptButtonBaseDiameter * s
        let y = topRowY + 36 * s
        let mid = usable.midX
        func frame(centeredAt x: CGFloat) -> CGRect {
            CGRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter)
        }
        return PromptButtonFrames(no: frame(centeredAt: mid - 40 * s),
                                  yes: frame(centeredAt: mid + 40 * s))
    }
```

and after the struct's closing brace, at file end:

```swift
/// The two prompt-button frames, in overlay coordinates.
struct PromptButtonFrames: Equatable {
    let no: CGRect
    let yes: CGRect
}
```

- [ ] **Step 4: Run the layout suite**

Run the Task 3 Step 3 command with `-only-testing:WaddleTests/TouchOverlayLayoutPromptButtonTests -only-testing:WaddleTests/TouchOverlayLayoutScaleTests`.
Expected: all `passed`, `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Touch/TouchOverlayLayout.swift App/Tests/TouchOverlayLayoutTests.swift
git commit -m "feat(touch): lay out Yes/No prompt buttons in the top band"
```

### Task 5: Overlay routing, prompt buttons, HUD segment

**Files:**
- Modify: `App/Sources/Touch/TouchGamepad.swift` (append wrappers before the final `}`)
- Modify: `App/Sources/Touch/TouchOverlayView.swift` (state at the top, `init`, `startMenuPolicyTimer`, `layoutSubviews`, `touchesBegan`, `touchesMoved`, `endTouches`, `updateDebugHUD`)

**Interfaces:**
- Consumes: Task 2's `WoofIOS_*` calls, Task 3's `MenuTouchRouter`, Task 4's `promptButtonFrames()`.
- Produces: overlay buttons with accessibility identifiers `promptYesButton` and `promptNoButton`; a third debug-HUD segment on the strip's second line, after the `pad=` segment, starting `cm=`.

- [ ] **Step 1: Add the gamepad wrappers**

In `App/Sources/Touch/TouchGamepad.swift`, before the class's final closing brace (after `currentTextInputContext()`), add:

```swift

    // MARK: Engine menus by touch

    /// Move the engine menu's pointer to `point` in overlay coordinates
    /// (the overlay fills SDL's window, so these are window points).
    func menuPointer(at point: CGPoint) {
        WoofIOS_InjectMenuPointer(Float(point.x), Float(point.y))
    }

    /// Press or release the pointer as menu-enter. Post the position first.
    /// A press during a Y/N prompt is dropped by the engine side (it would
    /// answer "yes"); `answerPrompt(yes:)` is how prompts are answered.
    @discardableResult
    func menuTap(down: Bool) -> Bool {
        WoofIOS_InjectMenuTap(down)
    }

    /// Answer the Y/N prompt or delete confirmation on screen.
    func answerPrompt(yes: Bool) {
        WoofIOS_InjectMenuAnswer(yes)
    }

    /// True while the engine shows a Y/N prompt or a delete confirmation.
    var isMenuMessageShowing: Bool { WoofIOS_IsMenuMessageShowing() }
```

- [ ] **Step 2: Add the overlay state**

In `App/Sources/Touch/TouchOverlayView.swift`, replace the probe's two lines

```swift
    private var turnTouch: UITouch?
    /// PROBE (touch menus): the finger driving the engine menu's pointer.
    private var menuTouch: UITouch?
```

with:

```swift
    private var turnTouch: UITouch?
    /// The finger driving the engine menu's pointer (`MenuTouchRouter`).
    private var menuTouch: UITouch?
    /// A finger that landed in the stick column while a menu was up, and
    /// where: the stick if it travels, a tap if it lifts in place.
    private var pendingMenuTouch: (touch: UITouch, start: CGPoint)?
    private let menuRouter = MenuTouchRouter()
    /// Answer an engine Y/N prompt; shown only while one is on screen.
    private let promptNoButton: OverlayButton
    private let promptYesButton: OverlayButton
```

- [ ] **Step 3: Create the prompt buttons in `init`**

In `init(gamepad:scheme:tuning:debugHUDEnabled:layoutOverrides:)`, before `super.init(frame: .zero)`, add:

```swift
        // Created here and never added to `buttons`: they are not a
        // `TouchOverlayControl` (the layout editor must not offer them), and
        // they answer on the press, not the release, because a prompt needs
        // one keystroke and OverlayPressTiming's held release is for the pad.
        let answer = { (yes: Bool) -> (Bool) -> Void in
            { down in if down { gamepad.answerPrompt(yes: yes) } }
        }
        promptNoButton = OverlayButton(title: "No", size: TouchOverlayLayout.promptButtonBaseDiameter,
                                       onPress: answer(false))
        promptNoButton.accessibilityIdentifier = "promptNoButton"
        promptYesButton = OverlayButton(title: "Yes", size: TouchOverlayLayout.promptButtonBaseDiameter,
                                        onPress: answer(true))
        promptYesButton.accessibilityIdentifier = "promptYesButton"
```

and after `accessibilityIdentifier = "touchOverlay"`, add:

```swift
        for button in [promptNoButton, promptYesButton] {
            button.isHidden = true
            addSubview(button)
        }
```

- [ ] **Step 4: Show the buttons from the policy timer**

In `startMenuPolicyTimer()`, inside the timer closure after `self?.dropAutomapGestureIfMapClosed()`, add:

```swift
            self?.updatePromptButtons()
            self?.dropMenuTouchesIfMenuClosed()
```

and add these two methods after `updateAutomapAvailability()`:

```swift
    /// The Yes/No pair appears with an engine prompt and leaves with it.
    /// The engine side also gates the answer itself, so a press that lands
    /// in the poll's 0.25 s window after the prompt closed is dropped there.
    private func updatePromptButtons() {
        let showing = gamepad.isMenuMessageShowing
        promptNoButton.isHidden = !showing
        promptYesButton.isHidden = !showing
    }

    /// A menu can close under a finger (the tapped item closed it, or the
    /// app was backgrounded). Forget the finger; the engine side posts the
    /// release for a press that was posted, so nothing stays held.
    private func dropMenuTouchesIfMenuClosed() {
        guard !WoofIOS_IsMenuActive() else { return }
        if menuTouch != nil {
            menuTouch = nil
            gamepad.menuTap(down: false)
        }
        pendingMenuTouch = nil
    }
```

- [ ] **Step 5: Lay the buttons out**

In `layoutSubviews()`, after the `for button in buttons { ... }` loop, add:

```swift
        let prompt = layout.promptButtonFrames()
        promptNoButton.frame = prompt.no
        promptYesButton.frame = prompt.yes
```

- [ ] **Step 6: Route touches**

In `touchesBegan`, replace the probe block

```swift
        let menuUp = WoofIOS_IsMenuActive()
        for touch in touches {
            let point = touch.location(in: self)
            if menuUp {
                // PROBE (touch menus): position first, then the press.
                if menuTouch == nil {
                    menuTouch = touch
                    WoofIOS_InjectMenuPointer(Float(point.x), Float(point.y))
                    WoofIOS_InjectMenuTap(true)
                }
                continue
            }
            if automapUp {
```

with:

```swift
        let menuUp = WoofIOS_IsMenuActive()
        for touch in touches {
            let point = touch.location(in: self)
            let route = router.route(point, stickTracking: stickTouch != nil,
                                     turnTracking: turnTouch != nil)
            switch menuRouter.began(menuActive: menuUp, trackRoute: route,
                                    nearButton: router.isNearButton(point),
                                    pointerOwned: menuTouch != nil) {
            case .pointer:
                // Position first, then the press: the engine checks a press
                // against the item the latest position highlighted.
                menuTouch = touch
                gamepad.menuPointer(at: point)
                gamepad.menuTap(down: true)
                continue
            case .pending:
                pendingMenuTouch = (touch, point)
                continue
            case .ignore:
                continue
            case .passThrough:
                break
            }
            if automapUp {
```

and replace the `switch router.route(point, stickTracking: ..., turnTracking: ...)` that follows (its `.stick` case) so the stick start is reusable:

```swift
            switch route {
            case .stick:
                beginStick(touch, at: point)
            case .turn:
```

(leave the `.turn` and `.ignore` cases as they are), then add this method directly after `touchesBegan`:

```swift
    /// Start the movement stick under `touch` at `point`: on touch-down in
    /// the stick column, or when a pending menu touch travels far enough.
    private func beginStick(_ touch: UITouch, at point: CGPoint) {
        stickTouch = touch
        stickModel = TouchStickModel(center: point, radius: layout.stickRadius,
                                     deadZone: CGFloat(tuning.stickDeadZone))
        drawStick(at: point)
        stickEngagedMarker.isHidden = false
    }
```

In `touchesMoved`, replace the probe's

```swift
            if touch == menuTouch {
                WoofIOS_InjectMenuPointer(Float(point.x), Float(point.y))
            } else if touch == stickTouch {
```

with:

```swift
            if touch == menuTouch {
                gamepad.menuPointer(at: point)
            } else if let pending = pendingMenuTouch, touch == pending.touch {
                if menuRouter.pendingBecameStick(from: pending.start, to: point) {
                    pendingMenuTouch = nil
                    beginStick(touch, at: pending.start)
                    let axes = stickModel.axes(for: point)
                    gamepad.setMovement(x: axes.x, y: axes.y, scheme: scheme)
                    moveKnob(stickKnob, to: stickModel.knobPosition(for: point))
                }
            } else if touch == stickTouch {
```

In `endTouches`, replace the probe's

```swift
            if touch == menuTouch {
                menuTouch = nil
                WoofIOS_InjectMenuTap(false)
            } else if touch == stickTouch {
```

with:

```swift
            if touch == menuTouch {
                menuTouch = nil
                gamepad.menuTap(down: false)
            } else if let pending = pendingMenuTouch, touch == pending.touch {
                pendingMenuTouch = nil
                let point = touch.location(in: self)
                if menuRouter.ended(pendingFrom: pending.start, at: point) == .tap {
                    gamepad.menuPointer(at: point)
                    gamepad.menuTap(down: true)
                    gamepad.menuTap(down: false)
                }
            } else if touch == stickTouch {
```

- [ ] **Step 7: Add the HUD segment**

In `updateDebugHUD()`, change the format string's second line from `"\n%@ · %@ · %@"` to `"\n%@ · %@ · %@ · %@"` and add, after `String(cString: WoofIOS_DebugInputState())`, the argument `String(cString: WoofIOS_DebugMenuState())`. Extend the comment above it with: `// then the touch-menu state (WoofIOS_DebugMenuState: current menu, prompt flag, item centres; TouchMenuTests reads it).`

- [ ] **Step 8: Build and run the touch unit suites**

Run: `grep -n PROBE App/Sources/Touch/*.swift` (expected: nothing), then the Task 3 Step 3 command with `-only-testing:WaddleTests/MenuTouchRouterTests -only-testing:WaddleTests/TouchOverlayLayoutPromptButtonTests -only-testing:WaddleTests/TouchTrackRouterTests -only-testing:WaddleTests/OverlayButtonAccessibilityTraitTests`.
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 9: Commit**

```bash
git add App/Sources/Touch/TouchGamepad.swift App/Sources/Touch/TouchOverlayView.swift
git commit -m "feat(touch): tap engine menu items, drag sliders, answer prompts with Yes/No

While a menu is up a free-area touch drives the engine's pointer: an
item highlights on touch-down and activates there, a slider follows the
finger. A touch in the stick column waits: a drag is still the stick
that navigates the menu, a lift in place is a tap. Yes/No buttons appear
with an engine prompt, since a pointer press there would answer yes."
```

### Task 6: `TouchMenuTests` (UI), replacing the probe test

**Files:**
- Delete: `App/UITests/TouchMenuProbeTests.swift`
- Create: `App/UITests/TouchMenuTests.swift`

**Interfaces:**
- Consumes: HUD segment `cm= msg= mp= mt= md= tgt=` (Task 2), buttons `promptYesButton`/`promptNoButton` (Task 5), the existing `menuButton`, `useButton`, `sessionDebugHUD`, `engineExitLabel`, and the `game-Freedoom Phase 2` tile.

- [ ] **Step 1: Delete the probe test and create the real one**

`rm App/UITests/TouchMenuProbeTests.swift`, then create `App/UITests/TouchMenuTests.swift`:

```swift
import XCTest

/// Woof's menus driven by touch (docs/superpowers/specs/2026-10-05-touch-menus-design.md).
/// The debug HUD's third segment (`WoofIOS_DebugMenuState`) reports which
/// menu is up and where its items are on screen, so this test taps real
/// screen points and reads back what the engine did.
///
/// Format of that segment: `cm=<menu> msg=<0|1> mp=<n> mt=<n> md=<n>
/// tgt=<x,y|x,y|...>` -- current menu name, prompt showing, pointer writes,
/// press/release writes, presses dropped, item centres in window points.
final class TouchMenuTests: XCTestCase {

    private let autoquitSeconds = 120.0

    @MainActor
    func testTapsOpenMenusAndPromptsNeedTheButtons() throws {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "\(Int(autoquitSeconds))"
        app.launchEnvironment["WADDLE_FORCE_TOUCH_OVERLAY"] = "1"
        app.launchArguments += ["-debugHUD", "YES"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Waddle"].waitForExistence(timeout: 90), "launcher UI never appeared")
        let ok = app.alerts.buttons["OK"]
        if ok.waitForExistence(timeout: 3) { ok.tap() }

        let phase2 = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH 'game-' AND identifier CONTAINS 'Freedoom Phase 2'")).firstMatch
        XCTAssertTrue(phase2.waitForExistence(timeout: 30), "Phase 2 tile missing")
        phase2.tap()

        let hud = app.staticTexts["sessionDebugHUD"]
        XCTAssertTrue(hud.waitForExistence(timeout: 30), "debug HUD never appeared")
        let booted = waitForHUD(hud, timeout: 30) { $0["pad"]?.hasSuffix(" virtual") == true }
        XCTAssertEqual(booted["pad"]?.hasSuffix(" virtual"), true, "engine should hold our pad: \(lastSeenStrip)")
        XCTAssertEqual(booted["cm"], "off", "no menu on the title screen: \(lastSeenStrip)")
        XCTAssertFalse(app.buttons["promptYesButton"].exists, "Yes must be hidden with no prompt up")

        // A pointer tap outside the stick column opens the item under it.
        app.buttons["menuButton"].tap()
        var main = waitForHUD(hud, timeout: 10) { $0["cm"] == "main" }
        var targets = points(main["tgt"])
        XCTAssertGreaterThanOrEqual(targets.count, 5, "main-menu item centres: \(lastSeenStrip)")

        // Empty space above New Game: a press there is eaten, nothing opens.
        tap(app, CGPoint(x: targets[0].x, y: targets[0].y - 60))
        Thread.sleep(forTimeInterval: 0.75)
        let stillMain = waitForHUD(hud, timeout: 1) { _ in false }
        XCTAssertEqual(stillMain["cm"], "main", "a tap on empty menu space must change nothing: \(lastSeenStrip)")

        tap(app, targets[2]) // Load Game; the centre is right of the stick column
        let load = waitForHUD(hud, timeout: 5) { $0["cm"] == "load" }
        XCTAssertEqual(load["cm"], "load", "one tap should open Load Game: \(lastSeenStrip)")

        // A tap in the stick column (left 40%) is pending until it lifts in
        // place, then it is a tap on the row under it: Options, index 1.
        closeMenus(app, hud)
        app.buttons["menuButton"].tap()
        main = waitForHUD(hud, timeout: 10) { $0["cm"] == "main" }
        targets = points(main["tgt"])
        XCTAssertGreaterThanOrEqual(targets.count, 5, "\(lastSeenStrip)")
        let stickColumnX = app.frame.width * 0.2
        tap(app, CGPoint(x: stickColumnX, y: targets[1].y))
        let options = waitForHUD(hud, timeout: 5) { $0["cm"] == "options" }
        XCTAssertEqual(options["cm"], "options", "a lift-in-place in the stick column should tap Options: \(lastSeenStrip)")

        // A drag in the stick column is still the stick, and it still moves
        // the menu cursor (DebugHUDInputTelemetryTests pins the counters).
        closeMenus(app, hud)
        app.buttons["menuButton"].tap()
        main = waitForHUD(hud, timeout: 10) { $0["cm"] == "main" }
        let movesBefore = Int(main["mv"] ?? "") ?? 0
        let stickStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.72))
        let stickEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.90))
        stickStart.press(forDuration: 0.2, thenDragTo: stickEnd, withVelocity: .fast, thenHoldForDuration: 1.0)
        let afterDrag = waitForHUD(hud, timeout: 10) { (Int($0["mv"] ?? "") ?? 0) > movesBefore }
        XCTAssertGreaterThan(Int(afterDrag["mv"] ?? "") ?? 0, movesBefore,
                             "a stick drag with the menu up must still navigate it: \(lastSeenStrip)")
        XCTAssertEqual(afterDrag["cm"], "main", "the drag must not have tapped anything: \(lastSeenStrip)")

        // Quit shows a prompt. A tap on it is dropped; No closes it; Yes quits.
        closeMenus(app, hud)
        app.buttons["menuButton"].tap()
        main = waitForHUD(hud, timeout: 10) { $0["cm"] == "main" }
        targets = points(main["tgt"])
        XCTAssertGreaterThanOrEqual(targets.count, 5, "\(lastSeenStrip)")
        tap(app, targets[targets.count - 1]) // Quit is last
        let prompt = waitForHUD(hud, timeout: 5) { $0["msg"] == "1" }
        XCTAssertEqual(prompt["msg"], "1", "Quit should show its prompt: \(lastSeenStrip)")
        XCTAssertTrue(app.buttons["promptYesButton"].waitForExistence(timeout: 3), "Yes should appear with the prompt")
        XCTAssertTrue(app.buttons["promptNoButton"].exists, "No should appear with the prompt")
        let droppedBefore = Int(prompt["md"] ?? "") ?? 0
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        Thread.sleep(forTimeInterval: 0.75)
        let afterPromptTap = waitForHUD(hud, timeout: 1) { _ in false }
        XCTAssertEqual(afterPromptTap["msg"], "1", "the prompt must survive a tap: \(lastSeenStrip)")
        XCTAssertGreaterThan(Int(afterPromptTap["md"] ?? "") ?? 0, droppedBefore,
                             "the press should be counted as dropped: \(lastSeenStrip)")

        app.buttons["promptNoButton"].tap()
        let declined = waitForHUD(hud, timeout: 5) { $0["msg"] == "0" }
        XCTAssertEqual(declined["msg"], "0", "No should dismiss the prompt: \(lastSeenStrip)")
        XCTAssertEqual(declined["cm"], "off", "answering a prompt closes the whole menu: \(lastSeenStrip)")
        XCTAssertTrue(waitUntil(timeout: 3) { !app.buttons["promptNoButton"].exists }, "No should hide with the prompt")

        app.buttons["menuButton"].tap()
        main = waitForHUD(hud, timeout: 10) { $0["cm"] == "main" }
        targets = points(main["tgt"])
        XCTAssertGreaterThanOrEqual(targets.count, 5, "\(lastSeenStrip)")
        tap(app, targets[targets.count - 1])
        XCTAssertTrue(app.buttons["promptYesButton"].waitForExistence(timeout: 5), "Yes should appear again")
        app.buttons["promptYesButton"].tap()
        XCTAssertTrue(app.staticTexts["engineExitLabel"].waitForExistence(timeout: 90),
                      "Yes should quit the session")
    }

    // MARK: helpers

    /// ≡ closes every open menu (MENU_ESCAPE clears them all); a second tap
    /// would reopen, so stop as soon as the HUD says off.
    @MainActor
    private func closeMenus(_ app: XCUIApplication, _ hud: XCUIElement) {
        for _ in 0..<3 {
            app.buttons["menuButton"].tap()
            if waitForHUD(hud, timeout: 3, until: { $0["cm"] == "off" })["cm"] == "off" { return }
        }
        XCTFail("could not close the menus: \(lastSeenStrip)")
    }

    @MainActor
    private func tap(_ app: XCUIApplication, _ p: CGPoint) {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: p.x, dy: p.y)).tap()
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return condition()
    }

    private func points(_ s: String?) -> [CGPoint] {
        (s ?? "").split(separator: "|").compactMap { pair in
            let xy = pair.split(separator: ",")
            guard xy.count == 2, let x = Double(xy[0]), let y = Double(xy[1]) else { return nil }
            return CGPoint(x: x, y: y)
        }
    }

    @MainActor
    private func waitForHUD(_ hud: XCUIElement, timeout: TimeInterval,
                            until condition: ([String: String]) -> Bool) -> [String: String] {
        let deadline = Date().addingTimeInterval(timeout)
        var parsed = fields(of: lastStrip(hud))
        while !condition(parsed) && Date() < deadline && hud.exists {
            Thread.sleep(forTimeInterval: 0.25)
            parsed = fields(of: lastStrip(hud))
        }
        return parsed
    }

    private var lastSeenStrip = ""
    @MainActor
    private func lastStrip(_ hud: XCUIElement) -> String {
        if hud.exists { lastSeenStrip = hud.label }
        return lastSeenStrip
    }

    /// `pad=` segment: values may hold spaces, so they run to the next known
    /// key. `cm=` segment: plain `key=value` pairs, split on spaces.
    private func fields(of label: String) -> [String: String] {
        let padKeys = ["pad", "pads", "btn", "ly", "lypk", "vly", "ab", "mv", "menu"]
        var result: [String: String] = [:]
        for segment in label.components(separatedBy: "\n").flatMap({ $0.components(separatedBy: " · ") }) {
            if segment.hasPrefix("pad=") {
                var rest = segment
                for (i, key) in padKeys.enumerated() {
                    guard let range = rest.range(of: "\(key)=") else { continue }
                    let after = rest[range.upperBound...]
                    let end = padKeys.dropFirst(i + 1).compactMap { after.range(of: " \($0)=")?.lowerBound }.min()
                        ?? after.endIndex
                    result[key] = String(after[..<end])
                    rest = String(after[end...])
                }
            } else if segment.hasPrefix("cm=") {
                for pair in segment.split(separator: " ") {
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    if kv.count == 2 { result[String(kv[0])] = String(kv[1]) }
                }
            }
        }
        return result
    }
}
```

- [ ] **Step 2: Regenerate, create a simulator, run it**

```bash
(cd App && xcodegen generate >/dev/null)
SIM=$(xcrun simctl create "Waddle Touch Menus" "iPhone 17 Pro" "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
xcodebuild -project App/Waddle.xcodeproj -scheme Waddle -derivedDataPath App/build-cli \
  -destination "platform=iOS Simulator,id=$SIM" ARCHS=arm64 \
  -only-testing:WaddleUITests/TouchMenuTests \
  -only-testing:WaddleUITests/DebugHUDInputTelemetryTests \
  -resultBundlePath App/build-cli/touch-menus.xcresult test 2>&1 | grep -E "Test Case.*(passed|failed)|error:|\*\* TEST" | tail -12
```
Expected: both test cases `passed`, `** TEST SUCCEEDED **`. On a failure, `xcrun xcresulttool export attachments --path App/build-cli/touch-menus.xcresult --output-path App/build-cli/attachments` and read the assertion message, which carries the whole strip.

- [ ] **Step 3: Commit**

```bash
git add App/UITests/TouchMenuTests.swift
git commit -m "test(touch): tap engine menu items, keep the stick drag, answer the Quit prompt"
```

### Task 7: Documentation

**Files:**
- Create: `docs/learnings/menu-click-answers-prompt-yes.md`
- Modify: `docs/learnings/INDEX.md` (append one line)
- Modify: `docs/manual-testing.md` (the "Touch" list)
- Modify: `README.md` ("Controls", the Touch bullet)

- [ ] **Step 1: The learning**

Create `docs/learnings/menu-click-answers-prompt-yes.md`:

```markdown
# A pointer click on a Woof Y/N prompt is "yes"

While `messageToPrint` is set ("Quit?", "Load game?", "End game?") or the
Load/Save delete confirmation (`delete_verify`) is up, `MouseResponder`
returns early, so a left-button `ev_mouseb_down` falls through to the
generic action table, where a mouse button is `input_menu_enter`. The
`messageToPrint` branch of `M_Responder` then rewrites `MENU_ENTER` to
`ch = 'y'` (`mn_menu.c`, "if (action == MENU_ENTER) ch = 'y'"), and
`delete_verify` accepts `MENU_ENTER` outright. A desktop user never notices
because their click is on a button they read; a touch user's tap "anywhere"
would quit the game.

Measured on 2026-10-05 by reading, then pinned by the probe that led to
touch-driven menus: a tap on the Quit prompt with the gate off is a quit.

**What to do:** never post a pointer press while `MN_MenuMessageShowing()`
is true. `WoofIOS_InjectMenuTap` drops it (and counts it, `md=` in the
debug HUD); the overlay answers prompts through `WoofIOS_InjectMenuAnswer`,
which types `'y'`/`'n'`, the letters both responders read.
`TouchMenuTests` is the check.

**Provenance:** touch-enabled-menus branch, 2026-10-05.
```

- [ ] **Step 2: Index it**

Append to `docs/learnings/INDEX.md`:

```markdown
- [A pointer click on a Woof Y/N prompt is "yes"](menu-click-answers-prompt-yes.md) — `MENU_ENTER` becomes `'y'` in the message branch and `delete_verify` takes it outright, so a touch press must be dropped while `MN_MenuMessageShowing()`; `TouchMenuTests` is the check
```

- [ ] **Step 3: Manual checklist**

In `docs/manual-testing.md`, replace the bullet that reads `≡ opens the menu and the stick + FIRE/USE navigate it` (keeping the rest of that bullet) with `≡ opens the menu; tapping an item opens it, and the stick + FIRE/USE still navigate it`, and add after the MAP-hidden bullet:

```markdown
- [ ] Menus by touch: tap Load Game on the main menu and the Load menu
      opens on that one tap; in Options → General, drag the mouse
      sensitivity slider with a finger and the value follows; in Save Game
      tap an empty slot and the keyboard comes up for the name; delete a
      save and answer the confirmation with the on-screen No, then Yes;
      choose Quit and confirm that a tap anywhere on the prompt does nothing
      while Yes/No answer it
```

- [ ] **Step 4: README**

In `README.md`'s Touch bullet, after `and menu (≡).` insert: `In the engine's menus, tap an item to choose it and drag a slider to set it; a Y/N prompt shows Yes/No buttons.`

- [ ] **Step 5: Check and commit**

Run: `Scripts/check-substrate.sh && echo OK`
Expected: `OK`.

```bash
git add docs/learnings/menu-click-answers-prompt-yes.md docs/learnings/INDEX.md docs/manual-testing.md README.md
git commit -m "docs(touch): record the prompt-click trap and the touch-menu checks"
```

### Task 8: Full unit suite, then the pull request

- [ ] **Step 1: Run `WaddleTests` on both destinations**

```bash
Scripts/ensure-ipad-simulator.sh > /dev/null
xcodebuild -project App/Waddle.xcodeproj -scheme Waddle -derivedDataPath App/build-cli \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' ARCHS=arm64 -only-testing:WaddleTests test 2>&1 | grep -E "Executed|\*\* TEST" | tail -3
xcodebuild -project App/Waddle.xcodeproj -scheme Waddle -derivedDataPath App/build-cli \
  -destination "platform=iOS Simulator,id=$SIM" ARCHS=arm64 -only-testing:WaddleTests \
  -only-testing:WaddleUITests/TouchControlsTests -only-testing:WaddleUITests/SoftKeyboardTests test 2>&1 | grep -E "Executed|failed|\*\* TEST" | tail -6
```
Expected: `** TEST SUCCEEDED **` on both. Then `xcrun simctl delete "$SIM"`.

- [ ] **Step 2: Open the PR**

```bash
git push -u origin tylervick/touch-enabled-menus
gh pr create --title "feat(touch): tap the engine's menus" --body "$(cat <<'EOF'
Tap an item in Woof's in-game menus to choose it, drag a slider to set it, and answer a Y/N prompt with on-screen Yes/No buttons. The stick still navigates menus: a drag in its column is the stick, a lift in place is a tap.

Woof 16's menus already take an absolute pointer; the overlay just never fed one. The shim now posts the position and the left-button press/release the menu understands, position first. A press on a Y/N prompt would be "yes" (new learning), so it is dropped and the Yes/No buttons type the letter instead.

Spec: docs/superpowers/specs/2026-10-05-touch-menus-design.md. Probe measurements are in the spec.

**What to test:** open the menu with ≡ and tap Load Game; it opens on one tap. Choose Quit: tapping the prompt does nothing, No and Yes answer it.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## PR 2: tap the title screen to open the menu (stacked on PR 1)

### Task 9: Attract-mode tap

**Files:**
- Modify: `Engine/woof/src/woof_ios.c` (after `WoofIOS_IsMenuMessageShowing`), `Engine/woof/src/woof_ios.h` (after `WoofIOS_IsMenuMessageShowing`), `Engine/WOOF_UPSTREAM.md` (extend the touch-menus entry)
- Modify: `App/Sources/Touch/MenuTouchRouter.swift`, `App/Tests/MenuTouchRouterTests.swift`
- Modify: `App/Sources/Touch/TouchGamepad.swift`, `App/Sources/Touch/TouchOverlayView.swift`
- Modify: `App/UITests/TouchMenuTests.swift`, `README.md`

**Interfaces:**
- Produces: `bool WoofIOS_IsAttractMode(void);`, `TouchGamepad.isAttractMode`, `MenuTouchRouter.began(menuActive:attractMode:trackRoute:nearButton:pointerOwned:)` (the `attractMode:` parameter is new; PR 1's callers pass it), `TouchGamepad.openMenu()`.

- [ ] **Step 1: Engine predicate**

In `woof_ios.c` after `WoofIOS_IsMenuMessageShowing`:

```c
// Title screen or a demo, with no menu up: a tap there opens the menu
// (MN_Responder's !menuactive branch treats KEY_ESCAPE as "open").
bool WoofIOS_IsAttractMode(void)
{
    return !menuactive && (gamestate == GS_DEMOSCREEN || demoplayback);
}
```

(`gamestate` is already declared extern in this file; add `extern boolean demoplayback; // doomstat.h` beside the existing `extern boolean demoplayback` if there is one, otherwise next to `extern gamestate_t gamestate;`.)

In `woof_ios.h` after `WoofIOS_IsMenuMessageShowing`:

```c
// True on the title screen or during a demo while no menu is up, so the
// overlay can open the menu on a tap (console "press any button").
bool WoofIOS_IsAttractMode(void);
```

In `WOOF_UPSTREAM.md`, append to the touch-menus entry: `` `WoofIOS_IsAttractMode` (title or demo, no menu) lets the overlay open the menu on a tap by injecting a paired `KEY_ESCAPE`. ``

Build: `Scripts/build-engine.sh 2>&1 | tail -1 && Scripts/check-engine-fresh.sh && echo FRESH`.

- [ ] **Step 2: Router tests, then router**

Append to `MenuTouchRouterTests`:

```swift
    func testAttractModeTouchIsPendingEverywhere() {
        for route in [TouchTrackRoute.stick, .turn, .ignore] {
            XCTAssertEqual(router.began(menuActive: false, attractMode: true, trackRoute: route,
                                        nearButton: false, pointerOwned: false), .pending)
        }
        XCTAssertEqual(router.began(menuActive: false, attractMode: true, trackRoute: .ignore,
                                    nearButton: true, pointerOwned: false), .ignore)
    }
```

and change every existing call in that file to pass `attractMode: false` after `menuActive:`. In `MenuTouchRouter.began`, change the signature to `began(menuActive: Bool, attractMode: Bool, trackRoute: TouchTrackRoute, nearButton: Bool, pointerOwned: Bool)` and the body to:

```swift
        if nearButton { return menuActive || attractMode ? .ignore : .passThrough }
        if menuActive {
            if trackRoute == .stick { return .pending }
            return pointerOwned ? .ignore : .pointer
        }
        if attractMode { return .pending }
        return .passThrough
```

(The near-button `.passThrough` keeps PR 1's `testNoMenuPassesThroughToStickAndTurnRouting` true: outside menus the track router already ignores near-misses itself.)

- [ ] **Step 3: Gamepad and overlay**

`TouchGamepad.swift`, after `isMenuMessageShowing`:

```swift
    /// Title screen or demo with no menu up.
    var isAttractMode: Bool { WoofIOS_IsAttractMode() }

    /// Open the engine menu from the title or a demo: KEY_ESCAPE, paired.
    func openMenu() {
        WoofIOS_InjectKey(27, true)  // KEY_ESCAPE (doomkeys.h)
        WoofIOS_InjectKey(27, false)
    }
```

`TouchOverlayView.touchesBegan`: read `let attract = gamepad.isAttractMode` beside `menuUp` and pass `attractMode: attract` to `menuRouter.began`. In `touchesMoved`, the pending promotion to the stick already works for attract mode unchanged. In `endTouches`, replace the pending branch's body with:

```swift
                pendingMenuTouch = nil
                let point = touch.location(in: self)
                if menuRouter.ended(pendingFrom: pending.start, at: point) == .tap {
                    if WoofIOS_IsMenuActive() {
                        gamepad.menuPointer(at: point)
                        gamepad.menuTap(down: true)
                        gamepad.menuTap(down: false)
                    } else if gamepad.isAttractMode {
                        gamepad.openMenu()
                    }
                }
```

- [ ] **Step 4: UI test step**

In `TouchMenuTests`, right after the `XCTAssertFalse(app.buttons["promptYesButton"].exists, ...)` line, add:

```swift
        // Title screen: a tap on the game opens the main menu.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        let opened = waitForHUD(hud, timeout: 5) { $0["cm"] == "main" }
        XCTAssertEqual(opened["cm"], "main", "a title-screen tap should open the menu: \(lastSeenStrip)")
        closeMenus(app, hud)
```

README Touch bullet: append `Tap the title screen to open the menu.`

- [ ] **Step 5: Run and commit**

Run Task 3 Step 3's command with `-only-testing:WaddleTests/MenuTouchRouterTests`, then Task 6 Step 2's `xcodebuild` (new simulator) for `TouchMenuTests` and `DebugHUDInputTelemetryTests`. Expected: all passed. Then:

```bash
git add Engine/woof/src/woof_ios.c Engine/woof/src/woof_ios.h Engine/WOOF_UPSTREAM.md \
  App/Sources/Touch/MenuTouchRouter.swift App/Tests/MenuTouchRouterTests.swift \
  App/Sources/Touch/TouchGamepad.swift App/Sources/Touch/TouchOverlayView.swift \
  App/UITests/TouchMenuTests.swift README.md
git commit -m "feat(touch): open the engine menu with a tap on the title screen"
git push
```

Open the stacked PR against PR 1's branch (`gh pr create --base tylervick/touch-enabled-menus` after moving this work to `tylervick/touch-menus-title-tap`), with a first sentence written for testers: "Tap the title screen to open the menu; everything else is PR #N."
