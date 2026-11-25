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
that edge is the arrow's tip. `ShelfActionAnchorTests.swift` measures it this
way against the tapped tile's frame.

Rules:

- Put a dialog that is *about* one thing on that thing: per tile, with a
  binding that answers only for its own item
  (`actionItem?.id == game.id`), and that clears the state only when it is
  still its own.
- The shelf's Delete confirmation, reached from a tile's long-press menu,
  has the same fault and is still on the shelf root (#535).
- A dialog that is about the whole screen (a page's save warning, Reset Usage
  Counts) still gets a popover. Its arrow points at the screen, so look at it
  before assuming it is fine.
- A geometry test cannot see this. Only the live `Popover` frame against
  the source's frame can, or a look at the screen.
