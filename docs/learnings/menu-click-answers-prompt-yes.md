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
typed, a choice being changed is committed as shown, and a key binding takes
the press as the mouse button to bind, which is upstream's design for a
mouse and was not tried by touch.

**Provenance:** touch-enabled-menus branch, 2026-10-05; issue 447,
2026-11-22.
