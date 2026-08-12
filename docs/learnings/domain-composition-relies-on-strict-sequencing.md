# Combining red-green domains is safe only because they never overlap in time

`run_shell_domain` and `run_swift_domain` share one global, `REVERTED`, and
each calls `restore_tree` inline on every normal exit path. `restore_tree`
restores *everything* currently recorded in `REVERTED`, not just the caller's
own files -- it has no notion of "domain" at all, only "paths reverted since
the last restore."

That makes the two runners safe to compose *only* because of an invariant
neither function enforces itself: the top-level dispatch

```bash
classify_domain swift "$(swift_src)" "$(swift_test)" > "$verdict_tmp"
sw="$(cat "$verdict_tmp")"
classify_domain shell "$(shell_src)" "$(shell_test)" > "$verdict_tmp"
sh="$(cat "$verdict_tmp")"
```

calls the two domains strictly sequentially, and each `classify_domain` call
blocks until its runner has reverted, evaluated, *and* restored -- so
`REVERTED` is always back to empty before the next domain's `revert_src`
ever appends to it. Neither runner's `restore_tree` can fire while the
other's revert is still in effect, because the other's revert hasn't
happened yet.

This was flagged as a live risk across two task reviews (a proved swift half
could mask, or be masked by, a vacuous shell half if their revert/restore
windows ever overlapped) but nothing exercised it until a diff could touch
both domains in the same run. Confirmed empirically, not just by reading the
code: instrumented `xcodebuild` and the shell suite to log the *other*
domain's file state at the moment each one runs. Swift's `xcodebuild` saw
the shell-added file still present (untouched); the shell suite saw the
swift source back at full HEAD content (already restored) -- no window where
either domain observed the other's revert.

## The first attempt at an executable check didn't check anything

The mixed-domain worst-of case ("a mixed pull request takes the worse of the
two verdicts") was written to double as the regression test for this
invariant, and a review caught that it doesn't work: its swift verdict comes
entirely from `stub_xcodebuild`'s fixed exit codes, and its shell suite is a
bare `exit 0` that never reads a file. Neither half's result depends on
whether the *other* domain's revert has actually been restored yet, so the
case passes identically whether the sequencing invariant holds or not --
confirmed by literally no-op'ing all three `restore_tree` calls inside
`run_swift_domain` and rerunning: that case still passed, byte for byte.

## Where else to look

If a future change makes the two `classify_domain` calls run concurrently, or
batches both domains' `revert_src` calls before either evaluates (e.g. to
share one `xcodebuild` invocation), this invariant breaks silently -- nothing
type-checks it, and the failure mode is a fabricated verdict in whichever
domain's evaluation observes the other's in-flight revert.

The executable check that actually catches this is
`Scripts/test-check-red-green.sh`'s "shell's suite observes swift's source
already restored to HEAD, not swift's in-flight revert" case. Its shell
suite reads `App/Sources/Thing.swift` -- the *swift* half's own reverted
file -- at the moment it runs, and fails if that file is still in swift's
BASE-reverted content rather than HEAD. Swift's own verdict is pinned by the
`xcodebuild` stub regardless, so only the shell half's observation can move
the result: sequencing intact reads `vacuous` (which dominates swift's
stubbed `proved` in the worst-of); sequencing broken reads `proved` on both
halves, and the worst-of has no `vacuous` left to fall back on. Verified by
the same no-op: with `run_swift_domain`'s `restore_tree` calls no-op'd, this
case fails (`got: proved`); restoring them makes it pass again. Keep the
shell suite's file check in place -- it is the only thing in the fixture
that makes the case sensitive to the invariant at all.
