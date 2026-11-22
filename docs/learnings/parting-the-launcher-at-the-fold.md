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

The column now stays inside the safe area, and the reader is measured
inside the same safe area, so the halves it reports add up to the column's
height. Each half's bar reaches under the status bar or the
home indicator by itself, as the one stack does on a flat device.

The reader is installed through UIKit under the root view, pinned to its
safe-area guide (`LauncherFold.follow`), which gives the same rect.

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
was lost but the column. Written after that pass, it came back every time.
The first fix waited 80 ms (9 of 9); the review asked what the 80 ms was
waiting for, and the answer is the end of the pass: `foldChanged` runs in
the fold reader's own main-queue block, so `returnColumn` queues one block
behind it and writes there (6 of 6: three fresh launches, each opened flat
twice). A delay that works says nothing about what it depends on.

The captures that showed this were taken with nothing open first, and those
were all right. As the inspector learning says: try a transition with a
panel open as well as without, and more than once.

A check of "did it come up" was tried and dropped: `onAppear` on the
inspector's content fires at launch with nothing presented, so a flag set
there says nothing.

## Two trees draw the panel, and state inside either is lost at every fold

The inspector's column and the lower half are separate view trees. The
review of pull request 461 found what that costs: with Settings > Files
pushed in the lower half, opening flat brought the column back at Settings.
Everything a screen kept in `@State` went the same way: the navigation path,
Control Feel, the rename alert, the save warning.

The path and every presentation are now on `ShelfPanelModel`
(`PanelPresentation.swift`), and each tree reads the same object. Four
things about doing that were not obvious:

- **A dialog outlives the tree that presented it, dead.** With the trees'
  state still separate, a save warning that was up when the device opened
  flat stayed on screen; "Change Anyway" could be pressed and did nothing,
  because its action belonged to a view that was gone. The UI test for this
  asserts the *answer applies*, not that the dialog is visible: visibility
  passed on the broken code.
- **The tree going down writes.** Its alert's dismissal writes `false` to
  the binding, which with shared state clears what the next tree was about
  to show. So only the tree on screen may write (`PanelHost`).
- **"On screen" has to be asked at the moment of the write.** The first
  `PanelHost` carried two flags worked out when its tree was last drawn, and
  a binding keeps the value it was made with: the departing column still
  said it was current. The rename alert survived opening flat and was lost
  on bending, on the simulator's hinge only; a compact window, which is
  what a UI test has, did not show it. The host now holds the model and
  asks it. `ShelfPanelTests` pins that with a binding made before the fold
  and written after it.
- **A presentation is put up again, and not at once.** A presentation begun
  while another is still leaving the same presenter is refused, and SwiftUI
  then believes it is up. Nothing tells a new tree that the old one's
  dismissal has finished, so presentations are held down for 0.7 s after a
  fold (`presentationsHeld`). That one *is* a duration, and the comment on
  it says what it stands in for.

A resting page is not an open panel, so opening flat removes it. If it has
a question up, `foldChanged` makes it the open panel first.

## The import banner and the band

Half open at `accessibility-extra-extra-extra-large`, the longest notice the
app makes (three loose files adopted, one failed) is five lines on the Duo
and sits in the lower half with its top 15 pt below the band. It is placed
from the window's bottom edge, so a longer notice would reach the band;
nothing makes one today.

## A game page as wide as a half breaks its buttons' labels

The lower half is 669 pt wide and about 380 pt tall. The game page there is
side by side at the default text size, and its two buttons shared the
caption's row: `ViewThatFits` passed the row and the even split then set
"New" over "Game". At the largest accessibility size the page stacks, the
art was a 96 pt strip, and the row broke "Contin-" / "ue". Both are the
failure `a-squeezed-row-of-texts-hyphenates-and-a-fixed-share-truncates.md`
describes, at a width the page had not been seen at.

This branch first answered with a rule of its own, "always stacked in the
lower half". Issue 468 then fixed the row for every window
(`GamePageMeasurements.buttonArrangement`, a row only where each button
holds the wider label), and the rule of this branch was dropped for it: on
the hinge, at the default size, the largest standard size and two
accessibility sizes, the one rule gives whole buttons in the half. Two
rules for one row would have had to be kept in step by hand.

What is still particular to the lower half: a page that stacks there has no
art.

## An accessibility element behind a view answers the hit test for it

The UI test needs to know where each half meets the band. The first marker
was a clear element the size of the half, in its background. With it there,
`app.buttons["importButton"].isHittable` was false: the marker answered the
accessibility hit test for everything drawn in front of it. The same thing
broke `app.tap(withNumberOfTaps:numberOfTouches:)` in
`accessibility-element-blocks-app-multi-touch-tap.md`. The markers are 2 pt
elements in the halves' corners, the pattern the touch overlay uses.

## A red picture test on CI that was not settled

The first push failed `ImportNoticeBannerTests` on CI's iPhone Duo leg, and
again on a re-run, with the signature
`a-scroll-view-measured-to-lay-out-its-own-content-can-spin.md` describes:
`image provider … timed out` and `building pipeline primitive_color… took
17.4 seconds`, where a neighbouring pull request's Duo leg took 0.69. Four
throwaway draft pull requests, one run each:

| Launcher's root | Duo leg |
|---|---|
| reader as a `UIViewRepresentable` in the background (the first push) | failed, twice |
| the same with the reader removed | passed |
| the reader view kept, the hinge and the region never asked for | passed |
| the reader installed through UIKit, hinge and region asked for | failed once, then passed twice (0.84 s) |

A build that logged what the reader saw on CI's Duo showed nothing to
explain it: closed, one hinge reading, three layout passes, the same as a
fresh simulator here, where the app sits idle. So the fold APIs are
correlated with the slow pipeline build on that runner, in five runs, and no
mechanism was found.

The review then found the reader is not needed for the failure at all: the
Duo leg failed the same way on `fix-issue-440` at c6b14bb (job
137105151084), a branch with no `LauncherFold`. I confirmed the job, the
leg and the commit; its log had gone by then, so the matching signature is
the reviewer's reading. The reviewer's counts: about 1 Duo run in 29
without the reader, 1 in 5 with it installed through UIKit. That is too
thin to clear the reader or to convict it. The reader is installed through UIKit now, which is
the form that last failed least. If that test goes red on the Duo leg again
on a branch that touches the launcher, this is the place to start, and the
counts above are too small to rule the reader out.

What the failure itself was is now known: drawings made while the test
process's first Metal pipeline built, which the suite now redraws
(`imagerenderer-hands-back-an-unfinished-drawing.md`, issue #439). What made
that build slow on this branch is not.

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
  on the gear, 3 gave one picture, with the shelf's content cut at its left
  edge, and 1 gave another, with the shelf fitted to its column. The branch
  gave `main`'s cut picture 3 times in 4. That state cannot be compared by
  pixels until it is stable, and it is `main`'s to fix (issue 469). An
  earlier version of this file said the content was cut in both pictures;
  the second had been compared by pixel count and not looked at. Issue 469
  then found the second too wide as well, by 24 pt, and fixed all of them:
  `a-scroll-view-held-to-its-container-keeps-its-old-width.md`.

The captures are in `assets/half-open-launcher-2026-11-21/`.
