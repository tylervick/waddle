# Agent Loop: Unattended Single-Item Runs — Design Spec

**Date:** 2026-08-07
**Status:** Designed. Architecture revised 2026-08-07 after the composition
spike (`docs/superpowers/plans/2026-08-07-agent-loop-spike-findings.md`)
disproved the coordinator/worker split; see "Why one agent".
**Predecessor:** `docs/superpowers/specs/2026-08-06-agent-substrate-design.md`
(merged as `c6f1558`), which built the backlog and knowledge store this
consumes.

## Problem

Spec 1 produced a machine-readable backlog: 19 open `agent:eligible` issues,
each carrying a definition of done, a runnable verification command, and its
provenance, enforced by `Scripts/check-issue-format.sh`. Nothing consumes it.

The open question is not whether an agent can close one of those issues — it
plainly can, attended. It is whether an agent can do so **unattended**, on a
brownfield iOS codebase whose verification is slow and whose most valuable work
is human-gated, and whether the result is worth reviewing.

This spec is an experiment designed to answer that with data. It optimises for
signal per iteration rather than throughput. Its deliverable is not the closed
issues; it is a report that says whether the loop helped.

## Scope

**In:** `Scripts/loop-precheck.sh` and its self-test; `Scripts/loop-prompt.md`;
`Scripts/loop-report.sh` and its self-test; the `docs/loop-trials/` record
format; the `loop-trials` branch convention; one `orca automations` entry; a
dedicated agent signing identity; the labels `agent:in-progress` and
`agent:stuck`.

**Out:** any change to the substrate's *mechanisms*. `CLAUDE.md`,
`Scripts/check-substrate.sh`, `Scripts/check-issue-format.sh`, and
`issue-format.yml` are consumed, never modified — by this spec's implementation
or by the loop it builds. `docs/learnings/` is the one exception, and only in
the direction the substrate already intends: a run may **add** a learning file
and its index line, which lands in a reviewed pull request like any other
change. Nothing here rewrites or removes an existing learning.

**Out, deliberately:** parallel runs, multi-agent orchestration, and Orca's
task/gate/dispatch surface. The unit of this experiment is one item per run;
the DAG machinery would sit unused, and concurrency would introduce the
simulator-contention confound the design specifically avoids.

## Research basis

Spec 1's research still applies. Three points bear directly on this design:

- Anthropic's [harness guidance](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)
  — one item per session, a startup routine that re-establishes state, and the
  rule that the call generating work must not be the call judging it.
- Huntley's [Ralph](https://ghuntley.com/ralph/) — progress accumulates in files
  and git, never in a context window, and quality is a function of how hard the
  project's checks push back.
- The counterweight literature on runaway loops — hence the runs-per-day
  ceiling, the agent's self-checked wall-clock budget, and a kill switch that is
  one command.

Yegge's [prescription](https://yegge.ai/essays/the-shape-of-things-to-come/) to
build orchestration "chemically bonded to your application" rather than adopting
a general harness is the one point this design consciously departs from, and the
departure is bounded, and the spike narrowed it further: Orca supplies scheduling
and per-run worktrees with repo setup hooks — the two things a bash script would
do badly here — while the protocol stays a versioned file in this repository.
Worker supervision was the third thing Orca was chosen for; it does not work, so
the design no longer relies on it.

## Architecture

Four tracked artifacts and one Orca object.

| Artifact | Role |
| --- | --- |
| `Scripts/loop-precheck.sh` | Decides whether a run happens, and which issue it takes |
| `Scripts/loop-prompt.md` | The protocol. The experiment's independent variable |
| `Scripts/loop-report.sh` | Aggregates trial records into a success rate |
| `docs/loop-trials/<run-timestamp>-issue-<N>.md` | One record per trial, on the `loop-trials` branch — the filename carries a full UTC timestamp, not just a date, so two runs on the same issue on the same day can't collide |
| `orca automations` entry `waddle-loop` | Schedule, provider, fresh worktree per run |

### One run

1. **The automation fires** (three times daily). Orca creates a fresh worktree
   off `main` and runs the `orca.yaml` setup hook, which clones `Vendor/out` with
   its `.fingerprint` stamp — so the worktree starts engine-current and skips a
   ~25-minute rebuild.
2. **The agent runs `Scripts/loop-precheck.sh` as its first action.** It refuses
   when a run is already live, when the root checkout's engine is stale (see
   Risks), or when no issue is claimable. On refusal the agent stops immediately
   and nothing further is spent. On success it prints one issue number.
3. **Selection**, inside the precheck. From open `agent:eligible` issues,
   excluding any labelled `agent:in-progress` or `agent:stuck` and any with a
   linked open pull request. Ordered `size:xs`, then `size:s`, then `size:m`,
   tie-broken by ascending issue number. Deterministic, so a trial can be
   reproduced.
4. **The agent claims the issue** with `agent:in-progress`, then immediately
   writes and pushes a trial record with `outcome: started`. This is the failure
   marker — see below.
5. **The agent does the work**: reads the issue, runs *that issue's own*
   verification command unmodified, commits under the agent signing identity,
   pushes, and opens a pull request declaring `Closes #N`. If it hit a trap worth
   recording, it adds a `docs/learnings/` file and its index line in the same
   pull request.
6. **The agent waits for CI and CodeRabbit, polling each independently**, capped
   at 15 minutes shared between them. That cap is separate from the 45-minute
   work budget — a run must never block indefinitely on a service it does not
   control. `ci_result` reflects CI's own conclusion only — `pass` once every
   check row other than CodeRabbit's has concluded successfully, `fail` the
   moment any of those rows concludes unsuccessfully, `timeout` only if CI
   itself had not concluded when the wait ended — and a stalled or
   rate-limited review never overwrites it. Separately, if `gh pr checks`
   reports a terminal non-review state for CodeRabbit (observed in practice
   as the check description `Review
   rate limited`), that is treated as an answer, not a pending state: the agent
   stops waiting for a review at once, records
   `coderabbit_findings_first: unavailable`, and does not retry or wait for
   CodeRabbit to recover. If CI has not concluded yet, the agent keeps polling
   for CI alone until it does or the cap expires. If CodeRabbit's terminal
   state fires, or the cap expires with no review to count — whether or not CI
   itself concluded — the agent skips step 7 entirely and goes to step 8, with
   `ci_result` already reflecting CI's own true outcome. Independence cuts both ways, though: if a
   real CodeRabbit review lands before the cap but CI is still running when
   the cap expires, the agent does not throw that review away — it still
   takes step 7.1's snapshot (a real, countable Major/Critical count) before
   going to step 8, records `ci_result: timeout` since CI itself never
   concluded, and skips the rest of step 7 (there is no concluded CI run to
   fix). A slow CI run must never suppress a review that already landed.
7. **The agent snapshots the review, then responds to it.** In that order, and
   the order is the whole point:
   1. Record `coderabbit_findings_first` — the Major/Critical count **before any
      fix is attempted** — and push that record immediately. This is the leading
      signal; once the agent starts fixing, the live count on GitHub no longer
      measures anything.
   2. Fix a red CI. A failing build is not a matter of opinion; the work is
      objectively incomplete.
   3. Address the Major/Critical CodeRabbit findings, within whatever remains of
      the 45-minute work budget and **at most three fix rounds**. A fourth round
      means the disagreement is not one the agent is going to resolve
      unattended, and grinding at it converts a useful trial into a timeout.
      Minor and Nitpick findings are recorded, never acted on. A finding the
      agent believes is wrong gets a reply on the pull request and no code
      change — changing correct code to clear a comment is the failure this
      rule exists to prevent.
8. **The agent rewrites its trial record** with the real outcome and pushes again.
9. **Cleanup.** The claim label is removed. On failure, `agent:stuck` is applied
   and a comment left on the issue stating what was tried and where it stopped.

### Why the snapshot must precede the fixes

The leading signal is "CodeRabbit Major/Critical findings on the run's pull
request". If the agent fixes those findings before the count is recorded, the
metric reads zero on every trial forever — and what it would then be measuring
is the agent's ability to satisfy CodeRabbit, not the quality of what it
produced. Snapshotting first keeps the measurement intact while still getting
the iteration.

The consequence is not confined to the protocol: `Scripts/loop-report.sh` must
read `coderabbit_findings_first` **from the record** rather than querying GitHub
at report time, because a live query now returns post-fix counts. A report that
kept querying live would silently report zero findings for every run and look
entirely healthy doing it.

The snapshot is pushed as its own record write, before any fix. A run that dies
mid-fix therefore still leaves the measurement behind — the same two-phase logic
that already protects the `started` marker.

### Why one agent, and how failures are still recorded

An earlier draft split this into a coordinator supervising a worker, so that the
recorder was never the thing being recorded. A spike disproved the mechanics
(see `docs/superpowers/plans/2026-08-07-agent-loop-spike-findings.md`):

- Workers launched via `orca orchestration worker-start` **never executed** —
  both stalled on the agent's interactive cold-start screen with no recovery.
- `--timeout-ms` is accepted and echoed but **not self-enforcing**; 118 seconds
  elapsed against a 30-second timeout with no state change and no notification.
  Fencing a hung worker was the split's main benefit, and it does not exist.
- An automation's **own** agent, by contrast, ran and completed normally,
  returning its output in the run's `outputSnapshot`.

So the split cost a layer and bought nothing the runtime actually delivers.

Failure capture moves instead to a **two-phase trial record**. The agent's first
act after claiming is to push a record with `outcome: started`; its last act is
to rewrite that record with the real outcome. A record still reading `started` is
a run that died — which is exactly the signal the split existed to preserve, at
no structural cost. The reconciliation happens in `Scripts/loop-report.sh`, which
reports any `started` record as a lost trial rather than omitting it.

This preserves the intent of the generator-never-judges rule where it
matters — for every run that survives long enough to push its `started`
record — while accepting that a single agent reports on itself for outcomes it
survives to report. One gap remains regardless: a run that dies between
claiming the issue and that first push landing leaves no record at all, not
even a `started` one, so it is not visible as a lost trial either — it is
simply absent. `Scripts/loop-prompt.md`'s ordering (claim only after the record
is prepared and committed locally, so a single push is the only thing left
after claiming) makes that window as small as it can be, and its "Known gaps"
section states plainly what it looks like from the report's side. The claim
that "no outcome can be silently dropped" is therefore true only outside this
one window, not unconditionally.

### Why trial records live on their own branch

Records go to a long-lived `loop-trials` branch, pushed directly, never into the
work pull request:

- A failed run produces no work pull request but must still record.
- Work pull requests stay pure code, so review is about the change.
- Records accumulate even while pull requests queue behind human review, so a
  slow week does not blind the experiment.

Distinct filenames mean the branch never conflicts. It can be merged to `main`
whenever, or never.

The branch is created once, at implementation time, as an orphan branch holding
only `docs/loop-trials/` — not a branch of `main`. That keeps its history free
of code changes, so merging it into `main` later contributes records and nothing
else. A run that finds the branch missing must fail loudly rather than create
it, since a missing branch means something is wrong with the setup and silently
recreating it would scatter records across divergent histories.

## Boundaries

### What the agent may never touch

- **Its own guardrails** — `Scripts/loop-*.sh`, `Scripts/loop-prompt.md`,
  `orca.yaml`, `CLAUDE.md`. A loop that can rewrite the rules it is judged by
  will eventually rewrite them. It *may* add files under `docs/learnings/` with
  their index line; that is the compounding half, and it lands in a reviewed
  pull request.
- **Tests, to make them pass.** Already in `CLAUDE.md`; restated in the prompt
  because it is the highest-value rule and the easiest to rationalise away.
- **`main`.** Its own branch only. This is currently instruction-only, not
  structural: there is no branch protection on `main` today (the API returns
  404 for a branch protection rule, and the repository's one ruleset has
  `enforcement: disabled`). Enabling branch protection so this is enforced
  rather than merely instructed is a recommended action for the repository
  owner to take separately — it is a repository settings change, outside what
  this design or its implementation should do on its own.
- **Signing, the release path, `Engine/woof`'s vendor pin, and App Store
  metadata** — the never-agent-eligible list from spec 1.

### Structural rails

These hold without the agent's cooperation:

- One run at a time, by precheck construction — so two `xcodebuild` sessions can
  never share a simulator.
- A wall-clock budget the agent checks itself. Orca's `--timeout-ms` is accepted
  but does not fire (spike, step 3), so this rail is instructed, not structural —
  a hung run is caught after the fact by its record still reading `started`.
- A **separate 15-minute cap on waiting for CI and CodeRabbit**, which does not
  draw on the 45-minute work budget. The two are capped separately on purpose: a
  slow service must not consume the time the agent needs to do its job, and an
  unresponsive one must never park a run indefinitely.
- Three runs per day as the burn ceiling.
- A dedicated signing identity, so `git log --author` separates loop commits
  from the owner's for free.
- Kill switch: `orca automations edit --disabled`, or `remove`. Worktrees are
  disposable; nothing else needs undoing.

### The agent identity

Loop commits are signed with a dedicated passphrase-less SSH signing key under
its own committer name and email, held outside 1Password. Two reasons: 1Password
signing prompts intermittently hang, which would stall an unattended run with no
one to dismiss the dialog; and a distinct author makes `git log --author` a
free, exact separator between loop work and the owner's.

The key signs only. Push authentication stays whatever the checkout already
uses, so the loop gains no capability the owner's own shell does not already
have — it is a provenance mechanism, not a permission grant.

### Claiming, and its failure mode

The claim is the `agent:in-progress` label. The precheck also excludes issues
with a linked open pull request, because the owner is the merge gate and work
pull requests sit unmerged for a while — without that exclusion a later run
would re-pick an issue already done.

A run that dies between labelling and cleanup would leave the claim stuck
forever, silently shrinking the backlog. So the precheck treats any
`agent:in-progress` older than two hours — well past the agent's wall-clock
budget — as
stale, clears it, and records that it did.

Liveness is determined by the label, never by the presence of a worktree. A
worktree left behind for inspection must not be mistaken for a running job.

### Sweeping abandoned worktrees

`orca automations remove` does not delete the per-run worktrees Orca creates, and
neither can a run delete its own — the agent is executing inside it. At three
runs a day these accumulate.

The precheck therefore sweeps them at the **start** of a run, next to the
stale-claim sweep but on its **own, higher** threshold: `STALE_WORKTREE_SECONDS`
(4h) rather than the stale-claim sweep's `STALE_CLAIM_SECONDS` (2h). Any
`auto-waddle-loop-*` worktree older than that is removed, and every removal is
logged. Start-of-run is the only workable moment. A run that crashes cannot
clean up by definition, so end-of-run cleanup only ever fires in the case where
there was nothing to clean. Sweeping cannot strand a pull request: the loop
pushes its branch to `origin` long before any worktree is old enough to
qualify.

The two thresholds are deliberately different, not shared. Section 4 (waiting
on CI and CodeRabbit, then fixing across up to three rounds) roughly doubled
how long a live run can take — 45 minutes of work, plus up to 15 minutes
waiting on CI/CodeRabbit, plus up to three rounds at up to 900 seconds each,
a worst case of about 105 minutes. The worktree sweep, unlike the stale-claim
sweep, has no independent signal of liveness: a worktree's name encodes only
its run's *start* time, so worktree age is run age, full stop. A threshold that
merely cleared the old 45-minute work budget would risk `orca worktree rm`-ing
a still-running agent's own worktree out from under it. `STALE_WORKTREE_SECONDS`
is set well above the ~105-minute worst case instead, with real margin rather
than a bare majority.

## Instrumentation

### The trial record

| Field | Notes |
| --- | --- |
| Run id, timestamp | |
| **Prompt version** | Git SHA of `Scripts/loop-prompt.md` at run time |
| Issue number, `kind`, `size` | |
| Outcome | `started`, `pr-opened`, `failed-verification`, `no-repro`, `stuck` |
| Wall clock | Self-timed by the agent; Orca exposes no turn or token count |
| Verification command, result | The issue's own command, run unmodified |
| Pull request number | If one was opened |
| Learnings file added | If any |
| `ci_result` | `pass`, `fail`, `timeout`, or `not-run` — CI on the run's own pull request, resolved independently of the review |
| **`coderabbit_findings_first`** | Major/Critical count **before any fix**, or `none` (the wait cap expired before an answer) or `unavailable` (CodeRabbit reported a terminal non-review state, e.g. rate-limited, and will not review). The leading signal. |
| `coderabbit_findings_after` | Same count after the fix phase, or `none` if no fixes were attempted |
| `fix_rounds` | How many CI/review fix passes the agent made |

The prompt version is the independent variable. Without it, a change in success
rate is unattributable and the experiment answers nothing.

`started` is not a terminal outcome. It is written before the work begins and
overwritten at the end; a record still reading `started` means the run died
mid-flight. `timeout` was dropped from the enum because nothing enforces a
timeout — a hung run presents as `started`, which is the honest description.

### The success metric: a leading and a lagging signal

**Leading** — arrives within minutes, graded, automatable, and what the prompt
is tuned against:

- **`coderabbit_findings_first`** — the Major/Critical count on the run's pull
  request, snapshotted **before the agent fixes anything**. This repository's
  CodeRabbit prefixes every review comment with a
  `_<category>_ | _<severity>_ | _<effort>_` triple, so the agent computes it as
  `grep -c '🟠 Major\|🔴 Critical'` over
  `gh api repos/{owner}/{repo}/pulls/<N>/comments --jq '.[].body'`. A plain count
  of all review comments is the fallback if that format ever changes.
  **The report must read this field from the record, never query GitHub live** —
  since the agent now fixes findings, a live query returns post-fix counts and
  would report zero for every run while appearing perfectly healthy.
- Whether the issue's own stated verification passed **unmodified**.
- `ci_result` on the run's own pull request.

**Lagging** — slow, authoritative, low volume, and not used for tuning: a pull
request merged without requiring changes. Its job is to check that the leading
signal tells the truth.

A single lagging metric was rejected: it is gated on the owner's availability,
so a busy fortnight stalls the experiment, and it is binary and late, so with 19
issues there are too few data points arriving too slowly to tune anything.

**Divergence between the two is a finding, not noise.** If CodeRabbit runs clean
while the owner keeps rejecting the work, that gap measures precisely what
automated review cannot see on this codebase. Spec 1 already hints at it:
CodeRabbit passed PR #35, and human-directed review still found a guard that
failed open and four issues whose verification commands could not run. Neither
signal alone caught that.

### The report

`Scripts/loop-report.sh` walks the trial records and prints exactly this: total
trial count and an outcome breakdown; per prompt version, the trial count, PRs
merged without requiring changes, and the CodeRabbit Major/Critical total; the
lost-trial list (records still reading `started`); and the stuck pile. It is the
artifact the experiment exists to produce.

**It reads `coderabbit_findings_first` from each record. It must not query
GitHub for that count.** The agent now fixes Major/Critical findings before the
run ends, so a live query returns post-fix numbers — the report would print zero
findings for every trial and give no outward sign anything was wrong. The live
query survives only as a fallback for records written before this field existed;
those records are identifiable by its absence and should be reported as such
rather than silently scored as zero. Merge state is still queried live, because
that genuinely changes after the run and no snapshot could capture it.

Every trial record also carries `verification_result`, `size`, `kind`,
`wall_clock_seconds`, `ci_result`, `coderabbit_findings_after`, and
`fix_rounds` (see the instrumentation table above). Those fields are captured
for later analysis; the report does not currently segment by `size` or `kind`,
nor does it compute a median wall clock, or read `verification_result`,
`ci_result`, or `fix_rounds` at all. `coderabbit_findings_after` in particular
is written by the protocol and read by nothing. That is a known gap between
the ambition of this section and what is implemented, called out here rather
than left for the report and this document to quietly disagree.

## Risks

**Root-checkout engine drift would look like agent failure.** Seventeen of the
19 backlog issues need `mise run bootstrap`. The `orca.yaml` hook makes that
about a minute *only while the root checkout's `Vendor/out` is fresh*, since
every worktree clones from it. If the root checkout goes stale, every run
inherits stale bits, `Scripts/check-engine-fresh.sh` fails closed, and each run
spends ~25 minutes rebuilding inside a 45-minute budget. The result is a run of
timeouts that look like agent failures and are actually the owner's checkout
drifting. Mitigation: the precheck asserts engine freshness in `ORCA_ROOT_PATH`
and skips the run with an explicit reason when stale.

**`--precheck` does not gate a manually triggered run.** The spike found that
`orca automations run <id>` skips the precheck entirely, for both a failing and a
passing command, leaving `precheckResult: null`. Whether it gates a *scheduled*
run was not established. Since the rollout deliberately begins with manual runs,
the gate cannot live there. Mitigation: the agent runs
`Scripts/loop-precheck.sh` itself as its first action and stops on refusal, which
behaves identically for manual and scheduled fires. Passing `--precheck` as well
is harmless belt-and-braces, but nothing depends on it.

**Precheck stdout does not reach the agent.** Pass-through could not be observed,
so the agent re-runs the selection itself rather than trusting an unverified
channel. The precheck is therefore idempotent and safe to run twice, with one
exception noted below.

**The stale-claim sweep is a side effect in otherwise pure logic.** Because the
agent runs the precheck itself, a sweep that clears a stale
`agent:in-progress` label happens during selection. That is acceptable — clearing
a dead run's claim is correct however often it happens — but it means the
precheck is not purely a query, and anything that runs it (including a human
debugging) may mutate labels. It logs every sweep to stderr for that reason.

**Orca leaves worktrees behind.** `orca automations remove` does not delete the
per-run git worktree and branch it created under `new-per-run`. The spike found
and cleaned two orphans by hand. Left unattended these accumulate at three per
day, so cleanup is explicit rather than assumed.

**A pull request left mid-review by section 4 has no path back into the
loop.** The wait-snapshot-fix phase (`Scripts/loop-prompt.md`, section 4) acts
only on the pull request the run that opened it is still executing inside. A
run that times out waiting on CI/CodeRabbit (4.1's 900-second cap) or dies
during the fix phase (4.3) leaves that pull request exactly where CodeRabbit
left it, findings and all — and no later run can resume the work, because the
precheck excludes any issue with a linked open pull request from selection
(see "Claiming, and its failure mode" above). That issue stays off the backlog
for as long as the pull request stays open. Verified concretely against the
live backlog: PR #55, open and declaring `Closes #13`, causes the precheck to
select issue #15 instead of #13, even though #13 would otherwise win the
size/number tie-break. Such a pull request depends entirely on the owner from
that point forward; closing it unmerged is what returns its issue to the pool.

**A rate-limited reviewer yields a trial with no leading signal, by design.**
CodeRabbit can report itself rate-limited as a check status — observed live on
PR #57, `gh pr checks 57` showing `CodeRabbit  pass  Review rate limited` —
without ever creating a review object. A poll that waited on the review count
alone would sit at 0 forever and burn the full 15-minute cap for an answer that
had already arrived, while a poll that treated CI and the review as one gate
would falsify a CI result that had nothing wrong with it: in the observed
case, CI passed in 6m8s and the run still recorded `ci_result: timeout`
because the review never resolved. `Scripts/loop-prompt.md` section 4.1
resolves CI and the review independently for exactly this reason, and treats
CodeRabbit's own terminal non-review state as an answer rather than a pending
one — recording `coderabbit_findings_first: unavailable` and moving on rather
than waiting for CodeRabbit to recover. The owner's ruling is that this is the
correct outcome, not a gap to close: a rate-limited review means the trial has
no leading signal, full stop, and the run must not wait for one, retry, or
treat the missing signal as a reason to discard an otherwise legitimate
`pr-opened` result with a passing CI run. `unavailable` is scored identically
to `none` by `Scripts/loop-report.sh` — excluded from the findings total,
reported on its own line, never queried live — but recorded as a distinct
value so a report reader can tell "the cap expired" apart from "the reviewer
declined."

**Prompt regressions** show as a step change in the report, because every record
carries the prompt SHA. This is the reason the SHA is recorded rather than a
hand-maintained version string.

**Backlog exhaustion is the graceful end.** Nineteen issues at three runs a day
is roughly a week. After that the precheck exits non-zero every time and nothing
is spent. That is when the report gets read.

## Verification

`Scripts/loop-precheck.sh` gets a hermetic self-test in the style of
`Scripts/test-check-substrate.sh` — a stub `gh`, fixture issue lists, no network
— covering selection order, every exclusion rule, the stale-claim sweep, and the
engine-freshness refusal. It is pure logic, cheap to test properly, and the
component most able to misbehave silently. `Scripts/loop-report.sh` gets one
too, against fixture records.

A dry-run mode proves the record path and the `loop-trials` push with the agent
instructed to select an issue, write both phases of its trial record, and stop
without editing any file or opening a pull request.

The first three trials are run manually via `orca automations run` and watched.
The schedule is enabled only after those land clean.

**Done means:** after a handful of trials, `Scripts/loop-report.sh` prints a
success rate segmented by prompt version, and the question "did this help?" is
answerable from data rather than impression.
