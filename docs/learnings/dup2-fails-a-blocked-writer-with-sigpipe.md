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

**Provenance:** issue #365, found 2026-11-10 from the result bundles of runs
42775216487 and 42940487234.
