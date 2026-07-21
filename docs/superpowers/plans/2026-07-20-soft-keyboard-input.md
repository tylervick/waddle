# Touch Soft-Keyboard Input Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let touch-only players type text (cheat codes now, save-game names for free) into the running Woof engine by summoning the iOS system keyboard with a four-finger tap.

**Architecture:** A four-finger tap over the running game presents an invisible `UITextField` "character funnel." Each keystroke is posted straight into the engine's event queue via `D_PostEvent` (bypassing SDL text input) as both an `ev_keydown` (cheats read `data2`) and an `ev_text` (save-name reads `data1`). A new engine query, `WoofIOS_GetTextInputContext()`, gates the keyboard so it only appears during live gameplay or save-name entry, never at the title screen or in ordinary menus.

**Tech Stack:** C (Woof engine / SDL3 bridge), Swift 6 + UIKit (touch overlay), XCTest / XCUITest, xcodegen + mise + xcodebuild.

**Spec:** `docs/superpowers/specs/2026-07-20-soft-keyboard-input-design.md`

## Global Constraints

- iOS deployment target **26.0**; Swift 6 (UIKit types are `@MainActor`-isolated).
- The engine ships as a prebuilt **`WoofEngine.xcframework`**; rebuild it with `mise run build-engine` after any change under `Engine/woof/src/`.
- The WoofEngine module map exposes **only `woof_ios.h`** — every Swift-visible bridge symbol MUST be declared there.
- After adding/removing Swift or test files, regenerate the Xcode project with `mise run generate` (xcodegen) before building.
- Run the full suite with `mise run test` (builds engine smoke + unit + UI on the `iPhone 17 Pro` simulator). Unit test target: **`WADdleTests`** (`App/Tests/`); UI test target: **`WADdleUITests`** (`App/UITests/`).
- Cheat detection reads `ev_keydown.data2` (lowercase ASCII); save-name reads `ev_text.data1`; both are posted per keystroke. Cheats only register while `gamestate == GS_LEVEL` and no menu is open — the keyboard must appear over the *live* game, never by opening a menu.
- Commits: no Claude/AI attribution, no `Co-Authored-By` line.

---

### Task 1: Engine C bridge — text injection + context query

Adds the four bridge functions and a menu accessor. There is no C unit-test harness in this repo, so this task is gated on a clean engine rebuild plus symbol presence; the runtime behavior is exercised by Task 4's UITest and on-device verification.

**Files:**
- Modify: `Engine/woof/src/woof_ios.h`
- Modify: `Engine/woof/src/woof_ios.c`
- Modify: `Engine/woof/src/mn_menu.c`
- Modify: `Engine/woof/src/mn_menu.h`

**Interfaces:**
- Produces (Swift-visible, via `import WoofEngine`):
  - `WoofIOS_TextInputContext` enum: `WOOF_TEXT_CTX_NONE`, `WOOF_TEXT_CTX_GAMEPLAY`, `WOOF_TEXT_CTX_SAVENAME`
  - `WoofIOS_TextInputContext WoofIOS_GetTextInputContext(void)`
  - `void WoofIOS_InjectChar(char c)`
  - `void WoofIOS_InjectBackspace(void)`
  - `void WoofIOS_InjectMenuConfirm(void)`
- Produces (engine-internal): `boolean MN_SaveStringEntering(void)`

- [ ] **Step 1: Declare the enum + prototypes in the bridge header**

In `Engine/woof/src/woof_ios.h`, immediately before the final `#endif`, add:

```c
// --- Soft-keyboard text injection (touch cheat/text entry) ---
// The overlay summons the iOS system keyboard on a four-finger tap and
// funnels each keystroke here. These post synthesized events directly onto
// the engine queue via D_PostEvent, bypassing SDL text input (which is
// stopped on iOS and flaky on the simulator). Main-thread-only, same
// contract as the touch-control functions above.

// Which text-entry context the engine is in right now, so the overlay can
// gate the keyboard: only summon during live gameplay (cheats) or while the
// save-name field is capturing input -- never at the title or in menus.
typedef enum
{
    WOOF_TEXT_CTX_NONE = 0,   // title, menus, intermission/finale, demo, etc.
    WOOF_TEXT_CTX_GAMEPLAY,   // in a live level, no menu, not paused (cheats)
    WOOF_TEXT_CTX_SAVENAME,   // menu save-name entry is active
} WoofIOS_TextInputContext;

WoofIOS_TextInputContext WoofIOS_GetTextInputContext(void);

// Inject one typed character. Posts BOTH an ev_keydown (data2 = lowercased
// char) that the cheat matcher (m_cheat.c M_FindCheats) reads, AND an
// ev_text (data1 = char) that menu save-name entry (mn_menu.c) reads -- so
// one call serves cheats and save-name typing wherever the responder chain
// currently is.
void WoofIOS_InjectChar(char c);

// Inject a Backspace keypress (ev_keydown, KEY_BACKSPACE) -- edits the
// save-name field.
void WoofIOS_InjectBackspace(void);

// Inject an Enter keypress (ev_keydown, KEY_ENTER) -- commits the save-name
// field (input_menu_enter -> MENU_ENTER). Harmless during gameplay.
void WoofIOS_InjectMenuConfirm(void);
```

- [ ] **Step 2: Add the save-name accessor to the menu module**

`saveStringEnter` is `static` in `mn_menu.c` (line ~98), so it needs an accessor. In `Engine/woof/src/mn_menu.c`, immediately before `boolean M_Responder(event_t *ev)`, add:

```c
// Exposes the (static) save-name text-entry state so the iOS host
// (woof_ios.c's soft keyboard) can gate its keyboard to the save-name
// field. Nonzero whenever the Load/Save menu is capturing a typed name.
boolean MN_SaveStringEntering(void)
{
    return saveStringEnter != 0;
}
```

In `Engine/woof/src/mn_menu.h`, immediately after `boolean M_Responder(struct event_s *ev);`, add:

```c
boolean MN_SaveStringEntering(void);
```

- [ ] **Step 3: Add the includes the new functions need**

In `Engine/woof/src/woof_ios.c`, the existing include block is:

```c
#include "config.h"
#include "doomtype.h" // `boolean` typedef backing the `menuactive` extern below
#include "i_printf.h"
#include "m_argv.h"
```

Replace it with (adds ctype + the engine headers for events, D_PostEvent, gamestate/GS_LEVEL, and key codes):

```c
#include <ctype.h>

#include "config.h"
#include "d_event.h"  // event_t / ev_keydown / ev_text
#include "d_main.h"   // D_PostEvent
#include "doomdef.h"  // gamestate_t, GS_LEVEL
#include "doomkeys.h" // KEY_BACKSPACE, KEY_ENTER
#include "doomtype.h" // `boolean` typedef backing the `menuactive` extern below
#include "i_printf.h"
#include "m_argv.h"
```

- [ ] **Step 4: Implement the four functions**

In `Engine/woof/src/woof_ios.c`, immediately after the closing `}` of `WoofIOS_IsMenuActive` (which already has `extern boolean menuactive;` above it, so `menuactive` is in scope), add:

```c
// --- Soft-keyboard text injection (see woof_ios.h) ---
// Post synthesized events directly onto the engine queue via D_PostEvent,
// bypassing SDL text input entirely. Cheats read ev_keydown.data2
// (m_cheat.c's M_FindCheats); the menu save-name field reads ev_text.data1
// plus the KEY_BACKSPACE/KEY_ENTER keydowns (mn_menu.c). D_ProcessEvents
// runs M_InputTrackEvent then the responder chain on each queued event, so
// a KEY_ENTER keydown activates input_menu_enter -> MENU_ENTER exactly as a
// real key would (m_input.c M_InputActivated matches ev_keydown.data1).
// Main-thread-only, same as the touch functions.
extern gamestate_t gamestate; // doomstat.h
extern int paused;            // doomstat.h
boolean MN_SaveStringEntering(void); // mn_menu.c (saveStringEnter is static)

WoofIOS_TextInputContext WoofIOS_GetTextInputContext(void)
{
    if (MN_SaveStringEntering())
    {
        return WOOF_TEXT_CTX_SAVENAME;
    }
    if (gamestate == GS_LEVEL && !menuactive && !paused)
    {
        return WOOF_TEXT_CTX_GAMEPLAY;
    }
    return WOOF_TEXT_CTX_NONE;
}

void WoofIOS_InjectChar(char c)
{
    int lower = tolower((unsigned char)c);

    event_t key = {0};
    key.type = ev_keydown;
    key.data1.i = lower; // Doom key id; letters == lowercase ASCII
    key.data2.i = lower; // cheat matcher reads data2 (lowercase ASCII)
    D_PostEvent(&key);

    event_t text = {0};
    text.type = ev_text;
    text.data1.i = (unsigned char)c; // save-name reads data1; menu uppercases
    D_PostEvent(&text);
}

void WoofIOS_InjectBackspace(void)
{
    event_t ev = {0};
    ev.type = ev_keydown;
    ev.data1.i = KEY_BACKSPACE; // mn_menu save-name reads ch (= data1)
    D_PostEvent(&ev);
}

void WoofIOS_InjectMenuConfirm(void)
{
    event_t ev = {0};
    ev.type = ev_keydown;
    ev.data1.i = KEY_ENTER; // input_menu_enter -> MENU_ENTER commits the save
    D_PostEvent(&ev);
}
```

- [ ] **Step 5: Rebuild the engine xcframework**

Run: `mise run build-engine`
Expected: completes with no errors; `Vendor/out/WoofEngine.xcframework` and `Vendor/stage/include/woof_ios.h` are refreshed. A compile error here (e.g. a missing include) means fix Step 3/4 before proceeding.

- [ ] **Step 6: Verify the new symbols are staged into the module header**

Run: `grep -n "WoofIOS_InjectChar\|WoofIOS_GetTextInputContext\|WOOF_TEXT_CTX_GAMEPLAY" Vendor/stage/include/woof_ios.h`
Expected: all three names print (confirms the header the WoofEngine module exposes to Swift now carries the new API).

- [ ] **Step 7: Commit**

```bash
git add Engine/woof/src/woof_ios.h Engine/woof/src/woof_ios.c Engine/woof/src/mn_menu.c Engine/woof/src/mn_menu.h
git commit -m "feat(engine): add soft-keyboard text-injection bridge + input-context query"
```

---

### Task 2: Keyboard gate + context enum (pure Swift, TDD)

Pure decision logic with no UIKit or engine dependency, so it is fully unit-testable in isolation.

**Files:**
- Create: `App/Sources/Touch/TextInputContext.swift`
- Test: `App/Tests/KeyboardGateTests.swift`

**Interfaces:**
- Produces: `enum TextInputContext { case none, gameplay, saveName }`; `enum KeyboardCommand { case none, present, dismiss }`; `enum KeyboardGate` with `static func shouldPresentOnTap(context:) -> Bool` and `static func pollCommand(context:isVisible:) -> KeyboardCommand`.

- [ ] **Step 1: Write the failing tests**

Create `App/Tests/KeyboardGateTests.swift`:

```swift
import XCTest
@testable import WADdle

final class KeyboardGateTests: XCTestCase {
    func testTapPresentsOnlyInGameplay() {
        XCTAssertTrue(KeyboardGate.shouldPresentOnTap(context: .gameplay))
        XCTAssertFalse(KeyboardGate.shouldPresentOnTap(context: .none))
        XCTAssertFalse(KeyboardGate.shouldPresentOnTap(context: .saveName))
    }

    func testPollAutoPresentsForSaveName() {
        XCTAssertEqual(KeyboardGate.pollCommand(context: .saveName, isVisible: false), .present)
        XCTAssertEqual(KeyboardGate.pollCommand(context: .saveName, isVisible: true), .none)
    }

    func testPollAutoDismissesWhenLeavingTextContext() {
        XCTAssertEqual(KeyboardGate.pollCommand(context: .none, isVisible: true), .dismiss)
        XCTAssertEqual(KeyboardGate.pollCommand(context: .none, isVisible: false), .none)
    }

    func testPollLeavesGameplayKeyboardAlone() {
        XCTAssertEqual(KeyboardGate.pollCommand(context: .gameplay, isVisible: true), .none)
        XCTAssertEqual(KeyboardGate.pollCommand(context: .gameplay, isVisible: false), .none)
    }
}
```

- [ ] **Step 2: Regenerate the project and run the tests to verify they fail**

Run:
```bash
mise run generate
xcodebuild -project App/WADdle.xcodeproj -scheme WADdle \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:WADdleTests/KeyboardGateTests test
```
Expected: BUILD FAILS — `cannot find 'KeyboardGate' in scope` / `TextInputContext` unresolved.

- [ ] **Step 3: Write the implementation**

Create `App/Sources/Touch/TextInputContext.swift`:

```swift
import Foundation

/// The engine's current text-entry context, mirrored from
/// `WoofIOS_GetTextInputContext()`. Drives when the soft keyboard is allowed
/// to appear (see `KeyboardGate`).
enum TextInputContext: Equatable {
    case none       // title, ordinary menus, intermission/finale, demo
    case gameplay   // live level, no menu, not paused -> cheats
    case saveName   // menu save-name field is capturing input
}

/// What a context poll should do with the keyboard right now.
enum KeyboardCommand: Equatable {
    case none, present, dismiss
}

/// Pure decision logic for when the soft keyboard may appear or must
/// disappear, given the engine's text-input context. Free of UIKit so it is
/// unit-testable in isolation (see KeyboardGateTests).
enum KeyboardGate {
    /// A summon gesture (four-finger tap) presents the keyboard only during
    /// live gameplay; in every other context the tap is ignored, so it can
    /// never pop up at the title screen or in ordinary menus.
    static func shouldPresentOnTap(context: TextInputContext) -> Bool {
        context == .gameplay
    }

    /// Run periodically: auto-present for save-name entry, auto-dismiss if
    /// the keyboard is visible but the engine has left a text context
    /// (player died, level ended, menu opened). Gameplay presentation is
    /// tap-driven, so a visible gameplay keyboard is left as-is.
    static func pollCommand(context: TextInputContext,
                            isVisible: Bool) -> KeyboardCommand {
        switch context {
        case .saveName:
            return isVisible ? .none : .present
        case .none:
            return isVisible ? .dismiss : .none
        case .gameplay:
            return .none
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
mise run generate
xcodebuild -project App/WADdle.xcodeproj -scheme WADdle \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:WADdleTests/KeyboardGateTests test
```
Expected: TEST SUCCEEDED (4 tests pass).

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Touch/TextInputContext.swift App/Tests/KeyboardGateTests.swift
git commit -m "feat(touch): add keyboard input-context gate logic"
```

---

### Task 3: Character-pump keyboard (TDD)

The invisible funnel `UITextField` + its delegate, injecting through a swappable `TextInjecting` protocol so the pump is unit-testable against a spy.

**Files:**
- Create: `App/Sources/Touch/TouchKeyboard.swift`
- Test: `App/Tests/TouchKeyboardTests.swift`

**Interfaces:**
- Produces:
  - `@MainActor protocol TextInjecting: AnyObject { func injectCharacter(_ scalar: UnicodeScalar); func injectBackspace(); func injectMenuConfirm() }`
  - `final class CheatTextField: UITextField`
  - `@MainActor final class TouchKeyboard: NSObject, UITextFieldDelegate` with `init(injector: TextInjecting)`, `let field: CheatTextField`, `var isVisible: Bool { get }`, `var onReturn: (() -> Void)?`, `@discardableResult func present() -> Bool`, `func dismiss()`.
- Consumes: nothing (protocol is satisfied by a spy here; by `TouchGamepad` in Task 4).

- [ ] **Step 1: Write the failing tests**

Create `App/Tests/TouchKeyboardTests.swift`:

```swift
import UIKit
import XCTest
@testable import WADdle

@MainActor
final class TouchKeyboardTests: XCTestCase {
    final class SpyInjector: TextInjecting {
        var characters: [UnicodeScalar] = []
        var backspaces = 0
        var confirms = 0
        func injectCharacter(_ scalar: UnicodeScalar) { characters.append(scalar) }
        func injectBackspace() { backspaces += 1 }
        func injectMenuConfirm() { confirms += 1 }
    }

    func testTypingInjectsEachCharacterInOrder() {
        let spy = SpyInjector()
        let kb = TouchKeyboard(injector: spy)
        for ch in "iddqd" {
            _ = kb.textField(kb.field,
                             shouldChangeCharactersIn: NSRange(location: 1, length: 0),
                             replacementString: String(ch))
        }
        XCTAssertEqual(String(String.UnicodeScalarView(spy.characters)), "iddqd")
    }

    func testEmptyReplacementInjectsBackspace() {
        let spy = SpyInjector()
        let kb = TouchKeyboard(injector: spy)
        _ = kb.textField(kb.field,
                         shouldChangeCharactersIn: NSRange(location: 0, length: 1),
                         replacementString: "")
        XCTAssertEqual(spy.backspaces, 1)
    }

    func testDelegateNeverAccumulates() {
        let spy = SpyInjector()
        let kb = TouchKeyboard(injector: spy)
        let result = kb.textField(kb.field,
                                  shouldChangeCharactersIn: NSRange(location: 1, length: 0),
                                  replacementString: "z")
        XCTAssertFalse(result)
    }

    func testReturnInvokesOnReturn() {
        let spy = SpyInjector()
        let kb = TouchKeyboard(injector: spy)
        var called = false
        kb.onReturn = { called = true }
        _ = kb.textFieldShouldReturn(kb.field)
        XCTAssertTrue(called)
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run:
```bash
mise run generate
xcodebuild -project App/WADdle.xcodeproj -scheme WADdle \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:WADdleTests/TouchKeyboardTests test
```
Expected: BUILD FAILS — `cannot find type 'TextInjecting'` / `'TouchKeyboard' in scope`.

- [ ] **Step 3: Write the implementation**

Create `App/Sources/Touch/TouchKeyboard.swift`:

```swift
import UIKit

/// Sink for synthesized keystrokes. Abstracted so the character pump can be
/// unit-tested against a spy without the C engine bridge (TouchGamepad is
/// the production conformer, added in the integration task).
@MainActor
protocol TextInjecting: AnyObject {
    func injectCharacter(_ scalar: UnicodeScalar)
    func injectBackspace()
    func injectMenuConfirm()
}

/// Invisible UITextField used purely as a character funnel.
final class CheatTextField: UITextField {
    // No caret on an invisible funnel field.
    override func caretRect(for position: UITextPosition) -> CGRect { .zero }
    // Suppress the copy/paste/select edit menu.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        false
    }
}

/// Owns the funnel text field + its delegate and turns keystrokes into
/// engine input via a TextInjecting sink. present()/dismiss() show and hide
/// the iOS system keyboard.
///
/// The field never accumulates text: a single non-breaking-space sentinel
/// is kept in it at all times, so the Delete key always produces a delegate
/// callback (an empty field would swallow it) -- letting us detect
/// backspaces via the delegate without overriding deleteBackward, and
/// giving the OS no prediction context. Every delegate change returns false,
/// so the sentinel stays put and nothing the user "types" is ever stored.
@MainActor
final class TouchKeyboard: NSObject, UITextFieldDelegate {
    private static let sentinel = "\u{00A0}" // non-breaking space

    let field = CheatTextField(frame: CGRect(x: -2, y: -2, width: 1, height: 1))
    private let injector: TextInjecting
    private(set) var isVisible = false

    /// Invoked when Return is pressed; the overlay decides whether that
    /// means "commit save-name" or just "dismiss".
    var onReturn: (() -> Void)?

    init(injector: TextInjecting) {
        self.injector = injector
        super.init()
        field.delegate = self
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        if #available(iOS 17.0, *) { field.inlinePredictionType = .no }
        field.keyboardType = .asciiCapable
        field.keyboardAppearance = .dark
        field.tintColor = .clear
        field.text = Self.sentinel
    }

    @discardableResult
    func present() -> Bool {
        field.text = Self.sentinel
        isVisible = field.becomeFirstResponder()
        return isVisible
    }

    func dismiss() {
        field.resignFirstResponder()
        isVisible = false
    }

    // MARK: UITextFieldDelegate

    func textField(_ textField: UITextField,
                   shouldChangeCharactersIn range: NSRange,
                   replacementString string: String) -> Bool {
        if string.isEmpty {
            injector.injectBackspace() // Delete key
        } else {
            for scalar in string.unicodeScalars where scalar.isASCII {
                injector.injectCharacter(scalar)
            }
        }
        return false // never accumulate; sentinel stays put
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onReturn?()
        return false
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
mise run generate
xcodebuild -project App/WADdle.xcodeproj -scheme WADdle \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:WADdleTests/TouchKeyboardTests test
```
Expected: TEST SUCCEEDED (4 tests pass).

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Touch/TouchKeyboard.swift App/Tests/TouchKeyboardTests.swift
git commit -m "feat(touch): add character-pump soft keyboard funnel"
```

---

### Task 4: Integration — gamepad conformance, four-finger tap, context poll, interaction guard

Wires the pieces together in the overlay and proves it end-to-end with a UITest that is robust against the simulator's hardware-keyboard setting (it asserts on an app-owned `softKeyboardActive` marker, not the OS keyboard's own rendering).

**Files:**
- Modify: `App/Sources/Touch/TouchGamepad.swift`
- Modify: `App/Sources/Touch/TouchOverlayView.swift`
- Test: `App/UITests/SoftKeyboardTests.swift`

**Interfaces:**
- Consumes: `TextInjecting`, `TouchKeyboard`, `TextInputContext`, `KeyboardGate`, `KeyboardCommand` (Tasks 2–3); `WoofIOS_InjectChar/Backspace/MenuConfirm`, `WoofIOS_GetTextInputContext`, `WOOF_TEXT_CTX_*` (Task 1).
- Produces: `TouchGamepad: TextInjecting`; `TouchGamepad.currentTextInputContext() -> TextInputContext`; overlay accessibility marker `"softKeyboardActive"`.

- [ ] **Step 1: Make TouchGamepad the production injector + context source**

At the end of `App/Sources/Touch/TouchGamepad.swift` (after the final `}` of the `TouchGamepad` class), add:

```swift
extension TouchGamepad: TextInjecting {
    func injectCharacter(_ scalar: UnicodeScalar) {
        guard scalar.isASCII else { return }
        WoofIOS_InjectChar(CChar(bitPattern: UInt8(scalar.value)))
    }

    func injectBackspace() { WoofIOS_InjectBackspace() }

    func injectMenuConfirm() { WoofIOS_InjectMenuConfirm() }

    /// Current engine text-input context, mirrored from the C bridge.
    func currentTextInputContext() -> TextInputContext {
        let ctx = WoofIOS_GetTextInputContext()
        if ctx == WOOF_TEXT_CTX_GAMEPLAY { return .gameplay }
        if ctx == WOOF_TEXT_CTX_SAVENAME { return .saveName }
        return .none
    }
}
```

- [ ] **Step 2: Add the keyboard, gesture, guard, and marker to the overlay**

In `App/Sources/Touch/TouchOverlayView.swift`:

**(a)** Add stored properties. After the existing `private var menuPolicyTimer: Timer?` line (near line 27), add:

```swift
    private let keyboard: TouchKeyboard
    private var keyboardActive = false
    private let keyboardActiveMarker = UIView()
```

**(b)** Initialize `keyboard` before `super.init`. In `init(gamepad:scheme:tuning:debugHUDEnabled:)`, the first lines currently are:

```swift
        self.gamepad = gamepad
        self.scheme = scheme
        self.tuning = tuning
        self.debugHUDEnabled = debugHUDEnabled
        super.init(frame: .zero)
```

Replace them with (constructs the keyboard from the same gamepad, which is the injector):

```swift
        self.gamepad = gamepad
        self.scheme = scheme
        self.tuning = tuning
        self.debugHUDEnabled = debugHUDEnabled
        self.keyboard = TouchKeyboard(injector: gamepad)
        super.init(frame: .zero)
```

**(c)** Wire the field, gesture, marker, and Return behavior. Immediately after `startMenuPolicyTimer()` in `init` (around line 120), add:

```swift
        // Soft keyboard: four-finger tap summons the iOS keyboard over the
        // live game for cheat/text entry (see the design spec). The field is
        // an invisible funnel; Return commits a save-name (only in that
        // context) then dismisses.
        addSubview(keyboard.field)
        keyboard.onReturn = { [weak self] in
            guard let self else { return }
            if self.gamepad.currentTextInputContext() == .saveName {
                self.gamepad.injectMenuConfirm()
            }
            self.dismissKeyboard()
        }

        // Small but non-zero frame in a corner: a zero-frame accessibility
        // element can be treated as off-screen and go missing from the
        // XCUITest tree. Non-interactive and effectively invisible.
        keyboardActiveMarker.frame = CGRect(x: 2, y: 2, width: 2, height: 2)
        keyboardActiveMarker.accessibilityIdentifier = "softKeyboardActive"
        keyboardActiveMarker.isAccessibilityElement = true
        keyboardActiveMarker.isUserInteractionEnabled = false
        keyboardActiveMarker.isHidden = true
        addSubview(keyboardActiveMarker)

        // Four fingers (not three): normal play uses at most ~2-3 touches, so
        // four is unambiguous, and it matches id's classic iOS DOOM gesture.
        let summon = UITapGestureRecognizer(target: self,
                                            action: #selector(handleSummonTap))
        summon.numberOfTouchesRequired = 4
        summon.numberOfTapsRequired = 1
        summon.cancelsTouchesInView = false // never swallow stick/turn/button touches
        addGestureRecognizer(summon)
```

**(d)** Add the tap handler, present/dismiss, and context poll. After the `updateAutomapAvailability()` method (around line 170), add:

```swift
    // MARK: Soft keyboard (four-finger tap; see design spec)

    @objc private func handleSummonTap() {
        if keyboard.isVisible {
            dismissKeyboard()
        } else if KeyboardGate.shouldPresentOnTap(
            context: gamepad.currentTextInputContext()) {
            presentKeyboard()
        }
    }

    /// Auto-present for save-name entry / auto-dismiss on leaving a text
    /// context. Called from the same 0.25s poll as automap suppression.
    private func updateKeyboardForContext() {
        switch KeyboardGate.pollCommand(context: gamepad.currentTextInputContext(),
                                        isVisible: keyboard.isVisible) {
        case .present: presentKeyboard()
        case .dismiss: dismissKeyboard()
        case .none: break
        }
    }

    private func presentKeyboard() {
        // Interaction guard: stop movement and make the gameplay controls
        // inert while typing, so touches near or under the keyboard cannot
        // steer or fire.
        gamepad.setMovement(x: 0, y: 0, scheme: scheme)
        stickTouch = nil
        turnTouch = nil
        stickBase.isHidden = true
        stickKnob.isHidden = true
        turnBase.isHidden = true
        turnKnob.isHidden = true
        keyboardActive = true
        for button in buttons { button.isUserInteractionEnabled = false }
        keyboard.present()
        keyboardActiveMarker.isHidden = false
    }

    private func dismissKeyboard() {
        keyboard.dismiss()
        keyboardActive = false
        for button in buttons { button.isUserInteractionEnabled = true }
        keyboardActiveMarker.isHidden = true
    }
```

**(e)** Have the existing poll also drive the keyboard. In `startMenuPolicyTimer()`, the timer block currently is:

```swift
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateAutomapAvailability()
        }
```

Replace it with:

```swift
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateAutomapAvailability()
            self?.updateKeyboardForContext()
        }
```

**(f)** Suppress gameplay touches while the keyboard is up. At the very top of `touchesBegan(_:with:)` and again at the top of `touchesMoved(_:with:)`, before the `for touch in touches {` loop, add:

```swift
        if keyboardActive { return }
```

**(g)** Dismiss the keyboard on teardown. In `removeFromSuperview()`, before `super.removeFromSuperview()`, add:

```swift
        if keyboard.isVisible { keyboard.dismiss() }
```

- [ ] **Step 3: Write the UITest**

Create `App/UITests/SoftKeyboardTests.swift`:

```swift
import XCTest

/// Verifies the four-finger-tap soft keyboard summons only during live
/// gameplay and dismisses. Asserts on the app-owned `softKeyboardActive`
/// marker rather than `app.keyboards`, which the simulator's connected
/// hardware keyboard can suppress. Real on-screen keyboard rendering and
/// actual cheat activation are device-verified (see the design spec).
final class SoftKeyboardTests: XCTestCase {

    @MainActor
    func testFourFingerTapSummonsAndDismissesInGame() throws {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "25"
        // The Simulator reports a phantom controller/keyboard, which would
        // otherwise hide the overlay (see OverlayPresenter.applyPolicy).
        app.launchEnvironment["WADDLE_FORCE_TOUCH_OVERLAY"] = "1"
        app.launch()

        let play = app.buttons["playFreedoom1"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()

        XCTAssertTrue(app.buttons["fireButton"].waitForExistence(timeout: 20),
                      "overlay never installed")

        let marker = app.otherElements["softKeyboardActive"]
        XCTAssertFalse(marker.exists, "keyboard active before any tap")

        // Four-finger tap at the center of the screen (empty overlay area).
        app.tap(withNumberOfTaps: 1, numberOfTouches: 4)
        XCTAssertTrue(marker.waitForExistence(timeout: 5),
                      "four-finger tap did not summon the keyboard in-game")

        app.tap(withNumberOfTaps: 1, numberOfTouches: 4)
        // waitForExistence returns false once the marker leaves the tree.
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: marker)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    func testFourFingerTapIgnoredWhileMenuOpen() throws {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "25"
        app.launchEnvironment["WADDLE_FORCE_TOUCH_OVERLAY"] = "1"
        app.launch()

        app.buttons["playFreedoom1"].tap()
        XCTAssertTrue(app.buttons["menuButton"].waitForExistence(timeout: 20))

        // Open the in-game menu -> context leaves GAMEPLAY.
        app.buttons["menuButton"].tap()

        let marker = app.otherElements["softKeyboardActive"]
        app.tap(withNumberOfTaps: 1, numberOfTouches: 4)
        XCTAssertFalse(marker.waitForExistence(timeout: 3),
                       "keyboard wrongly summoned while a menu was open")
    }
}
```

- [ ] **Step 4: Regenerate, build, and run the new UITest + full unit suite**

Run:
```bash
mise run generate
xcodebuild -project App/WADdle.xcodeproj -scheme WADdle \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:WADdleUITests/SoftKeyboardTests \
  -only-testing:WADdleTests/KeyboardGateTests \
  -only-testing:WADdleTests/TouchKeyboardTests test
```
Expected: TEST SUCCEEDED. If `testFourFingerTapSummonsAndDismissesInGame` cannot find the overlay, confirm `WADDLE_FORCE_TOUCH_OVERLAY` is set and the engine was rebuilt (Task 1 Step 5).

- [ ] **Step 5: Run the whole suite for regressions**

Run: `mise run test`
Expected: the full suite (engine smoke + unit + UI) passes; existing `TouchControlsTests` still green (the interaction guard and gesture must not disturb stick/turn/button input).

- [ ] **Step 6: Commit**

```bash
git add App/Sources/Touch/TouchGamepad.swift App/Sources/Touch/TouchOverlayView.swift App/UITests/SoftKeyboardTests.swift
git commit -m "feat(touch): four-finger-tap soft keyboard for cheats/text entry"
```

- [ ] **Step 7: Device verification (manual, authoritative)**

On a physical device (simulator text input is unreliable — SDL #9624):
1. Launch a Freedoom level. Four-finger tap → the iOS keyboard appears; the stick/buttons go inert.
2. Type `iddqd` → the god-mode confirmation message appears in the HUD; `idkfa` → full ammo/keys; `idclev31`-style warp works.
3. Four-finger tap again (or Return) → keyboard dismisses; controls resume.
4. Die or finish the level with the keyboard up → it auto-dismisses.
Record the result in the PR description.

---

## Notes / follow-ups (not in this plan)

- **Refinement vs spec §5.2:** the spec described catching Delete by overriding `deleteBackward()`. This plan instead keeps a non-breaking-space sentinel in the field and detects Delete via the delegate's empty-`replacementString` callback — more reliable (an empty field never calls `deleteBackward`) and a single input path for both typed characters and deletions. Same outcome, cleaner seam.
- **Discovery hint:** a pure gesture is not self-evident. A one-time tip or a line in the Control Feel (gear) screen is a low-risk follow-up; deferred as non-blocking (spec §6 marked it optional).
- **Reaching the save-name field on pure touch** (menu up/down navigation) is a pre-existing limitation independent of this feature; save-name typing rides the same primitive and works once that field is reached (e.g. via a controller), and the gate handles it automatically when it is.
