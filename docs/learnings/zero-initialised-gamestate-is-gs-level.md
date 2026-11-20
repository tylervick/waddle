# A zero-initialised `gamestate` reads as "in a level"

`g_game.c` declares `gamestate_t gamestate;` with no initialiser, and
`doomdef.h` numbers the enum `GS_NONE = -1, GS_LEVEL, ...`. So a fresh process
starts in `GS_LEVEL`, and stays there until the title page
(`D_DoAdvanceDemo`) or the first level load (`G_DoLoadLevel`) says otherwise.
Upstream never notices: nothing it runs in that window asks.

This port does ask. The debug HUD samples `WoofIOS_DebugGameState()` on a
timer from the moment the overlay is up, and on a slow first launch a sample
landed inside the window:

```
LegacySaveLoadTests.swift:69: XCTAssertNotEqual failed: ("Optional("level")") is equal to ("Optional("level")")
 - an unknown stamp must not be parsed into a level: ... gs=level load=254 lt=0 · pad=none none
```

The unknown stamp had been refused; the test read a level that never existed
(issue #379, seen once in six local runs and in none of sixteen CI runs). A
later session in the same launch has the other half of the problem: it starts
with whatever state the previous session ended in. The weapon grid's gate and
the soft keyboard's context read the same variable and had the same gap,
documented in `woof_ios.h` rather than closed.

`WoofIOS_Run` now sets `gamestate = GS_NONE` with the other per-session
resets, and the HUD reports that as `gs=none`. `D_Display` already has a
`GS_NONE` case, and every other reader compares against a specific state.

**The check:** `WaddleUITests/SessionStartStateTests` compares the
session-entry string (`WoofIOS_DebugSessionEntryState`) with what a fresh
process hands its first session, and that string now ends `gs=none`. Without
the reset the first session of every case reads `gs=level`.

**The general shape:** an enum with a "nothing yet" member that is not zero
makes zero-initialised storage claim a real state. When a test asserts "this
never becomes X", check what the variable holds before anything has set it.
