# A narrowed iPad window drops the inspector, and a departing dialog fails `isHittable`

Issue #520, measured 2026-11-23/24 on an iPad Pro 13-inch (M4), iOS 27.0
simulator, Xcode 27.1. Two separate findings came out of one red test.

## The red test: a race in the check, and an orphaned popover

`testAFoldKeepsTheSaveWarningUpAndItsAnswerStillApplies` failed on the iPad
with `Failed to determine hittability of "changeAnywayAction" Button:
Activation point invalid`, 1.6 s after the fold seam opened the launcher
flat. On an idle simulator it passed four runs in a row. Run alongside a
second test session it failed, which matches the issue's run inside the
full suite. Two things were behind it.

**The check.** `changeAnyway.exists && changeAnyway.isHittable`, asked
while the old tree's popover is still on its way out, finds that popover,
and `isHittable` then **records a failure** instead of answering false.
Polling does not help, because the first such answer fails the test. The
root now shows `panelSwapSettling` while `presentationsHeld` is true, and the
tests wait for it to go (`waitForPanelSwap`) before asking about a dialog.

**The app.** The lower half was trusted to dismiss its own popover once its
binding read false, in the same pass that removed it. Sometimes it did not.
The popover stayed as an orphan over the shelf, with its arrow pointing at
nothing, and the column's own warning did not come up while it was there. An
orphan that stays is the warning a test finds, so with the column's
re-presentation switched off, the test still passed. An orphan that goes
leaves no warning at all, which is what the recording of the red run shows.
Holding presentations a main-queue turn before removing the lower half still
left the orphan in 1 run of 2. Now the root dismisses any alert or dialog in
its window through UIKit when the pose changes
(`LauncherFold.dismissDialogs`). It runs after `foldChanged`, so the hold
refuses the dismissal's write and the next tree puts the warning up again.

Prove the test discriminates by switching off the new tree's presentation,
**on an iPad**. An orphan that answers the test's question looks exactly
like the fix working.

The first version of that dismissal took down *any* alert in the window on
every change of pose. That included the shelf's tile actions, its Delete
confirmation and the launcher's alert after a failed session, all of which
sit on a tree the fold leaves in place, so a bend dropped them (review of
pull request 524). It now acts only when the panel's shared state says a
panel dialog is up (`ShelfPanelModel.panelHasDialogUp`). UIKit shows one
alert at a time, so that alert is the panel's.
`testAPoseChangeLeavesTheShelfsTileActionsUp` and
`testAPoseChangeLeavesTheEngineErrorAlertUp` pin this. A fix that reaches
into UIKit's presentation chain needs a test for the dialogs it must leave
alone.

## A page kept across a fold has stale state, and the picker writes

The inspector keeps its column's page alive while the panel is in the lower
half. Moving that page's base picker onto a carried-over warning's choice
fired the picker's `onChange`, which decided again from the kept page's own
save count. If that count was stale, it could apply the change without asking,
with the warning still up (review of pull request 524). A choice that a
waiting warning is already asking about is no longer decided again
(`GamePage.decidesOnBaseSelection`), and the page reloads when its tree comes
back on screen.

The same review found the tests' last check, the picker's label after Change
Anyway, proved nothing: the picker already shows a waiting warning's choice.
`assertStoredBase` relaunches and reads the base from a fresh page. With
`apply` skipped, it fails.

## A narrowed window takes the panel down and does not put it back

With a game's page open beside the shelf, dragging the window's resize
grabber until it is compact (375 pt) lost the whole panel on `main`, with or
without a dialog up. The inspector wrote `false` to its binding and nothing
more. The root saw the new width class 0.27 s later. With the save warning
up, the popover's dismissal wrote `false` 74 ms after the inspector did,
through a binding that was still current, and that cancelled the edit. A
player in Split View, Stage Manager or windowed mode can do this.

An iPhone Duo folded shut writes `false` and then `true` itself
(`swiftui-inspector-writes-its-own-binding.md`). An iPad window does not.
`ShelfPanelModel.panelTakenDown` treats the inspector's `false` with a panel
open as a change of tree. It holds presentations as a fold does, and when a
change of width class comes within a second of it, in either order, it puts
the panel back up (`returnColumn`): as a sheet on a compact window, as the
column on a regular one.

## Resizing a window from a UI test

A new iPad simulator on iOS 27 runs apps in windows. SpringBoard has a
`resize-grabber` element (value `Bottom Right`) and `window-controls:<bundle
id>`. A slow `press(forDuration:thenDragTo:)` from the grabber resizes the
window. Narrowed to 375 pt, the system centres it (x 329), and **the size is
kept for the next launch**, so a test that narrows the window has to give the
whole screen back in a teardown block. Drag the window by its top edge to
x 0, then drag the grabber past the screen's right edge
(`WindowWidthPanelTests.restoreFullWidth`). If a run dies before teardown,
`simctl erase` your own device.

On a phone there is no grabber, and the test skips. CI's UI-test leg is the
iPhone only, so `testNarrowingTheWindowKeepsTheSaveWarningUpAndItsAnswerStillApplies`
runs nowhere in CI (`a-test-in-a-skipped-class-runs-nowhere.md`). Run it by
hand on the iPad when touching `ShelfPanelModel`.
