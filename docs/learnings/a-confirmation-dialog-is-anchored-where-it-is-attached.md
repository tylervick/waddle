# A confirmation dialog on an iPhone is a popover anchored to the view it is attached to

From iOS 26, SwiftUI's `.confirmationDialog` on an iPhone is no longer an
action sheet rising from the bottom edge. It is a popover with an arrow, and
the arrow points at the frame of whatever view carries the modifier. Attach it
to a screen's root and it points at that screen's middle.

The shelf did exactly that (issue #532). One dialog, driven by an
`actionItem` state, hung off the `NavigationStack` content beside the sheets
and alerts. Every tile's Continue / New Game / Details came up at the top centre
of the window, with the arrow at y ≈ 308 on a 393 × 852 pt iPhone 15 Pro,
whichever tile was tapped and however far the shelf was scrolled. It had been
like that since the shelf was introduced (44cc85b1, 2026-08-14). The owner
reported it from TestFlight build 323.

What it looks like in the accessibility tree (iOS 27.0 simulator):

```
PopoverDismissRegion   {{0, 0}, {393, 852}}
Popover                {{76, 59}, {240, 249.3}}   <- includes the arrow
  Sheet 'Shelf 3'      {{76, 59}, {240, 236.3}}   <- the dialog itself
```

The side on which `Popover` reaches past `Sheet` is the arrow's side, and
that edge is the arrow's tip. Along that edge the arrow is not in the tree.
UIKit centres a popover on its anchor unless that would cross the window's
margin, so the arrow is at the popover's middle, or between the middle and
the edge it was pushed in from. That is enough to tell the two tiles of a
row apart, which the tip's edge alone is not. `ShelfActionAnchorTests.swift`
measures it this way against the tapped tile's frame.

Rules:

- Do not host the dialog on the thing itself when that thing is a lazy
  grid's cell. The first fix did that, and a review of pull request 536
  found two ways it lost the dialog that the shelf-root version kept.
  Turning an iPhone rebuilt the cells for the new column count, and the
  presentation went with its cell: portrait to landscape and back lost
  "Shelf 16", and landscape to portrait lost "Shelf 4" in the second row
  (a first-row tile survived, so test below the first row). On a Duo,
  opening flat brought the Continue hero back and took its game's tile out
  of the grid, and the dialog with it.
- What holds: keep the presentation state and the dialog above the grid, on
  a clear view in an overlay of the scroll view, and move only that view.
  Whatever draws the game (its tile, or the hero) puts a reporter in its
  background while the game's actions are up. The reporter's
  `onGeometryChange` writes the frame, in a named coordinate space on the
  scroll view, into state, and the overlay's clear view takes that frame.
  The dialog is presented only once that frame is the item's, so it never
  opens pointing at the last game. When the cell leaves the screen the
  anchor keeps its last frame, and the shelf scrolls the game back into
  view on a change of size or pose (`ScrollViewReader.scrollTo`, the least
  distance).
- The shelf's Delete confirmation, reached from a tile's long-press menu,
  has the same fault and is still on the shelf root (#535). It can take the
  same anchor: report for `deleteCandidate` as well as `actionItem`, and
  move `deleteGamePrompt` onto the overlay's clear view.
- A dialog that is about the whole screen (a page's save warning, Reset Usage
  Counts) still gets a popover. Its arrow points at the screen, so look at it
  before assuming it is fine.
- A geometry test cannot see this. Only the live `Popover` frame against
  the source's frame can, or a look at the screen.
