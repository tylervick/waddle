# Touch Soft-Keyboard Input — Design Spec

**Date:** 2026-07-20
**Status:** Approved pending user review
**App:** WADdle (com.tylervick.BoomBox) — Woof! source port, SDL3, iOS

## 1. Summary

Touch-only players currently have no way to send keyboard input to the running
game. This blocks **cheat codes** (`iddqd`, `idkfa`, `idclev31`, …) and the
engine's **save-game name entry**, both of which require typed characters.

This feature adds a **general text-injection layer**: a four-finger tap over the
running game summons the iOS system keyboard, and each keystroke is mirrored
into the Woof engine as native input events. Cheats are the primary, day-one
consumer; save-game naming rides the same primitive for free. Any future text
field the engine grows is served by the same path.

**Not in scope:** a custom-drawn keyboard UI, macro/"quick-cheat" buttons, or a
native cheat-toggle menu that bypasses the string matcher. These are viable
alternatives (see §3) but are deliberately excluded in favor of the single
general path.

## 2. Idiomatic context (research)

The dominant pattern in established touch DOOM ports is an on-screen keyboard
that types cheat codes **letter-by-letter**, feeding the engine's normal
sliding-buffer cheat matcher — not a shortcut that bypasses it:

- **id's 2009 iOS DOOM:** four-finger tap → on-screen keyboard → type `IDDQD`.
  (This is the direct heritage for our gesture and working-branch name.)
- **id's 2019 Unity re-release:** kept the four-finger-tap keyboard, added a few
  cheat toggles in settings.
- **Delta Touch (Android reference):** a toggleable soft-keyboard overlay used
  for cheats, console, and save-names, plus optional assignable macro buttons.
- **2024 KEX "DOOM + DOOM II":** shifted to a native cheat toggle menu, keeping
  typed codes as a legacy path.

Woof has **no console** (unlike GZDoom), so that use case does not exist here.
Our two real consumers are cheats and save-game naming.

## 3. Decisions made (with rationale)

| Decision | Choice | Rationale |
|---|---|---|
| Scope | General text-injection layer (cheats + save-names + future) | The two engine paths share one "inject a character" primitive; the general layer costs ~nothing more than a cheat-only hack |
| Input surface | iOS **system keyboard** via a hidden `UITextField` | Far less UI to build than a custom keyboard; native feel; can be forced into a clean deterministic state (ASCII, no autocorrect/autocap) |
| Invocation | **Four-finger tap** over the running game | Matches id's classic idiom; four fingers is unambiguous vs. 1–3 finger gameplay touches and avoids iOS accessibility 3-finger gestures |
| Injection mechanism | Post `event_t` directly via `D_PostEvent` | Deterministic (we set `data1`/`data2` exactly); no dependence on SDL scancode→localized-char translation or keyboard layout; no `SDL_StartTextInput` state to juggle |
| Feedback | Rely on the engine's own on-screen text | Woof already prints cheat confirmations and echoes save-name characters; a custom preview bar is unnecessary (YAGNI) |

**Alternatives considered and rejected:**

- **Custom soft-keyboard overlay (UIKit-drawn):** maximum control, but we'd own
  a whole keyboard UI for no functional gain over the system keyboard.
- **Quick-cheat macro buttons:** great one-tap UX for the three named cheats but
  cannot do arbitrary text/save-names — conflicts with the general-path goal.
- **Native cheat-toggle menu (bypass matcher):** cleanest pure-cheat UX (the
  2024 KEX approach) but doesn't serve save-names and diverges from the
  "type the classic code" expectation. Could be a future supplement.

## 4. Engine mechanics (why the primitive is shaped this way)

Verified against the vendored engine tree:

- **Cheats** read `ev_keydown` events where `data2.i` is the **lowercase ASCII
  character** — `Engine/woof/src/m_cheat.c:1364` → `M_FindCheats` (a per-cheat
  sliding buffer matching against lowercase ASCII sequences). Dispatched from
  `st_stuff.c:2143` while `gamestate == GS_LEVEL` and no menu is active.
- **Save-game name entry** reads a **separate** `ev_text` event where `data1.i`
  is the ASCII character — `Engine/woof/src/mn_menu.c` save-string block
  (~lines 3095–3145); the menu uppercases characters itself. Backspace there is
  handled as a `KEY_BACKSPACE` keydown, not `ev_text`.
- `D_PostEvent` (`Engine/woof/src/d_main.c:166`) only enqueues when
  `data1 != 0`, so an injected keydown needs a nonzero `data1` (a valid Doom key
  id) **and** the character in `data2`.
- The existing touch path injects a **virtual SDL gamepad only**
  (`WoofIOS_SetTouch*` in `Engine/woof/src/woof_ios.c`) — there is **no**
  keyboard-injection function today. This feature adds one.
- iOS default: `I_InitKeyboard` calls `SDL_StopTextInput`, and SDL-simulator
  text input is flaky (SDL #9624). Posting `event_t` directly sidesteps both.

**Consequence for the primitive:** a single "inject one character" call must
post **both** an `ev_keydown` (for cheats) and an `ev_text` (for save-names) per
character, so the same keystroke routes correctly wherever the responder chain
happens to be.

## 5. Architecture

```
4-finger tap on TouchOverlayView
   → show hidden CheatTextField, becomeFirstResponder
   → iOS system keyboard appears over the running (unpaused) game
   → each keystroke → UITextFieldDelegate / deleteBackward override
        → TouchGamepad.injectChar(_:) / injectBackspace()
            → WoofIOS_InjectChar(c) / WoofIOS_InjectBackspace()
                → D_PostEvent(ev_keydown{data1,data2}) + D_PostEvent(ev_text{data1})
                    → Woof responder chain
                         · game live  → M_CheatResponder (reads ev_keydown.data2)
                         · save menu  → M_Responder save-name (reads ev_text.data1)
```

No pausing and **no DOOM menu is opened** by the gesture — cheats require the
game live. The text field is a **character funnel**, never a document: it stays
empty so it accumulates no state and offers the OS no prediction context.

### 5.1 C bridge (`Engine/woof/src/woof_ios.c` / `woof_ios.h`)

Two new functions, alongside the existing `WoofIOS_SetTouch*` (same
main-thread-only contract; UIKit callbacks run on the main thread where SDL
pumps the run loop, so the `events[]` ring buffer is never touched
concurrently):

- `void WoofIOS_InjectChar(char c)` — posts two events via `D_PostEvent`:
  - `ev_keydown` with `data1 = doom key id for c` (letters map to their
    lowercase ASCII, itself a valid nonzero Doom key id) and `data2 = tolower(c)`.
  - `ev_text` with `data1 = c` (raw; the menu uppercases as needed).
- `void WoofIOS_InjectBackspace(void)` — posts `ev_keydown` with
  `data1 = KEY_BACKSPACE`.

### 5.2 Swift / UIKit (`App/Sources/Touch/`)

- **`TouchOverlayView.swift`** — add a
  `UITapGestureRecognizer(numberOfTouchesRequired: 4)` that toggles keyboard
  visibility. A discrete 4-finger tap coexists with the existing 1–2 finger
  stick/turn/button tracking without interference.
- **New `TouchKeyboard.swift`** — owns the text field + delegate so
  `TouchOverlayView` doesn't grow another responsibility. Contains:
  - `CheatTextField: UITextField` subclass, configured for a clean stream:
    `autocorrectionType = .no`, `autocapitalizationType = .none`,
    `spellCheckingType = .no`, `smart{Quotes,Dashes,InsertDelete}Type = .no`,
    `inlinePredictionType = .no` (iOS 17+), `keyboardType = .asciiCapable`,
    `keyboardAppearance = .dark`. **Overrides `deleteBackward()`** to call
    `injectBackspace()` — the robust way to catch the delete key while the
    field stays empty (an empty field never reports deletions via the delegate).
  - `UITextFieldDelegate`:
    `textField(_:shouldChangeCharactersIn:replacementString:)` injects each
    character then **returns `false`** (field never accumulates);
    `textFieldShouldReturn(_:)` dismisses via `resignFirstResponder`.
- **`TouchGamepad.swift`** — add `injectChar(_:)` / `injectBackspace()` wrappers
  next to the existing `WoofIOS_*` wrappers, behind a `TextInjecting` protocol
  so the bridge is swappable for a test spy (see §7).

### 5.3 Interaction guard

While the keyboard is visible, suppress the overlay's stick/turn/button input
(the keyboard covers the bottom-left stick; the exposed upper turn area must not
register stray turns) and **zero the virtual gamepad axes** so the player
doesn't keep moving. Restore on dismiss.

## 6. Dismissal, discovery, and edge cases

**Dismissal (three ways):**
- Tap Return (`textFieldShouldReturn`).
- Four-finger tap again (toggle off).
- Hardware keyboard/controller connects — `OverlayPresenter.applyPolicy()`
  already hides the overlay in this case; also dismiss the soft field (the user
  now types directly).

**Discovery:** a pure gesture isn't self-evident. Surface the four-finger-tap
hint once — a one-time tip and/or a line in the Control Feel (gear) screen. No
custom input-preview bar.

**Edge cases:**
- Game keeps running while typing (cheats are live sliding-buffer matches) —
  intended; the interaction guard prevents accidental movement.
- Parameterized cheats (`idclev31`) work naturally — digits flow through the
  same per-character injection into the cheat parameter buffer.
- Uppercase input: cheats lowercase via `data2 = tolower(c)`; save-names receive
  the raw `c` and the menu uppercases it.

## 7. Testing strategy

- **Unit (Swift, TDD seam):** drive the character-pump through a fake
  `TextInjecting` spy. Assert `"iddqd"` → five ordered `injectChar` calls;
  delete → `injectBackspace`; Return → dismiss; and that the field returns
  `false` so it never accumulates.
- **UITest (XCUITest):** four-finger tap summons the system keyboard (assert it
  appears); typing + Return dismisses it.
- **Device manual verification:** actual `iddqd` → god-mode HUD confirmation,
  and a save-name round-trip — per the project's device-verified-playable bar
  (simulator text input is flaky; our direct-post path reduces exposure but
  device is authoritative).

## 8. Files touched

| File | Change |
|---|---|
| `Engine/woof/src/woof_ios.c` / `.h` | Add `WoofIOS_InjectChar` / `WoofIOS_InjectBackspace` |
| `App/Sources/Touch/TouchOverlayView.swift` | 4-finger tap recognizer; show/hide keyboard; interaction guard |
| `App/Sources/Touch/TouchKeyboard.swift` (new) | `CheatTextField` + delegate + `deleteBackward` override |
| `App/Sources/Touch/TouchGamepad.swift` | `injectChar` / `injectBackspace` wrappers behind `TextInjecting` |
| `App/Sources/UI/ControlFeelView.swift` | One-line discovery hint (optional) |
| `App/Tests/…` | Character-pump unit tests against a spy |
| `App/UITests/…` | Summon/dismiss keyboard UITest |
