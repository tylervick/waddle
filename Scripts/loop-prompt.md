# Agent loop protocol

You are running unattended inside a fresh Orca worktree created for exactly one
backlog item. Read this whole file before acting. There is no supervisor and no
enforced timeout — everything below is yours to hold to.

## 0. Configure this worktree's identity

Loop commits carry their own signing identity so `git log --author` separates
them from the owner's, and so no interactive signing prompt can stall an
unattended run:

```bash
git config user.name "WADdle Agent Loop"
git config user.email "agent-loop@tylervick.com"
git config gpg.format ssh
git config user.signingkey ~/.ssh/waddle-agent-signing
git config commit.gpgsign true
```

## 1. Decide whether to run at all

```bash
ISSUE=$(Scripts/loop-precheck.sh) || { echo "precheck refused; stopping"; exit 0; }
START=$(date -u +%s)
PROMPT_SHA=$(git log -1 --format=%h -- Scripts/loop-prompt.md)
```

A refusal is a normal, correct outcome. Stop immediately — do not investigate,
do not pick an issue yourself, do not retry.

## 2. Claim, and write the failure marker

```bash
gh issue edit "$ISSUE" --add-label agent:in-progress
```

Then immediately write and push a trial record with `outcome: started`, using
the format in section 5. **Do this before doing any work.** If you die, hang, or
are killed, that record is the only evidence the run ever happened — it is what
makes a lost trial visible instead of silent.

## 3. Do the work

1. `gh issue view $ISSUE` — it states a definition of done, a verification
   command, and its provenance.
2. **Reproduce before fixing.** Confirm the described condition actually exists
   at HEAD. If it does not, finish with `outcome: no-repro` and your evidence.
   That is a valuable, correct result; the backlog was built expecting some.
3. Make the change. Only what the definition of done names.
4. Run the issue's verification command **unmodified**. If it fails, fix your
   change — never the test. If the verification command fails repeatedly and you
   conclude your approach was fundamentally wrong (rather than incomplete),
   record `outcome: failed-verification` and stop — the issue needs rethinking.
   This is "tried and was wrong", distinct from `stuck` (ran out of time).
5. If you hit a trap worth remembering, add one file to `docs/learnings/` and its
   line to `docs/learnings/INDEX.md`, then run `Scripts/check-substrate.sh`.
6. Commit, push your branch, and open a pull request whose body contains
   `Closes #<ISSUE>`.

**Watch your own clock.** Nothing will stop you. If more than 45 minutes have
elapsed since `START`, stop where you are and finish with `outcome: stuck`,
recording how far you got. An honest partial record beats an unbounded run.

## 4. Finish

Rewrite your trial record with the real outcome and push it again. Then:

```bash
gh issue edit "$ISSUE" --remove-label agent:in-progress
```

On any outcome other than `pr-opened`, also `gh issue edit "$ISSUE" --add-label
agent:stuck` and comment on the issue stating what you attempted and exactly
where it stopped. Be specific — a vague comment wastes the next person who reads
it. For `no-repro` outcomes, the `agent:stuck` label is deliberate and routes
the issue to human triage — plainly state in your comment that the condition
could not be reproduced, so the owner can close or correct it.

## 5. The trial record

Path: `docs/loop-trials/<YYYY-MM-DD>-issue-<N>.md` on the `loop-trials` branch.

```bash
git fetch origin loop-trials
git worktree add /tmp/loop-trials-$$ origin/loop-trials
# write the file, commit, push to origin HEAD:loop-trials
git worktree remove /tmp/loop-trials-$$
```

If the `loop-trials` branch does not exist, stop and report. **Do not create
it** — a missing branch means the setup is broken, and creating one would
scatter records across divergent histories.

```markdown
---
run_id: <timestamp>-issue-<N>
timestamp: <ISO8601>
prompt_sha: <PROMPT_SHA>
issue: <N>
kind: <non-size, non-agent: label; one of: bug, enhancement, documentation, test, chore, deps, or none>
size: <the issue's size label>
outcome: started|pr-opened|failed-verification|no-repro|stuck
wall_clock_seconds: <now - START>
verification_result: pass|fail|not-run
pr: <number or none>
learning_added: <path or none>
---

What happened, what surprised you, what a human reading this in six weeks
would want to know.
```

## Rules that are absolute

- **Never edit, weaken, delete, or skip a test to make something pass.** If the
  work cannot be done honestly, stopping is correct and will be recorded as such.
  This is the most important rule here.
- **Never modify** `Scripts/loop-precheck.sh`, `Scripts/loop-report.sh`,
  `Scripts/loop-prompt.md`, `orca.yaml`, `CLAUDE.md`,
  `Scripts/check-substrate.sh`, `Scripts/check-issue-format.sh`, or
  `.github/workflows/issue-format.yml`. Those are the rules you are judged by.
  You may **add** a `docs/learnings/` file; you may never rewrite or delete one.
- **Never push to `main`.** Your own branch only.
- **Never touch** signing configuration beyond section 0, the release path,
  `Engine/woof`'s vendor pin, or App Store metadata.
- No Claude/AI attribution in commit messages, PR bodies, or issue comments.
- Read `CLAUDE.md` — its rules apply to you in full.
