# Replacing the agent loop's leading signal with a red-green test proof

## Why the current signal has to go

`Scripts/loop-prompt.md` records `coderabbit_findings_first` — CodeRabbit's
Major/Critical count on the run's pull request, snapshotted before any fix — as
the loop's leading signal. `docs/superpowers/specs/2026-08-07-agent-loop-design.md`
justified it as free: CodeRabbit already reviews every pull request, so
collecting the number costs nothing.

Eight trials in, that premise is false. CodeRabbit rate-limits, and it reports
the fact as a *check description* (`Review rate limited`) while the check state
reads `success`, so the failure is quiet. Measured state as of 2026-08-10:

| Trial | PR | `coderabbit_findings_first` | Did CodeRabbit review? |
|---|---|---|---|
| 2026-08-07 (legacy) | 55 | field absent | yes |
| `2026-08-07T223321Z` | 56 | absent/legacy | yes |
| `2026-08-08T012411Z` | 57 | `none` | **no** |
| `2026-08-08T025710Z` | 59 | `unavailable` | **no** |
| `2026-08-08T055251Z` | 61 | `unavailable` | yes (after a human commit) |
| `2026-08-11T030941Z` | 70 | `unavailable` | **no** |

One usable measurement in eight runs. The loop behaves correctly; the
instrument does not read. No amount of report-side work fixes this — and two
attempts at report-side work (PRs #66 and the fix tracked in issue 71) have
already been spent trying.

The deeper problem is that the signal depends on a third-party service outside
the owner's control, with no SLA and no local fallback. Any replacement must
not.

## What replaces it

A **red-green proof**: mechanical evidence that the test shipped with a change
actually fails without that change.

This targets a failure mode the project has already shipped, twice:

- **PR #57's body claimed** the fix was verified "by deleting the corresponding
  line and watching the suite go red." A reviewer deleted line 25 and every
  test still passed. The claim was false.
- **PR #61 shipped a vacuous test.** The owner caught it by hand, and it was
  removed before merge.

Both were self-reported quality claims that did not survive checking. That is
the specific thing this signal measures, and it is why the measurement must be
computed by something other than the agent being measured.

## The verdict vocabulary

| Verdict | Meaning |
|---|---|
| `proved` | With the source change reverted, the changed tests **compiled and failed**. The strongest evidence: the test detects the behavior the change introduced. |
| `proved-by-compile` | With the source change reverted, the tree **did not compile**. The test cannot pass without the change, so it is not vacuous — but this proves the test references new API, not that it checks correct behavior. Recorded separately so the report can show how much of the `proved` count is the weaker kind. |
| `vacuous` | With the source change reverted, the changed tests **still passed**. The test does not prove the change. This is PR #61's failure, caught mechanically. |
| `no-test` | Source changed; no test file changed. Behavior moved with nothing proving it. |
| `n/a` | No source file changed — a test-only, docs, or chore pull request. PR #70 is this shape. |
| `error` | The proof could not be computed (the job itself failed, a revert could not be constructed). Distinct from every verdict above: it means *unknown*, not *bad*. |

`error` and `n/a` must never be silently folded into a score. The existing
signal's whole history is a lesson in what happens when an absent measurement
is reported as a number — see `docs/learnings/masked-exit-status-fails-open.md`
and issue 71.

## Mechanism

### `Scripts/check-red-green.sh`

The logic lives in a script, not in workflow YAML, so it is hermetically
testable the way `Scripts/check-engine-fresh.sh` and
`Scripts/check-simulator-available.sh` are. It takes a base ref, computes the
verdict, and prints it.

```
base       = merge-base(HEAD, base-ref)
changed    = files changed between base and HEAD
test_files = changed ∩ App/Tests/**
src_files  = changed ∩ App/Sources/**

if src_files is empty   → n/a
if test_files is empty  → no-test
otherwise:
    revert src_files to their base state
    rebuild and run only the test classes declared in test_files
      build failed        → proved-by-compile
      tests failed        → proved
      tests passed        → vacuous
    restore the working tree
```

**Reverting is not `git checkout base -- <paths>`.** That fails for a file the
change *added*, which has no base state. The revert must handle three cases
explicitly: a modified file is restored to its base content, an added file is
deleted, and a deleted file is restored. Getting this wrong produces `error` at
best and a false `vacuous` at worst.

**There is no restore-and-confirm-green step.** CI already runs the full suite
on the pull request as-is; a second green run would spend roughly four minutes
proving something already proven.

### Test selection

Only the XCTest classes declared in the changed test files are run, via
`-only-testing:WADdleTests/<Class>`. Class names are parsed from the file
contents (`final class X: XCTestCase`), not inferred from filenames — the two
agree today, and nothing enforces that they keep agreeing.

### The CI job

A job in `.github/workflows/ci.yml` runs the script against the pull request
and prints the verdict on a distinct, greppable line:

```
TEST_PROOF: proved
```

This follows the marker convention `WADDLE_SIMULATOR_UNAVAILABLE` already
established in this repo, and the agent reads it the same way — by grepping the
run log.

**The job must never fail the build.** It exits 0 on every verdict, including
`vacuous`. This is not a convenience; it is required for the measurement to
mean anything. `2026-08-07-agent-loop-design.md` established that a signal the
agent can fix before it is recorded measures the agent's ability to satisfy the
checker rather than the quality of its work — which is why
`coderabbit_findings_first` is snapshotted pre-fix. A gating red-green job
would recreate that exact defect: the loop would iterate until the gate went
green, and the signal would read `proved` on every trial forever.

For the same reason, **the protocol must not act on a `vacuous` verdict.**
Section 4's fix phase addresses red CI and trusted-app review findings; the
test proof is recorded and left alone. This will feel wrong — a vacuous test is
a real defect and the loop is standing next to it — but a measurement the
subject is instructed to improve is not a measurement.

## Scope

**UI tests are excluded.** `WADdleUITests` boot the real engine, are
dispatched manually rather than on pull requests, and `RealWADTests` require
Scythe / Sunlust / Eviternity II fixtures that CI does not have
(`docs/learnings/simulator-test-hazards.md`). Wiring them in would make the
signal slow and flaky — the properties that made CodeRabbit useless. A pull
request touching only UI tests scores `n/a`.

**Shell work is included.** Issues 71 and 72 are `agent:eligible` and live in
`Scripts/`, where XCTest does not apply, but the same revert-and-rerun logic
works against the `Scripts/test-*.sh` suites, which run in seconds. Including
it roughly doubles how much of the backlog gets measured. The domains are:

| Domain | Source | Tests | Runner |
|---|---|---|---|
| swift | `App/Sources/**` | `App/Tests/**` | `xcodebuild -only-testing:WADdleTests/<Class>` |
| shell | `Scripts/*.sh` except `Scripts/test-*.sh` | `Scripts/test-*.sh` | the matching suite, by name |

In the shell domain the test for `Scripts/foo.sh` is `Scripts/test-foo.sh`,
by name and nothing cleverer. A changed script with no matching suite
contributes `no-test`; only the suites matching the changed scripts are run,
not all of them. Non-`.sh` files under `Scripts/` — `Scripts/loop-prompt.md`
is the one that matters — are not source in either domain, so a change
touching only those scores `n/a`.

**A pull request touching both domains is scored as the worst of the two**
(`vacuous` worse than `no-test` worse than `proved-by-compile` worse than
`proved`), and the report records which domains were evaluated. Pessimism is
deliberate: a proved Swift half must not mask a vacuous shell half. Mixed
pull requests are expected to be rare.

`error` is not a rank in that ordering — it means the proof could not be
computed. If **any** evaluated domain errors, the pull request's verdict is
`error`, regardless of what the other domain returned. A half-computed proof
is not a proof.

## What the loop records

A new trial-record field, `test_proof_first`, holding one verdict from the
table above, plus `test_proof_domains` naming what was evaluated (`swift`,
`shell`, `swift+shell`, or `none`).

`_first` is not decoration. It carries the same snapshot semantics as
`coderabbit_findings_first`: the verdict from the **first** CI run on the pull
request, before any fix round. If a later fix round changes the tests, the
pre-fix verdict must survive — and `Scripts/loop-report.sh` reads it from the
record rather than recomputing, for the same reason that file already
documents at length.

`coderabbit_findings_first` is **retained**, demoted from primary signal to a
secondary one. It costs nothing to keep collecting on the occasions CodeRabbit
does review, and dropping it would discard the one usable measurement the
experiment has.

## What this does not do

- It does not measure whether the fix is *correct*, only whether the test
  distinguishes the fixed tree from the unfixed one. A test can prove a wrong
  fix.
- `proved-by-compile` can fire for reasons unrelated to the test's quality —
  an unrelated compile coupling in the reverted tree produces it just as
  readily as a genuine API dependency. This is precisely why it is a separate
  verdict rather than folded into `proved`.
- It says nothing about the ~7 of 21 backlog issues that are test-only or
  chore work. Those score `n/a`, honestly, and the report must present `n/a`
  as an absent measurement rather than a zero.

## Testing

`Scripts/test-check-red-green.sh`, hermetic, following the pattern of the
sibling suites. It must cover each verdict in the vocabulary, and specifically:

- a modified source file, reverted, whose test then fails → `proved`
- an added source file, reverted by deletion, whose test then fails to
  compile → `proved-by-compile`
- a test that passes with the source reverted → `vacuous`
- source changed with no test touched → `no-test`
- test-only change → `n/a`
- a revert that cannot be constructed → `error`, never a verdict
- the working tree is restored after every path, including the error paths

Fixtures are throwaway git repositories built in the test, as
`Scripts/test-build-deps.sh` already does, so no case depends on the state of
the real checkout.
