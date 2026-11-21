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
later "prewarm". That is 1.5 to 2.5 minutes during which the runner is too busy to
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
that finds the snapshots already rendered takes 10 to 28 s and delays nothing.

The clock is `sysctl kern.boottime`: a probe run printed both, and
PosterBoard's "uptime 466s" was the runner's 465 s. A runner VM had been up 2
to 11 minutes when the job reached its test step, and `xcodebuild test` booted
the device itself a minute or two later, so which branch a run took was a coin
toss.

While this happens the runner's one-minute load average is 385 to 722 (eleven
runs, read as the renders finished). That number, more than any log line, is
why a launch asked for in those minutes is late.

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
the device, and waits for the line with which PosterBoard ends the renders:
`Successfully prewarmed gallery snapshots`, or `Failed to prewarm gallery
snapshots ... exceeded prewarm time` when they outlast its own 120 s limit (2
of 13 runs; the later prewarm finished the rest in 17 s). The renders then
happen before the first test instead of on a launch, and the later prewarm has
little or nothing to render. It prints `WADDLE_SIMULATOR_SETTLED` followed by
the PosterBoard line it matched, or `WADDLE_SIMULATOR_NOT_SETTLED
reason=deferred|timeout`, and lets the tests run as before. Its suite is
`Scripts/test-prepare-ui-test-simulator.sh`.

**The first version of that wait did not wait for the renders, and its
marker was not evidence (found in review of pull request 419).** `log stream`
prints its predicate back as its first line of output, `Filtering the log data
using "... CONTAINS "Successfully prewarmed gallery snapshots" ..."`, and the
wait searched the stream's output for that very string. It reported the
renders finished at the first look after the stream attached: before
PosterBoard's own line in 5 of 13 runs, by 17 to 54 s, and 10 s after boot on
a fresh local simulator that had no gallery yet. The suite's stub stream
printed no header, so fifteen cases passed. Two things to keep from it:

- **Search a tool's output for your own search string and you will find it.**
  Count only lines that have the shape of what you are waiting for (here: a
  timestamp and `PosterBoard[`), and make the marker quote what it matched,
  so a marker with nothing behind it cannot be printed.
- **A stub that is quieter than the tool tests a tool that does not exist.**
  The stub now prints the header; case 0 of the suite fails against the old
  script. And a tell had been in the logs all along: no CI run ever printed
  the script's own "PosterBoard is rendering the gallery" line, which a
  working match would have printed a minute before the end, every time.

It is a wait on two conditions and it costs real minutes on every run: the
rest of the boot window (up to 8 minutes), the boot (about 1.5), then the
gallery and its renders (2 to 4.5). The step took 4.5 to 13.5 minutes in the
eleven runs measured, and the log collection afterwards about one more.

Things that do not make it cheaper, so nobody tries them twice:

- **Booting earlier.** The gallery then arrives inside the window and is
  deferred.
- **Waiting for the prewarm instead.** On a simulator left idle it started 2.5,
  3.5 and 10 minutes after the boot finished (three probe runs), no sooner on
  average than the boot window ends and with no bound.
- **PosterBoard's "keynote mode"**, which its strings say skips gallery updates
  and the prewarm (`Keynote mode is enabled; we aren't going to prewarm
  anything`). Writing `KEYNOTE_MODE` or `pbf_keynoteModeEnabled` to
  `com.apple.PosterBoard` before the first boot is undone at first launch (`We
  are deleting the keynote mode here and moving on`), and writing them after
  it changed nothing: the prewarm ran its 368 renders. Whatever sets that mode
  is not those two defaults.
- **`simctl bootstatus -b` alone.** It returns when the boot finishes, four
  minutes before the renders do; `xcodebuild` already waited that long.

Two things the script does that look like fuss and are not:

- It reads the log with a `log stream`, plus a `log show` from the boot in the
  background, run again each time it finishes. The stream attached 2 to 6
  minutes after the boot on CI, sometimes after the line it was started for,
  and a `log show` in the loop took four minutes for one query at load 510
  (run 44771876139).
- When the stream exits it asks `simctl` for the device's state and boots it
  again if it is not `Booted`. On some runners the device is shut down seconds
  after `bootstatus` reports it booted: `CoreSimulator.log` has `Lost
  connection to com.apple.CoreSimulator.SimLaunchHost-arm64 (interrupted)` at
  that moment, between two `Sending load request for liblaunch` lines whose
  runtime mount paths differ, so the runner was still remounting its simulator
  runtimes. Run 44786994189 lost its whole wait and its log to this before the
  check existed; run 44824505379 hit it twice in a row, was booted a third
  time, and settled. `CoreSimulator.log` is kept in the `simulator-log`
  artifact so the next one can be read the same way.

## What the measurement runs showed, and what they could not

**Read this section with the defect above in mind.** These runs were made with
the first version of the wait. Their "settled" markers show nothing. What
follows was re-read from each run's archived simulator log, which does not
depend on the marker:

- The boot-window wait, which is a separate condition and did work, is what
  kept the renders from being deferred: every run with a log has `Calling
  prewarmSnapshotsForRequests with 184 requests` minutes after boot and no
  deferral line.
- In all thirteen runs with a log, PosterBoard's end-of-renders line came 2.4
  to 9.9 minutes before the first test asked for the app. That margin came
  from booting early and from `xcodebuild` building for five minutes or more
  after the step, not from the script detecting anything. In 5 of the 13 the
  step had already ended and the build had started while the renders had 17
  to 54 s still to run.

So the numbers below describe "the simulator booted past the boot window, 7 to
13 minutes before the first launch", which is what those runs did, and not "the
script waited for the renders", which no run before the fix did.

Twelve runs with the step in place, 2026-11-20: two of one test class and ten
of the whole suite. All twelve passed and none has either failure message. One
whole-suite run predates the shut-down check and measured nothing (its device
was shut down under the wait), which leaves nine with numbers.

- **The renders stay out of the session.** In all nine the later prewarm ran
  during the tests and took 10 to 28 s with nothing to render; the worst launch
  lag in any of them was 5.5 s, against 75 to 86 s in the three failures. That
  is the mechanism of #396 removed, shown in each run and not by counting
  green ones.
- **The first launch is quicker, and not always.** `xcodebuild` issued the
  first launch after 1.1 to 3.6 s in nine of ten runs and 18.2 s in the tenth,
  although that run had settled seven minutes earlier. Before, the same step
  took a median of 6.8 s and over 10 s in 16 of 36 passing runs. That fits the
  renders being a large part of #386's stall, and does not prove it: the wait
  also sits out the rest of the first boot and starts the tests on an older
  host, and no run separated those from the renders. The 18.2 s run says
  something else contributes whichever it is.
- **The counts prove little alone.** #386 was 9 failures in 70 attempts: ten
  clean whole-suite runs happen by luck about one time in four at that rate.
  #396 was 3 in 70: ten clean runs happen by luck two times in three.

## Reading the next one from a run

Every run now uploads the simulator's log as the `simulator-log` artifact and
prints three things in its `Collect the simulator log` step
(`Scripts/ui-test-launch-report.sh`, suite
`Scripts/test-ui-test-launch-report.sh`): PosterBoard's gallery and prewarm lines,
every app launch's lag with any over 10 s named, and the first launch's
`xcodebuild` timings. A failed launch with a `SLOW` line inside a prewarm is
#396 again; a first-test timeout with `launch issued after` in the minutes is
#386 again. Either one in a run whose `WADDLE_SIMULATOR_SETTLED` line quotes a
PosterBoard line (any run after the fix above) means this file is wrong about
the cause, and is worth an issue; a `SETTLED` line with no `PosterBoard:` quote
is from the first version and says nothing.

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
