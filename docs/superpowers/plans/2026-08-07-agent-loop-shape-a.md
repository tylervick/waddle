# Agent Loop (Shape A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Supersedes** `docs/superpowers/plans/2026-08-07-agent-loop.md`, whose Task 1
spike disproved the coordinator/worker architecture. That plan's Task 1 is done;
its Tasks 2–6 are void. Findings:
`docs/superpowers/plans/2026-08-07-agent-loop-spike-findings.md`.

**Goal:** Build an unattended loop that takes one `agent:eligible` issue per run,
does the work in a fresh Orca worktree, opens a pull request, and records a trial
record whether it succeeds or dies.

**Architecture:** One `orca automations` entry fires on a schedule and creates a
fresh worktree. A single agent follows `Scripts/loop-prompt.md`: it runs
`Scripts/loop-precheck.sh` itself and stops if refused; otherwise it claims the
issue, pushes a `started` trial record, does the work, opens a pull request, then
rewrites its record with the real outcome. A record still reading `started` is a
run that died. `Scripts/loop-report.sh` aggregates the records.

**Tech Stack:** Bash (matching existing `Scripts/` conventions), GitHub CLI
(`gh`), the `orca` CLI, Markdown.

**Spec:** `docs/superpowers/specs/2026-08-07-agent-loop-design.md` (revised
2026-08-07 after the spike).

**Branch:** `tylervick/agent-loop-spec`.

## What the spike established — bind to these, not to assumptions

| Finding | Consequence for this plan |
| --- | --- |
| `orca orchestration worker-start` workers never execute — they stall on the agent's cold-start screen | No sub-workers anywhere. One agent per run. |
| `--timeout-ms` is accepted but never fires | No enforced timeout. The agent self-checks a wall clock; a hung run is caught by its record still reading `started`. |
| `orca automations run <id>` **skips `--precheck` entirely** (`precheckResult: null` for both exit 0 and exit 1) | The agent runs the precheck itself as its first action. Do not rely on `--precheck` for gating. |
| Precheck stdout pass-through unobservable | The agent reads the precheck's stdout directly by invoking it. |
| An automation's own agent runs and completes, output in `outputSnapshot` | Shape A's core assumption is evidenced, not assumed. |
| CodeRabbit prefixes every review comment `_<category>_ \| _<severity>_ \| _<effort>_` | Count with `grep -c '🟠 Major\|🔴 Critical'`. The old `⚠️ Potential issue` string does not appear in this repo. |
| `orca automations remove` leaves the per-run worktree and branch behind | Cleanup is explicit. |
| Orca id nesting differs per command (`.result.<noun>.id` vs flat `.result.runId`) | Parse per command; never assume one convention. |
| Automations resolved to a stale `github:tylervick/boombox` project mapping | Verify the created automation points at `waddle` before trusting it. |

## Global Constraints

- Bash scripts: `set -euo pipefail`, `ROOT` derived from the script's own
  location, header comment explaining *why* — matching `Scripts/check-engine-fresh.sh`.
- Script self-tests are **hermetic**: fixture repo in `mktemp -d`, a stub `gh` on
  a controlled `PATH`, never touching the real tree or real GitHub. Matching
  `Scripts/test-check-substrate.sh`.
- Stale-claim threshold: **2 hours**. Agent wall-clock budget: **45 minutes**,
  self-checked. Runs per day: **3**.
- Trial-record `outcome` is one of `started`, `pr-opened`, `failed-verification`,
  `no-repro`, `stuck`. `started` is written first and overwritten last.
- The loop may never modify `Scripts/loop-precheck.sh`, `Scripts/loop-report.sh`,
  `Scripts/loop-prompt.md`, `orca.yaml`, `CLAUDE.md`,
  `Scripts/check-substrate.sh`, `Scripts/check-issue-format.sh`, or
  `.github/workflows/issue-format.yml`.
- The loop may **add** files under `docs/learnings/` with an index line; never
  rewrite or remove an existing learning.
- Never edit or delete a test to make it pass.
- Trial records go to the `loop-trials` orphan branch, never into a work PR.
- Conventional commits. No Claude/AI attribution in commit messages, PR bodies,
  or issue comments.
- **Signing:** 1Password's agent is currently unreachable and the owner is away.
  Commit with `git -c commit.gpgsign=false commit` and note the unsigned SHA in
  your report; the branch is unpushed, so the owner re-signs losslessly later.
  Never use `--no-gpg-sign` as a permanent setting and never alter git config.

## File Structure

| File | Responsibility |
| --- | --- |
| `Scripts/loop-precheck.sh` | Refuse a run, or name exactly one issue. Pure logic plus the stale sweep. |
| `Scripts/test-loop-precheck.sh` | Hermetic self-test, 9 cases. |
| `Scripts/loop-prompt.md` | The single-agent protocol. The experiment's independent variable. |
| `Scripts/loop-report.sh` | Parse records, reconcile PR state, print the report. |
| `Scripts/test-loop-report.sh` | Hermetic self-test, 7 cases. |

## The trial record format

`docs/loop-trials/<YYYY-MM-DD>-issue-<N>.md` on the `loop-trials` branch:
`---`-delimited frontmatter, then free prose. Only the frontmatter is parsed.

```markdown
---
run_id: 2026-08-07T14-03-11Z-issue-43
timestamp: 2026-08-07T14:03:11Z
prompt_sha: a1b2c3d
issue: 43
kind: test
size: xs
outcome: pr-opened
wall_clock_seconds: 812
verification_result: pass
pr: 57
learning_added: none
---

Free prose: what happened, what surprised the agent, anything a human reading
this in six weeks would want to know.
```

`verification_result` is `pass`, `fail`, or `not-run`. `pr` is a number or
`none`. `learning_added` is a path or `none`. There is no turn count — Orca
exposes none. The CodeRabbit finding count is deliberately absent: reviews land
minutes after a PR opens, so it is reconciled at report time.

---

### Task 1: `Scripts/loop-precheck.sh` and its self-test

The decision logic: refuse a run, or name exactly one issue. Written test-first.

**Files:**
- Create: `Scripts/loop-precheck.sh`
- Create: `Scripts/test-loop-precheck.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `Scripts/loop-precheck.sh`. On proceed, prints **only** the issue
  number to stdout, exit 0. On refusal, prints `skip: <reason>` to **stderr**,
  nothing to stdout, exit 1. Task 2's prompt has the agent invoke it and read
  stdout.

- [ ] **Step 1: Write the failing self-test**

Create `Scripts/test-loop-precheck.sh`:

```bash
#!/bin/bash
# Tests for Scripts/loop-precheck.sh.
#
# Fully HERMETIC: a fixture repo in a temp dir, a stub `gh` on a controlled
# PATH, and a stub check-engine-fresh.sh. Never touches the real tree, the real
# GitHub, or the real engine.
#
# The stub gh answers exactly the four calls the precheck makes -- issue list,
# pr list, the labeled-events timeline, and issue edit -- from fixture files, so
# each case controls the world precisely. A real gh would make these tests
# depend on live repo state, which is the opposite of a regression suite.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

make_fixture() { # dest
    mkdir -p "$1/Scripts" "$1/bin"
    cp "$ROOT/Scripts/loop-precheck.sh" "$1/Scripts/"
    printf '#!/bin/bash\nexit 0\n' > "$1/Scripts/check-engine-fresh.sh"
    chmod +x "$1/Scripts/check-engine-fresh.sh"
    printf '[]\n' > "$1/issues.json"
    printf '[]\n' > "$1/prs.json"
    printf '[]\n' > "$1/timeline.json"
    : > "$1/gh-calls.log"
    cat > "$1/bin/gh" <<'STUB'
#!/bin/bash
# Stub gh. Echoes fixture JSON; logs every call so tests can assert mutations.
FIX="$(dirname "$(dirname "$0")")"
echo "$*" >> "$FIX/gh-calls.log"
case "$1 $2" in
  "issue list") cat "$FIX/issues.json" ;;
  "pr list")    cat "$FIX/prs.json" ;;
  "api")        cat "$FIX/timeline.json" ;;
  "issue edit") exit 0 ;;
  *) echo "stub gh: unhandled: $*" >&2; exit 64 ;;
esac
STUB
    chmod +x "$1/bin/gh"
}

# LOOP_NOW pins "now" so staleness is deterministic across runs.
run_precheck() { # dir
    env PATH="$1/bin:/usr/bin:/bin" LOOP_NOW="2026-08-07T12:00:00Z" \
        "$1/Scripts/loop-precheck.sh"
}

# 1. No eligible issues -> refuse, on stderr, with stdout silent.
make_fixture "$TMP/a"
if out=$(run_precheck "$TMP/a" 2>"$TMP/err"); then fail "proceeded with no issues"; fi
[ -z "$out" ] || fail "printed '$out' to stdout on refusal; must be silent"
grep -q "^skip: " "$TMP/err" || fail "refusal reason missing from stderr"
pass "refuses when no eligible issues exist"

# 2. Ordering: size:xs beats size:s beats size:m, whatever order gh returns.
make_fixture "$TMP/b"
cat > "$TMP/b/issues.json" <<'J'
[{"number":50,"labels":[{"name":"agent:eligible"},{"name":"size:m"}]},
 {"number":51,"labels":[{"name":"agent:eligible"},{"name":"size:xs"}]},
 {"number":52,"labels":[{"name":"agent:eligible"},{"name":"size:s"}]}]
J
out=$(run_precheck "$TMP/b") || fail "refused a valid backlog"
[ "$out" = "51" ] || fail "picked $out; expected 51 (the only size:xs)"
pass "prefers size:xs over size:s over size:m"

# 3. Tie-break is the lowest issue number, so a trial is reproducible rather
#    than dependent on gh's ordering.
make_fixture "$TMP/c"
cat > "$TMP/c/issues.json" <<'J'
[{"number":70,"labels":[{"name":"agent:eligible"},{"name":"size:xs"}]},
 {"number":44,"labels":[{"name":"agent:eligible"},{"name":"size:xs"}]}]
J
out=$(run_precheck "$TMP/c") || fail "refused a valid backlog"
[ "$out" = "44" ] || fail "picked $out; expected 44 (lowest at same size)"
pass "tie-breaks on ascending issue number"

# 4. agent:stuck is excluded -- it defeated a previous run and must not be
#    retried without a human.
make_fixture "$TMP/d"
cat > "$TMP/d/issues.json" <<'J'
[{"number":60,"labels":[{"name":"agent:eligible"},{"name":"size:xs"},{"name":"agent:stuck"}]},
 {"number":61,"labels":[{"name":"agent:eligible"},{"name":"size:m"}]}]
J
out=$(run_precheck "$TMP/d") || fail "refused a valid backlog"
[ "$out" = "61" ] || fail "picked $out; expected 61 (60 is agent:stuck)"
pass "excludes agent:stuck issues"

# 5. An issue an open PR says it closes is excluded. Work PRs wait on human
#    review, so without this a later run re-picks finished work.
make_fixture "$TMP/e"
cat > "$TMP/e/issues.json" <<'J'
[{"number":80,"labels":[{"name":"agent:eligible"},{"name":"size:xs"}]},
 {"number":81,"labels":[{"name":"agent:eligible"},{"name":"size:m"}]}]
J
printf '[{"number":90,"body":"Fixes a thing.\\n\\nCloses #80"}]\n' > "$TMP/e/prs.json"
out=$(run_precheck "$TMP/e") || fail "refused a valid backlog"
[ "$out" = "81" ] || fail "picked $out; expected 81 (80 has an open PR)"
pass "excludes issues with a linked open PR"

# 6. A fresh claim means a run is live -> refuse entirely, so two runs can never
#    share a simulator.
make_fixture "$TMP/f"
cat > "$TMP/f/issues.json" <<'J'
[{"number":40,"labels":[{"name":"agent:eligible"},{"name":"agent:in-progress"}]},
 {"number":41,"labels":[{"name":"agent:eligible"},{"name":"size:xs"}]}]
J
printf '[{"event":"labeled","created_at":"2026-08-07T11:30:00Z","label":{"name":"agent:in-progress"}}]\n' \
    > "$TMP/f/timeline.json"
if out=$(run_precheck "$TMP/f" 2>"$TMP/err"); then fail "proceeded while a run was live"; fi
grep -q "run already live" "$TMP/err" || fail "wrong refusal reason: $(cat "$TMP/err")"
pass "refuses while a fresh claim is live"

# 7. A claim older than 2h is debris from a dead run. Clear it and carry on, or
#    the backlog silently shrinks forever.
make_fixture "$TMP/g"
cat > "$TMP/g/issues.json" <<'J'
[{"number":40,"labels":[{"name":"agent:eligible"},{"name":"size:xs"},{"name":"agent:in-progress"}]}]
J
printf '[{"event":"labeled","created_at":"2026-08-07T09:00:00Z","label":{"name":"agent:in-progress"}}]\n' \
    > "$TMP/g/timeline.json"
out=$(run_precheck "$TMP/g") || fail "refused despite the claim being stale"
[ "$out" = "40" ] || fail "picked $out; expected 40 after the stale sweep"
grep -q "issue edit 40 --remove-label agent:in-progress" "$TMP/g/gh-calls.log" \
    || fail "stale claim was never actually cleared"
pass "sweeps a stale claim and then proceeds"

# 8. A stale engine makes every run a 25-minute rebuild inside a 45-minute
#    budget -- refuse rather than manufacture fake failures.
make_fixture "$TMP/h"
cat > "$TMP/h/issues.json" <<'J'
[{"number":42,"labels":[{"name":"agent:eligible"},{"name":"size:xs"}]}]
J
printf '#!/bin/bash\nexit 1\n' > "$TMP/h/Scripts/check-engine-fresh.sh"
if out=$(run_precheck "$TMP/h" 2>"$TMP/err"); then fail "proceeded with a stale engine"; fi
grep -q "engine" "$TMP/err" || fail "refusal does not name the engine: $(cat "$TMP/err")"
pass "refuses when the root checkout's engine is stale"

# 9. An eligible issue with no size label is still reachable, after sized ones.
make_fixture "$TMP/i"
cat > "$TMP/i/issues.json" <<'J'
[{"number":30,"labels":[{"name":"agent:eligible"}]}]
J
out=$(run_precheck "$TMP/i") || fail "refused an unsized eligible issue"
[ "$out" = "30" ] || fail "picked $out; expected 30"
pass "picks an unsized eligible issue rather than skipping it"

echo "All loop-precheck tests passed."
```

- [ ] **Step 2: Run the self-test to verify it fails**

```bash
chmod +x Scripts/test-loop-precheck.sh
Scripts/test-loop-precheck.sh
```

Expected: FAIL — `cp: .../Scripts/loop-precheck.sh: No such file or directory`.

- [ ] **Step 3: Write `Scripts/loop-precheck.sh`**

```bash
#!/bin/bash
# Decides whether an agent-loop run happens, and which issue it takes.
#
# The loop agent runs this as its FIRST action and stops if refused. It is not
# wired as Orca's --precheck: a spike found `orca automations run` skips that
# hook entirely (precheckResult stayed null for both exit 0 and exit 1), and the
# rollout deliberately starts with manual runs. Gating from inside the agent
# behaves identically for manual and scheduled fires.
#
# Contract:
#   proceed -> print ONLY the issue number on stdout, exit 0
#   refuse  -> print "skip: <reason>" on stderr, nothing on stdout, exit 1
# Nothing else may reach stdout, because the caller reads it as the selection.
#
# Refusing is the common case and costs nothing. The three refusals, in order:
#
#   1. Stale engine in this checkout. Every worktree clones Vendor/out from
#      here, so a stale root makes check-engine-fresh.sh fail closed inside the
#      run and burns ~25 minutes of a 45-minute budget on a rebuild. The
#      resulting failures would look like agent failures and be nothing of the
#      sort.
#   2. A run is already live. One at a time is what makes it impossible for two
#      xcodebuild sessions to share a simulator.
#   3. Nothing claimable. The backlog is finite by design; exhausting it is the
#      graceful end of the experiment, not an error.
#
# Liveness is the agent:in-progress LABEL, never the presence of a worktree --
# Orca leaves worktrees behind after `automations remove`, so a leftover one
# must not read as a running job.
#
# NOT a pure query: clearing a stale claim mutates labels. That is correct
# however often it happens, but anyone running this by hand should know. Every
# sweep is logged to stderr.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STALE_CLAIM_SECONDS=7200   # 2h; comfortably past the 45m wall-clock budget
CLAIM_LABEL="agent:in-progress"

# LOOP_NOW lets the self-test pin "now". Unset in production.
NOW_ISO="${LOOP_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
to_epoch() { date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || echo 0; }
NOW_EPOCH="$(to_epoch "$NOW_ISO")"

skip() { echo "skip: $*" >&2; exit 1; }

# 1. Engine freshness in THIS checkout.
if ! "$ROOT/Scripts/check-engine-fresh.sh" >/dev/null 2>&1; then
    skip "root checkout's engine is stale; every worktree would inherit it and rebuild"
fi

# 2. Fetch the world in two calls, then decide locally.
issues="$(gh issue list --label agent:eligible --state open --limit 1000 \
            --json number,labels 2>/dev/null)" || skip "gh issue list failed"
open_prs="$(gh pr list --state open --limit 1000 --json number,body 2>/dev/null)" \
    || skip "gh pr list failed"

# 3. Liveness + stale sweep.
claimed="$(printf '%s' "$issues" | python3 -c 'import json,sys
for i in json.load(sys.stdin):
    if any(l["name"]=="agent:in-progress" for l in i["labels"]): print(i["number"])')"

for n in $claimed; do
    applied="$(gh api "repos/{owner}/{repo}/issues/$n/timeline" \
                 --jq '[.[] | select(.event=="labeled" and .label.name=="agent:in-progress") | .created_at] | last // ""' \
                 2>/dev/null)" || skip "gh api timeline failed for #$n"
    age=$(( NOW_EPOCH - $(to_epoch "${applied:-1970-01-01T00:00:00Z}") ))
    if [ "$age" -lt "$STALE_CLAIM_SECONDS" ]; then
        skip "run already live on #$n (claimed ${age}s ago)"
    fi
    gh issue edit "$n" --remove-label "$CLAIM_LABEL" >/dev/null 2>&1 \
        || skip "could not clear the stale claim on #$n"
    echo "swept stale claim on #$n (${age}s old)" >&2
done

# 4. Select.
choice="$(printf '%s\n%s' "$issues" "$open_prs" | python3 -c '
import json, re, sys
raw = sys.stdin.read()
issues_txt, prs_txt = raw.split("\n[", 1) if raw.count("\n[") else (raw, "[]")
issues = json.loads(issues_txt)
prs = json.loads("[" + prs_txt)
linked = set()
for p in prs:
    linked.update(int(m) for m in re.findall(r"(?:closes|fixes|resolves)\s+#(\d+)",
                                             p.get("body") or "", re.I))
rank = {"size:xs": 0, "size:s": 1, "size:m": 2}
best = None
for i in issues:
    names = {l["name"] for l in i["labels"]}
    if "agent:stuck" in names or "agent:in-progress" in names:
        continue
    if i["number"] in linked:
        continue
    r = min((rank[n] for n in names if n in rank), default=3)
    key = (r, i["number"])
    if best is None or key < best[0]:
        best = (key, i["number"])
print(best[1] if best else "")
')"

[ -n "$choice" ] || skip "no claimable agent:eligible issue"
echo "$choice"
```

- [ ] **Step 4: Run the self-test to verify it passes**

```bash
chmod +x Scripts/loop-precheck.sh
Scripts/test-loop-precheck.sh
```

Expected: nine `ok - ` lines then `All loop-precheck tests passed.`

Fix the script, never the test, if a case fails. The likeliest real problem is
case 7's `date -u -j -f` parse — BSD-only syntax, correct on macOS (this repo is
macOS-only) but worth verifying rather than assuming.

- [ ] **Step 5: Run it against the real repository**

```bash
Scripts/loop-precheck.sh; echo "exit=$?"
```

Expected: either a bare issue number and `exit=0`, or a `skip:` line on stderr
with `exit=1`. Both are correct. Record which you saw and why.

- [ ] **Step 6: Commit**

```bash
git add Scripts/loop-precheck.sh Scripts/test-loop-precheck.sh
git -c commit.gpgsign=false commit -m "feat: add the agent-loop precheck and its self-test

Refuses when the root checkout's engine is stale, when a claim is live, or when
nothing is claimable; otherwise names one issue, ordered by size then number so
a trial is reproducible. Sweeps claims older than two hours so a run that died
mid-flight cannot shrink the backlog permanently. The loop agent invokes this
itself, because Orca's --precheck hook is skipped on manual runs."
```

---

### Task 2: `Scripts/loop-prompt.md`

The single-agent protocol. Its git SHA is the experiment's independent variable.

**Files:**
- Create: `Scripts/loop-prompt.md`

**Interfaces:**
- Consumes: the precheck contract from Task 1.
- Produces: the document Task 5's automation points at, and the trial-record
  frontmatter Task 4's report parses.

- [ ] **Step 1: Write `Scripts/loop-prompt.md`**

````markdown
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
   change — never the test.
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
it.

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
kind: <the issue's kind label>
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
````

- [ ] **Step 2: Verify every guardrail path exists**

A rule naming a file that does not exist is decoration:

```bash
for f in Scripts/loop-precheck.sh Scripts/loop-prompt.md orca.yaml CLAUDE.md \
         Scripts/check-substrate.sh Scripts/check-issue-format.sh \
         .github/workflows/issue-format.yml; do
  test -f "$f" && echo "ok  $f" || echo "MISSING  $f"
done
```

Expected: all `ok`. `Scripts/loop-report.sh` is named in the prompt but created
in Task 4 — that is expected and needs no change here.

- [ ] **Step 3: Commit**

```bash
git add Scripts/loop-prompt.md
git -c commit.gpgsign=false commit -m "feat: add the agent-loop protocol

One agent per run: it gates itself on the precheck, claims the issue, writes a
'started' record before doing anything, then rewrites it with the real outcome.
A record still reading 'started' is a run that died, which is how a lost trial
stays visible without a supervising process."
```

---

### Task 3: Signing identity and the `loop-trials` branch

Both are prerequisites for any run. No application logic.

**Files:**
- Create: `~/.ssh/waddle-agent-signing` and `.pub` (outside the repo, never committed)
- Create: the `loop-trials` orphan branch on `origin`

**Interfaces:**
- Consumes: nothing.
- Produces: the key path Task 2's prompt configures, and the branch its records
  are pushed to.

- [ ] **Step 1: Create a signing-only key**

Passphrase-less on purpose: an unattended run has nobody to approve a prompt.
This is not hypothetical — the composition spike was itself blocked by exactly
that, when 1Password's agent hung waiting for a user who was away.

```bash
ssh-keygen -t ed25519 -N "" -C "waddle-agent-loop" -f ~/.ssh/waddle-agent-signing
chmod 600 ~/.ssh/waddle-agent-signing
```

- [ ] **Step 2: Register it with GitHub as a signing key**

```bash
gh ssh-key add ~/.ssh/waddle-agent-signing.pub --title "waddle-agent-loop" --type signing
gh ssh-key list | grep waddle-agent-loop
```

Expected: the key listed with type `signing`. Without this, loop commits show as
"Unverified" on GitHub.

- [ ] **Step 3: Create the `loop-trials` orphan branch**

An orphan branch, not a branch of `main`, so merging it later contributes records
and no code.

```bash
git stash list >/dev/null   # ensure a clean tree before switching
git checkout --orphan loop-trials
git rm -rf . >/dev/null 2>&1 || true
mkdir -p docs/loop-trials
cat > docs/loop-trials/README.md <<'EOF'
# Loop trial records

One file per agent-loop run: `<YYYY-MM-DD>-issue-<N>.md`, with a `---`
frontmatter block that `Scripts/loop-report.sh` parses, followed by free prose.

This is an orphan branch. It carries records only, never code, so merging it
into `main` contributes nothing but data. Records are pushed here directly
rather than through a pull request: they are measurements, not changes, and they
must accumulate even while work PRs wait on review.

A record whose `outcome` is still `started` is a run that died mid-flight. Those
are kept, not cleaned up — a lost trial is data.
EOF
git add docs/loop-trials/README.md
git -c commit.gpgsign=false commit -m "docs: start the loop-trials record branch"
git push -u origin loop-trials
git checkout tylervick/agent-loop-spec
```

- [ ] **Step 4: Verify both prerequisites**

```bash
git ls-remote --heads origin loop-trials
ssh-keygen -Y sign -f ~/.ssh/waddle-agent-signing -n git /dev/null >/dev/null && echo "signing key usable"
git rev-parse --abbrev-ref HEAD
```

Expected: a `refs/heads/loop-trials` line, `signing key usable`, and that you are
back on `tylervick/agent-loop-spec`.

- [ ] **Step 5: Report**

This task creates no repository commit on the working branch — its outputs are a
key, a GitHub registration, and a remote branch. Record all three in your report
with the verification output. Nothing to commit here.

---

### Task 4: `Scripts/loop-report.sh` and its self-test

The artifact the experiment exists to produce. Written test-first.

**Files:**
- Create: `Scripts/loop-report.sh`
- Create: `Scripts/test-loop-report.sh`

**Interfaces:**
- Consumes: the trial-record format in this plan's header.
- Produces: `Scripts/loop-report.sh [<trials-dir>]`, defaulting to
  `docs/loop-trials`. Exits 0 even with no records.

- [ ] **Step 1: Write the failing self-test**

```bash
#!/bin/bash
# Tests for Scripts/loop-report.sh.
#
# HERMETIC: fixture records in a temp dir, a stub `gh` for PR state and review
# comments. The report is the experiment's only output, so a silent parse
# failure would mean drawing conclusions from data that was never read.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

make_fixture() { # dest
    mkdir -p "$1/trials" "$1/bin"
    cat > "$1/bin/gh" <<'STUB'
#!/bin/bash
# Stub gh. `pr view` reports merged with no changes requested; `api` returns
# two CodeRabbit comments, one Major and one Minor, in this repo's real format.
case "$1" in
  api) cat <<'J'
_🗄️ Data Integrity & Integration_ | _🟠 Major_ | _🏗️ Heavy lift_
_📐 Maintainability & Code Quality_ | _🟡 Minor_ | _⚡ Quick win_
J
  ;;
  *) echo '{"state":"MERGED","reviewDecision":""}' ;;
esac
STUB
    chmod +x "$1/bin/gh"
}
record() { # dir issue outcome prompt_sha [pr]
    cat > "$1/trials/2026-08-07-issue-$2.md" <<EOF
---
run_id: r-$2
timestamp: 2026-08-07T12:00:00Z
prompt_sha: $4
issue: $2
kind: test
size: xs
outcome: $3
wall_clock_seconds: 600
verification_result: pass
pr: ${5:-none}
learning_added: none
---
prose
EOF
}
report() { env PATH="$1/bin:/usr/bin:/bin" "$ROOT/Scripts/loop-report.sh" "$1/trials"; }

# 1. No records -> say so, exit 0, rather than dividing by zero.
make_fixture "$TMP/a"
out="$(report "$TMP/a")" || fail "non-zero exit on an empty trials dir"
echo "$out" | grep -qi "no trials" || fail "empty dir should say so; got: $out"
pass "reports cleanly with no trials"

# 2. Counts trials and breaks down outcomes.
make_fixture "$TMP/b"
record "$TMP/b" 41 pr-opened abc123 57
record "$TMP/b" 42 no-repro abc123
out="$(report "$TMP/b")" || fail "report failed"
echo "$out" | grep -q "trials: 2" || fail "wrong trial count; got: $out"
echo "$out" | grep -q "no-repro" || fail "outcome breakdown missing no-repro"
pass "counts trials and breaks down outcomes"

# 3. Segments by prompt_sha -- the whole point. Without it a change in success
#    rate cannot be attributed to a prompt edit.
make_fixture "$TMP/c"
record "$TMP/c" 41 pr-opened abc123 57
record "$TMP/c" 42 pr-opened def456 58
out="$(report "$TMP/c")" || fail "report failed"
echo "$out" | grep -q "abc123" || fail "prompt_sha abc123 missing"
echo "$out" | grep -q "def456" || fail "prompt_sha def456 missing"
pass "segments results by prompt version"

# 4. THE LOST-TRIAL SIGNAL. A record still reading `started` means the run died
#    before rewriting it. This replaces the supervisor the spike disproved, so
#    it must be surfaced loudly, never counted as a normal outcome.
make_fixture "$TMP/d"
record "$TMP/d" 43 started abc123
out="$(report "$TMP/d")" || fail "report failed"
echo "$out" | grep -qi "lost" || fail "a 'started' record was not reported as lost; got: $out"
pass "reports a still-started record as a lost trial"

# 5. Lists the stuck pile by issue, so the human has a triage queue.
make_fixture "$TMP/e"
record "$TMP/e" 44 stuck abc123
out="$(report "$TMP/e")" || fail "report failed"
echo "$out" | grep -q "44" || fail "stuck issue 44 not listed; got: $out"
pass "lists the stuck pile"

# 6. The LEADING signal: CodeRabbit findings counted per prompt version, using
#    this repo's real severity markers.
make_fixture "$TMP/f"
record "$TMP/f" 41 pr-opened abc123 57
out="$(report "$TMP/f")" || fail "report failed"
echo "$out" | grep -qi "coderabbit" || fail "no CodeRabbit signal; got: $out"
echo "$out" | grep -q "1 CodeRabbit" || fail "expected 1 Major finding, not the Minor; got: $out"
pass "counts only Major/Critical CodeRabbit findings"

# 7. A malformed record is REPORTED, never silently skipped -- dropping one
#    biases every number invisibly.
make_fixture "$TMP/g"
record "$TMP/g" 41 pr-opened abc123 57
printf 'no frontmatter here\n' > "$TMP/g/trials/2026-08-07-issue-99.md"
out="$(report "$TMP/g" 2>&1)" || fail "report failed"
echo "$out" | grep -qi "unparseable\|malformed" || fail "malformed record swallowed; got: $out"
pass "reports malformed records instead of dropping them"

echo "All loop-report tests passed."
```

- [ ] **Step 2: Run the self-test to verify it fails**

```bash
chmod +x Scripts/test-loop-report.sh
Scripts/test-loop-report.sh
```

Expected: FAIL — `Scripts/loop-report.sh: No such file or directory`.

- [ ] **Step 3: Write `Scripts/loop-report.sh`**

```bash
#!/bin/bash
# Aggregates agent-loop trial records into the report the experiment exists to
# produce: does the loop help, and did a given prompt edit make it better?
#
# Segmenting by prompt_sha is the point. One overall rate cannot distinguish
# "the loop works" from "the loop broke three prompt edits ago", and the prompt
# is the only variable deliberately changed.
#
# Two signals:
#   leading  -- CodeRabbit Major/Critical findings, and whether verification
#               passed unmodified. Fast, graded, what the prompt is tuned against.
#   lagging  -- the PR merged without requiring changes. Slow and authoritative;
#               it exists to check the leading signal is telling the truth.
#
# A record whose outcome is still `started` is a LOST TRIAL -- the run died
# before rewriting it. There is no supervising process to notice that (Orca's
# --timeout-ms does not fire), so this report is the only thing that will.
# Malformed records are reported, never skipped: dropping one biases every
# number here invisibly.
set -euo pipefail
TRIALS_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)/docs/loop-trials}"
MARKERS='🟠 Major|🔴 Critical'

shopt -s nullglob
files=("$TRIALS_DIR"/*-issue-*.md)
if [ ${#files[@]} -eq 0 ]; then
    echo "no trials recorded in $TRIALS_DIR"
    exit 0
fi

frontmatter() { awk 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{exit} NR>1' "$1"; }
field() { printf '%s\n' "$1" | awk -F': *' -v k="$2" '$1==k{print $2; exit}'; }

total=0; declare -a rows=(); declare -a bad=(); declare -a stuck=(); declare -a lost=()
for f in "${files[@]}"; do
    fm="$(frontmatter "$f")"
    issue="$(field "$fm" issue)"; outcome="$(field "$fm" outcome)"
    if [ -z "$issue" ] || [ -z "$outcome" ]; then bad+=("$(basename "$f")"); continue; fi
    total=$((total + 1))
    rows+=("$(field "$fm" prompt_sha)|$outcome|$(field "$fm" pr)|$issue")
    [ "$outcome" = "stuck" ] && stuck+=("$issue")
    [ "$outcome" = "started" ] && lost+=("$issue")
done

echo "trials: $total"
echo
echo "outcomes:"
printf '%s\n' "${rows[@]}" | cut -d'|' -f2 | sort | uniq -c | sed 's/^/  /'
echo

echo "by prompt version:"
for sha in $(printf '%s\n' "${rows[@]}" | cut -d'|' -f1 | sort -u); do
    n=0; merged=0; prs=0; findings=0
    for r in "${rows[@]}"; do
        [ "${r%%|*}" = "$sha" ] || continue
        n=$((n + 1))
        pr="$(printf '%s' "$r" | cut -d'|' -f3)"
        # A trial with no PR feeds neither signal. Counting it as zero findings
        # would score a dead run as a flawless review.
        [ "$pr" = "none" ] && continue
        prs=$((prs + 1))
        state="$(gh pr view "$pr" --json state,reviewDecision 2>/dev/null || echo '{}')"
        case "$state" in
            *'"MERGED"'*) case "$state" in
                *CHANGES_REQUESTED*) ;;
                *) merged=$((merged + 1)) ;;
            esac ;;
        esac
        c="$(gh api "repos/{owner}/{repo}/pulls/$pr/comments" --jq '.[].body' 2>/dev/null \
              | grep -c -E "$MARKERS" || true)"
        findings=$((findings + c))
    done
    if [ "$prs" -gt 0 ]; then
        echo "  $sha: $n trials, $merged merged without changes, $findings CodeRabbit Major/Critical across $prs PR(s)"
    else
        echo "  $sha: $n trials, no PRs opened"
    fi
done
echo

if [ ${#lost[@]} -gt 0 ]; then
    echo "LOST TRIALS (run died before recording an outcome): ${lost[*]}"
    echo "  These are runs that started and never finished. Nothing else detects them."
    echo
fi
if [ ${#stuck[@]} -gt 0 ]; then
    echo "stuck pile (needs human triage): ${stuck[*]}"
    echo
fi
if [ ${#bad[@]} -gt 0 ]; then
    echo "WARNING: ${#bad[@]} unparseable record(s), excluded from every number above:" >&2
    printf '  malformed: %s\n' "${bad[@]}" >&2
fi
```

- [ ] **Step 4: Run the self-test to verify it passes**

```bash
chmod +x Scripts/loop-report.sh
Scripts/test-loop-report.sh
```

Expected: seven `ok - ` lines then `All loop-report tests passed.`

- [ ] **Step 5: Commit**

```bash
git add Scripts/loop-report.sh Scripts/test-loop-report.sh
git -c commit.gpgsign=false commit -m "feat: add the agent-loop report and its self-test

Segments outcomes by prompt version, and surfaces records still reading
'started' as lost trials -- with no supervising process and a --timeout-ms that
does not fire, this report is the only thing that notices a run that died.
Counts CodeRabbit Major/Critical findings using this repo's real severity
markers."
```

---

### Task 5: Wire the automation, disabled, and prove it end to end

**Files:**
- Modify: `Scripts/loop-prompt.md` (append the operating section)

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces: the `waddle-loop` automation, created **disabled**.

- [ ] **Step 1: Create the automation, disabled**

```bash
orca automations create \
  --name "waddle-loop" \
  --trigger "0 9,13,17 * * *" \
  --timezone "$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')" \
  --prompt "Read Scripts/loop-prompt.md and carry it out." \
  --provider claude \
  --repo path:/Users/tyler/Documents/doom-ios-2026 \
  --workspace-mode new-per-run \
  --base-branch main \
  --disabled \
  --json
```

Record the id. **Then verify the repo mapping** — the spike found automations
resolving to a stale `github:tylervick/boombox` project despite being pointed at
the `waddle` path:

```bash
orca automations show <id> --json
```

Confirm the repo/project it names is `waddle`, and that the trigger parsed as
three fires a day. If it shows `boombox`, stop and report — a run against the
wrong project mapping is not something to work around silently.

- [ ] **Step 2: Prove a refusing precheck stops the run**

Do **not** label issues to force a refusal — that mutates the public backlog and
leaves it broken if the run fails partway. Override the precheck instead:

```bash
orca automations edit <id> --precheck "bash -c 'exit 1'" --json
orca automations run <id> --json
orca automations runs --id <id> --json
```

Record what happened. Per the spike, `orca automations run` skips `--precheck`
entirely, so the expected result is that the run proceeds anyway — which is
exactly why gating lives inside the agent. Confirm that expectation rather than
assuming it, then restore:

```bash
orca automations edit <id> --precheck "Scripts/loop-precheck.sh" --json
```

- [ ] **Step 3: Prove the record path with a no-work run**

```bash
orca automations edit <id> --prompt "Read Scripts/loop-prompt.md and carry it out, EXCEPT: do not make any code change and do not open a pull request. Run the precheck, claim the issue, push the 'started' record, then immediately rewrite the record with outcome: no-repro and reason 'dry run', and clean up as section 4 says." --json
orca automations run <id> --json
```

Then verify, from the repo root:

```bash
git fetch origin loop-trials
git show origin/loop-trials --stat | head
mkdir -p /tmp/lt && git archive origin/loop-trials docs/loop-trials | tar -x -C /tmp/lt
Scripts/loop-report.sh /tmp/lt/docs/loop-trials
gh issue view <the issue it picked> --json labels
```

Expected: a record file for the chosen issue, the report parsing it, and **no**
`agent:in-progress` label left behind. If the label is still there, the cleanup
path is broken — that is a real defect, not a dry-run artifact.

- [ ] **Step 4: Clean up the worktree Orca leaves behind**

The spike found `orca automations remove` does not delete per-run worktrees, and
these accumulate at three a day. Check and remove:

```bash
orca worktree list --json | grep -i "waddle-loop" || echo "none left behind"
# for each: orca worktree rm --worktree <selector>
```

Record what you found and removed.

- [ ] **Step 5: Restore the real prompt and record the controls**

```bash
orca automations edit <id> --prompt "Read Scripts/loop-prompt.md and carry it out." --json
orca automations show <id> --json
```

Append to `Scripts/loop-prompt.md`:

```markdown
## Operating this loop

- Automation id: `<id>` (`orca automations show <id>`)
- Pause: `orca automations edit <id> --disabled`
- Remove: `orca automations remove <id>` — then check `orca worktree list` and
  remove any per-run worktrees it left behind; it does not clean them up.
- Run once, now: `orca automations run <id>` (note: this skips `--precheck`,
  which is why the agent gates itself)
- Read results: `Scripts/loop-report.sh`

The automation stays **disabled** until three manual runs have landed clean.
```

- [ ] **Step 6: Commit**

```bash
git add Scripts/loop-prompt.md
git -c commit.gpgsign=false commit -m "docs: record the agent-loop automation controls

Automation id, pause, remove-and-clean-worktrees, run-once, and read-results,
so operating the loop does not mean reconstructing commands from the plan."
```

---

## Rollout (owner-performed, not an implementation task)

1. `orca automations run <id>` — watch it. Is the PR one you would accept? Read
   the trial record.
2. Repeat twice, adjusting `Scripts/loop-prompt.md` between runs. Every edit
   changes `prompt_sha`, so the report segments them automatically.
3. Only then `orca automations edit <id> --enabled`.
4. After a week, or once the backlog empties, run `Scripts/loop-report.sh` and
   decide whether the loop earned its keep.

## Verification

| Task | Gate |
| --- | --- |
| 1 | `Scripts/test-loop-precheck.sh` — 9 cases |
| 2 | Every path in the never-modify list exists |
| 3 | `loop-trials` ref on origin; signing key usable; back on the working branch |
| 4 | `Scripts/test-loop-report.sh` — 7 cases |
| 5 | A record round-trips to the branch, parses, and leaves no claim label |

## Notes for the implementer

**Bind to the spike's findings, not to intuition.** The table near the top of
this plan lists things that were tested and found false — no enforced timeout, no
precheck on manual runs, no working sub-workers, a different CodeRabbit marker
format. If something in your implementation depends on one of those behaving the
way it "should", stop and re-read that table.

**The lost-trial signal is load-bearing.** With the supervisor gone, a record
still reading `started` is the *only* way a died-mid-run trial becomes visible.
Task 4's case 4 is the test that protects it. Do not weaken it.

**Signing is deliberately disabled for now.** 1Password is unreachable and the
owner is away; the branch is unpushed, so these commits get re-signed later. Use
`git -c commit.gpgsign=false commit` per-command — never change git config, and
never leave `commit.gpgsign=false` behind.
