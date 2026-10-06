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

**Provenance:** touch-enabled-menus branch, 2026-10-05.
