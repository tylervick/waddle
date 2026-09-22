# A sheet leaves the presenter's navigation bar in the accessibility tree

When SwiftUI presents a sheet, the screen underneath stays in the hierarchy
XCUITest walks. So `app.navigationBars.buttons["X"]` searches **both** bars,
and matches anything labelled `X` on the presenter as well as on the sheet.

The collision that bit: Settings is a `.sheet` from the shelf. The shelf's gear
is `Label("Settings", systemImage: "gearshape")`, so its accessibility label is
"Settings". Files is *pushed* inside the sheet, and iOS labels a back button
with its parent's title — also "Settings". Two matches, and XCUITest raises:

```
Failed to tap "Settings" Button: Find single matching element.
Multiple matching elements found for <XCUIElementQuery>
```

Scope to the bar you mean:

```swift
let back = app.navigationBars["Files"].buttons["Settings"]   // not app.navigationBars.buttons
```

## Why this one got expensive

`HiddenGamesScreenTests.swift` hit it first and fixed it correctly **in that
file**, leaving an accurate comment explaining the mechanism. `closeSettings`
in `XCTestCase+UIHelpers.swift` had the same query and was missed. The
knowledge existed, in prose, three files away from the code that needed it.

It then broke `main` for three days without anyone noticing, for two
compounding reasons:

1. **UI Tests does not run on pull requests** — only on push to `main`. The PR
   that introduced the collision (#232, "Files and Hidden Games under
   Settings") merged green.
2. **The failure landed in a skip detector.** `DemoLoopReplayTests` needs
   DOOM2.WAD, which is copyrighted and absent from CI, so it is designed to
   skip there. Its detector polls Settings → Files and calls `closeSettings`,
   so the ambiguity turned "skip cleanly" into "fail". A test that was never
   supposed to run in CI became CI's only red.

## Why there is no check script for this

`CLAUDE.md` asks that a learning which can be an executable check should become
one. This one resists it. The dangerous pattern is not "unscoped
`app.navigationBars`" — `returnToShelf` uses exactly that against the game
page and is correct, because a *push* replaces the presenter's bar rather than
keeping it. A grep banning the shape would fail on working code, and a guard
that cries wolf is a guard people learn to bypass.

What would actually pay is closing gap 1: running UI Tests on pull requests, or
on a merge queue. That is a workflow change and belongs to the owner.

## Rule

Inside a sheet, address bar buttons through the bar: `app.navigationBars["<that
bar's title>"].buttons[...]`. Reserve the unscoped form for pushes, where the
presenter's bar is gone.
