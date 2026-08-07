# Agent Loop: CI & Review Response Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make each loop run wait for CI and CodeRabbit, snapshot the review
findings *before* fixing anything, then fix red CI and address Major/Critical
findings — and sweep the per-run worktrees Orca leaves behind.

**Architecture:** Three independent changes to the shipped loop. The precheck
gains a start-of-run worktree sweep beside its existing stale-claim sweep. The
protocol gains a wait-snapshot-fix phase between opening the pull request and
writing the final record. The report stops querying GitHub for the finding count
and reads it from the record instead — mandatory, because the agent now changes
that count before the report ever runs.

**Tech Stack:** Bash (matching existing `Scripts/` conventions), GitHub CLI
(`gh`), the `orca` CLI, Markdown.

**Spec:** `docs/superpowers/specs/2026-08-07-agent-loop-design.md` (amended at
`dacc26e`).

**Branch:** `tylervick/agent-loop-review-response` (already created).

## Global Constraints

- Bash scripts: `set -euo pipefail`, `ROOT` derived from the script's own
  location, header comment explaining *why* — matching `Scripts/check-engine-fresh.sh`.
- Self-tests are **hermetic**: fixtures in `mktemp -d`, stub binaries on a
  controlled `PATH`, never touching the real tree, real GitHub, or real Orca.
- Stale-claim and abandoned-worktree threshold: **2 hours** (`STALE_CLAIM_SECONDS=7200`).
- Agent work budget: **45 minutes**, self-checked. CI/review wait cap: **15
  minutes**, separate and additional.
- `outcome` remains `started`, `pr-opened`, `failed-verification`, `no-repro`,
  `stuck`. Applying fixes does **not** introduce a new outcome value.
- The snapshot (`coderabbit_findings_first`) is written and pushed **before any
  fix is attempted**.
- Never weaken, delete, or skip an existing test case.
- Conventional commits, signed. No Claude/AI attribution anywhere.
- `.superpowers/` is gitignored scratch — never commit from it.

## File Structure

| File | Change |
| --- | --- |
| `Scripts/loop-precheck.sh` | Add the abandoned-worktree sweep (Task 1) |
| `Scripts/test-loop-precheck.sh` | +2 cases → 12 total (Task 1) |
| `Scripts/loop-prompt.md` | New wait/snapshot/fix section; 4 new record fields (Task 2) |
| `Scripts/loop-report.sh` | Read the snapshot from records, not from GitHub (Task 3) |
| `Scripts/test-loop-report.sh` | +2 cases → 10 total (Task 3) |

---

### Task 1: Sweep abandoned per-run worktrees

**Files:**
- Modify: `Scripts/loop-precheck.sh`
- Modify: `Scripts/test-loop-precheck.sh`

**Interfaces:**
- Consumes: the script's existing `NOW_EPOCH`, `to_epoch()`, `STALE_CLAIM_SECONDS`, and `skip()`.
- Produces: no new interface. The sweep is a side effect logged to stderr; the
  stdout contract (issue number only, or nothing) is unchanged.

- [ ] **Step 1: Write the two failing test cases**

Append to `Scripts/test-loop-precheck.sh`, before the final `echo`. Note the
fixture's stub `orca` — the existing `make_fixture` does not create one, so these
cases extend it inline.

```bash
# 11. Sweeps an abandoned per-run worktree older than the threshold, and leaves
#     a recent one alone. Orca does not remove these itself and a run cannot
#     remove the one it is executing inside, so without this they accumulate at
#     three a day.
make_fixture "$TMP/j"
cat > "$TMP/j/issues.json" <<'J'
[{"number":42,"labels":[{"name":"agent:eligible"},{"name":"size:xs"}]}]
J
cat > "$TMP/j/bin/orca" <<'STUB'
#!/bin/bash
FIX="$(dirname "$(dirname "$0")")"
echo "$*" >> "$FIX/orca-calls.log"
case "$1 $2" in
  "worktree list")
    echo "id::/w/auto-waddle-loop-run-1-20260807T0900  refs/heads/a  /w/auto-waddle-loop-run-1-20260807T0900"
    echo "id::/w/auto-waddle-loop-run-2-20260807T1155  refs/heads/b  /w/auto-waddle-loop-run-2-20260807T1155"
    echo "id::/w/CRUD-games  refs/heads/c  /w/CRUD-games" ;;
  "worktree rm") exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP/j/bin/orca"
: > "$TMP/j/orca-calls.log"
out=$(run_precheck "$TMP/j") || fail "refused a valid backlog"
[ "$out" = "42" ] || fail "picked $out; expected 42"
grep -q "auto-waddle-loop-run-1-20260807T0900" "$TMP/j/orca-calls.log" \
    || fail "the 3h-old worktree was not swept"
grep -q "auto-waddle-loop-run-2-20260807T1155" "$TMP/j/orca-calls.log" \
    && fail "swept a worktree only 5 minutes old"
grep -q "CRUD-games" "$TMP/j/orca-calls.log" \
    && fail "touched a worktree that is not a loop worktree"
pass "sweeps abandoned loop worktrees and spares recent and unrelated ones"

# 12. An unparseable worktree name is REPORTED and skipped, never silently
#     ignored. The sweep keys on Orca's naming convention; if that changes, the
#     sweep must fail loudly rather than quietly stop working.
make_fixture "$TMP/k"
cat > "$TMP/k/issues.json" <<'J'
[{"number":42,"labels":[{"name":"agent:eligible"},{"name":"size:xs"}]}]
J
cat > "$TMP/k/bin/orca" <<'STUB'
#!/bin/bash
FIX="$(dirname "$(dirname "$0")")"
echo "$*" >> "$FIX/orca-calls.log"
case "$1 $2" in
  "worktree list") echo "id::/w/auto-waddle-loop-newformat  refs/heads/a  /w/auto-waddle-loop-newformat" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP/k/bin/orca"
: > "$TMP/k/orca-calls.log"
out=$(run_precheck "$TMP/k" 2>"$TMP/err") || fail "refused a valid backlog"
[ "$out" = "42" ] || fail "picked $out; expected 42"
grep -q "cannot parse a timestamp" "$TMP/err" || fail "unparseable name was skipped silently"
grep -q "worktree rm" "$TMP/k/orca-calls.log" && fail "removed a worktree it could not date"
pass "reports an unparseable worktree name instead of silently skipping it"
```

- [ ] **Step 2: Run the suite to verify the new cases fail**

```bash
Scripts/test-loop-precheck.sh
```

Expected: cases 1–10 pass, then case 11 FAILs with "the 3h-old worktree was not
swept" — the sweep does not exist yet.

- [ ] **Step 3: Add the sweep to `Scripts/loop-precheck.sh`**

Insert immediately after the engine-freshness check (after its closing `fi`) and
before the `gh issue list` call:

```bash
# 2. Sweep abandoned per-run worktrees.
#
# `orca automations remove` does not delete the worktrees Orca creates per run,
# and a run cannot delete the one it is executing inside. At three runs a day
# they accumulate indefinitely.
#
# Start of run is the only workable moment. A run that crashes cannot clean up
# after itself by definition, so end-of-run cleanup would only ever fire in the
# case where there is nothing to clean.
#
# Age comes from the timestamp Orca puts in the worktree name
# (auto-waddle-loop-run-<n>-<YYYYMMDDTHHMM>) rather than filesystem mtime, so it
# is deterministic and testable. If that convention ever changes the name will
# stop parsing, and this reports it loudly rather than quietly sweeping nothing.
#
# Removing a swept worktree cannot strand a pull request: the loop pushes its
# branch to origin long before any worktree is old enough to qualify.
if command -v orca >/dev/null 2>&1; then
    orca worktree list 2>/dev/null | awk '{print $3}' | grep '/auto-waddle-loop-' \
    | while read -r wt_path; do
        base="$(basename "$wt_path")"
        stamp="${base##*-}"
        case "$stamp" in
            [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9]) ;;
            *)
                echo "worktree sweep: cannot parse a timestamp from '$base'; skipping it" >&2
                continue ;;
        esac
        d="${stamp%T*}"; t="${stamp#*T}"
        wt_iso="${d:0:4}-${d:4:2}-${d:6:2}T${t:0:2}:${t:2:2}:00Z"
        wt_age=$(( NOW_EPOCH - $(to_epoch "$wt_iso") ))
        if [ "$wt_age" -ge "$STALE_CLAIM_SECONDS" ]; then
            if orca worktree rm --worktree "path:$wt_path" >/dev/null 2>&1; then
                echo "swept abandoned worktree $base (${wt_age}s old)" >&2
            else
                echo "worktree sweep: could not remove '$base'" >&2
            fi
        fi
    done
fi
```

Renumber the comments on the steps that follow it (`# 2.` → `# 3.`, and so on)
so the numbering stays sequential.

- [ ] **Step 4: Run the suite to verify it passes**

```bash
Scripts/test-loop-precheck.sh
```

Expected: twelve `ok - ` lines then `All loop-precheck tests passed.`

If case 11 fails on the date parse, check `to_epoch`'s BSD `date -u -j -f` format
string against the `wt_iso` you build — both must be `%Y-%m-%dT%H:%M:%SZ`.

- [ ] **Step 5: Confirm the real repo is unaffected**

```bash
Scripts/loop-precheck.sh; echo "exit=$?"
orca worktree list | grep -c auto-waddle-loop
```

The leftover `auto-waddle-loop-run-3-*` worktree from the first live trial is
older than two hours, so expect a `swept abandoned worktree` line on stderr and a
count of 0 afterwards. Confirm PR #55's branch still exists on origin:
`git ls-remote --heads origin | grep issue-13`.

- [ ] **Step 6: Commit**

```bash
git add Scripts/loop-precheck.sh Scripts/test-loop-precheck.sh
git commit -m "feat(loop): sweep abandoned per-run worktrees at run start

Orca does not remove the worktrees it creates per run, and a run cannot remove
the one it is executing inside, so they accumulate at three a day. Start of run
is the only workable moment: a crashed run cannot clean up by definition, so
end-of-run cleanup would only fire when there is nothing to clean. Age comes
from the timestamp in the worktree name so it is deterministic and testable,
and a name that stops parsing is reported rather than silently skipped."
```

---

### Task 2: The wait, snapshot, and fix phase

**Files:**
- Modify: `Scripts/loop-prompt.md`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: four new trial-record fields that Task 3's report reads —
  `ci_result` (`pass`/`fail`/`timeout`/`not-run`),
  `coderabbit_findings_first` (integer),
  `coderabbit_findings_after` (integer or `none`),
  `fix_rounds` (integer).

- [ ] **Step 1: Insert the new section between "3. Do the work" and "4. Finish"**

The existing sections 4 and 5 renumber to 5 and 6. Update every cross-reference
to them elsewhere in the file — search for "section 4" and "section 5".

````markdown
## 4. Wait for CI and review, snapshot, then respond

Your pull request is open but the run is not over. Two things now judge it: CI,
and CodeRabbit's review. You will respond to both — but the **order below is not
negotiable**, and step 1 must complete before you change a single line.

### 4.1 Wait, with a hard cap

Poll until both CI and the CodeRabbit review have finished, up to **15 minutes**.
This cap is separate from the 45-minute work budget: a slow service must not eat
the time you need to work, and an unresponsive one must never park the run
forever.

```bash
gh pr checks <PR> --watch --interval 30
gh pr view <PR> --json reviews --jq '[.reviews[] | select(.author.login=="coderabbitai")] | length'
```

If 15 minutes elapse with either unfinished: record `ci_result: timeout`,
`coderabbit_findings_first: none`, **skip 4.2 and 4.3 entirely**, and go to
section 5. A timeout is a legitimate trial result, not a failure to work around.

### 4.2 Snapshot the review BEFORE fixing anything

```bash
gh api repos/{owner}/{repo}/pulls/<PR>/comments --paginate --jq '.[].body' \
  | grep -c -E '🟠 Major|🔴 Critical'
```

Write that number into your trial record as `coderabbit_findings_first`, set
`ci_result` to `pass` or `fail`, and **push the record now** — before any fix.

This is the experiment's leading signal. Once you start fixing, the count on
GitHub measures your ability to satisfy CodeRabbit rather than the quality of
what you originally produced, and the number is gone for good. Pushing it as its
own write also means a run that dies mid-fix still leaves the measurement
behind, exactly as the `started` marker does.

### 4.3 Respond

Within whatever remains of the 45-minute budget, in this order:

1. **Fix a red CI.** A failing build is not an opinion — the work is
   objectively incomplete. Never make a test pass by weakening it; that rule
   applies here exactly as it does in section 3.
2. **Address the Major/Critical CodeRabbit findings.** Ignore Minor and Nitpick
   — they are recorded, not acted on.

If you disagree with a finding, say so in a reply on the pull request and leave
the code alone. Do not silently skip it, and do not change code you believe is
correct just to clear a comment.

Count each pass over CI-plus-review as one `fix_rounds`. Stop at **3 rounds**
even if findings remain: a fourth round means the disagreement is not one you
are going to resolve unattended. Then re-read the finding count into
`coderabbit_findings_after` and go to section 5.
````

- [ ] **Step 2: Add the four fields to the record template in the (now) section 6**

```markdown
ci_result: pass|fail|timeout|not-run
coderabbit_findings_first: <integer, or none if CI/review timed out>
coderabbit_findings_after: <integer, or none if no fixes were attempted>
fix_rounds: <integer, 0 if none>
```

Place them after `verification_result` and before `pr`. Then add this note below
the template:

```markdown
`coderabbit_findings_first` is the experiment's leading signal and is written in
section 4.2 *before* any fix. `Scripts/loop-report.sh` reads it from this record
and never queries GitHub for it — a live query would return post-fix counts and
silently report zero findings for every run.
```

- [ ] **Step 3: Add the new phase to "Known gaps"**

```markdown
- **A run that dies during section 4.3 leaves a pull request half-fixed.** The
  `coderabbit_findings_first` snapshot survives, so the measurement is intact,
  but the record still reads `started` and the pull request carries partial fix
  commits. Treat it like any other lost trial: the record is the evidence, and
  the pull request needs a human read.
```

- [ ] **Step 4: Verify structure**

```bash
grep -c '^```' Scripts/loop-prompt.md
grep -n "^## " Scripts/loop-prompt.md
grep -c 'outcome: started|pr-opened|failed-verification|no-repro|stuck' Scripts/loop-prompt.md
grep -n "section 4\|section 5\|section 6" Scripts/loop-prompt.md
```

Expected: an even fence count; sections 0–6 present and sequential; the outcome
enum line intact; and every "section N" cross-reference pointing at the right
renumbered section.

- [ ] **Step 5: Commit**

```bash
git add Scripts/loop-prompt.md
git commit -m "feat(loop): wait for CI and review, snapshot, then respond

A run no longer ends at pull-request-open. It waits up to 15 minutes for CI and
CodeRabbit -- a cap separate from the work budget so a slow service cannot eat
it -- records the Major/Critical count BEFORE touching anything, then fixes red
CI and addresses those findings for at most three rounds.

The snapshot order is the whole point: once the agent fixes findings, the live
count measures its ability to satisfy CodeRabbit rather than the quality of what
it produced."
```

---

### Task 3: The report reads the snapshot, not GitHub

**Files:**
- Modify: `Scripts/loop-report.sh`
- Modify: `Scripts/test-loop-report.sh`

**Interfaces:**
- Consumes: the `coderabbit_findings_first` record field from Task 2.
- Produces: no new interface.

- [ ] **Step 1: Write the two failing test cases**

Append to `Scripts/test-loop-report.sh` before the final `echo`. The existing
`record()` helper does not emit the new field, so these write their fixtures
directly.

```bash
# 9. The leading signal comes from the RECORD, not a live query. The agent now
#    fixes findings before the run ends, so a live query returns post-fix
#    counts -- a report that kept querying would print zero for every trial and
#    look perfectly healthy doing it.
make_fixture "$TMP/h"
cat > "$TMP/h/trials/2026-08-07T120000Z-issue-41.md" <<'EOF'
---
run_id: r-41
timestamp: 2026-08-07T12:00:00Z
prompt_sha: abc123
issue: 41
kind: bug
size: size:xs
outcome: pr-opened
wall_clock_seconds: 600
verification_result: pass
ci_result: pass
coderabbit_findings_first: 3
coderabbit_findings_after: 0
fix_rounds: 1
pr: 57
learning_added: none
---
prose
EOF
out="$(report "$TMP/h")" || fail "report failed"
echo "$out" | grep -q "3 CodeRabbit" \
    || fail "did not use the recorded snapshot of 3; got: $out"
pass "reads the CodeRabbit count from the record, not from a live query"

# 10. A record predating the snapshot field falls back to a live query, and says
#    so. Silently scoring it zero would understate every pre-existing trial.
make_fixture "$TMP/i"
record "$TMP/i" 41 pr-opened abc123 57
out="$(report "$TMP/i" 2>&1)" || fail "report failed"
echo "$out" | grep -qi "legacy\|no recorded snapshot" \
    || fail "legacy record was scored without any warning; got: $out"
pass "flags records that predate the snapshot field"
```

- [ ] **Step 2: Run the suite to verify the new cases fail**

```bash
Scripts/test-loop-report.sh
```

Expected: cases 1–8 pass, case 9 FAILs — the report still queries the stub `gh`,
which returns 1 Major, so it prints `1 CodeRabbit` instead of `3`.

- [ ] **Step 3: Change the findings computation in `Scripts/loop-report.sh`**

Add `coderabbit_findings_first` to the `rows` entry. Find the line building
`rows+=(...)` and extend it to a fifth field:

```bash
    rows+=("$(field "$fm" prompt_sha)|$outcome|$(field "$fm" pr)|$issue|$(field "$fm" coderabbit_findings_first)")
```

Then replace the per-prompt-version loop body's findings computation. The
existing `c="$(gh api ... | grep -c -E "$MARKERS" || true)"` block becomes:

```bash
        crf="$(printf '%s' "$r" | cut -d'|' -f5)"
        if [ -n "$crf" ] && [ "$crf" != "none" ]; then
            findings=$((findings + crf))
        else
            # Pre-snapshot record. Query live, but say so: since the agent now
            # fixes findings before a run ends, this number is post-fix and
            # understates what the run originally produced.
            legacy=$((legacy + 1))
            c="$(gh api "repos/{owner}/{repo}/pulls/$pr/comments" --jq '.[].body' 2>/dev/null \
                  | grep -c -E "$MARKERS" || true)"
            findings=$((findings + c))
        fi
```

Declare `legacy=0` alongside `n=0; merged=0; prs=0; findings=0`, and after the
per-sha `echo`, add:

```bash
    if [ "$legacy" -gt 0 ]; then
        echo "    ($legacy record(s) predate coderabbit_findings_first; scored by live query, which is post-fix and may understate)"
    fi
```

Finally update the script's header comment: the leading signal is now read from
the record, and the live query is a fallback for legacy records only.

- [ ] **Step 4: Run the suite to verify it passes**

```bash
Scripts/test-loop-report.sh
```

Expected: ten `ok - ` lines then `All loop-report tests passed.`

- [ ] **Step 5: Run the report against the two real records**

```bash
git fetch origin loop-trials
rm -rf /tmp/lt && mkdir -p /tmp/lt
git archive origin/loop-trials docs/loop-trials | tar -x -C /tmp/lt
Scripts/loop-report.sh /tmp/lt/docs/loop-trials
```

Both existing records predate the field, so expect the legacy note on both and a
live-queried count. That is correct behaviour, and it is exactly what the note
exists to disclose.

- [ ] **Step 6: Commit**

```bash
git add Scripts/loop-report.sh Scripts/test-loop-report.sh
git commit -m "fix(loop): read the CodeRabbit count from the record

The agent now fixes Major/Critical findings before a run ends, so querying
GitHub at report time returns post-fix counts -- the report would have printed
zero findings for every trial while appearing entirely healthy. It now reads
the snapshot the run recorded before fixing. Records predating that field still
fall back to a live query, and the report says so rather than scoring them
silently."
```

---

## Verification

| Task | Gate |
| --- | --- |
| 1 | `Scripts/test-loop-precheck.sh` — 12 cases; real-repo run sweeps the stale trial worktree and leaves PR #55's branch on origin |
| 2 | Sections 0–6 sequential, fences balanced, every "section N" cross-reference correct |
| 3 | `Scripts/test-loop-report.sh` — 10 cases; real records show the legacy note |

Then, across the whole branch: `Scripts/check-substrate.sh` and
`Scripts/check-issue-format.sh` both exit 0.

## Notes for the implementer

**Task 3 is the one that fails silently if you get it wrong.** A report that
keeps querying GitHub will print zero findings for every trial from now on and
give no outward sign of trouble — the numbers will look plausible and be
meaningless. Case 9 exists precisely to catch that, which is why its fixture
records `3` while the stub `gh` returns `1`: only a report reading the record can
print `3`.

**The order in Task 2's section 4 is the substance, not the sequence.** If the
snapshot moves after the fixes for any reason — convenience, a tidier flow — the
experiment's leading signal is destroyed and nothing about the output will look
wrong. The prose says so; keep it.

**Do not run the loop while working on this.** The automation is disabled and
must stay disabled. Task 1's Step 5 runs the precheck, which is read-only apart
from its sweeps, and those sweeps are the point.
