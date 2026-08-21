# Killing an `xcodebuild` test session wedges CoreSimulator, and the next run blames your diff

Interrupting a UI-test session — `TaskStop`, `pkill xcodebuild`, Ctrl-C, an
editor window closing — can leave CoreSimulator unable to launch the app at
all. Every subsequent test that calls `app.launch()` then fails like this:

```
Simulator device failed to launch com.tylervick.waddle.
The request was denied by service delegate (SBMainWorkspace) for reason:
Busy ("Application failed preflight checks")
```

**Why it misleads.** These are reported as ordinary test failures, one per test,
with the failing line pointing at `app.launch()` inside *your* test file. A run
that had been green comes back with `EngineSmokeTests`, `DemoLoopReplayTests`,
`LibraryTabTests` and `PlayTabTests` all red at once, and the natural reading is
"my change broke the app". Nothing in the message says the simulator is the
problem. Observed 2026-08-20 on the agent-loop trial for issue #183: four tests
went red across two consecutive full runs, and the diff under test was pure
layout geometry that could not affect app launch.

**How to tell it apart from a real failure.** The tell is the string
`Application failed preflight checks` / `Busy`, and that the failure arrives
*before* any assertion in the test body — the test never got a running app.
A real regression fails an assertion; this fails to launch. Also suspicious:
several unrelated test classes failing at identical ~10.5 s durations, which is
the launch timeout rather than anything the tests measured.

**`xcrun simctl shutdown all` is not enough.** It returns success and boots
nothing, and the very next run fails the same way — the wedge lives in the
long-running `CoreSimulatorService`, not in the device. Restart the service:

```bash
pkill -f xcodebuild; pkill -f XCTRunner
killall -9 Simulator
xcrun simctl shutdown all
killall -9 com.apple.CoreSimulator.CoreSimulatorService
```

`launchd` restarts the service on next use, so nothing needs starting by hand.
Re-run the suite after this and the phantom failures are gone.

**Not an executable check.** The condition is only observable by *attempting* a
launch, which the suite already does — a guard could not learn anything the
tests do not already surface a few seconds later, and would cost a simulator
boot on every run to find out. The value here is in reading the failure
correctly, not in predicting it. This is the opposite case to
`Scripts/check-simulator-available.sh`, which is worth its cost because
enumeration is cheap and its failure mode (`WADDLE_SIMULATOR_UNAVAILABLE`) is
otherwise indistinguishable from a bad pin.

**Provenance:** agent-loop trial `2026-08-21T000113Z` (issue #183), which lost
two full verification runs to it before recognising the string.
