# A `WaddleUITests` failure means nothing until you check the latest `main` run

No pull request runs `WaddleUITests`. `ci.yml` is deliberately
`-only-testing:WaddleTests`, and `ui-tests.yml` runs on `push: main` and manual
dispatch. So `main` can carry a red UI test indefinitely with no red check on
anybody's branch, and the first person to run the suite locally sees failures
that have nothing to do with their diff.

**Before attributing any `WaddleUITests` failure to your own change, get a
baseline from `main` rather than assuming green:**

```bash
gh run list --workflow=ui-tests.yml --limit 5
gh run view <id> --log | grep -oE "Test Case '.*' (passed|failed)" | sort -u
```

A branch signal, when you want one pre-merge, is
`gh workflow run ui-tests.yml --ref <branch>`.

Two things make this worth a file rather than a habit. `RealWADTests` cannot
pass anywhere without the non-redistributable fixtures in
`simulator-test-hazards.md`, so it is skipped in CI and red locally — expected,
not a regression. And a real failure in these suites is often several steps
upstream of the code you changed: an engine session that never started produces
"the gesture never reached the shim", which reads exactly like a broken input
router. Confirm the session actually reached gameplay before believing a
failure is about the thing it names.

## Why this file does not name the currently-red tests

It used to, in two files, and both went stale without anyone noticing —
`ui-tests-are-red-at-head.md` and `touch-controls-ui-tests-red-at-head.md`,
retired 2026-09-20. Between them they named four tests as reliably red. By the
time anyone checked, three were passing on three consecutive `main` runs, and
the fourth was in `PresetEditTests` — a file PR #232 had deleted outright.
`.revyl/tests/README.md` had flagged the contradiction and asked whoever ran
them next to resolve it.

The deletion is the sharp end of it. A named test can go away entirely, and the
file naming it carries on telling people to expect its failure, which is advice
about a test that cannot run. Nothing detects that: `check-substrate.sh`
enforces the file/INDEX bijection, not that a learning's claims are still true.

A file that names specific red tests has to be revised every time one is fixed,
and nothing forces that revision — so it rots into advice that tells the next
person to ignore a genuine regression. Nor can it become an executable check:
a guard asserting "these tests are red" would enshrine the breakage and would
have to be deleted the moment somebody fixed it.

Track individual red tests as issues, where closing one is the same act as
fixing it. The command above is always current; a list in a file never is.

The currently-known red case is issue 251 —
`DemoLoopReplayTests/testDoom2AfterFreedoomDoesNotCrashOnReplay`, red on every
run since PR #232. That sentence will rot too; the issue tracker will not.

**Provenance:** 2026-09-20, retiring both predecessors after the `main` runs for
PRs #248–#250 showed their named tests passing.
