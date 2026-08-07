# Agent Loop: Unattended Single-Item Runs — Design Spec

**Date:** 2026-08-07
**Status:** Designed, not implemented.
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
- The counterweight literature on runaway loops — hence the hard timeout, the
  runs-per-day ceiling, and a kill switch that is one command.

Yegge's [prescription](https://yegge.ai/essays/the-shape-of-things-to-come/) to
build orchestration "chemically bonded to your application" rather than adopting
a general harness is the one point this design consciously departs from, and the
departure is bounded: Orca supplies scheduling, per-run worktrees, and worker
supervision — all things a bash script would do badly — while the protocol
itself stays a versioned file in this repository.

## Architecture

Four tracked artifacts and one Orca object.

| Artifact | Role |
| --- | --- |
| `Scripts/loop-precheck.sh` | Decides whether a run happens, and which issue it takes |
| `Scripts/loop-prompt.md` | The protocol. The experiment's independent variable |
| `Scripts/loop-report.sh` | Aggregates trial records into a success rate |
| `docs/loop-trials/<date>-issue-<N>.md` | One record per trial, on the `loop-trials` branch |
| `orca automations` entry `waddle-loop` | Schedule, provider, fresh worktree per run |

### One run

1. **The automation fires** (three times daily) and the precheck runs first. It
   refuses when a run is already live, when the root checkout's engine is stale
   (see Risks), or when no issue is claimable. A refusal exits non-zero, the run
   is skipped, and nothing is spent.
2. **Selection.** From open `agent:eligible` issues, excluding any labelled
   `agent:in-progress` or `agent:stuck` and any with a linked open pull request.
   Ordered `size:xs`, then `size:s`, then `size:m`, tie-broken by ascending issue
   number. Deterministic, so a trial can be reproduced.
3. **Orca creates a fresh worktree** off `main` and runs the `orca.yaml` setup
   hook, which clones `Vendor/out` with its `.fingerprint` stamp — so the
   worktree starts engine-current and skips a ~25-minute rebuild.
4. **The coordinator** labels the issue `agent:in-progress` — the claim — and
   starts a supervised worker with a 45-minute hard timeout.
5. **The worker** reads the issue, does the work, runs *that issue's own*
   verification command unmodified, commits under the agent signing identity,
   pushes, and opens a pull request declaring `Closes #N`. If it hit a trap
   worth recording, it adds a `docs/learnings/` file and its index line in the
   same pull request.
6. **The coordinator** reads the worker's output and writes the trial record.
7. **Cleanup.** The claim label is removed. On failure, `agent:stuck` is applied
   and a comment left on the issue stating what was tried and where it stopped.

### Why the coordinator and worker are separate roles

If the agent doing the work also wrote the trial record, then a worker that
hangs or dies would leave no record — and those are precisely the trials worth
studying. An experiment that silently drops its failures reports a success rate
that means nothing. Separating the roles means a fenced or timed-out worker is
still recorded, honestly, as a timeout.

This is the same generator-never-judges rule spec 1 applied to code review,
applied here to measurement.

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

### What the worker may never touch

- **Its own guardrails** — `Scripts/loop-*.sh`, `Scripts/loop-prompt.md`,
  `orca.yaml`, `CLAUDE.md`. A loop that can rewrite the rules it is judged by
  will eventually rewrite them. It *may* add files under `docs/learnings/` with
  their index line; that is the compounding half, and it lands in a reviewed
  pull request.
- **Tests, to make them pass.** Already in `CLAUDE.md`; restated in the prompt
  because it is the highest-value rule and the easiest to rationalise away.
- **`main`.** Its own branch only. Branch protection should enforce this rather
  than leaving it instructed.
- **Signing, the release path, `Engine/woof`'s vendor pin, and App Store
  metadata** — the never-agent-eligible list from spec 1.

### Structural rails

These hold without the agent's cooperation:

- One run at a time, by precheck construction — so two `xcodebuild` sessions can
  never share a simulator.
- A 45-minute timeout enforced by Orca, not by the agent's own judgment.
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
`agent:in-progress` older than two hours — well past the 45-minute timeout — as
stale, clears it, and records that it did.

Liveness is determined by the label, never by the presence of a worktree. A
worktree left behind for inspection must not be mistaken for a running job.

## Instrumentation

### The trial record

| Field | Notes |
| --- | --- |
| Run id, timestamp | |
| **Prompt version** | Git SHA of `Scripts/loop-prompt.md` at run time |
| Issue number, `kind`, `size` | |
| Outcome | `pr-opened`, `failed-verification`, `timeout`, `no-repro`, `stuck` |
| Worker wall clock, turn count | |
| Verification command, result | The issue's own command, run unmodified |
| Pull request number | If one was opened |
| Learnings file added | If any |

The prompt version is the independent variable. Without it, a change in success
rate is unattributable and the experiment answers nothing.

### The success metric: a leading and a lagging signal

**Leading** — arrives within minutes, graded, automatable, and what the prompt
is tuned against:

- Count of CodeRabbit findings at Important-or-above on the run's pull request.
  CodeRabbit already reviews every pull request in this repository, so this
  costs nothing to collect.
- Whether the issue's own stated verification passed **unmodified**.

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

`Scripts/loop-report.sh` walks the trial records, queries each pull request's
current state via `gh`, and prints success rate segmented by prompt version, by
`size`, and by `kind`, plus median wall clock and the current stuck pile. It is
the artifact the experiment exists to produce.

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

**The Orca composition is unverified.** It is not established that an
automation-launched agent session can itself call
`orca orchestration worker-start`, nor that this composes cleanly with
`--workspace-mode new-per-run`. Implementation task 1 is a spike proving it. If
it does not compose, the documented fallback is a single automation whose agent
does the work and writes its own record, with the precheck stamping a run-start
marker so an unfinished stamp still registers as a failed trial.

**The CodeRabbit severity parse may be brittle.** Extracting a clean
Important-or-above count from its comment format is unproven; the same spike
validates it, falling back to a raw comment count.

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

A dry-run mode proves the record path and the `loop-trials` push using a no-op
worker, without doing real work.

The first three trials are run manually via `orca automations run` and watched.
The schedule is enabled only after those land clean.

**Done means:** after a handful of trials, `Scripts/loop-report.sh` prints a
success rate segmented by prompt version, and the question "did this help?" is
answerable from data rather than impression.
