# A UI test's autoquit budget is a guess about how fast the runner is

`WADDLE_AUTOQUIT_SECONDS` asks an engine session to quit a fixed number of
seconds after it starts. A test that taps and drags inside the session has to
fit all of that inside the number, and the number was written on a machine
where a tap takes under a second.

On a slow CI runner it does not. Measured on full run 42971838691
(2026-11-11): one tap took about 9 s and a 1.2 s stick drag about 14 s.
`DebugHUDInputTelemetryTests` gives its session 20 s; the session ended in the
middle of the drag, and the next step failed with

```
Failed to tap "useButton" Button: No matches found
```

over a hierarchy that was the shelf, with the game "last played 23 seconds
ago". The app was healthy and had done what it was told. This was seen three
times in the full runs of 2026-11-11, in three different tests (issue #380),
and it reads like a crash until the exit records are checked
(`dup2-fails-a-blocked-writer-with-sigpipe.md` has the method).

Raising the number moves the guess and makes every passing run slower by the
difference. `revyl-agent-latency-outruns-a-short-autoquit.md` is the same trap
with a slower driver.

## What the tests do instead

A launch that also calls `app.holdAutoquit()` (`WADDLE_AUTOQUIT_HOLD`) keeps
its budget, but the app does not act on it until the test calls
`releaseAutoquit()`, which posts a Darwin notification the app listens for.
The session lasts its budget or as long as the test needs, whichever is
longer. The rule is `AutoquitGate` (`App/Sources/AutoquitGate.swift`), pinned
by `App/Tests/AutoquitGateTests.swift`.

Two properties are deliberate:

- **A fast machine sees no change.** A release that arrives before the budget
  is up does not end the session early, so tests that assert a session lasted
  its window (`MenuStateAcrossSessionsTests`) still hold, and nothing got
  slower.
- **It is opt-in.** A test that taps a tile and only waits for the session to
  end has no steps for the budget to cut short, and `EngineSmokeTests`
  measures the plain autoquit itself. Those launches are unchanged.

## Using it in a new test

- Call `app.holdAutoquit()` beside the `WADDLE_AUTOQUIT_SECONDS` line whenever
  the test taps, drags, rotates, or reads the debug HUD while the session is
  up.
- Call `releaseAutoquit()` after the last such step, before waiting for
  `engineExitLabel`. Every session of a multi-session test needs its own.
- Call it while the session is known to be running (an overlay element has
  been seen). The app drops a release that arrives with no session up.
- A held session that is never released does not end. A test that forgets the
  release fails on its 90 s wait for the exit label, which is the signal; a
  test that never waits for the session to end (`SoftKeyboardTests`) needs
  only the hold.

## Proving a change like this

A fast machine passes these tests with or without the hold, so a green local
run says nothing. Put `sleep(30)` before a step inside the session, in an edit
that is not committed: without the hold the test fails with the message
above, with it the test passes. Both directions were run for
`DebugHUDInputTelemetryTests` and `MenuStateAcrossSessionsTests`; the pull
request for #380 has the output.
