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

## A `true` written in the same pass as the change of layout is not shown

Opening flat with Settings open in the lower half has to put the column back
up. `foldChanged(isSplit: false)` first wrote `isPresented = true` on the
spot, in the pass that also takes the lower half away. The binding then read
`true` (logged, ten reads) and no column appeared: 3 of 5 openings on the
simulator, on the first opening after a launch as well as later ones, with
animations disabled or not. Bending again showed Settings below, so nothing
was lost but the column. Written a frame later, in a pass of its own
(`returnColumn`), it came back in 9 of 9: three fresh launches, each opened
flat twice, and three more in one run.

The captures that showed this were taken with nothing open first, and those
were all right. As the inspector learning says: try a transition with a
panel open as well as without, and more than once.

A check of "did it come up" was tried and dropped: `onAppear` on the
inspector's content fires at launch with nothing presented, so a flag set
there says nothing.

## A game page as wide as a half breaks its buttons' labels

The lower half is 669 pt wide and about 380 pt tall. The game page there is
side by side at the default text size, and its two buttons shared the
caption's row: `ViewThatFits` passed the row and the even split then set
"New" over "Game". At the largest accessibility size the page stacks, the
art was a 96 pt strip, and the row broke "Contin-" / "ue". Both are the
failure `a-squeezed-row-of-texts-hyphenates-and-a-fixed-share-truncates.md`
describes, at a width the page had not been seen at. In the lower half the
buttons are always stacked and a stacked page has no art.

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

## The sweep dragged the wrong half

`DuoLayoutSweepTests.bringIntoView` scrolled the shelf by dragging the middle
of the window. Half open that is the panel's half, so the shelf never moved
and three shots were lost at the largest text size with nothing failing but
"could not be reached". It drags inside the shelf's half now (`shelfArea`).
A helper that says "the window" for "the thing that scrolls" stops being
right when a screen gets a second scroll view.

## Comparing flat poses with `main`: what is noise and what is not

Captures of `main` and of the branch, same simulator, same pose, status-bar
time held (`simctl status_bar override`), a fresh store or a fixed
`lastPlayed`: closed, open and open turned tall come out identical to the
pixel, with two things to know first.

- Two captures of the *same* build can differ by about 1,170 pixels, all in
  the home indicator's bar, and by a handful in a glass button. Take two of
  each and compare the best pair, or a real zero looks like a difference.
- On an open Duo held wide, with a panel beside the shelf, `main` does not
  lay the shelf out the same way every launch: in 4 launches opened by a tap
  on the gear, 3 gave one picture and 1 another, and in both the shelf's
  content is cut at its left edge. The branch gave `main`'s usual picture 3
  times in 4. That state cannot be compared by pixels until it is stable,
  and it is `main`'s to fix.

The captures are in `assets/half-open-launcher-2026-11-21/`.
