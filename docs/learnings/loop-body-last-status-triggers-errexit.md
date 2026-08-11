# The last command in a loop body can trip `errexit`, even when its failure is expected

`cmd1 && cmd2` is a normal, idiomatic way to say "do `cmd2` only if `cmd1`
succeeds," and `cmd1` failing is not a bug -- it is one of the two outcomes
the code is written to handle. Put that idiom as the *last* statement in a
`while`/`until`/`for` loop body under `set -e`, and it stops being safe:

```bash
set -e
printf 'a\n' | while IFS= read -r s; do
    [ -f /nonexistent/path ] && echo "$s"
done
echo "reached end"   # never prints
```

A `while` loop's own exit status is the exit status of the last command
executed in its body (or 0 if the body never ran) -- not the exit status of
the condition that ended it. When `[ -f ... ]` is false, `&&` short-circuits
and the compound command's status is 1; if that happens to be the last thing
the loop body runs, the loop's own status is 1. That status is not "checked"
by anything -- it isn't the condition of an `if`, it isn't on the left of
`||`, it isn't negated -- so `errexit` treats it exactly like a bare failing
command and kills the shell right after the loop, before the next statement
ever runs.

This bit `run_shell_domain` in `Scripts/check-red-green.sh`: the first source
file with no matching `Scripts/test-<name>.sh` -- an ordinary, expected
outcome, not a failure -- aborted the whole script with no verdict printed at
all. It surfaced as one specific test case failing
(`Scripts/test-check-red-green.sh` case 11, a changed script with no matching
suite) while the sibling cases with a match kept passing, because a match
makes the `&&` list's status 0 and hides the trap.

## The fix

Spell the same logic as an `if`, whose own compound status is 0 whenever the
condition is false and there is no `else` -- there is no bare failing status
left over for `errexit` to notice:

```bash
if [ -f "$t" ]; then echo "$t"; fi
```

## Not the same failure as masking or a discarded subshell

[Masking a query's exit status](masked-exit-status-fails-open.md) is about
throwing away real failure evidence with `|| true` so a failure reads as
data. Nothing here is masked -- quite the opposite: an *expected*, harmless
outcome was left completely unguarded and read as a fatal one.

[Command substitution discarding a callee's state](command-substitution-discards-callee-state.md)
is about a subshell erasing variable assignments and `exit` calls that were
meant to reach the parent. This trap needs no subshell at all -- the loop
here runs with a pipe into it (which does subshell it in bash 3.2), but the
failure is the same with a `for` loop or `< <(...)` process substitution
that never forks anything. The mechanism is purely "a compound command's
trailing status, unchecked, is exactly as fatal under `errexit` as a bare
command's."

## Where else to look

Any loop body whose last statement is a `test && action` or `cmd || action`
pair where the "did nothing" branch is a legitimate outcome, not an error, is
suspect. Guarding the *whole* compound with `|| true` would hide a real
failure inside `action` too, so `if`/`fi` (or moving the guard so the
unchecked command is never last) is the fix, not blanket masking.

`pipefail` produces the identical shape without any `&&`/`||` in sight.
`test_classes` in `Scripts/check-red-green.sh` (Task 4, the Swift domain
runner) ends each loop iteration with `grep -o ... | sed ...`: a test file
that legitimately declares no `XCTestCase` class makes `grep` exit 1 for "no
lines selected" even though `sed` runs and exits 0. Under `set -o pipefail`
the pipeline's own status is `grep`'s nonzero one, and as the loop body's
last statement that killed the whole script under `errexit` -- silently,
before `run_swift_domain` ever got to report the `error` verdict this exact
input is supposed to produce. The fix is the same family, just applied to a
pipeline instead of a `&&` list: `... | sed ... || true`, justified the same
way the `swift_src`/`swift_test`/etc. domain functions at the top of the same
file already mask a query's own no-match exit -- the absence of a match is
the expected answer here, read from the *accumulated output*, not from this
command's exit status.
