# XCUITest's `tap()` returns after the app has idled, so "straight after a tap" is too late

The same fact cost a duration measurement elsewhere
(`xcuitest-tap-returns-after-the-app-goes-idle.md`). This file covers
timing an event *during* the tap's effect.

Issue #472 asked for a fold "straight after a tap" on Control Feel, to bend
the device while its sheet was still arriving. A
`notify_post` written on the line after `row.tap()` landed 1.08 s after
the tap began: `tap()` finds the element, sends the touch, and then waits
for the app to idle, which here is after the sheet has finished arriving.
The test passed on the very commit that had the defect.

From the activity log (iPhone 18 Pro and iPad Pro 13-inch simulators, iOS
27.0, 2026-11-26): the touch begins 0.13 to 0.25 s after `tap()` starts,
the "Synthesize event" step lasts about 0.3 s, and the idle wait after it
takes another 0.3 to 0.6 s.

A fixed delay from the start of `tap()` is not enough either. The first
version of `testControlFeelBentWhileItsSheetArrivesKeepsItsTitle` posted the
fold from another thread 0.45 s after `tap()` began. The review of pull
request 557 ran it on an iPad Pro 13-inch: 10 passes in 11 on fixed code
and only 4 failures in 5 on the broken parent of pull request 539. The
touch began anywhere from 0.16 to 0.40 s after `tap()` started. Late, the
fold missed the sheet and the broken code passed. Later still, it landed
during the touch, the tap was lost, and the fixed code failed.

What works: let the app time the event from the action itself. With
`WADDLE_TEST_BEND_AFTER_CONTROL_FEEL_MS` set, `PlayerSettingsView` posts
the fold toggle that many milliseconds after Control Feel's row fires (a
DEBUG seam). At 150 ms the test passed 20 of 20 on the iPad at the head
of pull request 557 and failed 10 of 10 at 539's parent (2026-11-26).

Two more things found on the way:

- **The window depends on the device.** On a compact iPhone the missing
  title never showed at any delay, on the commit that had it. The iPad's
  column did show it, 3 runs in 3 at 0.0 and 0.15 s, and at 0.3 s not.
  So reproduce a fold defect on the layout the report came from.
- **The Device Hub hook cannot time a fold that closely.** One
  `Scripts/duo-pose-device-hub.sh` call took 20 to 45 s, and its last press
  came 2 to 3 s after its last read of the tree. A sub-second gap between a
  touch and a fold needs the `WADDLE_TEST_HALF_OPEN` seam, not the hinge.
