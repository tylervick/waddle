# The post-session debug stack sits on the tile row; one more line and every two-session UI test fails on "previous exit label never cleared"

`ContentView`'s `sessionStartDebugStack` (shown after a session under
`WADDLE_DEBUG_SESSION_START`) is an opaque black box drawn over the shelf,
just above the exit label, and on a phone in portrait its bottom edge already
sits inside the first row of game tiles. Adding one more `Text` line to it
moved the box over the tiles' tap points, so `play()` in
`SessionStartStateTests` tapped the Freedoom tile, the tap landed on the box,
no session started, and the assertion that fired was

```
XCTAssertTrue failed - t2-phase2-after-title-quit: previous exit label never cleared
```

which reads as "the engine refused to start a second session", a Task 10
symptom, in three unrelated tests at once. It was none of that. The first
session of each test still passed because the stack is not on screen before
the first session.

Measured 2026-10-01 on PR #307's branch: the three cases failed on both the
shared simulator and a freshly created one; the same three passed on `main`
on the fresh simulator minutes later; the shelf screenshots `play()` attaches
show the box over the tiles in both. Two things were going on at the same
time (another checkout running tests on the same simulator, which does kill
runners with "signal kill"), and the screenshots are what separated them.

Two fixes, both kept:

- New fields join an existing line (`pcheats=` rides on the zone line) rather
  than adding one. The stack's height is a budget.
- The stack is `.allowsHitTesting(false)`, so a tile under it still receives
  a tap. The text is for reading, by XCUITest identifiers and by the Revyl
  agent off a screenshot; nothing on it is tappable.

If a two-session test starts failing this way, look at the
`<name>-shelf-after-session` attachment before suspecting the engine.
