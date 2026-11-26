# XCUITest's `tap()` returns after the app has idled, so "straight after a tap" is too late

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

What works: schedule the event from another thread before calling `tap()`,
at a time measured from its start. `testControlFeelBentWhileItsSheetArrivesKeepsItsTitle`
posts the fold 0.45 s after `tap()` starts, about when the touch ends.
`TEST_RUNNER_BEND_DELAY` adds to that, because the runner's environment
takes `TEST_RUNNER_`-prefixed variables from `xcodebuild`. That test fails at
the parent of pull request 539 and passes at its merge, and posted after
`tap()` returns it passed at both.

Two more things found on the way:

- **The window depends on the device.** On a compact iPhone the missing
  title never showed at any delay, on the commit that had it. The iPad's
  column did show it, 3 runs in 3 at 0.0 and 0.15 s, and at 0.3 s not.
  So reproduce a fold defect on the layout the report came from.
- **The Device Hub hook cannot time a fold that closely.** One
  `Scripts/duo-pose-device-hub.sh` call took 20 to 45 s, and its last press
  came 2 to 3 s after its last read of the tree. A sub-second gap between a
  touch and a fold needs the `WADDLE_TEST_HALF_OPEN` seam, not the hinge.
