# A fresh simulator renders every lock-screen wallpaper once, and host uptime decides when

Two UI-test failures on CI had nothing to do with the app or the tests
(issues #386 and #396):

- the **first** test of a run fails with `Timed out while launching application
  via Xcode`, and every later test launches normally;
- a test **in the middle** of a run fails inside `app.launch()` with
  `Application 'com.tylervick.waddle' does not have a process ID`, although the
  app launched and ran.

## What the simulator does

On a device that has never booted, `PosterBoard` (the lock-screen wallpaper
process) builds its wallpaper gallery about two minutes after boot and then
renders a snapshot of every item in it: 184 requests at once, or 368 from its
later "prewarm". That is 100 to 210 s during which the runner is too busy to
launch an app on time.

When the renders happen is decided by **the host's uptime** at the moment the
gallery arrives. The simulator shares the host's kernel, so "uptime" is the
runner VM's, not the simulator's. PosterBoard logs the decision:

```
Gallery controller requested snapshot prewarm for role: PRPosterRoleLockScreen (reason: PBFPowerLogReasonExtensionsUpdated)
Calling prewarmSnapshotsForRequests with 184 requests
Successfully prewarmed gallery snapshots for role: PRPosterRoleLockScreen
```

or, with the host up for less than ten minutes:

```
Gallery controller requested snapshot prewarm for role PRPosterRoleLockScreen, but prewarm has not run and uptime 392s is within 600s boot window; deferring to -prewarm:
```

Deferred, the renders run inside the next prewarm (`Starting prewarm...` to
`Prewarm is complete; executed in 137.5 seconds`), which started 5 to 20
minutes after boot in the runs examined, in the middle of the tests. A prewarm
that finds the snapshots already rendered takes 11 to 15 s and delays nothing.

A runner VM had been up 2 to 5 minutes when a job started, and `xcodebuild test`
booted the device itself a minute or two later, so which branch a run took was
a coin toss.

## How that maps onto the two failures

**#396, the mid-run failure: the deferred prewarm.** All three failures found
have the deferral line (uptime 392, 416 and 454 s) and one launch whose
`running foreground` update reached the test runner 75 to 86 s late, inside the
prewarm; every other launch in those runs took under 2.1 s. In three runs that
took the other branch, the prewarm ran for 11 to 15 s and no launch after the
first lagged.

**#386, the first-test failure: the first launch is asked for while the device
is still doing first-boot work.** Timed from `xcodebuild`'s session log in four
failures, the time goes mostly in `xcodebuild` itself, before the simulator is
asked for anything: 53, 72, 94 and 112 s between `Test runner session received
application launch request` and `Stored token 1 for launch`, a step that takes
14 ms on every later launch and 1.4 to 45 s (median 6.8 s) on the first launch
of 36 runs that passed. The simulator had finished booting (the test runner was installed and
running on it) and the app was not yet installed: `xcodebuild` installs it only
after that step, in 2 to 9 s. Three of the four failures were rendering the
gallery at that moment. The fourth had deferred it and was 30 s past the
gallery's arrival, so the renders are not the whole of it; what `xcodebuild`
waits on in that step was not established. It is one process on a machine
whose every core is taken by a first boot, and that is as far as the evidence
goes.

## What the workflow does about it

`Scripts/prepare-ui-test-simulator.sh`, a step of `ui-tests.yml` before the
tests. It waits until the host has been up for the 600 s boot window, boots
the device, and waits for the `Successfully prewarmed gallery snapshots` line.
The renders then happen before the first test instead of on a launch, and the
later prewarm has nothing to render. It prints `WADDLE_SIMULATOR_SETTLED`, or
`WADDLE_SIMULATOR_NOT_SETTLED reason=deferred|timeout` and lets the tests run
as before. Its suite is `Scripts/test-prepare-ui-test-simulator.sh`.

It is a wait on two conditions and it costs real minutes on every run: the
rest of the boot window, then the gallery and its renders. There is no cheaper
honest version. Booting earlier puts the gallery inside the window, and nothing
found makes PosterBoard render on request.

## Reading the next one from a run

Every run now uploads the simulator's log as the `simulator-log` artifact and
prints three things in its `Collect the simulator log` step
(`Scripts/ui-test-launch-report.sh`): PosterBoard's gallery and prewarm lines,
every app launch's lag with any over 10 s named, and the first launch's
`xcodebuild` timings. A failed launch with a `SLOW` line inside a prewarm is
#396 again; a first-test timeout with `launch issued after` in the minutes is
#386 again. Either one in a run that printed `WADDLE_SIMULATOR_SETTLED` means
this file is wrong about the cause, and is worth an issue.

Before 2026-11-20 only a failed run carried the log, inside the result bundle:

```
xcrun xcresulttool export diagnostics --path UITestResults.xcresult --output-path diag
/usr/bin/log show --archive "$(find diag -name system.logarchive)" --style compact \
  --predicate 'process == "PosterBoard" AND eventMessage CONTAINS "snapshot prewarm"'
```

A re-run of a failed job keeps the first attempt's artifact;
`gh api repos/<owner>/<repo>/actions/runs/<id>/artifacts` lists both and
`gh run download` fetches only the newest. In zsh, call `/usr/bin/log` by path.

**Provenance:** issues #386 and #396, 2026-11-20, from the result bundles of
runs 44425524958, 44438159194, 44513333625 and 44058279062 (first test) and
44655330761, 44422772566 and 44491496532 (mid-run).
