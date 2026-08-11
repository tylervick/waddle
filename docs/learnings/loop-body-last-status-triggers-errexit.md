# A loop body's trailing `&&` list trips `errexit` only when the loop is a pipeline stage

`cmd1 && cmd2` is a normal, idiomatic way to say "do `cmd2` only if `cmd1`
succeeds," and `cmd1` failing is not a bug -- it is one of the two outcomes
the code is written to handle. Put that idiom as the *last* statement in a
loop body under `set -e`, and whether it is safe depends on how the loop is
fed:

```bash
set -e
printf 'a\n' | while IFS= read -r s; do
    [ -f /nonexistent/path ] && echo "$s"
done
echo "reached end"   # never prints
```

## Measured, bash 3.2.57 (macOS)

Same body in every row -- `[ -f /nonexistent/path ] && echo "$x"` as the last
statement -- differing only in how the loop gets its input:

| Shape | Result |
|---|---|
| `printf … \| while … done` | aborts, exit 1 |
| `echo … \| for x in a b; do …; done` | aborts, exit 1 |
| `for x in a b; do …; done` | reaches end, exit 0 |
| `while … done < <(printf …)` | reaches end, exit 0 |
| `while … done < file` | reaches end, exit 0 |

Three more rows pin the mechanism rather than the loop:

| Shape | Result |
|---|---|
| `while … done < file` with a bare `false` as the last body statement | aborts, exit 1 |
| `{ [ -f … ] && echo x; }` (brace group, same shell) | reaches end, exit 0 |
| `( [ -f … ] && echo x )` (subshell), and the same inside a function | aborts, exit 1 |

## The mechanism is the pipeline, not the loop

Under `set -e`, a command that fails as a **non-final member of an `&&`/`||`
list** is exempt -- that is the documented rule, and it is the whole reason
`[ -f x ] && cmd` is safe as an ordinary statement. Two things follow, and the
second is the one that surprises:

1. **The exemption is carried by the enclosing compound's inherited status, in
   the same shell.** A `for` loop, a redirect-fed `while`, a process-
   substitution-fed `while`, and a brace group all just *inherit* that already-
   exempt status, so nothing fires. The exemption is what does the work, not
   any special treatment of loops -- swap the `&&` list for a bare `false` and
   the identical redirect-fed loop aborts (row 6).
2. **The exemption does not survive an execution boundary.** Where the status
   has to be re-delivered from one execution context to another -- a pipeline
   stage's subshell, an explicit `( … )`, or a function returning to its call
   site -- the parent receives a plain nonzero status with nothing attached
   saying it was exempt, and `errexit` fires on it as it would on any bare
   failing command. In bash a non-final pipeline stage runs in a subshell, so
   `printf … | while … done` crosses exactly that boundary.

So the dangerous shape is specifically **a loop fed by a pipe** (or otherwise
wrapped in a subshell or returned from a function), whose body's last statement
is an `&&`/`||` list that is expected to short-circuit.

This bit `run_shell_domain` in `Scripts/check-red-green.sh`, which is
pipe-fed: the first source file with no matching `Scripts/test-<name>.sh` --
an ordinary, expected outcome, not a failure -- aborted the whole script with
no verdict printed at all. It surfaced as one specific test case failing
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

## Do not run the inference backwards

The rows above are easy to misread as "loops are fine, this was overblown."
Verifying the `for` or `while … < file` form, concluding the shape is
harmless, and stripping an `if`/`fi` guard back to `&&` inside a *piped* loop
reintroduces the exact abort, and it reintroduces it silently: the script dies
between statements with no message, and in `check-red-green.sh`'s case that
means no verdict at all where a verdict was expected. An earlier version of
this file made the opposite error -- it claimed the trailing status behaves
"exactly like a bare failing command" regardless of shape and explicitly
denied any subshell involvement -- which is why the table is here, measured,
rather than a sentence asking to be trusted.

When in doubt, measure the actual shape you are about to write. It is four
lines and one `echo "reached end"`.

## Not the same failure as masking or a discarded subshell

[Masking a query's exit status](masked-exit-status-fails-open.md) is about
throwing away real failure evidence with `|| true` so a failure reads as
data. Nothing here is masked -- quite the opposite: an *expected*, harmless
outcome was left completely unguarded and read as a fatal one.

[Command substitution discarding a callee's state](command-substitution-discards-callee-state.md)
is about a subshell erasing variable assignments and `exit` calls that were
meant to reach the parent. That one is about what the subshell *swallows*;
this one is about the one thing it lets through -- a bare exit status,
stripped of the `errexit` exemption it had on the other side.

## Where else to look

Any loop body whose last statement is a `test && action` or `cmd || action`
pair where the "did nothing" branch is a legitimate outcome, not an error, is
suspect **if that loop is a pipeline stage, sits in a subshell, or is the last
statement of a function**. Guarding the *whole* compound with `|| true` would
hide a real failure inside `action` too, so `if`/`fi` (or moving the guard so
the unchecked command is never last) is the fix, not blanket masking.

`pipefail` produces a similar-looking shape with no `&&`/`||` in sight -- and
it is *worse*, because there is no exemption to inherit in the first place, so
it aborts in every loop shape above, redirect-fed included. `test_classes` in
`Scripts/check-red-green.sh` (the Swift domain runner) ends each loop iteration
with `grep -o … | sed …`: a test file that legitimately declares no
`XCTestCase` class makes `grep` exit 1 for "no lines selected" even though
`sed` runs and exits 0. Under `set -o pipefail` the pipeline's own status is
`grep`'s nonzero one -- an ordinary failing command, exempt from nothing -- and
as the loop body's last statement that killed the whole script under `errexit`,
silently, before `run_swift_domain` ever got to report the `error` verdict this
exact input is supposed to produce. The fix is `… | sed … || true`, justified
the same way the `swift_src`/`swift_test`/etc. domain functions at the top of
the same file already mask a query's own no-match exit -- the absence of a
match is the expected answer here, read from the *accumulated output*, not from
this command's exit status.
