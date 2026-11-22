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

Found by reading on 2026-10-05, then pinned by the probe that led to
touch-driven menus: a tap on the Quit prompt with the gate off is a quit.

**What to do:** never post a pointer press while `MN_MenuMessageShowing()`
is true. `WoofIOS_InjectMenuTap` drops it (and counts it, `md=` in the
debug HUD); the overlay answers prompts through `WoofIOS_InjectMenuAnswer`,
which types `'y'`/`'n'`, the letters both responders read.
`TouchMenuTests` is the check.

## A third confirmation, missed for seven weeks

A setup screen's reset button asks "reset to defaults?" with its own flag,
`default_verify` in `mn_setup.c`, answered in `MN_SetupResponder` by `'Y'`,
`'N'` or `MENU_ENTER`. It was not in `MN_MenuMessageShowing()`, so the gate
above did not cover it: after the reset button, a touch anywhere reset every
setting on the screen, and no Yes/No buttons came up (issue 447, reproduced
by touch on 2026-11-21: a flipped setting went back to its default on a tap
of empty space). The mechanism is one step longer than the other two.
`MN_SetupMouseResponder` returns false while an item is selected, and the
reset button selects itself, so the press is not eaten there and falls
through as `MENU_ENTER`.

`default_verify` is in the gate now, and `SetupScreenOverlapTests.
testResetToDefaultsIsAnsweredOnlyByTheYesAndNoButtons` is the check.

**When looking for the next one:** grep for what answers on `MENU_ENTER`
while something else is "selected", not for `messageToPrint`. Every Y/N
question that goes through `M_StartMessage` (quit, end game, nightmare, a
save from another version) is `messageToPrint` and was always covered;
`delete_verify` and `default_verify` are separate flags with separate
responders. The other things a selected setup item does with a stray press
were read on 2026-11-22 and left alone: a number being typed is committed as
typed, and a choice being changed is committed as shown.

## The fourth: a key binding waits for *anything*, and the overlay is two devices

A touched row of a Key Bindings screen waits for the input to bind, and
`BindInput` gives it whatever arrives next and takes it from the action of
the same group that had it. Tried by touch on 2026-11-22 (issue 462), with
the Run row waiting:

| The next touch | What the engine saw | Result |
|---|---|---|
| empty space | the left mouse button | MOUSE1 moved from Fire to Run |
| the on-screen USE | a pad button | USE moved from Use to Run: the on-screen USE stopped using |
| the on-screen FIRE | the pad's trigger | FIRE stopped firing |
| a weapon button | a pad shoulder | bound to Run |
| ≡ | `MENU_ESCAPE` | cancelled; `ChangeEntry` takes it before `BindInput` runs |

The overlay reaches the engine as a mouse (touches) *and* as a gamepad (its
buttons and stick), so a gate on pointer presses alone covers one row of that
table. `MN_BindingPending` / `WoofIOS_IsBindingPending` is the seam, and the
overlay sends nothing while it is true but ≡: the buttons stand down in
`hitTest`, a touch is never the stick, a held stick stops moving, and
`WoofIOS_InjectMenuTap` drops the press. It is not in
`MN_MenuMessageShowing`, which would put Yes and No on screen for something
that is not a question. `SetupScreenOverlapTests.
testNothingFromTheOverlayIsBoundWhileAKeyBindingRowWaits` is the check; it
reads the rows' drawn widths, since a binding has no value to read.

Real hardware is not in that path. With a keyboard or controller attached
the overlay is hidden and SDL feeds the engine directly, so a key, a pad
button or a mouse button binds as upstream intends.

**Provenance:** touch-enabled-menus branch, 2026-10-05; issues 447 and 462,
2026-11-22.
