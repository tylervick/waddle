# A fit measured at the default text size is not a fit

Issue #353 was closed on 2026-11-10 by letting a shelf tile's one-line title
shrink to 0.85 of its size, a number worked out from the title's width at the
default Dynamic Type size. Ten days later the same two tiles read
"Freedoom Ph…" again (issue #426): one step of Dynamic Type up, the type had
grown and the tile had not.

The tile's width comes from the grid's floor, which has two values: 150 pt at
every standard size and 320 pt at every accessibility size. The title's font
has twelve. So the scale a one-line "Freedoom Phase 1" needs falls through each
band and jumps back up between them. On a closed iPhone Duo (344 pt of
content):

| size | tile | title | scale needed |
|---|---|---|---|
| large (default) | 162 | 148 | 0.96 |
| extra-large | 162 | 165 | 0.86 |
| extra-extra-large | 162 | 183 | 0.78 |
| extra-extra-extra-large | 162 | 200 | 0.71 |
| accessibility-medium … extra-large | 344 | 243 … 347 | fits … 0.93 |
| accessibility-extra-extra-large | 344 | 408 | 0.79 |
| accessibility-extra-extra-extra-large | 344 | 460 | 0.70 |

(The title column is the default width scaled by the headline's point size at
each step, so read it to a few points; the two sizes the issue names are
measured in `ShelfTileLargeTextTests`.)

`WideGridLayoutTests` measured the real title in the real font, which is the
right method, and measured it at `.large` only. A rule about text has to be
checked at every `DynamicTypeSize`, and at the last size of each band of
whatever the container's size depends on, because that is where it is
tightest.

What replaced it: above the default size the title keeps its one line where
the allowed shrink still holds the whole name, and otherwise takes a second
line at its own size (`PlayableTileLayout.titleLineLimit`,
`oneLineTitleMinimumWidth`). `ShelfTileLargeTextTests` walks every size.

The same sweep found the other half (issue #431): a one-column tile at 4:3 in
a short, wide window (a closed Duo on its side, 678x466) is taller than the
viewport, and its title is on its bottom edge. A tile's height is now capped
at the viewport less the shelf's insets
(`PlayableTileLayout.tileHeight(width:viewportHeight:contentPadding:)`), from
the scroll view's own size and arithmetic, never from a tile's frame
(`a-scroll-view-measured-to-lay-out-its-own-content-can-spin.md`). The
viewport there is 350 pt: 82 pt of bar above the scroll view and 34 pt below.

## Three ways the hand captures for this lied

Taken by script on a Mac shared with other workers, without a UI test:
install, `simctl ui content_size`, pose through
`Scripts/duo-pose-device-hub.sh`, `simctl launch`, `simctl io screenshot`.

- **The first launch after the hinge moves can draw the old window.** Opened
  from closed-landscape and launched at once, the shelf drew three columns in
  the left 562 pt of a 951 pt window once, and a white screen once, on a
  build that draws four columns there on every later launch. It looked like
  a regression between two builds and was neither build. Launch twice after
  a change of pose, or compare against a second launch of the other build,
  before believing a difference.
- **`pgrep -f Waddle.app/Waddle` finds someone else's app.** Every worker's
  simulator runs a process with that path. The first pass of the #437 hang
  reproduction read 99% CPU from another session's engine and would have
  been reported as a hang. `simctl launch` prints the pid; use that one.
- **A shot's file name is not evidence of which build drew it.** A retake of
  the "before" shots with the install step skipped photographed whatever
  build was on the simulator, which was the "after" one. Install in the same
  command that photographs, or diff the pair: a before and an after that are
  pixel-identical where a change was expected is this.

Captures: `docs/learnings/assets/shelf-tiles-large-text-2026-11-21/`.
