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

## UIKit brings the column back at the next launch, and can leave its inset behind

Issue #496, measured 2026-11-26 to 11-28 on an open iPhone Duo simulator held
wide (iOS 27.1, Xcode 27.1), with real gear taps through
`Scripts/duo-pose-device-hub.sh touch`.

**Where it comes from.** UIKit saves a split view's columns in two places:
the app's user defaults (`com.apple.UIKit.UISplitViewController.Root`,
where `secondaryEdgeSplitViewControllerColumn` reads 4, the inspector, while
a panel is up), and the scene's saved state
(`Library/Saved Application State/<bundle>.savedState/<session>/internalUserInfo.data`,
the same dictionary). The scene's copy is written when the scene deactivates
or goes to the background, not when the app is killed. At the next launch
UIKit restores the column from the scene's copy: in a probe that logged both
at `WaddleApp.init`, every launch found 4 in the defaults, and only the
launches whose scene copy also read 4 got the column back (SwiftUI's `true`
write and a first layout pass at 587 of 951 pt). With the scene copy at 2,
the defaults' 4 did nothing. `userInfo.data` beside it holds only SwiftUI's
scene id.

**What a stray is.** In every launch that gets the column back, SwiftUI
writes `true`, `systemSetPresented` refuses it, and by 0.8 s UIKit reports
the inspector hidden (`isShowing(.inspector)` false, its view out of the
window). Usually the content column's trailing safe-area inset goes back to
the window's own (84 pt on the Duo). In a stray it stays at the column's
width, 364 pt, for good (still 364 at 6 s), and the shelf and its bar are
laid out inside it: the wordmark centred over the left 587 pt beside an
empty band. Nothing of ours sets that inset (`additionalSafeAreaInsets` was
0 throughout).

**What did not work.**
- Editing the defaults copy before the scene connects (the first versions of
  pull request 554: removing the key, or rewriting 4 to 2). It fixed only the
  `WADDLE_OPEN_PANEL` seam, which never deactivates the scene and so never
  writes the scene's copy. With real taps it was no better than `main`, and
  with the app backgrounded first, worse: the scene copy still says 4.
- Forcing a layout of the split view (`setNeedsLayout`, `layoutIfNeeded`):
  the inset stayed 364.
- `ignoresSafeArea(.container, edges: .trailing)` outside the shelf's
  `NavigationStack`: the stack is a UIKit navigation controller, which takes
  its safe area from UIKit, not from SwiftUI's modifiers.
- Showing and hiding the inspector in one pass: the hide was dropped and the
  column stayed up, a stray every time.

**What does.** Changing the content column's `additionalSafeAreaInsets`
makes UIKit work its safe area out again, and the leftover 364 goes.
`ColumnInsetRepair` sits inside the shelf and, when no column is wanted
(`ShelfPanelModel.columnIsWanted`), none is showing, and the content column
is still inset more than the window, moves the additional inset by a point
and back on the next turn. Public API only, and nothing UIKit saved is
touched, so a width the player dragged the inspector to on an iPad is kept
(410.5 pt before and after a relaunch).

Counted with the builds installed side by side and interleaved, real taps,
a launch counted only after one with Settings confirmed open:

| Path | `main` | defaults rewritten 4 → 2 | this repair |
|---|---|---|---|
| background, then kill (two blocks) | 6 of 78 | 5 of 39 | 0 of 78 (11 repairs) |
| kill only | 0 of 39 | 0 of 39 | 0 of 39 |
| first relaunch after erasing the device | 0 of 3 | 0 of 3 | 0 of 3 |

On the kill-only run the scene's copy read 2 before every launch, so no
column was restored and nothing could stray: whether a kill strays depends
on whether something deactivated the scene while the panel was up (taps
through Device Hub sometimes do). Every repair logged 364 against 84 before
it, and 84 after.

**How to measure it.** Only real taps through the hook, the builds side by
side under their own bundle ids and interleaved, and the background path
(open Settings, switch to another app, then kill) as well as the kill path:
the seam and sequential blocks both hid the result here. A launch counts only
if the launch before it had Settings confirmed open on screen.

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
