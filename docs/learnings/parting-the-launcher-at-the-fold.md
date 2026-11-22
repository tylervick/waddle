# Parting the launcher at the fold: what went wrong first

Issue #429 (2026-11-21): on a half-open iPhone Duo the launcher is in two
halves, the shelf above the fold and the panel below it. `ContentView` owns
the arrangement, `LauncherFoldReader` reads the pose, `ShelfPanelModel`
knows it as `isSplit`. Each of these was got wrong once on the way.

## A column that ignores the safe area takes the insets from the bars inside it

The halves are measured from the window's top, so the first version put them
in a `VStack` with `.ignoresSafeArea()`. The shelf's `NavigationStack` then
had no top inset: its bar sat at y 0 and the wordmark was cut by the status
bar. A `NavigationStack` inside a view that ignores the safe area does not
get the insets back by being at the window's edge.

The column now stays inside the safe area, and the reader is the column's
background, so its bounds are the column's and the halves it reports add up
to the column's height. Each half's bar reaches under the status bar or the
home indicator by itself, as the one stack does on a flat device.

## A sheet is the window's, whichever half presents it

Control Feel and the game page's Add… picker were sheets. Presented from the
lower half they still covered the window, across the fold. Inside the lower
half (`launcherIsInTwoHalves` in the environment) each is pushed into the
half's own navigation stack instead, from the same `isPresented` state, with
the sheet's binding held false. The layout editor is a full-screen cover on
purpose (it needs the session's bounds) and is left as it is.

A page pushed on the shelf, or the Settings sheet, can also be up *before*
the device is bent: a closed Duo has a compact window. `ShelfView` moves
either to the lower half when `isSplit` turns true.

## The inspector's binding needs a third state

`swiftui-inspector-writes-its-own-binding.md` has two properties, what is
open and whether the inspector is up. In two halves the inspector must be
down while something is open, and it writes `false` to its binding as it
goes, so "open" there cannot be read from `isPresented`. `openInLowerHalf`
holds it; `foldChanged(isSplit:)` carries an open panel across in both
directions, and a `true` from the system while parted is refused, or
accepted and taken back when the window has just become regular, by the
same rule as an empty column. `ShelfPanelTests` pins each case.

## An accessibility element behind a view answers the hit test for it

The UI test needs to know where each half meets the band. The first marker
was a clear element the size of the half, in its background. With it there,
`app.buttons["importButton"].isHittable` was false: the marker answered the
accessibility hit test for everything drawn in front of it. The same thing
broke `app.tap(withNumberOfTaps:numberOfTouches:)` in
`accessibility-element-blocks-app-multi-touch-tap.md`. The markers are 2 pt
elements in the halves' corners, the pattern the touch overlay uses.

## Checking it

`HalfOpenLauncherTests` (an extension of `PlayTabTests`, so a pull request
runs it) uses the session's `WADDLE_TEST_HALF_OPEN` seam; the fold is flipped
by the same Darwin notification. What the screen looks like on a real hinge
is the sweep's job: `Scripts/duo-layout-sweep.sh run half-open`, shots 02,
04, 10 and 12 to 15 against the band at 1366 to 1486 px.
