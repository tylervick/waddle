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

`Scripts/check-red-green.sh`'s `run_shell_domain` hit this concretely, twice,
because closing one instance of the shape did not close the shape itself:
first a `Scripts/test-*.sh` suite committed without `chmod +x` (exit 126),
then a suite with a bad shebang or a typo'd command (exit 127) -- both die
before their own assertions ever run, and both would have reported `proved`
from a broken commit rather than from the revert ever being noticed. The
second one was caught only because a reviewer asked "what else exits nonzero
without the assertions running" instead of accepting that the first fix
closed the category.

The prediction in this file's own "Where else to look" section came true
before the file was a day old: `run_swift_domain`'s `test-without-building`
step hit it directly. `xcodebuild`'s own exit code cannot tell "a test
failed" apart from "the simulator was never available to run it on" --
`build-for-testing` only needs the SDK and had already succeeded, so a
CoreSimulator enumeration failure at the `test-without-building` step (CI
run 31427755601, `docs/learnings/simulator-enumeration-race.md`, against
this exact `RG_DESTINATION` default) would have reached `proved`, the
strongest verdict this instrument can emit, from an infrastructure hiccup.
Closed by reusing rather than reimplementing:
`Scripts/check-simulator-available.sh` already exists, already has its own
hermetic suite, and already distinguishes "CoreSimulator enumerated nothing"
from "a genuine destination pin problem" for exactly this device/OS pair.
Run unguarded immediately before `test-without-building`, either of its
failure modes hits the same unguarded-hard-stop shape as the shell domain's
126/127 -- `errexit` aborts the script, the `EXIT` trap restores the tree,
and the caller sees a non-zero exit with no verdict rather than a fabricated
`proved`.

## The fix is not a masked exit status, and not a fourth verdict

This is not [a masked exit status read as data](masked-exit-status-fails-open.md)
-- nothing here throws away evidence with `|| true`. It's the opposite:
126 and 127 were being read as data (a real assertion failure) when neither
should have been interpreted as data about the *test's own logic* at all.

The fix also does not require a new verdict string. `run_shell_domain`'s
contract is exactly `proved` | `vacuous` | `no-test` -- no `error` outlet.
Two things enforce the boundary, both unguarded on purpose:

- **Precondition:** `[ -x "$t" ]` runs as its own bare statement before the
  suite is invoked at all, ruling out the common case (126) up front.
- **Postcondition:** the suite's actual exit status is captured
  (`status=0; "./$t" ... || status=$?`, not folded into `|| rc=1`), and a
  `case` statement routes 126 and 127 to the same unguarded hard stop, while
  every other nonzero status -- 1 above all, the conventional assertion
  failure -- becomes `rc=1`, a real, counted `proved`.

Either path left uncaught (no `||`/`&&`/`if` swallows it) means `errexit`
aborts the whole script the instant it fires, the same hard-stop
`revert_src` already relies on for its own unmasked `git checkout` --
caught by the `EXIT` trap, which restores the tree, and the caller sees a
non-zero exit with no verdict printed at all. That absence *is* `error`
("the proof could not be computed") in every sense that matters, without the
function needing to spell the word.

**The boundary is 126 and 127, not wider.** Signals (a suite killed by
`SIGSEGV` or `SIGABRT` exits 128+n) are deliberately left as ordinary
failures: a crash can be exactly the regression a fix addresses, and
widening the "never ran" bucket to catch it would start misreading a
legitimate assertion failure as an infrastructure problem -- the same
fabrication in the opposite direction. 126 and 127 are the two POSIX shell
reserves specifically for "could not execute the command at all"; nothing
past that line has as clean a claim to meaning "never ran."

## Where else to look

Any place a nonzero exit status is read as "the check ran and found a
problem" is suspect if that status can also mean "the check didn't run."
`xcodebuild`, `pytest`, and similar test runners have their own nonzero exit
codes for "harness couldn't even start" (missing scheme, no devices,
compile error before a single test method runs) distinct from "a test
failed" -- conflating them the same way would recreate this exact defect in
Task 4's swift domain runner.
