# A pull request's UI Tests run cannot tell you how long `main`'s takes

The iPhone "UI tests" job on `main` was cancelled at its 90-minute limit on
four push runs in a row (45686877866, 45687986123, 45714177534, 45729033105),
while pull request runs of the same workflow passed in 30 to 40 minutes. That
gap looked like something `main`-only going wrong. It was not: a pull request
runs only the five shell-smoke classes
(`docs/learnings/ui-test-failures-need-a-main-baseline.md`), a push to `main`
runs all of `WaddleUITests`, and the two durations measure different suites.

The full suite had simply outgrown the limit. The last green push run
(45634863622) used 86 of the 90 minutes for 98 tests. Pull requests #536 and
#543 added nine shelf-anchor tests worth about 630 s, two of them over three
minutes each, and the job then needed about 93. In 45714177534 xcodebuild
printed `Executed 107 tests, with 22 tests skipped and 0 failures` and was
cancelled eleven seconds later.

**A cancelled job has no failure to read, so read the end of the log.** The
last `Executed N tests` line and the last `Test Case ... started` line tell a
suite that finished late from a test that hung. Some job logs fetched through
the API stop short of the end (two of the four runs here did); use a run whose
log reaches `##[error]The operation was canceled.`

**Compare per-test durations against the last green `main` run, not a pull
request.** Extract `Test Case '...' (passed|failed|skipped) (N seconds)` from
both, join on the test name, and the new tests and any slowed ones fall out.

**A full-suite branch run reproduces `main`'s conditions**:
`gh workflow run ui-tests.yml --ref <branch> -f leg=iPhone` with no
`only_testing` runs the whole suite on the phone, as a push does.

`timeout-minutes` in `.github/workflows/ui-tests.yml` carries the run numbers
it was set from; when the suite grows, raise it from a run's numbers, never to
cover a test that hangs.
