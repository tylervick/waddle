# Touch-driven engine menus

**Date:** 2026-10-05
**Branch:** `tylervick/touch-enabled-menus`
**Status:** design, approved direction; implementation to follow

## Goal

A player can operate Woof's in-game menus (main, Options and its
sub-screens, Load/Save, episode and skill pickers) by touching the item they
want, instead of steering the skull cursor with the overlay's stick and USE
button. The pad buttons keep working as a fallback.

## What the probe established (2026-10-05, simulator)

Woof 16's menu system already takes an absolute pointer: `ev_mouse_state`
moves the highlight (`CursorPosition`), `ev_mouseb_down` on the highlighted
item activates it (`MouseResponder`, left button is bound to menu-enter by
default), thermometer sliders drag, Load/Save page tabs are clickable, and the
setup screens have their own pointer handler (`MN_SetupMouseResponder`). On
iOS nothing feeds that pointer, because the touch overlay is a full-window
subview of SDL's window and consumes every touch before SDL's own
touch-to-mouse synthesis can see it.

A throwaway probe posted the pointer position and a left-button press/release
through the shim, in that order, from the overlay's touch callbacks:

| Check | Result |
| --- | --- |
| One tap on "Load Game" | Load menu opened (one pointer write, one press/release) |
| One tap on "Options" | Options menu opened |
| Tap anywhere on the Quit prompt | Dropped by the shim; prompt stayed up |
| Row height, iPhone 17 Pro portrait | 24 pt, full width; landscape about 33 pt |

Two traps were confirmed by reading the engine and are designed around below:

1. **Order matters.** A press is checked against the item highlighted
   *before* it. Position must be queued ahead of the press in the same tic,
   which we control because we post both events ourselves.
2. **A click answers a Y/N prompt "yes".** While `messageToPrint` is set,
   `MouseResponder` bails and the press falls through to `MENU_ENTER`, which
   `M_Responder` turns into `'y'` (`mn_menu.c:3186`). The same applies to the
   Load/Save delete confirmation (`delete_verify`, `mn_menu.c:2886`).

Delta Touch on Android takes the same route (GZDoom's mouse-capable menus,
touches delivered as clicks). A native front end in the style of id's 2009
Doom Classic was rejected: Woof's setup screens are hundreds of table-driven
items with sliders and key bindings, and the prompts and save-name editor live
in static state, so a reimplementation would diverge from upstream and make
every re-vendor harder.

## Non-goals

- Replacing or restyling Woof's menu drawing. The skull cursor and the
  `MF_HILITE` brightening are the only hover feedback, as on desktop.
- Nearest-row snapping. Rows are contiguous (`LINEHEIGHT` pitch, `LINEHEIGHT`
  tall), so there is no dead space between them to snap across. Revisit only
  if device testing shows misses.
- Multi-finger menu gestures. One finger drives the pointer; others are
  ignored while a menu is up. Pad buttons are subviews and keep their own
  touches.
- Touch for the automap, the intermission or the finale. Unchanged.

## Design

### Engine side (`Engine/woof/src`, all under `WOOF_IOS`)

**`i_video.c`** gains one helper next to `I_DebugWindowSize`:

```c
boolean I_MenuPointFromWindow(float x, float y, float *out_x, float *out_y);
```

It maps a point in the SDL window's coordinate space (UIKit points) to the
menu's unscaled video space, with exactly the math `UpdateMouseMenu` applies
to `SDL_GetMouseState`: pixel density, then the logical presentation rect,
then `video.unscaledw` by `SCREENHEIGHT`. Returns false before the window
exists. A second helper, `I_WindowPointFromMenu`, is the inverse and serves
telemetry only.

**`mn_menu.c`** gains, in its existing `WOOF_IOS` telemetry block:

```c
boolean MN_MenuMessageShowing(void);      // messageToPrint || delete_verify
const char *MN_DebugCurrentMenuName(void); // "off" "msg" "setup" "main" "load" "save" "epi" "skill" "other"
boolean MN_DebugMenuItemCenter(int index, float *x, float *y);
```

The last two are test telemetry; the first is a product seam.

**`woof_ios.c` / `woof_ios.h`** gain the overlay-facing calls, modelled on
`WoofIOS_InjectKey`:

```c
void WoofIOS_InjectMenuPointer(float x_points, float y_points);
bool WoofIOS_InjectMenuTap(bool down);
void WoofIOS_InjectMenuAnswer(bool yes);
bool WoofIOS_IsMenuMessageShowing(void);
bool WoofIOS_IsAttractMode(void);
const char *WoofIOS_DebugMenuState(void);
```

- `InjectMenuPointer` posts `ev_mouse_state` (`data1 = 0`, `data2/3` = menu
  coordinates). No-op when no menu is up or the window does not exist.
- `InjectMenuTap(true)` posts `ev_mouseb_down` for `MOUSE_BUTTON_LEFT` and
  records that a press is held. It is dropped, and returns false, when no menu
  is up or `MN_MenuMessageShowing()` is true. `InjectMenuTap(false)` posts
  `ev_mouseb_up` only if a press is held, and always does so then, even if
  the menu closed in between, so the engine's mouse button state never
  latches. The caller posts position before the press.
- `InjectMenuAnswer(yes)` posts a paired `ev_keydown`/`ev_keyup` for `'y'` or
  `'n'`, dropped unless `MN_MenuMessageShowing()` is true (the same
  synchronous gate `WoofIOS_InjectMenuConfirm` uses, because the overlay's
  visibility poll runs every 0.25 s). `'y'` and `'n'` are what both the
  message responder and the delete confirmation read.
- `IsAttractMode` is `gamestate == GS_DEMOSCREEN || demoplayback`, with no
  menu up. It gates the title-tap behaviour below.
- `DebugMenuState` returns `"cm=<menu> msg=<0|1> mp=<pointer writes>
  mt=<tap writes> md=<taps dropped> tgt=<x,y|x,y|...>"`, item centres as
  window points, so a UI test taps real screen positions. It is its own HUD
  segment, so `DebugHUDInputTelemetryTests`' parser of the `pad=` segment is
  untouched.

**`Engine/WOOF_UPSTREAM.md`** records each of these as a patch-set entry, in
the same style as the `WoofIOS_InjectKey` entry.

### App side

**`App/Sources/Touch/MenuTouchRouter.swift`** (new, pure) decides what a
touch means while a menu is up, so the rule is unit-testable without UIKit:

```swift
struct MenuTouchRouter {
    static let tapSlop: CGFloat            // 10 pt
    enum Began { case pointer, pending, ignore, passThrough }
    func began(menuActive: Bool, trackRoute: TouchTrackRoute,
               nearButton: Bool, pointerOwned: Bool) -> Began
    func pendingBecameStick(from: CGPoint, to: CGPoint) -> Bool
    enum Ended { case tap, none }
    func ended(pendingFrom: CGPoint, at: CGPoint) -> Ended
}
```

Outside the stick column (`TouchTrackRouter`'s left 40%) a menu touch is
`.pointer` unless a finger already owns the pointer or the touch is a
near-miss on a button. Inside the stick column it is `.pending`: the stick
navigates menus through the virtual pad today (`DebugHUDInputTelemetryTests`
and the Revyl menu-input-telemetry test drag it with the main menu open), so
a pending touch that travels past `tapSlop` becomes the stick exactly as
before, and one that lifts in place is a tap (position, press, release
posted together on lift). With no menu up the router answers
`.passThrough` and the stick/turn routing applies. The soft-keyboard guard
already runs before any of this in `touchesBegan`.

**`App/Sources/Touch/TouchGamepad.swift`** wraps the shim calls the way it
wraps the others: `menuPointer(at:)`, `menuTap(down:)`,
`answerPrompt(yes:)`, `isMenuMessageShowing`, `isAttractMode`.

**`App/Sources/Touch/TouchOverlayView.swift`**:

- A `menuTouch: UITouch?` alongside `stickTouch` and `turnTouch`.
- `touchesBegan`: after the keyboard guard, read `WoofIOS_IsMenuActive()`
  once for the batch. `.pointer`: store the touch, post the pointer, then
  the press. `.pending`: remember the touch and where it landed.
  `.ignore`: nothing. Only `.passThrough` reaches the stick/turn routing,
  so a menu tap outside the stick column can no longer steer the player.
- `touchesMoved`: the pointer finger re-posts its position (hover follows the
  finger; sliders drag). A pending finger that travels past the slop starts
  the stick at the point it landed, as `touchesBegan` would have.
- `touchesEnded`/`Cancelled`: the pointer finger posts the release and is
  forgotten. A pending finger that lifts in place posts position, press and
  release together.
- The 0.25 s policy timer (`startMenuPolicyTimer`) additionally drops
  `menuTouch` if the menu closed under the finger (posting the release), and
  shows or hides the prompt buttons below.
- Attract mode: a free-area touch that begins while `WoofIOS_IsAttractMode()`
  is true is routed to the stick or turn exactly as during play (a press
  still engages the stick, which `TouchControlsTests` measures on the title
  screen), and if it lifts within `MenuTouchRouter.tapSlop` it also posts a
  paired `KEY_ESCAPE` through `WoofIOS_InjectKey`, which `MN_Responder`'s
  `!menuactive` branch turns into "open the main menu".

**Prompt buttons.** Two `OverlayButton`s, titled "Yes" and "No", with
accessibility identifiers `promptYesButton` and `promptNoButton`, hidden
unless `WoofIOS_IsMenuMessageShowing()` is true. They call
`answerPrompt(yes:)` on press. They are deliberately *not* `TouchOverlayControl` cases: that enum is
`CaseIterable` and drives the layout editor, which must not offer to move a
transient button. Instead `TouchOverlayLayout.promptButtonFrames()` returns
the pair, side by side in the *top* band, centred between MAP and ≡, No on
the left and Yes on the right, USE's diameter. The top band rather than the
bottom one because USE's default centre is 160 pt in from the right edge,
which in portrait is where a centred bottom pair would land. The layout
test suite pins that both frames lie inside the usable area, sit below the
HUD reserve, and overlap no control's default frame across the phone, iPad
and tiny-window bounds. While the buttons are visible, MAP stays
hidden as it is today for any menu.

The existing fallback remains: USE answers yes (`gamepad_confirm` is
`MENU_ENTER`, which the message responder maps to `'y'`) and ≡ answers no
(`MENU_ESCAPE`).

### Data flow, one tap on "Load Game"

1. `touchesBegan` with the main menu up: router says `.pointer`.
2. Overlay calls `menuPointer(at:)`, the shim maps the window point to menu
   space and posts `ev_mouse_state`.
3. Overlay calls `menuTap(down: true)`; shim posts `ev_mouseb_down`.
4. Next `D_ProcessEvents`: `ev_mouse_state` runs `CursorPosition`, which sets
   `highlight_item` to Load Game; then `ev_mouseb_down` runs
   `MouseResponder`, the point is inside the highlighted item's rect, `itemOn`
   is set, and the fall-through `MENU_ENTER` activates it.
5. `touchesEnded`: `menuTap(down: false)` posts `ev_mouseb_up`, which the
   Load menu's responder ignores.

### Error handling

- A press while a prompt is showing is dropped and counted (`md=`), never
  turned into an answer.
- A release is posted whenever a press was, so a menu that closes mid-press
  cannot leave the engine with a held mouse button.
- `InjectMenuPointer` before the SDL window exists is a no-op.
- A letter or Enter injected by the prompt buttons is gated synchronously in
  the shim, so the 0.25 s visibility poll cannot deliver a stale answer into
  an ordinary menu.

## Testing

- **Unit (`WaddleTests`)**: `MenuTouchRouterTests` for the began/pending/
  ended rules; `TouchOverlayLayoutTests` additions for the prompt buttons'
  frames.
- **UI (`WaddleUITests`)**: `TouchMenuTests`, modelled on the probe:
  1. open the main menu with ≡, read `tgt=`, tap "Load Game" once, assert
     `cm=load`; tap "Options" inside the stick column and assert it opened
     on the lift; drag the stick with the menu up and assert `mv=` grew and
     nothing was tapped; tap the empty space above "New Game" and assert
     nothing changed;
  2. tap "Quit", assert `msg=1`, tap the middle of the screen, assert `msg=1`
     and `md=` incremented;
  3. tap `promptNoButton`, assert `msg=0` and `cm=off` (answering a prompt
     closes the whole menu, `mn_menu.c:3207`); reopen with ≡, tap "Quit"
     again, tap `promptYesButton`, assert the session ends
     (`engineExitLabel`);
  4. on the title screen with no menu up, tap the middle of the game view,
     assert `cm=main`.
  It runs on the iPhone leg of `mise run test` like the other UI tests; CI
  runs it under the UI smoke workflow on app PRs.
- **Manual, device**: `docs/manual-testing.md` gets a touch-menus item (open
  Options → General, drag the mouse sensitivity slider, tap a save slot and
  type a name, delete a save and answer the confirmation with the buttons).

## Documentation

- `docs/learnings/menu-click-answers-prompt-yes.md` + `INDEX.md` line: a
  Woof menu click while a Y/N prompt is up is "yes", so any pointer injection
  has to gate on `messageToPrint`/`delete_verify`.
- `Engine/WOOF_UPSTREAM.md`: the new patch-set entries.
- `README.md` controls section, one line: menus can be tapped.

## Delivery

Two stacked pull requests, both on this branch's lineage:

1. **Engine + overlay**: shim, overlay routing, prompt buttons, router unit
   tests, layout tests, UI test, learning, upstream notes. Engine framework
   rebuilt and `Scripts/check-engine-fresh.sh` green.
2. **Attract-mode tap** (small, droppable): `IsAttractMode`, the tap-vs-drag
   rule, its UI test step, README line.

The probe's uncommitted code in the worktree is the starting point for the
first PR; its telemetry moves into `WoofIOS_DebugMenuState`, its test file is
replaced by `TouchMenuTests`, and every `PROBE` marker goes.
