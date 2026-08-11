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

## Where else to look

If a future change makes the two `classify_domain` calls run concurrently, or
batches both domains' `revert_src` calls before either evaluates (e.g. to
share one `xcodebuild` invocation), this invariant breaks silently -- nothing
type-checks it, and the failure mode is a fabricated `vacuous` in whichever
domain's evaluation loses the race. The executable check is
`Scripts/test-check-red-green.sh`'s "a mixed pull request takes the worse of
the two verdicts" case: it is the only fixture with both a swift and a shell
half, and stubs `xcodebuild`'s test-without-building to fail (which would
read as `proved`) while the shell suite is arranged to pass unconditionally
(`vacuous`) -- the worse of the two. Keep both halves in that fixture strong
enough that only correct sequencing produces the assertion's expected
worst-of `vacuous`.
