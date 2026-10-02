# On the iOS 27 simulator, an alert jumps under `typeText`, and the next tap misses

`WaddleUITests/GamePageTests/testRenameFromThePageUpdatesTheTile` failed on
every run on this machine's iOS 27 simulator (Xcode 27), on `main` as well as
on the branch under test, while CI on iOS 26.2 stayed green (issue #306). The
Rename alert opened, the name was typed, the alert closed, and the tile kept
its old name. A breadcrumb added inside the Save button's action never fired:
the tap closed the alert without running the button.

**What the probes measured** (2026-10-02, temporary UI tests on an iPhone 17
Pro simulator, iOS 27, logging the alert's frame, the keyboard's frame and
the Save button's frame around the typing step). Every 100 ms after the last
key of `typeText`:

| t after typing | alert frame y | keyboard frame y | note |
|---|---|---|---|
| 0–300 ms | 356 | 918 | keyboard entirely below the 874 pt screen; alert centred |
| 400 ms on | 209 | 590 | keyboard back on screen; alert at its avoiding position |

So `typeText` hides the software keyboard while it types — the keyboard
*element* stays in the tree, which is why `app.keyboards.count` read 1
throughout — and the alert drops to the centre; about 400 ms after the last
key the keyboard slides back and the alert springs up. A tap issued straight
after `typeText` is aimed at the centred frame and lands below the alert
once it has moved: nothing is hit. A second probe pinned the rest: after
that tap **the alert is still up, with the typed name in its field**; the
test's next step, tapping the shelf's back button, goes through the alert (a
tap outside a SwiftUI alert dismisses it on this runtime), the page pops,
and the tile keeps its old name. A second Save tap renames correctly. The
breadcrumb was right — Save's action never ran — and the recording's "alert
closed" was the back-button tap, not Save. With half a second between steps
every variant of the helper passed.

**The check is `XCTestCase.waitForAlertToSettle()`** in
`App/UITests/XCTestCase+UIHelpers.swift`, which `clearAndType` calls after
typing: it polls until the keyboard's frame is on screen and the alert's
frame no longer intersects it, up to three seconds. Two earlier conditions
failed and are worth not repeating: "two frame samples a quarter second
apart agree" was fooled by the pause at the centre, and "the alert does not
intersect the keyboard" was fooled by the keyboard being off screen, where it
intersects nothing. The resting state is the keyboard on screen *and* the
alert clear of it.

**Two things to carry forward.** A local UI failure needs a baseline on the
same simulator before it says anything about a diff (this one cost an hour
of bisecting an innocent branch before the baseline was taken;
`ui-test-failures-need-a-main-baseline.md`). And when a tap "does nothing"
in XCUITest, log the target's frame on both sides of the preceding action —
a tap aimed from a stale frame is indistinguishable from a tap that landed
and was ignored until the frames are in the log.

**Provenance:** issue #306, found while verifying PR #305.
