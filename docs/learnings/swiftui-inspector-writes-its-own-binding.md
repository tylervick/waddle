# SwiftUI's inspector writes to its own binding, and where it is attached matters

`ShelfPanelModel` and `ContentView` host the shelf's panel (a game's page or
Settings beside the library, issue #372) in a SwiftUI `.inspector`. Three
things about the inspector were learned on the simulator on 2026-11-10 (Xcode
27.1; iPhone Duo on iOS 27.1, iPad Pro 13-inch and iPhone 17 Pro Max on iOS
27.0), each by getting it wrong first.

## It has to be attached outside the navigation stack

Attached to the shelf inside its `NavigationStack`, on an open iPhone Duo the
shelf's principal toolbar item (the wordmark) is centred across both columns
and straddles the divider, and after a rotation the column disappears while
its Done button stays in the shelf's bar. Attached to the `NavigationStack`
itself, from the root view, it is a clean trailing column when the Duo is
open and a sheet with its own bar when closed. So the state it shows has to
live somewhere both the root and the shelf can reach.

## It writes `true` to `isPresented` with nothing open

On a regular-width window the inspector writes `true` to its binding a moment
after launch, unprompted. Logged on the iPad:

```
PANELPROBE get false          (x12)
PANELPROBE set true content=nil class=Optional(regular)
PANELPROBE get true           (x18)
```

A binding wired straight to a stored `Bool` accepts that, and the app shows
an empty column beside the shelf on every iPad and on a large iPhone in
landscape. This shipped to `main` for an hour (#375) because every capture
taken before the merge had a panel open on purpose; nobody looked at the
shelf with nothing open on a wide window.

The binding's setter must refuse a `true` it has nothing to show for
(`ShelfPanelModel.systemSetPresented`).

## It also writes `false` then `true` across a fold, and that one is real

When an iPhone Duo folds or unfolds with the panel open, the column is torn
down and put back as a sheet (or the reverse), and the binding sees `false`
then `true`. If "presented" is derived from "has content", the `false` clears
the content and the `true` has nothing to present: the panel is lost on the
first fold. Content and presentation are separate properties for that reason,
and only an explicit close forgets the content.

## Refusing the write is not always enough

Unfold a Duo with nothing open and the window goes from compact to regular
width. SwiftUI puts an empty column up, writes `true`, has it refused, and
does not look at the binding again: the column stays. It only takes a column
down for a change it can observe.

So in the moments after the window becomes regular width, a `true` with
nothing to show is *accepted*, which makes the model and SwiftUI agree that
the column is up, and taken back about a frame later with animations
disabled. At launch and on a phone's rotation into landscape, refusing alone
is enough, and accepting there would flash a column at every launch, which
is why the two cases are told apart by whether the window has just changed
width.

## Do not close it on a timer

The first workaround bounced the binding on a timer after the width change
(wait 120 ms, write `true`, wait 60 ms, write `false`). It passed two
unfolds in a row and then failed on the first unfold after a fresh launch:
the system put its column up *after* the bounce had already run. Reacting to
SwiftUI's own write has nothing to race. Both orders are handled, the write
arriving after the width change and just before it.

A workaround for a transition has to be tried on the first transition after
launch, more than once. Three fresh launches each unfolded twice is what
`ShelfPanelModel` was checked against; the captures were compared by
measuring the region where the column appears, not by eye.

## What to check when touching this

Look at the shelf **with nothing open** on a regular-width window, at launch
and after each transition into regular width: an iPad, a large iPhone rotated
to landscape, and a Duo unfolded. Then with a panel open through a fold and
back. `WADDLE_OPEN_PANEL` opens a panel at launch for a capture, since
nothing synthetic can long-press a tile on the open Duo
(`iphone-duo-simulator-traps.md`).

`ShelfPanelTests` pins the model's half of these behaviours. It cannot see
a column on a screen (`geometry-tests-cannot-see-the-screen.md`).
