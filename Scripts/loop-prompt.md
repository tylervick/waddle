# Agent loop protocol

You are running unattended inside a fresh Orca worktree created for exactly one
backlog item. Read this whole file before acting. There is no supervisor and no
enforced timeout — everything below is yours to hold to.

## 0. Every commit carries its identity inline — nothing is set up in advance

Loop commits carry their own signing identity so `git log --author` separates
them from the owner's, and so no interactive signing prompt can stall an
unattended run.

**There is no setup step here, and that is deliberate.** Two earlier forms of
this section were each tried and each failed:

1. Plain `git config user.name ...` etc. This repo has
   `extensions.worktreeConfig` unset, so those writes land in the shared
   `.git/config` and retag the *owner's own main checkout* with the agent's
   identity and signing key — not just this worktree.
2. Exporting `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_n`/`GIT_CONFIG_VALUE_n` once,
   up front. This avoids the file-contamination problem but fails for a
   different reason: an unattended run is not one continuous shell, it is a
   sequence of separate tool invocations, and shell state — including
   exported environment variables — does not survive between them. Verified
   directly: a variable exported in one invocation was already gone in the
   next. Section 3's work commit and section 5's `loop-trials` commits happen
   in later invocations, in a different worktree — by the time they run, the
   export from this section is gone, `commit.gpgsign true` falls back to the
   owner's global `gpg.ssh.program` (1Password's `op-ssh-sign`, which cannot
   see this key), and the commit fails with
   `fatal: failed to write commit object` — *after* the issue is already
   claimed. That is the worst failure shape available: a consumed backlog
   issue with no record of why. Worse, it is intermittent — it depends on
   whether a given tool call happens to land in the same shell as a prior
   one — so it reads as flakiness, not a reproducible bug.

**The only form that survives both failures is `git -c` flags spelled out in
full on every single commit, every time**, because the configuration then
travels with that one command instead of depending on anything set up
earlier. If you are ever tempted to hoist this into a one-time `export` or
`git config` block to avoid repeating it: don't. That is exactly how both
earlier attempts failed, and doing it a third way will not change the result
— shell state still won't survive the next tool call. The verbosity is not
an oversight; every commit in this protocol (section 3's work commit, and
both trial-record commits in section 5) must carry this exact form written
out in place, not a reference back to this section:

```bash
git -c user.name="WADdle Agent Loop" \
    -c user.email="agent-loop@tylervick.com" \
    -c gpg.format=ssh \
    -c user.signingkey=~/.ssh/waddle-agent-signing.pub \
    -c gpg.ssh.program=ssh-keygen \
    -c commit.gpgsign=true \
    commit -m "..."
```

`gpg.ssh.program=ssh-keygen` must be on every invocation: the owner's global
git config points that setting at 1Password's `op-ssh-sign`, which only
signs with keys held in the 1Password agent and will reject this key.
`user.signingkey` must point at the `.pub` file, not the private key — that
is the conventional value `ssh-keygen` expects.

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
6. Commit with the full identity form from section 0 — written out here, not
   referenced, because this commit happens in its own tool invocation:

   ```bash
   git -c user.name="WADdle Agent Loop" \
       -c user.email="agent-loop@tylervick.com" \
       -c gpg.format=ssh \
       -c user.signingkey=~/.ssh/waddle-agent-signing.pub \
       -c gpg.ssh.program=ssh-keygen \
       -c commit.gpgsign=true \
       commit -m "<a real commit message describing the change>"
   ```

   Then push your branch and open a pull request whose body contains
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
This procedure runs twice — once from section 2 (`outcome: started`) and once
from section 4 (the real outcome) — each time in its own tool invocation, in
its own temporary worktree. The commit must therefore carry the full identity
form both times; neither run can rely on anything from section 0 or from the
other run.

```bash
git fetch origin loop-trials
git worktree add /tmp/loop-trials-$$ origin/loop-trials
cd /tmp/loop-trials-$$
# write docs/loop-trials/<YYYY-MM-DD>-issue-<N>.md, then:
git add docs/loop-trials/<YYYY-MM-DD>-issue-<N>.md
git -c user.name="WADdle Agent Loop" \
    -c user.email="agent-loop@tylervick.com" \
    -c gpg.format=ssh \
    -c user.signingkey=~/.ssh/waddle-agent-signing.pub \
    -c gpg.ssh.program=ssh-keygen \
    -c commit.gpgsign=true \
    commit -m "docs(loop-trials): start record for issue <N>"
    # or: -m "docs(loop-trials): record <outcome> outcome for issue <N>"
git push origin HEAD:loop-trials
cd -
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

## Operating this loop

**Prerequisite before the first real run:** this branch must be merged to
`main` first. Every per-run worktree Orca creates is cut from `main`, and
`Scripts/loop-prompt.md`, `Scripts/loop-precheck.sh`, and
`Scripts/loop-report.sh` currently exist only on this branch
(`tylervick/agent-loop-spec`). A run against an unmerged `main` dies
immediately at `Scripts/loop-precheck.sh: no such file`. This is a hard
prerequisite, not a nicety — the "run once, now" command below will not work
until it is satisfied.

- Automation id: `8a0d5727-9d5c-46a6-b0ef-92d5accf3859` (`orca automations show
  8a0d5727-9d5c-46a6-b0ef-92d5accf3859`)
- Pause: `orca automations edit 8a0d5727-9d5c-46a6-b0ef-92d5accf3859 --disabled`
- Remove: `orca automations remove 8a0d5727-9d5c-46a6-b0ef-92d5accf3859` — then
  check `orca worktree list` and remove any per-run worktrees it left behind;
  it does not clean them up.
- Run once, now: `orca automations run 8a0d5727-9d5c-46a6-b0ef-92d5accf3859`
  (note: this skips `--precheck`, which is why the agent gates itself)
- Read results: `Scripts/loop-report.sh`

The automation stays **disabled** until three manual runs have landed clean.

**Known cosmetic defect — ignore `boombox` if you see it:** Orca resolves
this automation's project as `github:tylervick/boombox`, not `waddle`. The
repo was renamed on GitHub after Orca's repo record was created, and Orca
never picked up the rename; there is no `orca repo` subcommand to refresh it.
This is cosmetic for this design — the loop's actual GitHub work (`gh issue
list`, `gh issue edit`, `gh pr create`) all runs inside the per-run
worktree's checkout against that checkout's real `origin`
(`git@github.com:tylervick/waddle.git`), not through Orca's project mapping,
and GitHub redirects API calls for renamed repos regardless. If Orca's UI or
CLI output names `boombox` anywhere, that is this same known issue, not a new
one — no need to re-investigate.
