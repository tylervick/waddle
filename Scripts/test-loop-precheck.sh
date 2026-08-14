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
  "api "*)      cat "$FIX/timeline.json" ;;
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
# The stub emits a remedy on stderr the way the real check-engine-fresh.sh
# does. Asserting only that the word "engine" appears -- which this case did
# originally -- passes while the precheck discards that remedy with 2>&1, so
# the operator is told the symptom and not the fix. This is a state the loop
# cannot clear itself, so the message is the entire interface a human gets.
printf '#!/bin/bash\necho "rebuild it with: Scripts/build-engine.sh" >&2\nexit 1\n' \
    > "$TMP/h/Scripts/check-engine-fresh.sh"
if out=$(run_precheck "$TMP/h" 2>"$TMP/err"); then fail "proceeded with a stale engine"; fi
grep -q "engine" "$TMP/err" || fail "refusal does not name the engine: $(cat "$TMP/err")"
grep -q "Scripts/build-engine.sh" "$TMP/err" \
  || fail "refusal discarded check-engine-fresh's remedy; got: $(cat "$TMP/err")"
grep -q "ROOT checkout" "$TMP/err" \
  || fail "refusal does not say where to run it; got: $(cat "$TMP/err")"
pass "refuses when the engine is stale, and passes the remedy through"

# 9. An eligible issue with no size label is still reachable, after sized ones.
make_fixture "$TMP/i"
cat > "$TMP/i/issues.json" <<'J'
[{"number":30,"labels":[{"name":"agent:eligible"}]}]
J
out=$(run_precheck "$TMP/i") || fail "refused an unsized eligible issue"
[ "$out" = "30" ] || fail "picked $out; expected 30"
pass "picks an unsized eligible issue rather than skipping it"

# 10. No matching agent:in-progress labeling event anywhere in the timeline --
#     e.g. paginated past it, or some other reason it's simply not there --
#     must refuse as LIVE, never fall back to the 1970 epoch and sweep a claim
#     that might still be running. Absence of proof is not proof of staleness.
make_fixture "$TMP/j"
cat > "$TMP/j/issues.json" <<'J'
[{"number":90,"labels":[{"name":"agent:eligible"},{"name":"agent:in-progress"}]}]
J
printf '[{"event":"commented","created_at":"2026-08-07T09:00:00Z"}]\n' \
    > "$TMP/j/timeline.json"
if out=$(run_precheck "$TMP/j" 2>"$TMP/err"); then
    fail "proceeded despite no labeling event anywhere in the timeline"
fi
[ -z "$out" ] || fail "printed '$out' to stdout on refusal; must be silent"
grep -q "run already live" "$TMP/err" || fail "wrong refusal reason: $(cat "$TMP/err")"
pass "refuses (as live, not stale) when no agent:in-progress labeling event is found"

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
    echo "id::/w/auto-waddle-loop-run-1-20260807T0700  refs/heads/a  /w/auto-waddle-loop-run-1-20260807T0700"
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
grep -q "auto-waddle-loop-run-1-20260807T0700" "$TMP/j/orca-calls.log" \
    || fail "the 5h-old worktree was not swept"
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

# 13. `orca worktree list` returns worktrees, but none of them are loop
#     worktrees -- the sweep's own pipeline (list | awk | grep | while) must
#     never abort the precheck just because grep found nothing to sweep.
#     Regression test for a `pipefail` bug: grep exits 1 on no-match, and
#     under this script's `set -euo pipefail` that (or a `while` loop whose
#     body never ran, which itself exits non-zero at EOF) used to kill the
#     whole run before it ever reached `gh issue list` -- silently, with no
#     `skip:` reason on stderr. This is the everyday case, not a corner case:
#     it is what happens on every run once there is nothing left to sweep.
make_fixture "$TMP/l"
cat > "$TMP/l/issues.json" <<'J'
[{"number":42,"labels":[{"name":"agent:eligible"},{"name":"size:xs"}]}]
J
cat > "$TMP/l/bin/orca" <<'STUB'
#!/bin/bash
FIX="$(dirname "$(dirname "$0")")"
echo "$*" >> "$FIX/orca-calls.log"
case "$1 $2" in
  "worktree list")
    echo "id::/w/CRUD-games  refs/heads/c  /w/CRUD-games" ;;
  "worktree rm") exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP/l/bin/orca"
: > "$TMP/l/orca-calls.log"
out=$(run_precheck "$TMP/l" 2>"$TMP/err") \
    || fail "the sweep's no-match pipeline aborted the precheck (exit=$?, stderr: $(cat "$TMP/err"))"
[ "$out" = "42" ] || fail "picked $out; expected 42"
grep -q "worktree rm" "$TMP/l/orca-calls.log" && fail "removed a worktree when nothing matched"
pass "proceeds when orca worktree list has no loop worktrees to sweep"

# 14. A shape-valid but CALENDAR-INVALID timestamp (Feb 30th) must not fail
#     open. This is the same shape as case 10's bug: a value the code cannot
#     interpret gets treated as ancient rather than as unknown. Verified on
#     this platform's `date`: Feb 30 2026 does not error -- `mktime` silently
#     normalizes it to Mar 2 2026 and returns success, which (against a NOW of
#     Aug 7) reads as a plausible ~5-month-old worktree and would get swept.
#     Pre-fix, this case fails at the `worktree rm` assertion below; post-fix
#     it must be reported and left alone.
make_fixture "$TMP/m"
cat > "$TMP/m/issues.json" <<'J'
[{"number":42,"labels":[{"name":"agent:eligible"},{"name":"size:xs"}]}]
J
cat > "$TMP/m/bin/orca" <<'STUB'
#!/bin/bash
FIX="$(dirname "$(dirname "$0")")"
echo "$*" >> "$FIX/orca-calls.log"
case "$1 $2" in
  "worktree list")
    echo "id::/w/auto-waddle-loop-run-9-20260230T1200  refs/heads/a  /w/auto-waddle-loop-run-9-20260230T1200" ;;
  "worktree rm") exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP/m/bin/orca"
: > "$TMP/m/orca-calls.log"
out=$(run_precheck "$TMP/m" 2>"$TMP/err") || fail "refused a valid backlog"
[ "$out" = "42" ] || fail "picked $out; expected 42"
grep -qi "calendar-invalid" "$TMP/err" || fail "calendar-invalid timestamp was not reported: $(cat "$TMP/err")"
grep -q "worktree rm" "$TMP/m/orca-calls.log" && fail "removed a worktree with a calendar-invalid timestamp"
pass "reports a calendar-invalid worktree timestamp instead of sweeping it"

# 15. agent:next outranks size entirely. Without it the only ways to steer the
#     loop are lying about the size label -- which corrupts the `size` field
#     trial records carry -- or making every competing issue ineligible.
make_fixture "$TMP/o"
cat > "$TMP/o/issues.json" <<'J'
[{"number":10,"labels":[{"name":"agent:eligible"},{"name":"size:xs"}]},
 {"number":11,"labels":[{"name":"agent:eligible"},{"name":"size:s"}]},
 {"number":93,"labels":[{"name":"agent:eligible"},{"name":"size:m"},{"name":"agent:next"}]}]
J
out=$(run_precheck "$TMP/o") || fail "refused a valid backlog"
[ "$out" = "93" ] || fail "picked $out; expected 93 (agent:next beats a lower size and a lower number)"
pass "agent:next outranks size and issue number"

# 16. Two agent:next issues still tie-break on the lowest number, so the
#     override narrows the field rather than making the choice arbitrary.
make_fixture "$TMP/p"
cat > "$TMP/p/issues.json" <<'J'
[{"number":93,"labels":[{"name":"agent:eligible"},{"name":"size:m"},{"name":"agent:next"}]},
 {"number":84,"labels":[{"name":"agent:eligible"},{"name":"size:m"},{"name":"agent:next"}]}]
J
out=$(run_precheck "$TMP/p") || fail "refused a valid backlog"
[ "$out" = "84" ] || fail "picked $out; expected 84 (lowest among agent:next)"
pass "agent:next still tie-breaks on ascending issue number"

# 17. agent:next does not override the exclusions. A stuck issue stays out even
#     when it is flagged -- otherwise the flag could resurrect work that
#     already defeated a run.
make_fixture "$TMP/q"
cat > "$TMP/q/issues.json" <<'J'
[{"number":93,"labels":[{"name":"agent:eligible"},{"name":"size:m"},{"name":"agent:next"},{"name":"agent:stuck"}]},
 {"number":11,"labels":[{"name":"agent:eligible"},{"name":"size:s"}]}]
J
out=$(run_precheck "$TMP/q") || fail "refused a valid backlog"
[ "$out" = "11" ] || fail "picked $out; expected 11 (agent:next must not override agent:stuck)"
pass "agent:next does not override agent:stuck"

# 18. GitHub honours nine closing keywords, not three. An open pull request
#     saying "Fixed #41" must exclude 41, or the loop redoes finished work.
make_fixture "$TMP/r"
cat > "$TMP/r/issues.json" <<'J'
[{"number":41,"labels":[{"name":"agent:eligible"},{"name":"size:xs"}]},
 {"number":42,"labels":[{"name":"agent:eligible"},{"name":"size:m"}]}]
J
cat > "$TMP/r/prs.json" <<'J'
[{"number":900,"body":"Fixed #41 by not swallowing the error."}]
J
out=$(run_precheck "$TMP/r") || fail "refused a valid backlog"
[ "$out" = "42" ] || fail "picked $out; expected 42 (41 is linked by 'Fixed #41')"
pass "excludes an issue linked by any of the nine closing keywords"

echo "All loop-precheck tests passed."
