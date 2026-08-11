# An exit status can mean "never ran", not "failed" -- and folding both into one bucket fabricates a measurement

A test suite invoked as `"./$t"` has more than two possible outcomes even
though it only returns one number. Exit 0 means the assertions ran and held.
A meaningful nonzero exit -- the one the whole test-proof feature is built to
detect -- means the assertions ran and one of them didn't hold. But other
nonzero exits mean the assertions never ran at all: 126 (`Permission denied`,
the executable bit is missing), 127 (`command not found`, a bad shebang or a
missing interpreter), a shell syntax error caught before the first line
executes. Catching all of these with one `|| rc=1` and reading `rc=1` as "the
suite noticed the revert" folds "detected a regression" and "never got the
chance to check" into the same bucket, and reports the stronger claim for
both.

This is the same shape as the failure `docs/superpowers/specs/2026-08-10-test-proof-signal-design.md`
was written to replace: CodeRabbit's rate-limit response read as check state
`success`, so "the review didn't run" was indistinguishable from "the review
ran and found nothing." Here it would have been "the test didn't run" reading
as `proved` -- inside the very instrument built to catch exactly that
substitution, and feeding an autonomous commit loop that cannot eyeball the
difference the way a human reviewer caught PR #61's vacuous test by hand.

`Scripts/check-red-green.sh`'s `run_shell_domain` hit this concretely: a
`Scripts/test-*.sh` suite committed without `chmod +x` exits 126 the instant
it's invoked, before its own assertions run, and would have reported
`proved` from a broken commit rather than from the revert ever being
noticed.

## The fix is not a masked exit status, and not a fourth verdict

This is not [a masked exit status read as data](masked-exit-status-fails-open.md)
-- nothing here throws away evidence with `|| true`. It's the opposite:
`126` was being read as data (a real assertion failure) when it should not
have been interpreted as data about the *test's own logic* at all.

The fix also does not require a new verdict string. `run_shell_domain`'s
contract is exactly `proved` | `vacuous` | `no-test` -- no `error` outlet.
The precondition for "did the suite even run" (`[ -x "$t" ]`) is checked as
its own bare, unguarded statement, left uncaught by any `||`/`&&`/`if`. Under
`errexit` this aborts the whole script the instant it's false, the same
hard-stop `revert_src` already relies on for its own unmasked `git
checkout` -- caught by the `EXIT` trap, which restores the tree, and the
caller sees a non-zero exit with no verdict printed at all. That absence
*is* `error` ("the proof could not be computed") in every sense that
matters, without the function needing to spell the word.

## Where else to look

Any place a nonzero exit status is read as "the check ran and found a
problem" is suspect if that status can also mean "the check didn't run."
`xcodebuild`, `pytest`, and similar test runners have their own nonzero exit
codes for "harness couldn't even start" (missing scheme, no devices,
compile error before a single test method runs) distinct from "a test
failed" -- conflating them the same way would recreate this exact defect in
Task 4's swift domain runner.
