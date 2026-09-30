# A Revyl agent spends 15–30 s per step, so a short autoquit ends the session before it looks

Found 2026-09-30 while verifying issue #111 on a farm device.

`WADDLE_AUTOQUIT_SECONDS` is set per run for the engine tests
(`.revyl/tests/README.md`), and the values the existing tests use (8, 20,
120) were chosen for what the *engine* needs to reach: a title page, a demo
level. A script that reads the screen several times *during* a session has a
different budget: the agent takes a screenshot, thinks, and acts once per
step, at fifteen to thirty seconds each, and instructions like "wait ten more
seconds" add to that.

`background-suspend` has eleven steps. With a 90-second autoquit its
post-return readings all happened after the engine had already quit, and the
agent reported "the engine had already terminated rather than holding the
paused game view" — which read as the defect under test until the final
validation, which passed, showed the session had simply ended on schedule.
The same script with a 300-second autoquit read the paused level twice.

**Rule:** budget the autoquit from the number of steps that need the session
alive, at thirty seconds each, plus every explicit wait, and say the real
figure in the test's `system_prompt` so the agent does not wait for a quit
that is minutes away.
