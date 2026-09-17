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

**When that is not enough either (observed 2026-09-16).** The sequence above
cleared the wedge once, then the very next run re-wedged, and running it a
second and third time did nothing — three consecutive `test` invocations all
died at `Busy ("Application failed preflight checks")` before any assertion.
What did clear it was erasing the device and booting it explicitly *before*
handing it to `xcodebuild`, then addressing that device by UDID rather than by
name:

```bash
pkill -f xcodebuild; pkill -f XCTRunner; killall -9 Simulator
xcrun simctl shutdown all
UDID=$(xcrun simctl list devices available -j | ...)   # the device you test on
xcrun simctl erase "$UDID"
killall -9 com.apple.CoreSimulator.CoreSimulatorService
sleep 6
xcrun simctl boot "$UDID"                              # boot it yourself, then wait
sleep 10
xcodebuild ... -destination "platform=iOS Simulator,id=$UDID" ...
```

`erase` is what the service-restart alone does not do — it discards the
device's installed-app state, which is where the failed install that produces
`Busy` actually lives. Pre-booting matters too: letting `xcodebuild` boot a
cold device as part of the run is when the race is most likely to recur.

**What re-wedges it.** Starting sessions back to back, and killing one that is
mid-flight. A `test` invocation that hits a command timeout is a kill, so a
tight timeout around a long `xcodebuild` run is itself a cause. Give these runs
generous timeouts and let them finish; the wedge costs far more than the wait.

Note this is not a *unit*-test-free problem: `WaddleTests` is hosted by the app
target, so even a pure-arithmetic suite has to launch the app and is blocked by
exactly the same wedge.

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
