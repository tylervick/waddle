# Agent loop protocol

You are running unattended inside a fresh Orca worktree created for exactly one
backlog item. Read this whole file before acting. There is no supervisor and no
enforced timeout — everything below is yours to hold to.

## 0. Configure this worktree's identity

Loop commits carry their own signing identity so `git log --author` separates
them from the owner's, and so no interactive signing prompt can stall an
unattended run.

Set these as environment variables, not with plain `git config`.
`extensions.worktreeConfig` is unset in this repo, so `git config` writes land
in the shared `.git/config` and would retag the *owner's own main checkout*
with the agent's identity and signing key — not just this worktree.
`GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_n`/`GIT_CONFIG_VALUE_n` apply to every git
invocation this session runs (including the temporary `loop-trials` worktree
in section 5) without ever writing to a config file, so they cannot leak
into the shared repo no matter how `extensions.worktreeConfig` is set. If you
are ever tempted to "simplify" this back to plain `git config`, don't —
that is precisely the contamination this works around:

```bash
export GIT_CONFIG_COUNT=6
export GIT_CONFIG_KEY_0=user.name
export GIT_CONFIG_VALUE_0="WADdle Agent Loop"
export GIT_CONFIG_KEY_1=user.email
export GIT_CONFIG_VALUE_1="agent-loop@tylervick.com"
export GIT_CONFIG_KEY_2=gpg.format
export GIT_CONFIG_VALUE_2=ssh
export GIT_CONFIG_KEY_3=user.signingkey
export GIT_CONFIG_VALUE_3="$HOME/.ssh/waddle-agent-signing.pub"
export GIT_CONFIG_KEY_4=gpg.ssh.program
export GIT_CONFIG_VALUE_4=ssh-keygen
export GIT_CONFIG_KEY_5=commit.gpgsign
export GIT_CONFIG_VALUE_5=true
```

`gpg.ssh.program` must be overridden here: the owner's global git config
points it at 1Password's `op-ssh-sign`, which only signs with keys held in
the 1Password agent. `user.signingkey` must point at the `.pub` file, not the
private key — that is the conventional value `ssh-keygen` expects. Skip
either override and `commit.gpgsign true` turns every commit into
`fatal: failed to write commit object` — which happens *after* the issue is
already claimed, so it is the worst failure shape available: a consumed
backlog issue with no record of why.

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

## Operating this loop

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

**Prerequisite before the first real run:** this branch must be merged to
`main` first. Every per-run worktree Orca creates is cut from `main`, and
`Scripts/loop-prompt.md`, `Scripts/loop-precheck.sh`, and
`Scripts/loop-report.sh` currently exist only on this branch
(`tylervick/agent-loop-spec`). A run against an unmerged `main` dies
immediately at `Scripts/loop-precheck.sh: no such file`. This is a hard
prerequisite, not a nicety.

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
