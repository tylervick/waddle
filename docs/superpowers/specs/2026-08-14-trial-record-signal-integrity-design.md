# Trial-record signal integrity

**Status:** diagnosis, with a proposed order of work. No implementation yet.
**Date:** 2026-08-14
**Issues:** #71, #145, #146, #147 — all owner-only.

## Why this document exists

Four defects were found on 2026-08-14, in four different places, by four different
routes. Filed separately they read as unrelated maintenance. Read together they are
one failure, and the shared shape is worth stating once rather than four times:

> **Every one of these fields reports a measurement that was never taken, in a form
> indistinguishable from one that was.**

That is the property the loop's whole experiment rests on. `docs/superpowers/specs/
2026-08-06-agent-substrate-design.md` states the premise — *"an agent with no
explicit completion condition reports success on incomplete work"* — and the trial
record exists to hold the loop to a completion condition it cannot fake. A record
that says `0` when nothing was measured is the same defect one level up, committed
by the instrument instead of the agent.

None of this makes the loop's *work* wrong. Every pull request it opened was
reviewed by a human before merge. What is wrong is the evidence we would use to
decide whether the loop is working, and in which direction to tune it.

## The audit

| Field | What it appears to say | What is actually true | Issue |
|---|---|---|---|
| `outcome: started` | this run died before finishing | also the value of a run that is *still running* | #145 |
| `outcome: started` (recovery) | uniquely identifies this run's record | collides with any stranded record for the same issue | #146 |
| `coderabbit_findings_first` | a review happened and found this many | nobody ever asked for the review | #147 |
| reconciled `0` in the report | reviewed, found nothing Major/Critical | never reviewed; zero comments is what absence looks like | #71 |

### #145 — an in-flight run is reported as dead

`Scripts/loop-report.sh:154` classifies every record still at `outcome: started` as a
lost trial, under a heading asserting the run "died before recording an outcome". A
record carries `started` from §2 until §5 rewrites it, so a healthy run in progress is
byte-identical to a corpse.

Measured 2026-08-14T18:31:39Z, while run 34 was actively working on #124:

```
LOST TRIALS (run died before recording an outcome): 41 124
stuck pile (needs human triage): 68 14 124
```

#124 appears in both lists at once, and the run it claims died went on to finish
normally as `pr-opened` with PR #144. The distinguishing evidence exists outside the
record — #41 has no `agent:in-progress` claim, #124 had one.

### #146 — the recovery rule assumes uniqueness it does not have

`Scripts/loop-prompt.md` §5 tells a run that lost its `<RUN_TS>` literal that its
record is *"the only file matching `docs/loop-trials/*-issue-<ISSUE>.md` […] whose
frontmatter still reads `outcome: started`"*. A previous run that died at `started`
falsifies that. Issue #41's stranded record is the live precondition today.

Narrower than the others — it is a fallback, and the primary path (`<RUN_TS>`) is
sound. It earns its place here because it fails in the most expensive way available:
a run could rewrite the dead record with its own outcome, erasing the only trace a
run ever died while stranding its own record at `started` — manufacturing a fresh
phantom lost trial in the same move.

### #147 — nobody asks for the review

All seven `coderabbitai` references in `Scripts/loop-prompt.md` are reads or
allowlists. Nothing posts `@coderabbitai review`. CodeRabbit stopped reviewing
repositories under 10 stars automatically; `tylervick/waddle` has 1. Its notice on
PR #144:

> Reviews should be triggered manually for repositories with fewer than 10 stars.

So §4.1 waits out its 900-second cap for a review that was never requested. Run 34
also found a **second** terminal string the protocol does not name — `Review skipped:
manual review required for this OSS repository`, distinct from the `Review rate
limited` §4.1 matches on — and flagged it in its own record for whoever tunes the
detection.

Rate limiting remains a real and separate state. The two must not be collapsed:
"try again later" and "this repo requires a manual trigger, permanently" call for
opposite responses.

### #71 — reconciliation fabricates the zero

`Scripts/loop-report.sh:354-378` gates its live query on `fix_rounds: 0` plus
all-agent commit authorship. **Nothing in that gate proves a review ever happened.**
It then live-queries for Major/Critical comments, finds none, and counts a real `0`.

Run 35 reproduced this at HEAD and found the source comment states the wrong premise
outright — it claims an empty result is *"a PR CodeRabbit reviewed and found nothing
Major/Critical in — PRs #57 and #59's actual shape"*. Those PRs have **zero reviews
of any kind**.

## The compound failure

#71 and #147 are worse together than apart, and neither issue can see it alone.

Across all 24 PR-opening records: **13 `unavailable`, 8 `0`, 1 `none`, 1 `1`**, plus
one legacy blank. The records with no usable measurement — the 13 plus the 1 `none` —
number exactly **14**, and every one of them satisfies reconciliation's gate.

So the set of records reconciled into a real-looking `0` is precisely the set of
records where no review happened. #147 explains why there were no reviews;
#71 turns each absence into a number. **The report's CodeRabbit signal is very
nearly manufactured from absence in its entirety** — a conclusion neither issue
supports on its own, and which no single trial record could have revealed.

## What is sound, and must not be broken while fixing this

Fixing measurement bugs invites over-correction. These parts work and are not in
scope:

- **`test_proof_first` is the leading signal and it functions.** It replaced
  `coderabbit_findings_first` as the primary signal for exactly this class of
  reason (`2026-08-10-test-proof-signal-design.md`), and its `error` verdict already
  models "not measured" honestly rather than as a zero.
- **`ci_result`, `verification_result` and `outcome`'s terminal values are real.**
  They come from commands that actually ran.
- **The distinction between `none` and `unavailable` is already correct in §4.1's
  prose.** The vocabulary is right; what is missing is *why* the reviewer declined.
- **`loop-report.sh` counting records rather than issues is correct.** The unit is a
  trial. A re-attempted issue is genuinely two trials, and deduplicating by issue
  would hide the retries that matter most.
- **Refusing to live-query a snapshot field is correct**, and the reason is written
  into the script: a live query after the fact measures the fixed code, not the code
  reviewed. #71 is not an argument for querying more; it is an argument for querying
  only when a review provably happened.

## Proposed order

1. **#147 first.** It is the only one that changes what future records *contain*.
   Every run completed before it lands produces another ambiguous `unavailable`.
2. **#71 second**, and only after #147. Its correct fix is to require evidence a
   review happened before reconciling — evidence that #147 is what starts producing.
   Fixing #71 first means writing a gate against a signal that does not yet exist.
3. **#145 third.** Self-contained, hermetically testable, and the fix is a lookup the
   loop's own precheck already performs.
4. **#146 last.** Narrowest, and a fallback rather than a live path.

The historical records cannot be repaired, and should not be rewritten. The honest
remedy for the existing 14 is that the report should stop reconciling them, which
falls out of #71's fix.

## Non-goals

- **Do not widen #71 into a general reporting rewrite.** `Scripts/loop-report.sh` is
  a guardrail; the change should be the smallest one that stops fabricating.
- **Do not trigger reviews via CodeRabbit's checkbox.** It requires PATCHing another
  user's comment body and parsing an opaque `checkboxId` UUID, and races the bot's
  own edits. The comment form is documented by CodeRabbit and costs one call.
- **Do not make the red-green proof gate CI.** Settled in
  `2026-08-10-test-proof-signal-design.md`; a gating proof reads `proved` forever.
- **Do not hand any of this to the loop.** Every file involved —
  `Scripts/loop-report.sh`, `Scripts/test-loop-report.sh`, `Scripts/loop-prompt.md` —
  is on the never-modify list. Run 35 refused #71 on exactly these grounds in 150
  seconds, which is the system working.

## Provenance

Found 2026-08-14 across runs 32–35 and the owner session watching them. #145 was
measured live while run 34 was in flight and could not have been captured afterwards.
#147 originates in run 34's own trial record, which flagged the undocumented second
string. #71 predates the session; run 35 reproduced it at HEAD and widened its blast
radius from 3 PRs to 14 records. #146 was found while filing #145.

Two of these were found because a run wrote down something it was surprised by, in a
record nobody had asked it to justify. That is worth noting when weighing what the
narrative section of the trial record is for.
