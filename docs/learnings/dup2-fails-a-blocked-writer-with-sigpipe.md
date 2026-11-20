# `dup2` over a pipe kills a thread that is asleep writing to it

The full UI run kept losing the app in one or two tests per run, a different
test each time, with no crash report (issue #365). The app was being killed
by SIGPIPE, and the code doing it was `SessionLogCapture`.

## The kernel behaviour

On Darwin, replacing a descriptor with `dup2` closes the old one first, and
closing a pipe's write end fails every thread that is *asleep in `write()` on
that descriptor* with EPIPE. It does this although the pipe's reader is alive
and other descriptors on the same write end stay usable. EPIPE raises
SIGPIPE, and SIGPIPE's default action ends the process. Nothing writes a
crash report for it.

A writer is only asleep in `write()` when the pipe is full. `SessionLogCapture`
tees stdout and stderr through a pipe for the length of an engine session,
and swaps descriptors at both ends of it: `begin()` puts the tee over the
original, `end()` puts the original back over the tee. Under XCUITest the
app's stderr carries XCTest's own in-process logging (47 MB of it in one full
run) down a pty that `xcodebuild` reads. When the runner is busy that pty
backs up, the pump stalls, the tee fills, a logging thread goes to sleep on
it, and the session ends under that thread.

## What the capture does about it

`begin()` marks the tee `F_SETNOSIGPIPE` for good, and marks the original the
same way only across its own `dup2`, putting the setting back afterwards. The
sleeping write still fails with EPIPE and its bytes are lost; that is the
kernel's doing and nothing here can prevent it. The process is no longer told
to die for it.

**The executable check:** `App/Tests/SessionLogCaptureBlockedWriterTests.swift`.
It puts a writer to sleep on a full pipe and swaps the descriptor under it at
each end of a session, with a handler counting SIGPIPEs. Both cases failed
against the old code. Read it for the mechanics.

## "No crash report" does not mean the app did not die

The evidence that settled this was in every failing run's result bundle all
along, in the simulator's system log, not in `DiagnosticReports`:

```
xcrun xcresulttool export diagnostics --path UITestResults.xcresult --output-path diag
/usr/bin/log show --archive "$(find diag -name system.logarchive)" --style compact \
  --predicate 'process == "SpringBoard" AND eventMessage CONTAINS "Process exited" AND eventMessage CONTAINS "com.tylervick.waddle>"'
```

Each line ends with how that launch of the app ended. A healthy run is all
`SIGTERM(15)` (the next test's launch terminating the last one) with a
`SIGKILL(9)` or two. Anything else is a death to explain: the four failures
examined were each one `SIGPIPE(13)`, timed within 300 ms of the session's
audio stopping. In zsh, call `/usr/bin/log` by its path; `log` is a builtin.

## What could not be done

The condition was not reproduced end to end on a local machine. Pausing
`xcodebuild` outright also stalls the app's main thread, so the session never
ends while the pipe is full; pausing it in pulses left the session ending
normally four times out of four. The link between the kernel behaviour and
the CI deaths is the timing in the logs and the absence of any other
descriptor swap at session end, not a local replay.

## 2026-11-20: the same condition, once it stopped being fatal

With SIGPIPE out of the way the app survived a backed-up pty, and froze
instead (issue #394). In run 44572978942 `xcodebuild`'s copy of the app's
output stops in the middle of a line, XCTest's query thread logs its last
message six seconds later, the main thread three seconds after that, and the
test fails with `Timed out while evaluating UI query` over an app stuck on
its last frame. Nothing was killed: the pump was asleep in its pass-through
`write()`, the tee was full behind it, and every thread that logged joined
the queue.

The pump no longer writes to the original. A second thread per descriptor
does, fed through a 64 KiB queue, so a destination nobody reads can put only
that thread to sleep. A pump that finds the queue full waits up to
`stallGrace` (2 s) for room, then takes the reader for stalled and drops
pass-through bytes without waiting, until a write to the original completes
again; a note saying how many bytes are missing goes down the original at
that point. The session log is written before the pass-through is offered
anything, so it keeps every byte either way.

Three things to know before changing it:

- **The grace period is what keeps a slow reader from losing bytes, and it
  is also a bound on the first freeze.** A thread can still sleep on the tee
  for up to `stallGrace`, once per stall. Zero would drop output every time
  the runner hiccups.
- **`testEndingASessionDoesNotSignalAWriterAsleepOnTheTee` needs that
  window.** It wants a writer asleep on the tee when `end()` runs, and with
  a stalled original a writer is now only asleep there during the grace
  period. The test gets there in about 0.3 s. Shorten the default towards
  that and the case fails on "the writer never blocked", which reads like a
  broken test and is a real change of behaviour.
- **Do not replace the second thread with `O_NONBLOCK` or `poll` on the
  saved descriptor.** `O_NONBLOCK` is a property of the open file, which the
  app shares with whoever handed it stderr and gets back at `end()`. `poll`
  followed by a blocking `write` is a race against the other captured
  descriptor: stdout and stderr are usually the same pty.

- **`end()` has to call the grace period off.** A pump waiting for room
  outlives a `drainDeadline` shorter than `stallGrace`, and `end()` then
  closed the log with part of the session still in the tee: 73,728 of
  122,880 bytes logged, found in review of pull request 399. `end()` now
  tells each writer to stop waiting, so the pump reads the tee straight
  through to EOF.

A device was not tested, for the reason the issue gives: nothing there holds
a pty on the app's stderr. The CI stall itself was not reproduced either;
the check is a pipe nobody reads.

**The executable check:** `App/Tests/SessionLogCaptureStalledReaderTests.swift`.
Against the capture as it was on `main` at 61c5b36 the writer stops after
69,632 of 4,194,304 bytes and the log holds none of them.

**Provenance:** issue #365, found 2026-11-10 from the result bundles of runs
42775216487 and 42940487234; issue #394, found 2026-11-19 from run
44572978942.
