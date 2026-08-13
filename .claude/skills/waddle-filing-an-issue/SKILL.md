---
name: waddle-filing-an-issue
description: Use when filing, drafting, revising, or reviewing a GitHub issue in the WADdle repo — including choosing between agent:eligible and agent:blocked, picking a size label, writing the Definition of done or Verification section, or fixing a red "Issue Format" workflow run.
---

# Filing an issue in WADdle

## Overview

Issues are this repo's only machine-readable backlog. `Scripts/loop-precheck.sh`
picks one; `Scripts/loop-prompt.md` §3 then hands the unattended run nothing but
`gh issue view <N>`. Whatever the issue does not say, nobody knows.

`docs/superpowers/specs/2026-08-06-agent-substrate-design.md` gives the reason
the format exists: *"an agent with no explicit completion condition reports
success on incomplete work."*

Read live examples before writing — they are the house style, not this file:
`gh issue view 72` (evidence-first bug), `gh issue view 64` (small, precise),
`gh issue view 84` and `gh issue view 93` (blocked, with the block justified).

If the issue is about adding or changing a `Scripts/check-*.sh` guard, the
`waddle-writing-a-guard-script` skill covers what the work itself must look like.

## The three required sections

`Scripts/check-issue-format.sh` fails if **any open `agent:eligible` issue** is
missing a non-empty section under each of these literal level-2 headings:

```
## Definition of done
## Verification
## Provenance
```

Mechanics worth knowing (all in that script):

- Matching is exact on the whole line `## <heading>`, after a trailing `\r` is
  stripped (so the web form's CRLF bodies behave like API-created ones). `###
  Verification`, `## Verification:` and `## verification` all read as *missing*.
- A section is "empty" only if it has no non-whitespace characters at all. So a
  **leftover template HTML comment passes** — `<!-- The exact command that
  demonstrates it. -->` is non-whitespace. The check is a floor, not a standard;
  it cannot tell you the section says anything. Delete the comments and write
  the content.
- Only `agent:eligible` is checked. `agent:blocked` issues are not — but #84 and
  #93 carry all three anyway, because the format is what makes an issue usable,
  not just what makes CI green.

**Where it runs:** `.github/workflows/issue-format.yml`, on `issues`
(`opened`, `edited`, `labeled`, `reopened`), plus a weekly backstop
(`cron: "0 6 * * 1"`) and `workflow_dispatch`. It is deliberately *not* in
`ci.yml` — a malformed issue used to redden `main` and every open PR with an
error the PR author had no permission to fix. So a malformed issue now reddens
the **Issue Format** workflow, and stays red on every subsequent issue event
until the body is fixed. That workflow also fails on a `skip - ` line, so the
job cannot go green having checked zero issues.

Start from `.github/ISSUE_TEMPLATE/agent-eligible.md`, and verify your own draft
before filing rather than trusting the workflow to catch it: paste the body into
a file and run the same extraction the check runs, or just confirm all three
headings are present verbatim at level 2.

## Evidence first: quote the measurement, don't assert the problem

The strongest issues in this repo paste output rather than describing a
condition. This is the single largest difference between a good and a bad issue
here.

| Issue | What it pastes |
|---|---|
| #93 | The live "What to Test" text read back from App Store Connect for build 210 — all ten bullets — then counts how many concern a tester (two). |
| #84 | `build 207 shipped from 906c2bce5`; `HEAD was a8c45a5, 55 commits later`; running the script produced 13 bullets, none in build 207. |
| #72 | Timestamps proving the mitigation ran and still lost: worktree 20:09:21, `Vendor/build` mtime 20:12:29, xcodeproj written 20:14:33, agent still hit stale caches minutes later. Names both trials that paid the cost. |
| #64 | The literal wrong string the user sees: `Used by: Sunlust MP, Eviternity. Remove it from those presets first.` |

Rules that follow from those:

- Name the file and the line or the symbol. #84 quotes `BODY="$(changelog
  "$TAG..HEAD")"` — one line of code is often the whole issue.
- Date the measurement ("Measured 2026-08-12") and say what you ran.
- State the wrong output **and** what makes it wrong. "13 bullets" is data;
  "none of which are in build 207" is the finding.
- Say why it matters in consequences, not adjectives: a wrong changelog "would
  tell a tester to exercise features their build does not contain."
- Name the mitigation that already exists and failed, if there is one — #72's
  whole argument is that `orca.yaml`'s `rm -rf` runs and loses a race.

If you cannot reproduce it, say so and file it as a question or don't file it.
The substrate spec's triage section: an item that cannot be reproduced is
recorded as unreproducible rather than filed on suspicion, because a backlog of
ghosts makes the loop look broken when the backlog is.

## `agent:eligible` or `agent:blocked`

This is the judgement call people get wrong. Three questions, in order.

**1. Does the work touch a path the loop is forbidden to change?**
**Open `Scripts/loop-prompt.md` → "Rules that are absolute" and read the list
there.** It is edited as the loop learns; do not trust any copy of it, this one
included. The stable shape:

- The loop's own guardrails: `Scripts/loop-precheck.sh`,
  `Scripts/loop-report.sh`, `Scripts/loop-prompt.md`,
  `Scripts/check-substrate.sh`, `Scripts/check-issue-format.sh`,
  `Scripts/test-loop-precheck.sh`, `Scripts/test-loop-report.sh`, `orca.yaml`,
  `CLAUDE.md`.
- Anything under `.github/workflows/` — a workflow it added would execute on its
  own pull request. **Consequence:** an issue that adds a new
  `Scripts/check-*.sh` guard cannot also wire it into `ci.yml`. Either say in
  the Definition of done that CI wiring is the owner's follow-up, or file it
  `agent:blocked`. **Do not copy #80 here** — it is `agent:eligible` today and
  asks for both "Wire it to a `schedule:` workflow" and "Register the new suite
  in the `Verify the build-script helpers` step of `.github/workflows/ci.yml`".
  As filed, the loop cannot finish it. It is the live example of this mistake,
  not a model.
- Signing configuration, `Engine/woof`'s vendor pin, App Store metadata,
  `mise.toml`, and **adding any dependency** — pinning or locking a toolchain
  version counts; check before assuming it does not.
- The release path, which is **split, not blanket-forbidden** — the signing and
  upload scripts are forbidden, the notes assembler is not. Read the current
  split rather than guessing.
- Existing `docs/learnings/` files may be **added to**, never rewritten or
  deleted.

`docs/superpowers/specs/2026-08-06-agent-substrate-design.md` → "Never
agent-eligible" adds: anything needing a physical device, App Store Connect work,
screenshot capture and metadata judgement, engine vendor re-pins (GPL provenance).

**2. Can a pull request verify it before merge, or does the first real test
happen in production?** This is the criterion the whole taxonomy rests on —
`Scripts/loop-prompt.md` states it outright: *"The line is drawn at whether a
pull request can verify the change before it merges."* It is why the release
path splits: the notes assembler has a hermetic suite plus a `--print` smoke in
`ci.yml`, so its worst case is wrong words the owner reads before merging; the
upload and signing scripts are exercised by nothing on a pull request
(`testflight.yml` is `workflow_dispatch`-only), so their first real test is a
live release.

#84 and #93 turn on the same question and land the other way. Both are
hermetically testable in principle — and both are blocked, because the artefact
they produce goes to real TestFlight testers and "a wrong result costs a build
number to correct." #93 states the reasoning to copy: opening it up later "would
be defensible — but as a deliberate decision, not an accident of labelling."

**3. What does a wrong result cost?** A wrong string in a Library alert (#64) is
caught in review and costs nothing. A wrong changelog is already in testers'
hands. Weigh the cost of the *undetected* wrong result, not the likely one.

**What is NOT a reason to block:** "the loop might get it wrong." The loop never
merges its own work — `Scripts/loop-prompt.md` forbids `gh pr merge` and any
push to `main`; the owner is the merge gate on every run. A plausible-but-wrong
pull request costs a review, which is the same thing any contribution costs.

**State the call either way, at the end of Provenance.** The `agent:blocked`
label's own description is "Needs a human; reason stated in the issue" — #84 and
#93 each end with a "Blocked for the loop: …" paragraph naming the reason and
the sibling issues that share it. Write the symmetric paragraph when you mark
something `agent:eligible`: what lands, that none of it is a protected path, and
that a pull request verifies it before merge. It is one sentence, and it is what
lets a reviewer check the call instead of re-deriving it.

## Size labels change what the loop attempts first

`size:xs` (one file plus one test) · `size:s` (one module, no cross-cutting
change) · `size:m` (crosses `Engine/`, or touches multiple modules).

`Scripts/loop-precheck.sh` §5 ranks `size:xs`=0, `size:s`=1, `size:m`=2, and
**anything with no size label = 3**, then tie-breaks on ascending issue number,
and takes the minimum. So:

- An unlabelled issue sorts behind every labelled one — leaving the size off is
  not neutral, it is deprioritising.
- Selection is deterministic. The same issue is re-picked every run until
  something changes.
- Excluded from selection: `agent:stuck`, a live `agent:in-progress` claim, and
  any issue whose number appears as `closes|fixes|resolves #N` in an **open** PR
  body.

Size is an estimate; the template asks you to correct it when the PR lands, so
that trials stay comparable (`…agent-substrate-design.md` → Risks).

Note the **learning tax**: `CLAUDE.md` requires a `docs/learnings/` file plus its
`INDEX.md` line for any trap worth remembering, and `Scripts/check-substrate.sh`
enforces the bijection. So a guard-adding issue is four files minimum. Read
`size:xs` as *one behaviour plus its test* — the learning and its index line do
not push it to `size:s` on their own.

Also add exactly one kind label. `Scripts/loop-prompt.md` §6 records it as the
trial's `kind`:

| Label | Use for |
|---|---|
| `bug` | Something produces a wrong result — including tooling and guards, not just the app (#71, #72, #84) |
| `enhancement` | New behaviour that does not exist yet (#93, #96) |
| `test` | Coverage or test infrastructure, where the test *is* the deliverable (#48, #63) |
| `chore` | Maintenance with no user-visible change, including adding a new guard (#46, #80) |
| `documentation` / `deps` | Docs; dependency or toolchain bumps needing code changes (#79) |

## Title

`<area or symbol>: <the observable defect>` — the area is a subsystem
(`build:`, `release:`, `ui:`, `engine:`, `diagnostics:`) or the thing itself
(`woof_ios.c:`, `TouchOverlayView:`, `LoadoutEditorView.save()`). Nothing
enforces this; it is convention, visible in `gh issue list`. State the defect,
not the fix: "*always ends the changelog range at HEAD, not at the build it
annotates*", not "fix the changelog range".

## Writing the Verification section

The exact command, in a fenced block, that an unattended run will execute
**unmodified** (`Scripts/loop-prompt.md` §3.4: if it fails, fix the change,
never the test). Either `mise run test` or something narrower.

For a Swift change, the narrow form used by #64:

```
mise run bootstrap
xcodebuild -project App/WADdle.xcodeproj -scheme WADdle \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:WADdleTests test
```

For shell work, name the suites directly — `Scripts/test-build-deps.sh`,
`Scripts/check-substrate.sh`, … as #72 and #84 do.

Say what the new tests must cover, in prose, as concretely as the commands.
#72 spells out both directions ("a cache that is stale must not survive, and a
cache that is valid must not be needlessly discarded"). #93 lists four required
cases including the failure path.

### Demand a discrimination proof for any safety property

A test that runs is not a test that discriminates. This repo has shipped both
failures: `docs/superpowers/specs/2026-08-10-test-proof-signal-design.md` records
PR #57, whose body claimed verification "by deleting the corresponding line and
watching the suite go red" — a reviewer deleted line 25 and every test still
passed — and PR #61, which shipped a vacuous test caught by hand before merge.
`Scripts/check-red-green.sh` now scores exactly this and has a `vacuous` verdict
for it.

So when the issue concerns a guard, a refusal, a fail-closed path, or anything
whose value is that it catches something, put the proof in the Verification
section in the shape #84 and #93 both use:

> Prove the new ones discriminate: break the range endpoint back to `..HEAD`,
> confirm the new case fails, restore, confirm it passes. A case that passes
> against the old behaviour is not covering this.

Name the specific thing to break. "Break it and see" is not a proof;
"break the grouping, and separately break the fallback" is.

Add "Do not weaken any of the existing N cases" when you are extending a suite.

## Never write a closing keyword in a commit message

A closing keyword in a **commit message** closes the issue the moment the commit
reaches `main` — **including inside backticks, inside a fenced block, and inside
prose merely describing the mechanism.** Markdown formatting is not an
exemption; GitHub reads the raw message. A commit in this repo once closed a
live issue exactly that way, by quoting one in prose. The rule is recorded in
`docs/superpowers/plans/2026-08-10-test-proof-signal.md:23` and
`docs/superpowers/plans/2026-08-11-whats-to-test.md:23`.

The rule is usually quoted as "`Closes` / `Fixes` / `Resolves`", but **GitHub
honours nine keywords**, case-insensitively, in the subject *or* the body:

```
close  closes  closed   fix  fixes  fixed   resolve  resolves  resolved
```

`Fixed #13` closes issue 13 exactly as hard as `Closes #13` does. The reference
form varies too — `#N`, `GH-N`, `owner/repo#N`, and a full
`https://github.com/…/issues/N` URL all count.

Where each of the three surfaces stands:

| Surface | Effect |
|---|---|
| **Commit message** | Closes on merge to `main`. Never write one. |
| **Pull request body** | Closes on merge — correct and **required** here. |
| **Issue body / comment** | Inert; does not close anything. Safe to quote. |

In a pull request body it is required: `Scripts/loop-prompt.md` §3 tells every
run to open a PR whose body contains `Closes #<ISSUE>`, and
`Scripts/loop-precheck.sh` §5 parses exactly
`(?:closes|fixes|resolves)\s+#(\d+)` out of open PR bodies to keep a claimed
issue from being handed to a second run.

**The trap when writing about this rule:** house style says quote the offending
text, and an issue body is inert so you safely can. The *pull request* that
fixes such an issue is not — quoting an example there closes whatever it names,
on top of its own intended `Closes #<ISSUE>`.

To *refer* to an issue from a commit message without closing it, write the bare
number — `issue 42`, `#42`, `per #42`. None of those is a keyword.

## Quick reference

| | |
|---|---|
| Template | `.github/ISSUE_TEMPLATE/agent-eligible.md` (delete the comments) |
| Title | `<area or symbol>: <observable defect>` |
| Required headings | `## Definition of done`, `## Verification`, `## Provenance` |
| Enforced by | `Scripts/check-issue-format.sh` via `.github/workflows/issue-format.yml` |
| Enforced on | open `agent:eligible` issues only, on issue events + weekly cron |
| Labels | one kind (`bug`/`enhancement`/`documentation`/`test`/`chore`/`deps`), one size (`size:xs`/`s`/`m`), one of `agent:eligible`/`agent:blocked` |
| Check it yourself | `Scripts/check-issue-format.sh` (needs an authenticated `gh`) |
| Selection order | size rank, then ascending issue number (`Scripts/loop-precheck.sh`) |

## Common mistakes

| Mistake | Fix |
|---|---|
| Template HTML comments left under a heading | They *pass* the check — it only tests for non-whitespace. Delete them and write the content. |
| Heading written `### Verification` or `## Verification:` | Matching is exact on the whole line at level 2. The section reads as missing. |
| Definition of done names an activity | Name the observable condition. Not "fix the size cap" but "`ZipExtractor` rejects any entry whose uncompressed size exceeds the cap, and a test proves it." |
| "X is broken" with no output | Paste the measurement, dated, with the command that produced it. |
| Verification says "run the tests" | Give the exact command, unmodified-runnable, plus what the new cases must cover. |
| New test demanded with no discrimination proof | Name the thing to break, and the expected fail-then-pass. |
| Blocked with no reason | The label means "reason stated in the issue". Write the "Blocked for the loop: …" paragraph. |
| Blocked because "an agent might get it wrong" | Not a reason — the owner is the merge gate on every run. |
| `Fixed #13` assumed safe because the rule names three verbs | Nine keywords close, in any case, anywhere in the message. |
| No size label | Sorts behind every labelled issue in `loop-precheck.sh`. |
| Provenance says "found while testing" | Name the PR, review, trial record, or date. It is the only surviving context. |
| Issue adds a guard script *and* wires it into `ci.yml` | The loop may not touch `.github/workflows/`. Split it or block it. |
