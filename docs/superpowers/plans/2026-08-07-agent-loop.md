# Agent Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an unattended loop that takes one `agent:eligible` issue per run,
does the work in a fresh Orca worktree, opens a pull request, and records a trial
record whether it succeeded or failed.

**Architecture:** An `orca automations` entry fires on a schedule. Its
`--precheck` runs `Scripts/loop-precheck.sh`, which refuses the run or names one
issue. Orca creates a fresh worktree and runs the `orca.yaml` setup hook. A
coordinator agent follows `Scripts/loop-prompt.md`: it claims the issue, starts a
supervised worker under a hard timeout, then reads the worker's output and writes
a trial record to the `loop-trials` orphan branch. `Scripts/loop-report.sh`
aggregates those records into a success rate.

**Tech Stack:** Bash (matching existing `Scripts/` conventions), GitHub CLI
(`gh`), the `orca` CLI, Markdown.

**Spec:** `docs/superpowers/specs/2026-08-07-agent-loop-design.md`

**Branch:** `tylervick/agent-loop-spec` (already created; the spec is committed
there at `b199313`).

## Global Constraints

- **Task 1 is a gate.** It proves the Orca composition. If it fails, STOP and
  report — do not proceed to Task 2 on assumptions.
- Bash scripts: `set -euo pipefail`, `ROOT` derived from the script's own
  location, header comment explaining *why* — matching `Scripts/check-engine-fresh.sh`.
- Script self-tests are **hermetic**: fixture repo in `mktemp -d`, a stub `gh` on
  a controlled `PATH`, never touching the real tree or the real GitHub. Matching
  `Scripts/test-check-substrate.sh`.
- Worker timeout: **45 minutes** (`--timeout-ms 2700000`). Stale-claim threshold:
  **2 hours**. Runs per day: **3**.
- The loop may never modify `Scripts/loop-*.sh`, `Scripts/loop-prompt.md`,
  `orca.yaml`, `CLAUDE.md`, `Scripts/check-substrate.sh`,
  `Scripts/check-issue-format.sh`, or `.github/workflows/issue-format.yml`.
- The loop may **add** files under `docs/learnings/` with an index line; it may
  never rewrite or remove an existing learning.
- Never edit or delete a test to make it pass.
- Trial records go to the `loop-trials` orphan branch, never into a work PR.
- Conventional commits. No Claude/AI attribution in commit messages, PR bodies,
  or issue comments.
- Commit signing occasionally hangs — retry up to 10 times at 15s intervals;
  never `--no-gpg-sign`, never commit unsigned.

## File Structure

| File | Responsibility |
| --- | --- |
| `Scripts/loop-precheck.sh` | Refuse a run, or name exactly one issue. Pure logic. |
| `Scripts/test-loop-precheck.sh` | Hermetic self-test for the above. |
| `Scripts/loop-prompt.md` | The protocol: coordinator section and worker section. The experiment's independent variable. |
| `Scripts/loop-report.sh` | Parse trial records, reconcile PR state, print the report. |
| `Scripts/test-loop-report.sh` | Hermetic self-test for the above. |
| `docs/superpowers/plans/2026-08-07-agent-loop-spike-findings.md` | Task 1's output; what the Orca composition actually does. |

## The trial record format

Every trial record is `docs/loop-trials/<YYYY-MM-DD>-issue-<N>.md` on the
`loop-trials` branch, with a `---`-delimited frontmatter block followed by free
prose. `Scripts/loop-report.sh` parses only the frontmatter. Exact keys:

```markdown
---
run_id: d-8f3a21
timestamp: 2026-08-07T14:03:11Z
prompt_sha: a1b2c3d
issue: 43
kind: test
size: xs
outcome: pr-opened
wall_clock_seconds: 812
turns: 24
verification_result: pass
pr: 57
learning_added: none
---

Free prose: what happened, what surprised the coordinator, anything a human
reading this in six weeks would want to know.
```

`outcome` is one of `pr-opened`, `failed-verification`, `timeout`, `no-repro`,
`stuck`. `verification_result` is `pass`, `fail`, or `not-run`. `pr` is an issue
number or `none`. `learning_added` is a path or `none`.

**The CodeRabbit finding count is deliberately not a record field.** CodeRabbit
reviews land minutes after a pull request opens, while the coordinator writes its
record the moment the worker finishes — so at write time the count does not exist
yet. Like merge state, it is reconciled at report time by
`Scripts/loop-report.sh`. The record captures only what is knowable when the run
ends; anything that matures later is queried fresh, so a record never goes stale.

---

### Task 1: Composition spike (GATE)

Proves the three assumptions the rest of the plan rests on. Produces findings,
not production code.

**Files:**
- Create: `docs/superpowers/plans/2026-08-07-agent-loop-spike-findings.md`

**Interfaces:**
- Consumes: nothing.
- Produces: the findings document. Task 3 (`loop-prompt.md`) uses the exact
  command sequence and JSON field names recorded there; Task 6 uses the
  `--precheck` semantics.

- [ ] **Step 1: Prove the Orca worker composition end to end**

Run these from the repo root, capturing every id. `worker-start` needs a task,
which needs a run, so all three are required:

```bash
orca orchestration run-create --objective "agent-loop spike" --json
# capture .runId (note the exact field name — record it)

orca orchestration task-create --spec "Print the current git branch, then stop." \
  --run <run_id> --json
# capture .taskId

orca orchestration worker-start --task <task_id> --worktree current \
  --agent claude --timeout-ms 120000 --json
# capture .dispatchId
```

Record the **exact JSON field names** each command returns. The plan's later
tasks assume `runId`, `taskId`, `dispatchId`; if they differ, the findings
document is the source of truth.

- [ ] **Step 2: Prove you can read the worker's output**

```bash
orca orchestration worker-read --dispatch <dispatch_id> --json
```

Record: does it return structured turns or raw terminal text? Is there a turn
count or token count anywhere in the payload? Is wall-clock derivable? Task 5's
report needs `turns` and `wall_clock_seconds` — if neither is available from
Orca, record that, and note that the coordinator must time the worker itself
with `date +%s` around the call.

- [ ] **Step 3: Prove the timeout actually fires**

```bash
orca orchestration task-create --spec "Sleep for 5 minutes, then print done." \
  --run <run_id> --json
orca orchestration worker-start --task <task_id> --worktree current \
  --agent claude --timeout-ms 30000 --json
```

Wait past 30s, then `worker-read`. Record what a timed-out dispatch looks like —
the status value, whether `worker-read` still returns partial output, and whether
`orca orchestration worker-abandon` or `worker-stop` is needed to clean up. The
coordinator must be able to distinguish "timed out" from "finished".

- [ ] **Step 4: Determine `--precheck` gating semantics**

The docs are ambiguous — the example precheck prints a value, which suggests
output matters, but exit code is the obvious gate. Test both:

```bash
orca automations create --name "spike-precheck-exit1" --trigger daily \
  --precheck "bash -c 'exit 1'" --prompt "Print OK" --provider claude \
  --repo path:/Users/tyler/Documents/doom-ios-2026 --disabled --json
orca automations run <id> --json
orca automations runs 2>&1 | head
```

Then repeat with `--precheck "bash -c 'echo 42; exit 0'"`. Record which
combination causes the run to proceed versus skip, and whether precheck stdout is
made available to the agent prompt (this decides whether `loop-precheck.sh` can
pass the chosen issue number to the coordinator through stdout, or whether the
coordinator must re-run the selection itself).

Delete both spike automations afterwards: `orca automations remove <id>`.

- [ ] **Step 5: Determine the CodeRabbit comment shape**

PR #36 has a completed CodeRabbit review.

```bash
gh pr view 36 --json reviews,comments --jq '.reviews[] | {author: .author.login, state: .state, body: .body[0:400]}'
gh api repos/tylervick/waddle/pulls/36/comments --jq '.[] | {user: .user.login, body: .body[0:300]}'
```

Record whether CodeRabbit findings carry a machine-readable severity marker
(e.g. a `_⚠️ Potential issue_` or `_🛠️ Refactor suggestion_` prefix), and write
down the exact string to grep for. If no reliable severity marker exists, record
that the fallback is a raw count of CodeRabbit review comments.

- [ ] **Step 6: Write the findings document**

Create `docs/superpowers/plans/2026-08-07-agent-loop-spike-findings.md` with one
section per step above, each recording the exact commands run and the exact
output shape. Include a **Verdict** section stating either:

- `COMPOSITION PROVEN` — the coordinator/worker split works; proceed to Task 2; or
- `COMPOSITION FAILED — <reason>` — in which case STOP. Do not start Task 2.
  The documented fallback is spec shape A: a single automation whose agent does
  the work and writes its own record, with the precheck stamping a run-start
  marker so an unfinished stamp registers as a failed trial. That fallback needs
  its own plan; escalate rather than improvising.

- [ ] **Step 7: Commit**

```bash
git add docs/superpowers/plans/2026-08-07-agent-loop-spike-findings.md
git commit -m "docs: record the agent-loop composition spike findings

Proves whether an automation-launched agent can drive a supervised worker,
what worker-read returns, how the timeout presents, how --precheck gates a
run, and whether CodeRabbit findings carry a parseable severity marker."
```

---

### Task 2: `Scripts/loop-precheck.sh` and its self-test

The decision logic: refuse a run, or name exactly one issue. Pure logic, no side
effects except the stale-claim sweep. Written test-first.

**Files:**
- Create: `Scripts/loop-precheck.sh`
- Create: `Scripts/test-loop-precheck.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `Scripts/loop-precheck.sh`. On proceed, prints **only** the chosen
  issue number to stdout and exits 0. On refusal, prints `skip: <reason>` to
  **stderr**, prints nothing to stdout, and exits 1. Task 3's prompt and Task 6's
  automation both depend on that contract.

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

# Fixture: a fake repo holding the precheck, a stub gh, and a stub engine check.
# ISSUES/PRS/TIMELINE are JSON files the stub gh echoes back.
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
# Stub gh. Echoes fixture JSON; logs mutating calls so tests can assert them.
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

# NOW is fixed so "2 hours ago" is deterministic across runs.
run_precheck() { # dir
    env PATH="$1/bin:/usr/bin:/bin" LOOP_NOW="2026-08-07T12:00:00Z" \
        "$1/Scripts/loop-precheck.sh"
}

# 1. No eligible issues at all -> refuse, and say so on stderr not stdout.
make_fixture "$TMP/a"
if out=$(run_precheck "$TMP/a" 2>"$TMP/err"); then fail "proceeded with no issues"; fi
[ -z "$out" ] || fail "printed '$out' to stdout on refusal; must be silent"
grep -q "^skip: " "$TMP/err" || fail "refusal reason missing from stderr"
pass "refuses when no eligible issues exist"

# 2. Ordering: size:xs beats size:s beats size:m, regardless of issue order.
make_fixture "$TMP/b"
cat > "$TMP/b/issues.json" <<'J'
[{"number":50,"labels":[{"name":"agent:eligible"},{"name":"size:m"}]},
 {"number":51,"labels":[{"name":"agent:eligible"},{"name":"size:xs"}]},
 {"number":52,"labels":[{"name":"agent:eligible"},{"name":"size:s"}]}]
J
out=$(run_precheck "$TMP/b") || fail "refused a valid backlog"
[ "$out" = "51" ] || fail "picked $out; expected 51 (the only size:xs)"
pass "prefers size:xs over size:s over size:m"

# 3. Tie-break within a size is the lowest issue number, so a trial is
#    reproducible rather than depending on gh's ordering.
make_fixture "$TMP/c"
cat > "$TMP/c/issues.json" <<'J'
[{"number":70,"labels":[{"name":"agent:eligible"},{"name":"size:xs"}]},
 {"number":44,"labels":[{"name":"agent:eligible"},{"name":"size:xs"}]}]
J
out=$(run_precheck "$TMP/c") || fail "refused a valid backlog"
[ "$out" = "44" ] || fail "picked $out; expected 44 (lowest number at same size)"
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

# 5. An issue already closed by an open PR is excluded. Work PRs sit unmerged
#    behind human review, so without this a later run re-picks finished work.
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

# 7. A claim older than 2h is stale (a run died mid-flight). Clear it and carry
#    on, or the backlog silently shrinks forever.
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

# 8. A stale engine in the root checkout makes every run a 25-minute rebuild
#    inside a 45-minute budget -- refuse instead of producing fake timeouts.
make_fixture "$TMP/h"
cat > "$TMP/h/issues.json" <<'J'
[{"number":42,"labels":[{"name":"agent:eligible"},{"name":"size:xs"}]}]
J
printf '#!/bin/bash\nexit 1\n' > "$TMP/h/Scripts/check-engine-fresh.sh"
if out=$(run_precheck "$TMP/h" 2>"$TMP/err"); then fail "proceeded with a stale engine"; fi
grep -q "engine" "$TMP/err" || fail "refusal does not name the engine: $(cat "$TMP/err")"
pass "refuses when the root checkout's engine is stale"

# 9. An eligible issue with no size label still gets picked, after all sized
#    ones -- it must never be silently unreachable.
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
# Wired as the --precheck of the `waddle-loop` Orca automation. Contract:
#   proceed -> print ONLY the issue number on stdout, exit 0
#   refuse  -> print "skip: <reason>" on stderr, nothing on stdout, exit 1
# Nothing else may reach stdout, because the caller reads it as the selection.
#
# Refusing is the common case and costs nothing. The three refusals, in order,
# and why each exists:
#
#   1. Stale engine in this checkout. Every worktree clones Vendor/out from
#      here, so a stale root makes check-engine-fresh.sh fail closed inside the
#      run and burns ~25 minutes of a 45-minute budget on a rebuild. The
#      resulting timeouts would look like agent failures and be nothing of the
#      sort.
#   2. A run is already live. One run at a time is what makes it impossible for
#      two xcodebuild sessions to share a simulator.
#   3. Nothing claimable. The backlog is finite by design; exhausting it is the
#      graceful end of the experiment, not an error.
#
# Liveness is the agent:in-progress LABEL, never the presence of a worktree --
# a worktree kept for post-mortem inspection must not read as a running job.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STALE_CLAIM_SECONDS=7200   # 2h; comfortably past the 45m worker timeout
CLAIM_LABEL="agent:in-progress"

# LOOP_NOW exists so the self-test can pin "now" and make staleness
# deterministic. Unset in production, where it means the current time.
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

has_label() { # json_labels label
    printf '%s' "$1" | grep -qF "\"$2\""
}

# 3. Liveness + stale sweep. Any issue still carrying the claim label is either
#    a live run (refuse) or the debris of a dead one (clear and continue).
claimed="$(printf '%s' "$issues" \
    | python3 -c 'import json,sys
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

# 4. Select. Exclusions: agent:stuck, and any issue a currently-open PR says it
#    closes -- work PRs wait on human review, so without that a later run would
#    re-pick finished work.
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

If a case fails, fix the script — never the test. The one case most likely to
need real debugging is 7 (stale sweep), because it depends on `date -u -j -f`,
which is BSD-only syntax; that is correct on macOS and this repo is macOS-only,
but the parse must be verified rather than assumed.

- [ ] **Step 5: Run it against the real repository**

```bash
Scripts/loop-precheck.sh; echo "exit=$?"
```

Expected: either a bare issue number and `exit=0`, or a `skip:` line on stderr
with `exit=1`. Both are correct. Record which you saw and why.

- [ ] **Step 6: Commit**

```bash
git add Scripts/loop-precheck.sh Scripts/test-loop-precheck.sh
git commit -m "feat: add the agent-loop precheck and its self-test

Refuses a run when the root checkout's engine is stale, when a claim is live,
or when nothing is claimable; otherwise names one issue, ordered by size then
issue number so a trial is reproducible. Sweeps claims older than two hours so
a died-mid-flight run cannot shrink the backlog permanently."
```

---

### Task 3: `Scripts/loop-prompt.md`

The protocol both agents follow. This is the experiment's independent variable,
so it is a tracked file whose SHA appears in every trial record.

**Files:**
- Create: `Scripts/loop-prompt.md`

**Interfaces:**
- Consumes: the precheck contract from Task 2 (issue number on stdout, exit 0);
  the exact Orca command sequence and JSON field names from Task 1's findings.
- Produces: the document the Task 6 automation points at. The trial-record
  frontmatter keys it specifies are what Task 5's report parses.

- [ ] **Step 1: Write `Scripts/loop-prompt.md`**

Use Task 1's findings for the exact field names in the coordinator's Orca calls.
Where this draft says `.runId` / `.taskId` / `.dispatchId`, substitute whatever
the spike actually recorded.

````markdown
# Agent loop protocol

You are running inside a fresh Orca worktree created for exactly one backlog
item. Read this whole file before acting.

There are two roles. You are the **coordinator**. You will start a **worker**
and supervise it. Do not do the work yourself — if you find yourself editing
`App/` or `Engine/`, you have taken the wrong role.

## Coordinator

1. Determine the issue number. The automation's precheck already chose one; if
   it was not passed to you, run `Scripts/loop-precheck.sh` and use its stdout.
   If that exits non-zero, stop — there is nothing to do, and that is a normal
   outcome, not a failure.

2. Record the start time and the prompt version:

   ```bash
   START=$(date -u +%s)
   PROMPT_SHA=$(git log -1 --format=%h -- Scripts/loop-prompt.md)
   ```

3. Claim the issue:

   ```bash
   gh issue edit <N> --add-label agent:in-progress
   ```

4. Start the worker under a hard 45-minute timeout:

   ```bash
   orca orchestration run-create --objective "agent-loop issue #<N>" --json
   orca orchestration task-create --spec "<the worker brief, see below>" --run <runId> --json
   orca orchestration worker-start --task <taskId> --worktree current \
     --agent claude --timeout-ms 2700000 --json
   ```

   The worker brief is: "Read `Scripts/loop-prompt.md`, section **Worker**, and
   carry it out for issue #<N>."

5. Wait for the worker, then read its output:

   ```bash
   orca orchestration worker-read --dispatch <dispatchId> --json
   ```

6. Write the trial record and push it to the `loop-trials` branch. **Do this
   even when the worker timed out, died, or failed** — an unrecorded failure is
   the one outcome that makes the whole experiment worthless.

   ```bash
   git fetch origin loop-trials
   git worktree add /tmp/loop-trials-$$ origin/loop-trials
   # write /tmp/loop-trials-$$/docs/loop-trials/<YYYY-MM-DD>-issue-<N>.md
   # commit there, push to origin loop-trials, then remove the worktree
   ```

   If the `loop-trials` branch does not exist, stop and report. Do not create
   it — a missing branch means the setup is wrong, and creating one would
   scatter records across divergent histories.

7. Clean up:
   - Always: `gh issue edit <N> --remove-label agent:in-progress`
   - On any outcome other than `pr-opened`: `gh issue edit <N> --add-label agent:stuck`,
     and comment on the issue stating what was attempted and exactly where it
     stopped. Be specific and honest; a vague comment wastes the next human who
     reads it.

## Worker

You are fixing exactly one issue. Do not touch anything else.

1. Read the issue: `gh issue view <N>`. It states a definition of done, a
   verification command, and its provenance.

2. **Reproduce before fixing.** Confirm the described condition actually exists
   at HEAD. If it does not, stop and report `no-repro` with your evidence — that
   is a valuable, correct outcome, and the backlog was built expecting some of
   these.

3. Make the change. Keep it to what the definition of done names, and nothing
   more.

4. Run the issue's own verification command **unmodified**. If it fails, fix
   your change. If it cannot pass without weakening a test, stop and report —
   see the rules below.

5. If you hit a trap worth remembering, add one file to `docs/learnings/` with
   its index line in `docs/learnings/INDEX.md`. `Scripts/check-substrate.sh`
   enforces the bijection; run it.

6. Commit, push your branch, and open a pull request whose body contains
   `Closes #<N>`.

## Rules that are absolute

- **Never edit, weaken, delete, or skip a test to make something pass.** If the
  work cannot be done honestly, stopping is the correct outcome and will be
  recorded as such. This is the single most important rule here.
- **Never modify** `Scripts/loop-*.sh`, `Scripts/loop-prompt.md`, `orca.yaml`,
  `CLAUDE.md`, `Scripts/check-substrate.sh`, `Scripts/check-issue-format.sh`, or
  `.github/workflows/issue-format.yml`. Those are the rules you are judged by.
  You may **add** a `docs/learnings/` file; you may never rewrite or delete one.
- **Never push to `main`.** Your own branch only.
- **Never touch** signing, the release path, `Engine/woof`'s vendor pin, or App
  Store metadata.
- No Claude/AI attribution in commit messages, PR bodies, or issue comments.
- Read `CLAUDE.md` — its rules apply to you in full.
````

- [ ] **Step 2: Verify the guardrail list matches reality**

Every path named under "Never modify" must exist, or the rule is decoration:

```bash
for f in Scripts/loop-precheck.sh Scripts/loop-prompt.md orca.yaml CLAUDE.md \
         Scripts/check-substrate.sh Scripts/check-issue-format.sh \
         .github/workflows/issue-format.yml; do
  test -f "$f" && echo "ok  $f" || echo "MISSING  $f"
done
```

Expected: all `ok`. `Scripts/loop-report.sh` is deliberately absent from that
list because Task 5 has not created it yet — add it to the prompt in Task 5.

- [ ] **Step 3: Commit**

```bash
git add Scripts/loop-prompt.md
git commit -m "feat: add the agent-loop protocol

The coordinator claims an issue, supervises a worker under a 45-minute
timeout, and records a trial whatever the outcome. The worker reproduces
before fixing, runs the issue's own verification unmodified, and may never
weaken a test or edit the rules it is judged by."
```

---

### Task 4: Agent signing identity and the `loop-trials` branch

Setup with no application logic, but both are prerequisites for any run.

**Files:**
- Create: `~/.ssh/waddle-agent-signing` and `.pub` (outside the repo, not committed)
- Create: the `loop-trials` orphan branch on `origin`

**Interfaces:**
- Consumes: nothing.
- Produces: a signing key path and committer identity the Task 6 automation
  configures per run; and the `loop-trials` branch the coordinator pushes to.

- [ ] **Step 1: Create a signing-only key**

Passphrase-less on purpose: an unattended run at 2am has nobody to dismiss a
prompt, and 1Password's signing agent is already known to hang intermittently
here. The key signs; it grants no push access, which stays with the checkout's
existing credentials.

```bash
ssh-keygen -t ed25519 -N "" -C "waddle-agent-loop" -f ~/.ssh/waddle-agent-signing
chmod 600 ~/.ssh/waddle-agent-signing
```

- [ ] **Step 2: Register it with GitHub as a signing key**

```bash
gh ssh-key add ~/.ssh/waddle-agent-signing.pub --title "waddle-agent-loop" --type signing
gh ssh-key list | grep waddle-agent-loop
```

Expected: the key appears with type `signing`. Without this, loop commits show
as "Unverified" on GitHub.

- [ ] **Step 3: Record the git configuration the loop will use**

Do not set these globally — they apply per run, inside the disposable worktree,
so your own commits are unaffected:

```bash
git config user.name "WADdle Agent Loop"
git config user.email "agent-loop@tylervick.com"
git config gpg.format ssh
git config user.signingkey ~/.ssh/waddle-agent-signing
git config commit.gpgsign true
```

Add these five lines to `Scripts/loop-prompt.md`'s Coordinator section as step
0, so every run configures its worktree before its first commit.

- [ ] **Step 4: Create the `loop-trials` orphan branch**

An orphan branch, not a branch of `main`, so its history holds records and no
code — merging it into `main` later contributes only records.

```bash
git checkout --orphan loop-trials
git rm -rf . >/dev/null 2>&1 || true
mkdir -p docs/loop-trials
cat > docs/loop-trials/README.md <<'EOF'
# Loop trial records

One file per agent-loop run: `<YYYY-MM-DD>-issue-<N>.md`, with a `---`
frontmatter block that `Scripts/loop-report.sh` parses, followed by free prose.

This is an orphan branch. It carries records only, never code, so merging it
into `main` contributes nothing but data. Records are pushed here directly
rather than through a pull request: they are measurements, not changes, and
they must accumulate even while work PRs wait on review.
EOF
git add docs/loop-trials/README.md
git commit -m "docs: start the loop-trials record branch"
git push -u origin loop-trials
git checkout tylervick/agent-loop-spec
```

- [ ] **Step 5: Verify both prerequisites**

```bash
git ls-remote --heads origin loop-trials    # must print a ref
ssh-keygen -Y sign -f ~/.ssh/waddle-agent-signing -n git /dev/null >/dev/null && echo "signing key usable"
```

Expected: a `refs/heads/loop-trials` line, and `signing key usable`.

- [ ] **Step 6: Commit the prompt change from Step 3**

```bash
git add Scripts/loop-prompt.md
git commit -m "feat: configure the agent signing identity per run

A passphrase-less signing-only key, set inside the disposable worktree so the
owner's own git config is untouched. Unattended runs cannot dismiss a signing
prompt, and 1Password's agent is known to hang here."
```

---

### Task 5: `Scripts/loop-report.sh` and its self-test

The artifact the experiment exists to produce. Written test-first.

**Files:**
- Create: `Scripts/loop-report.sh`
- Create: `Scripts/test-loop-report.sh`
- Modify: `Scripts/loop-prompt.md` (add `Scripts/loop-report.sh` to the
  never-modify list)

**Interfaces:**
- Consumes: the trial-record frontmatter format defined in this plan's header
  and written by Task 3's coordinator.
- Produces: `Scripts/loop-report.sh [<trials-dir>]`, defaulting to
  `docs/loop-trials`. Prints a human-readable report; exits 0 even with no
  records.

- [ ] **Step 1: Write the failing self-test**

Create `Scripts/test-loop-report.sh`:

```bash
#!/bin/bash
# Tests for Scripts/loop-report.sh.
#
# HERMETIC: fixture trial records in a temp dir, a stub `gh` for PR state.
# The report is the experiment's only output, so a silent parse failure here
# would mean drawing conclusions from data that was never read.
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
# two CodeRabbit review comments, one of which carries a severity marker.
case "$1" in
  api) cat <<'J'
[{"user":{"login":"coderabbitai"},"body":"_⚠️ Potential issue_\n\nsomething"},
 {"user":{"login":"coderabbitai"},"body":"_🧹 Nitpick_\n\nsomething minor"}]
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
run_id: d-$2
timestamp: 2026-08-07T12:00:00Z
prompt_sha: $4
issue: $2
kind: test
size: xs
outcome: $3
wall_clock_seconds: 600
turns: 10
verification_result: pass
pr: ${5:-none}
learning_added: none
---
prose
EOF
}
report() { env PATH="$1/bin:/usr/bin:/bin" "$ROOT/Scripts/loop-report.sh" "$1/trials"; }

# 1. No records at all -> say so and exit 0, rather than dividing by zero.
make_fixture "$TMP/a"
out="$(report "$TMP/a")" || fail "non-zero exit on an empty trials dir"
echo "$out" | grep -qi "no trials" || fail "empty dir should say so; got: $out"
pass "reports cleanly with no trials"

# 2. Counts trials and separates outcomes.
make_fixture "$TMP/b"
record "$TMP/b" 41 pr-opened abc123 57
record "$TMP/b" 42 timeout abc123
out="$(report "$TMP/b")" || fail "report failed"
echo "$out" | grep -q "trials: 2" || fail "wrong trial count; got: $out"
echo "$out" | grep -q "timeout" || fail "outcome breakdown missing timeout"
pass "counts trials and breaks down outcomes"

# 3. Segments by prompt_sha -- this is the whole point. Without it a change in
#    success rate cannot be attributed to a prompt edit.
make_fixture "$TMP/c"
record "$TMP/c" 41 pr-opened abc123 57
record "$TMP/c" 42 pr-opened def456 58
out="$(report "$TMP/c")" || fail "report failed"
echo "$out" | grep -q "abc123" || fail "prompt_sha abc123 missing from report"
echo "$out" | grep -q "def456" || fail "prompt_sha def456 missing from report"
pass "segments results by prompt version"

# 4. Lists the stuck pile by issue, so the human has a triage queue.
make_fixture "$TMP/d"
record "$TMP/d" 44 stuck abc123
out="$(report "$TMP/d")" || fail "report failed"
echo "$out" | grep -q "44" || fail "stuck issue 44 not listed; got: $out"
pass "lists the stuck pile"

# 5. A malformed record is REPORTED, never silently skipped -- a dropped record
#    would quietly bias every number in the report.
make_fixture "$TMP/e"
record "$TMP/e" 41 pr-opened abc123 57
printf 'no frontmatter here\n' > "$TMP/e/trials/2026-08-07-issue-99.md"
out="$(report "$TMP/e" 2>&1)" || fail "report failed"
echo "$out" | grep -qi "unparseable\|malformed" || fail "malformed record was swallowed; got: $out"
pass "reports malformed records instead of dropping them"

# 6. The LEADING signal: CodeRabbit findings are counted per prompt version.
#    This is the half of the metric that arrives in minutes and is what the
#    prompt is actually tuned against, so a report without it is half blind.
make_fixture "$TMP/f"
record "$TMP/f" 41 pr-opened abc123 57
out="$(report "$TMP/f")" || fail "report failed"
echo "$out" | grep -qi "coderabbit" || fail "no CodeRabbit signal in the report; got: $out"
pass "reports the CodeRabbit findings count"

# 7. A trial that opened no PR contributes no CodeRabbit count and must not be
#    scored as zero findings -- "no PR" and "a clean PR" are opposite outcomes.
make_fixture "$TMP/g"
record "$TMP/g" 42 timeout abc123
out="$(report "$TMP/g")" || fail "report failed"
echo "$out" | grep -q "1 trials, 0 merged" || fail "PR-less trial mis-scored; got: $out"
pass "does not score a PR-less trial as a clean review"

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
# Segmenting by prompt_sha is the point. A single overall success rate cannot
# distinguish "the loop works" from "the loop stopped working three prompt
# edits ago", and the prompt is the only variable being deliberately changed.
#
# Two signals, per the spec:
#   leading  -- verification passed unmodified, and CodeRabbit findings count.
#               Fast, graded, and what the prompt is tuned against.
#   lagging  -- the PR merged without requiring changes. Slow and authoritative;
#               it exists to check that the leading signal is telling the truth.
#
# A malformed record is reported, never skipped: silently dropping records
# biases every number here, and the bias would be invisible.
set -euo pipefail
TRIALS_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)/docs/loop-trials}"

shopt -s nullglob
files=("$TRIALS_DIR"/*-issue-*.md)
if [ ${#files[@]} -eq 0 ]; then
    echo "no trials recorded in $TRIALS_DIR"
    exit 0
fi

# Extract frontmatter into "key=value" lines; empty output means unparseable.
frontmatter() { awk 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{exit} NR>1' "$1"; }
field() { printf '%s\n' "$1" | awk -F': *' -v k="$2" '$1==k{print $2; exit}'; }

total=0; declare -a rows=(); declare -a bad=(); declare -a stuck=()
for f in "${files[@]}"; do
    fm="$(frontmatter "$f")"
    issue="$(field "$fm" issue)"
    outcome="$(field "$fm" outcome)"
    if [ -z "$issue" ] || [ -z "$outcome" ]; then
        bad+=("$(basename "$f")")
        continue
    fi
    total=$((total + 1))
    rows+=("$(field "$fm" prompt_sha)|$outcome|$(field "$fm" pr)|$(field "$fm" wall_clock_seconds)|$issue")
    [ "$outcome" = "stuck" ] && stuck+=("$issue")
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
        # A trial with no PR contributes to neither signal. Counting it as zero
        # findings would score a timeout as a flawless review.
        [ "$pr" = "none" ] && continue
        prs=$((prs + 1))

        # Lagging signal: merged, and review never demanded changes.
        state="$(gh pr view "$pr" --json state,reviewDecision 2>/dev/null || echo '{}')"
        case "$state" in
            *'"MERGED"'*) case "$state" in
                *CHANGES_REQUESTED*) ;;
                *) merged=$((merged + 1)) ;;
            esac ;;
        esac

        # Leading signal: CodeRabbit findings at Important-or-above. The marker
        # strings come from Task 1's spike; if that found no reliable severity
        # marker, MARKERS should be emptied and this becomes a raw comment count.
        MARKERS='⚠️ Potential issue|🛠️ Refactor suggestion'
        c="$(gh api "repos/{owner}/{repo}/pulls/$pr/comments" --paginate 2>/dev/null \
              | grep -c -E "$MARKERS" || true)"
        findings=$((findings + c))
    done
    if [ "$prs" -gt 0 ]; then
        echo "  $sha: $n trials, $merged merged without changes, $findings CodeRabbit findings across $prs PR(s)"
    else
        echo "  $sha: $n trials, $merged merged without changes, no PRs opened"
    fi
done
echo

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

- [ ] **Step 5: Add the report to the prompt's never-modify list**

In `Scripts/loop-prompt.md`, change the never-modify bullet from
`Scripts/loop-*.sh` to explicitly enumerate
`Scripts/loop-precheck.sh`, `Scripts/loop-report.sh`, and
`Scripts/loop-prompt.md`. A glob is easy for an agent to read as not applying to
a file it wants to touch; the enumeration is not.

- [ ] **Step 6: Commit**

```bash
git add Scripts/loop-report.sh Scripts/test-loop-report.sh Scripts/loop-prompt.md
git commit -m "feat: add the agent-loop report and its self-test

Segments outcomes by prompt version, since a single overall rate cannot tell
'the loop works' from 'the loop broke three prompt edits ago'. Malformed
records are reported rather than skipped, because dropping them would bias
every number invisibly."
```

---

### Task 6: Wire the automation, disabled, and prove it end to end

Creates the Orca object and runs the whole path once with a no-op worker before
anything real happens.

**Files:**
- No repository files. Creates one `orca automations` entry.

**Interfaces:**
- Consumes: everything from Tasks 2–5, plus Task 1's `--precheck` semantics.
- Produces: the `waddle-loop` automation, created **disabled**.

- [ ] **Step 1: Create the automation, disabled**

Use the `--precheck` semantics recorded in Task 1's findings. Created disabled so
nothing can fire before the dry run passes.

```bash
orca automations create \
  --name "waddle-loop" \
  --trigger "0 9,13,17 * * *" \
  --timezone "$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')" \
  --precheck "Scripts/loop-precheck.sh" \
  --prompt "Read Scripts/loop-prompt.md and carry out the coordinator role." \
  --provider claude \
  --repo path:/Users/tyler/Documents/doom-ios-2026 \
  --workspace-mode new-per-run \
  --base-branch main \
  --disabled \
  --json
```

Record the returned automation id. Confirm the trigger parsed as three runs a
day, not something else:

```bash
orca automations show <id> --json
```

- [ ] **Step 2: Prove the precheck refuses correctly through Orca**

Temporarily label every `agent:eligible` issue so nothing is claimable, then
force a run and confirm it skips rather than proceeding:

```bash
gh issue list --label agent:eligible --state open --json number --jq '.[].number' \
  | while read -r n; do gh issue edit "$n" --add-label agent:stuck; done
orca automations run <id> --json
orca automations runs 2>&1 | head -5
```

Expected: the run records a skip, and no worktree was created
(`orca worktree list | grep -c waddle-loop` → 0).

Then restore:

```bash
gh issue list --label agent:stuck --state open --json number --jq '.[].number' \
  | while read -r n; do gh issue edit "$n" --remove-label agent:stuck; done
```

- [ ] **Step 3: Prove the record path with a no-op worker**

Temporarily replace the automation prompt so the coordinator supervises a worker
that does nothing but print, then writes a real trial record:

```bash
orca automations edit <id> --prompt "Read Scripts/loop-prompt.md and carry out the coordinator role, EXCEPT: the worker's brief is only 'print the current branch name and stop'. Do not edit any file, do not open a pull request. Still write and push the trial record, with outcome: no-repro."
orca automations run <id> --json
```

Then verify the record actually landed on the branch:

```bash
git fetch origin loop-trials
git show origin/loop-trials:docs/loop-trials/ | head
Scripts/loop-report.sh <(git show origin/loop-trials:docs/loop-trials/) 2>&1 | head
```

Expected: a record file exists for the chosen issue, and the report parses it.
Also confirm the claim label was cleaned up:
`gh issue view <N> --json labels` must not show `agent:in-progress`.

- [ ] **Step 4: Restore the real prompt**

```bash
orca automations edit <id> --prompt "Read Scripts/loop-prompt.md and carry out the coordinator role."
orca automations show <id> --json
```

- [ ] **Step 5: Record the automation id where a human will find it**

Append to `Scripts/loop-prompt.md`, at the end:

```markdown
## Operating this loop

- Automation id: `<id>` (`orca automations show <id>`)
- Pause: `orca automations edit <id> --disabled`
- Remove entirely: `orca automations remove <id>`
- Run once, now: `orca automations run <id>`
- Read results: `Scripts/loop-report.sh`

The automation stays **disabled** until three manual runs have landed clean.
```

- [ ] **Step 6: Commit**

```bash
git add Scripts/loop-prompt.md
git commit -m "docs: record the agent-loop automation controls

Automation id, pause, remove, run-once, and read-results, so operating the
loop does not require reconstructing the commands from the plan."
```

---

## Rollout (owner-performed, not an implementation task)

The automation stays disabled until this gate passes. It is deliberately manual:
the first real runs are the riskiest, and watching three of them teaches more
about the prompt than reading it ever will.

1. `orca automations run <id>` — watch it. Confirm the PR it opens is one you
   would have accepted, and read the trial record.
2. Repeat twice more, adjusting `Scripts/loop-prompt.md` between runs. Every
   edit changes `prompt_sha`, so `Scripts/loop-report.sh` will segment them.
3. Only then: `orca automations edit <id> --enabled`.
4. After roughly a week, or once the backlog empties, run
   `Scripts/loop-report.sh` and decide whether the loop earned its keep.

## Verification

The spec's definition of done: after a handful of trials,
`Scripts/loop-report.sh` prints a success rate segmented by prompt version, and
"did this help?" is answerable from data.

Per-task gates:

| Task | Gate |
| --- | --- |
| 1 | Findings document ends `COMPOSITION PROVEN`, or execution stops |
| 2 | `Scripts/test-loop-precheck.sh` — 9 cases |
| 3 | Every path in the never-modify list exists |
| 4 | `loop-trials` ref exists on origin; signing key usable |
| 5 | `Scripts/test-loop-report.sh` — 7 cases |
| 6 | A trial record round-trips to the branch and parses |

## Notes for the implementer

**Task 1 is a real gate, not a formality.** The coordinator/worker split is the
spec's central bet and it rests on an unverified assumption: that an
automation-launched agent can itself call `orca orchestration worker-start`. If
it cannot, Tasks 3 and 6 are wrong in ways that will not be obvious until they
fail at runtime. Stop and escalate rather than adapting on the fly — the
fallback is a different architecture and deserves its own plan.

**The precheck is where a silent bug hurts most.** It runs unattended, its
failures look like "nothing to do", and nothing downstream notices. That is why
it has nine test cases for maybe sixty lines of logic. Do not trim them.

**Do not run this against the real backlog before Task 6's dry run passes.** A
malformed prompt at that point burns real issues, opens real PRs on a public
repo, and — worse for the experiment — produces trial records that mix protocol
bugs with genuine agent failures, which is exactly the confound the whole design
is built to avoid.
