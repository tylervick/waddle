# Agent Substrate: Durable Backlog & Compounding Learnings — Design Spec

**Date:** 2026-08-06
**Status:** Designed, not implemented.
**Successor:** Spec 2 (unattended single-item loop) — to be written after this
ships and has been used.

## Problem

WADdle's backlog and its hard-won technical knowledge are invisible to anyone
starting from a fresh clone.

The backlog lives in `.superpowers/sdd/progress.md` — 98 lines carrying roughly
25 deferred items accumulated across Plans 1–4, everything from `sigemptyset`
pedantry and the missing `ZipExtractor` per-entry size cap through to absent
`sha1(of:)` and `allLoadouts` sort tests. That file is gitignored by
`.superpowers/sdd/.gitignore`, which contains only `*`. It exists on exactly one
machine.

The knowledge is worse off. Facts that cost real debugging time — that
`SDL_SetMainReady()` must precede the first `SDL_Init`, that orientation support
needs both the Info.plist entries *and* `SDL_HINT_ORIENTATIONS`, that a
`UITapGestureRecognizer` silently never fires inside SDL's directly-owned
`UIWindow` — live in a per-user memory store outside the repository. The repo
has no `CLAUDE.md` and no `AGENTS.md`; `.claude/` is gitignored too. A
contributor, or an agent, sees none of it.

The result is that the only machine-visible work surface is four open GitHub
issues, and every session rediscovers the same traps.

## Scope

**In:** extraction of the deferred-item ledger into labelled GitHub issues; a
required issue format and the GitHub issue template that enforces it; a label
taxonomy extending the existing labels; a tracked `CLAUDE.md`; `docs/learnings/`
with an index; `Scripts/check-substrate.sh` and its self-test; wiring that check
into `ci.yml`.

**Out, deferred to Spec 2:** the runner script, launchd scheduling, the
dedicated agent signing key, prompt versioning, and trial records. This spec
builds the substrate those things will stand on and defines the interface
between them, nothing more.

**Out, deliberately:** adopting [beads](https://github.com/gastownhall/beads) or
any other dedicated agent-issue tracker. Two thirds of the intended work surface
(Renovate's dependency dashboard, CodeRabbit review findings) already lives on
GitHub, and a second backlog would mean reading from two places. The seam
defined below keeps that swap cheap if it ever looks worthwhile.

## Research basis

This design follows a survey of current practice in long-running agentic loops.
Three findings changed it, and are cited inline where they apply:

- Anthropic's [harness guidance](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)
  — agents mark work complete without verifying it unless each item carries an
  explicit, checkable definition of done; and the call that generates work must
  not be the call that judges it.
- Every's [compound engineering](https://every.to/chain-of-thought/compound-engineering-how-every-codes-with-agents)
  — the step that makes a loop compound rather than merely repeat is writing
  each review finding back into the repository as a durable rule.
- Huntley's [Ralph](https://ghuntley.com/ralph/) — progress must accumulate in
  files and git, never in a context window, and quality is a function of how
  hard the project's checks push back.

The counterweight literature on runaway loops and cost overruns applies to
Spec 2, not here; this spec adds no automation that can run away.

## Component 1: the backlog

### Triage

Each ledger item is classified as still-valid, already-fixed, or won't-fix.

Classification is by reproduction against current code, not by reading the
ledger. The ledger spans four plans; its file:line citations have drifted, and
several items were closed incidentally by later work without being struck off.
An item that cannot be reproduced is recorded as unreproducible and closed
rather than filed on suspicion.

This matters more than it looks. Issues filed for bugs that no longer exist
would consume the loop's first trials chasing ghosts, and the resulting failure
rate would be attributed to the loop rather than to the backlog.

### Issue format

Every issue labelled `agent:eligible` carries three things, as three literal
level-2 headings in the issue body so the check below can be mechanical rather
than heuristic:

- `## Definition of done` — one sentence naming the specific condition that must
  become true. Not "fix the size cap" but "`ZipExtractor` rejects any entry
  whose uncompressed size exceeds the cap, and a test proves it."
- `## Verification` — the exact command that demonstrates it, in a fenced code
  block: either `mise run test` or a narrower `-only-testing:` filter.
- `## Provenance` — the plan and review that deferred the item, so the ledger's
  surrounding context survives extraction.

The first two exist because an agent with no explicit completion condition
reports success on incomplete work. The third exists because the ledger is
staying gitignored.

`.github/ISSUE_TEMPLATE/agent-eligible.md` ships the three headings so a
hand-filed issue starts in the right shape. The template is a convenience; the
check, not the template, is what enforces the format.

### Labels

The repository already uses `bug`, `enhancement`, and `documentation`. Those
stay. Added:

| Label | Meaning |
| --- | --- |
| `agent:eligible` | May be claimed by an unattended run |
| `agent:blocked` | May not, with the reason stated in the issue |
| `test`, `chore`, `deps` | Kinds not covered by the existing three |
| `size:xs` | One file plus one test |
| `size:s` | One module, no cross-cutting change |
| `size:m` | Crosses `Engine/`, or touches multiple modules |

Size exists to make trials comparable. The chosen work surface — ledger items,
open issues, and Renovate follow-ups — is deliberately heterogeneous, and
without a size marker a failed dependency bump and a failed unit test are
indistinguishable in the record.

### Never agent-eligible

These get `agent:blocked` with the reason recorded:

- Anything requiring a physical device, including the touch-tuning defaults
  still awaiting on-device values
- App Store Connect work (#28) — owner-only by construction
- Screenshot capture and metadata judgment
- Engine vendor re-pins, which carry GPL provenance obligations
- Anything touching code signing or the release path

### The ledger stays gitignored

Extraction is one-time. GitHub issues become the sole forward home; future
reviews file issues directly rather than appending to `progress.md`. Provenance
lines mean nothing is lost if that file disappears.

Tracking `.superpowers/` was considered and rejected: it would pull
superpowers-internal churn into the repository for no gain, since the content
worth keeping is exactly what triage is about to extract.

## Component 2: the learnings

### `CLAUDE.md`

Tracked, at repository root, deliberately thin — only rules that are always true
and always relevant. Seed content, all of it already paid for in debugging time:

- Never run two `xcodebuild` test sessions against one simulator concurrently
- The Woof pin is master `798acebd`; SDL2-era tags such as `woof_15.3.0` must
  never be used
- The engine save flag is `-save`, not `-savedir`
- `woof.pk3` sits at the app bundle root
- The GameData folder reference must not be named "Resources"
- Conventional-commit style, matching existing history
- Never edit or delete a test to make it pass
- The verification command
- A pointer to `docs/learnings/INDEX.md`

Hard cap: if `CLAUDE.md` exceeds 50 lines, content moves to `docs/learnings/`. A
file of equally-weighted rules stops being read.

### `docs/learnings/`

One fact per file. Each states what the trap is, how it was discovered — naming
the PR or commit — and what to do instead.

Initial population is transcription rather than invention, drawn from
`progress.md` and the existing per-user memory store. Expected content covers
the engine and build traps, the iOS 26 UI idiosyncrasies (TabView tab-bar
buttons never receiving accessibility identifiers; List swipe-action layout
varying with row height), the worktree traps (the `Vendor` symlink that
`.gitignore` does not match, and `Vendor/build`'s CMakeCache hardcoding another
checkout's path), and the SDL findings (`SDL_SetMainReady`, the SIGTERM bracket,
orientation needing both halves, gesture recognizers not firing in SDL's
window). Roughly 12–15 files.

`docs/learnings/INDEX.md` carries one line per learning in the form
`- [Title](file.md) — hook`, matching the shape already proven in the per-user
memory index.

### Two rules that make it compound

**Authorship.** A learning is drafted by whoever hit the trap, human or agent,
and lands only through a pull request. Bad lessons get vetoed before they
calcify. The party that produced the work never ratifies its own lesson.

**Promotion.** Prose is the fallback. A learning that can be an executable check
becomes one — `Scripts/check-engine-fresh.sh` and
`Scripts/test-engine-fingerprint.sh` are existing instances of exactly this —
and the learning file then points at the check rather than restating it.

### Boundary with the per-user memory store

The two would otherwise overlap and drift apart:

- Repository-specific technical facts → `docs/learnings/`. Public, shared,
  reviewable in a diff.
- User preferences, session state, and cross-project context → the per-user
  memory store.

WADdle technical facts currently held in per-user memory are migrated, not
duplicated. A fact in both places will eventually disagree with itself.

## The seam

Spec 2 touches this substrate at exactly two points.

**Read:** `gh issue list --label agent:eligible --state open --json …`. Each
returned item carries its own definition of done and verification command, so
the runner needs no per-item knowledge.

**Write:** a new file under `docs/learnings/` plus one index line, in the same
pull request as the fix that produced it.

Holding the interface to those two points is what keeps both the beads swap and
outright abandonment cheap.

## Verification

The substrate is issues and documentation, so its checks are structural. Per the
promotion rule they are executable rather than a convention.

`Scripts/check-substrate.sh` asserts:

1. Every open `agent:eligible` issue body contains all three required headings,
   `## Definition of done`, `## Verification`, and `## Provenance`, each with a
   non-empty section beneath it. This requires network and an authenticated
   `gh`, so it skips cleanly — reporting the skip, exiting zero — when no token
   is available. CI must not fail for a missing token.
2. `docs/learnings/INDEX.md` has exactly one entry per file in
   `docs/learnings/`, and no entry pointing at a missing file.
3. `CLAUDE.md` is within the 50-line cap.

`Scripts/test-check-substrate.sh` is its self-test, following the pattern of
`test-check-engine-fresh.sh` and `test-engine-fingerprint.sh`. Both run in
`ci.yml`'s existing "Verify the build-script helpers" step, which already
executes the other three script self-tests before the build.

**Done means:** a fresh clone plus `gh issue list --label agent:eligible` yields
a non-empty list of items each independently actionable by someone with no prior
context, and `check-substrate.sh` passes in CI.

## Risks

**Triage is the expensive part and the easiest to rush.** Reproducing ~25 items
against current code is slower than transcribing them. Rushing it produces a
backlog that looks healthy and is partly fiction. Mitigation: unreproducible is
an acceptable and recorded outcome — the goal is a true backlog, not a large
one.

**Size labels will be wrong at first.** A `size:xs` item that turns out to be
`size:m` corrupts the trial comparison Spec 2 depends on. Mitigation: size is
re-assessed and corrected at PR time. Systematic underestimation is itself a
finding worth having.

**Learnings rot, and a false learning is worse than none** because it is
followed with confidence. Mitigation: each file records the commit or PR it came
from, making staleness checkable; and any learning contradicted during work must
be corrected in the same PR that found the contradiction.

**The substrate may outlive its purpose.** If Spec 2 is never built or is
abandoned, `CLAUDE.md` and `docs/learnings/` still earn their place for human
contributors, and the issues are the backlog either way. Nothing here is
load-bearing only for the loop.
