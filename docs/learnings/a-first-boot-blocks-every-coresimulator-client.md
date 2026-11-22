# A simulator's first boot blocks every other CoreSimulator client

A hosted runner's simulators have never booted. The first boot of one takes
minutes (data migration, then the wallpaper renders described in
[ui-test-launch-flakes-and-the-wallpaper-gallery.md](ui-test-launch-flakes-and-the-wallpaper-gallery.md)),
and while it runs, **other CoreSimulator clients wait**: `simctl list`, and
`xcodebuild`'s lookup of its `-destination`, which happens before it prints
`Command line invocation:` and long before it compiles anything.

So "start the next simulator booting in the background, to overlap its boot
with the work in front of it" does the opposite of what it says.
`simctl boot` returns at once, which is what makes it look free; the
`xcodebuild` on the next line then sits silent until the boot is done.

## What it cost

`ci.yml` once ran three unit-test legs as steps of one job and booted the
iPad in the background just before the iPhone leg. Over 29 green runs
(2026-11-21 and -22), splitting each `xcodebuild … test` step by its log
timestamps, medians in minutes:

| Phase | iPhone step (iPad booting behind it) | iPad step | Duo step | `ui-tests.yml` (simulator settled first) |
| --- | --- | --- | --- | --- |
| step start to `Command line invocation:` | **8.0** (2.3 to 13.9) | 0.3 | 0.3 | 0.4 |
| build output | 6.3 | 0.9 | 1.2 | 1.8 |
| silent until the test host is up | 4.7 | 0.6 | 2.6 | 2.0 |
| tests | 1.4 | 0.5 | 2.5 | n/a |
| whole step | 20.7 | 2.5 | 6.8 | |

The first row is the finding: the same command reaches its first line of
output in under half a minute everywhere except directly behind a first
boot. The second row is the same story at lower volume: the build of
identical targets takes 6.3 minutes beside a booting simulator and 1.8 on a
runner whose simulator has settled. Compiling was never the expensive part
of that job; `SwiftDriver` runs four times in it.

The job's own comments had already met this once and read it as a local
oddity: a `simctl list` placed after the iPad boot "returned exactly three
minutes later" (run 42849345701), and the fix then was to move that one
call above the boot.

Issue #415 reports the same silence from the other side: seven of its eleven
cancelled jobs were cancelled 7.7 to 11.2 minutes into the iPhone step
"with no xcodebuild output yet".

## What to do instead

- **One simulator per runner.** `ci.yml`'s unit-test legs are a matrix now,
  one job per device, and nothing boots a simulator ahead of `xcodebuild`.
  The table above is why that is faster even though each leg compiles for
  itself: in that layout's first three runs (44973823949, 44975173011,
  44975944420) every leg's `xcodebuild` printed its first line within a
  second of starting and built in 0.7 to 2.6 minutes, and a leg took 5.1 to
  9.0 minutes from start to finish.
- If a simulator must be booted ahead of time (as `ui-tests.yml` does, to
  wait out the wallpaper renders), boot it and **wait for it** before
  starting anything that talks to CoreSimulator. Booting it and carrying on
  buys nothing.
- When a step's log shows minutes between `##[group]Run xcodebuild` and
  `Command line invocation:`, look for a simulator booting, not for a slow
  compiler.

To split a job log the same way: the timestamps of `##[group]Run xcodebuild`,
`Command line invocation:`, the longest gap before `Test Suite 'All tests'
started`, and `** TEST SUCCEEDED **`.
