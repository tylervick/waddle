# The engine reads stick axes only from the first gamepad it opened, and under automation that is a phantom

Found 2026-09-20 with the in-game debug strip, after three Revyl device runs
in which the overlay's menu button worked in every session but neither USE
nor the virtual stick did anything in the Doom menu.

Woof's `I_OpenGamepad` keeps whichever gamepad it opened first and ignores
every later `SDL_EVENT_GAMEPAD_ADDED` (`CheckActiveGamepad`). Two consequences
that look like one bug from the outside:

- **Button events reach the engine from any gamepad SDL has open**
  (`I_HandleGamepadEvent` never checks `which`), so the overlay's START opens
  the menu and its USE would normally confirm.
- **Axes are polled from the opened gamepad alone** (`I_GetAxisState`), so a
  stick on any other pad is dead, and so is FIRE, which is a trigger axis.

Under XCUITest in the simulator, GameController reports a phantom
`GCController` for the whole session -- `OverlayPresenter` already knew this
and forces the overlay visible under `WADDLE_FORCE_TOUCH_OVERLAY` because of
it. SDL's MFi backend turns that phantom into a gamepad named `Gamepad`, the
engine opens it at `I_InitGamepad` before the overlay's virtual pad exists,
and the strip read `pad=Gamepad foreign pads=2[Gamepad;Waddle Touch Controls]`.
Revyl's farm devices present the same thing, which is why the proof harness
had to force the overlay in the first place.

The fix is a selection, not a preference: whenever the overlay is the intended
input (visible, or forced by the harness), `OverlayPresenter.applyPolicy`
calls `WoofIOS_SelectTouchGamepad()`, and `I_SelectGamepad` closes the active
gamepad and opens the virtual one. A hidden overlay means a real controller or
keyboard is in use, and the engine's own choice stands. The presenter's forced
path used to `return` before the policy path ran, so the first version of the
call never executed under the harness -- the strip is what caught that too.

`WaddleUITests/DebugHUDInputTelemetryTests` reads the strip and requires
`pad=... virtual`, a cursor at item 0 after START, a menu-move count (`mv=`)
that grows on a held stick drag, and a button-event count that grows on USE.
It asserts the move count rather than where the cursor ends up: a hold long
enough to auto-repeat walks a five-entry menu round in a loop, and ten moves
land on New Game again -- which looked exactly like a dead stick for five
runs until the strip grew `lypk=` (peak axis since the pad was opened),
`ab=` (axis-derived presses posted) and `mv=`.
