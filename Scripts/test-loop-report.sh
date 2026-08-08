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
make_recon_fixture() { # dest
    # A second stub, purpose-built for the reconciliation tests (16-19).
    # make_fixture's stub answers every `gh api` call identically regardless
    # of endpoint, which is fine for the existing tests (none of them assert
    # anything about a commits query) but useless here: reconciliation reads
    # TWO different `gh api` endpoints -- pulls/<pr>/commits (authorship) and
    # pulls/<pr>/comments (the live CodeRabbit query) -- and a test needs to
    # control each independently and see which ones actually fired. Defaults:
    # a single agent-authored commit (so a bare fixture is reconciliation-
    # eligible) and one real Major finding waiting on the comments endpoint
    # (so "was it live-queried" is directly observable, same trick as
    # make_fixture's stub for case 14). Tests override commit-emails.txt to
    # exercise the foreign-author refusal.
    mkdir -p "$1/trials" "$1/bin"
    : > "$1/gh-calls.log"
    printf 'agent-loop@tylervick.com\n' > "$1/commit-emails.txt"
    cat > "$1/review-body.txt" <<'BODY'
_🗄️ Data Integrity & Integration_ | _🟠 Major_ | _🏗️ Heavy lift_
BODY
    cat > "$1/bin/gh" <<'STUB'
#!/bin/bash
FIX="$(dirname "$(dirname "$0")")"
echo "$*" >> "$FIX/gh-calls.log"
case "$*" in
  *"pulls/"*"/commits"*)  cat "$FIX/commit-emails.txt" ;;
  *"pulls/"*"/comments"*) cat "$FIX/review-body.txt" ;;
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

# 8. EVERY record malformed, none valid -- rows stays a truly empty array.
#    "${rows[@]}" on a truly empty array is an unbound-variable error under
#    `set -u` on macOS's bash 3.2, which would exit 1 before ever reaching the
#    malformed-record warning. Case 7 pairs a malformed record with a valid
#    one, so it never exercises the empty-array path; this case does.
make_fixture "$TMP/h"
printf 'no frontmatter here\n' > "$TMP/h/trials/2026-08-07-issue-77.md"
out="$(report "$TMP/h" 2>&1)" || fail "non-zero exit when every record is malformed"
echo "$out" | grep -qi "unparseable\|malformed" || fail "malformed-only dir did not warn; got: $out"
pass "exits 0 and warns when every record is malformed"

# 9. The leading signal comes from the RECORD, not a live query. The agent now
#    fixes findings before the run ends, so a live query returns post-fix
#    counts -- a report that kept querying would print zero for every trial and
#    look perfectly healthy doing it.
make_fixture "$TMP/i"
cat > "$TMP/i/trials/2026-08-07T120000Z-issue-41.md" <<'EOF'
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
out="$(report "$TMP/i")" || fail "report failed"
echo "$out" | grep -q "3 CodeRabbit" \
    || fail "did not use the recorded snapshot of 3; got: $out"
pass "reads the CodeRabbit count from the record, not from a live query"

# 10. A record predating the snapshot field falls back to a live query, and says
#    so. Silently scoring it zero would understate every pre-existing trial.
make_fixture "$TMP/j"
record "$TMP/j" 41 pr-opened abc123 57
out="$(report "$TMP/j" 2>&1)" || fail "report failed"
echo "$out" | grep -qi "legacy\|no recorded snapshot" \
    || fail "legacy record was scored without any warning; got: $out"
pass "flags records that predate the snapshot field"

# 11. An ABSENT field (case 10's fixture, via `record()`, which never emits
#    coderabbit_findings_first at all) and a PRESENT-but-`none` field are
#    different situations and must produce different report lines: absent
#    means "this run predates the field, fall back to a live query"; `none`
#    means "this run has the field and says nothing was measured, never query
#    live for it." This case pins the absent-field side explicitly, with its
#    own fixture (not reusing case 10), so the two paths stay separately
#    verifiable even as the following cases change what `none` does.
make_fixture "$TMP/k0"
cat > "$TMP/k0/trials/2026-08-07T120000Z-issue-48.md" <<'EOF'
---
run_id: r-48
timestamp: 2026-08-07T12:00:00Z
prompt_sha: abc123
issue: 48
kind: bug
size: size:xs
outcome: pr-opened
wall_clock_seconds: 600
verification_result: pass
pr: 57
learning_added: none
---
prose
EOF
out="$(report "$TMP/k0" 2>&1)" || fail "report failed"
echo "$out" | grep -qi "legacy\|no recorded snapshot" \
    || fail "a record with the field entirely absent was not flagged as legacy; got: $out"
echo "$out" | grep -qi "unavailable" \
    && fail "an absent field must never be reported as 'unavailable' -- that's the none/malformed line; got: $out"
pass "an absent coderabbit_findings_first field takes the live fallback and prints the legacy note"

# 12. `coderabbit_findings_first: none` is the value the protocol actually
#    instructs the agent to write on a CI/review timeout (Scripts/loop-prompt.md
#    section 6) -- distinct from the field being absent entirely (case 11).
#    Unlike the absent case, the field IS present here and says explicitly
#    that nothing was measured, so this must route to the "unavailable" line,
#    excluded from the findings total, and must NOT be scored by a live query
#    (which would fabricate a post-fix number for a trial that never had a
#    fix attempt) and must NOT be reported as "legacy" (which would conflate
#    it with a record that simply predates the field).
make_fixture "$TMP/k"
cat > "$TMP/k/trials/2026-08-07T120000Z-issue-45.md" <<'EOF'
---
run_id: r-45
timestamp: 2026-08-07T12:00:00Z
prompt_sha: abc123
issue: 45
kind: bug
size: size:xs
outcome: pr-opened
wall_clock_seconds: 600
verification_result: pass
ci_result: timeout
coderabbit_findings_first: none
coderabbit_findings_after: none
fix_rounds: 0
pr: 57
learning_added: none
---
prose
EOF
out="$(report "$TMP/k" 2>&1)" || fail "report aborted on a literal 'none' snapshot; got: $out"
echo "$out" | grep -qi "unavailable" \
    || fail "literal 'none' snapshot was not flagged as unavailable; got: $out"
echo "$out" | grep -qi "legacy" \
    && fail "a literal 'none' snapshot must not be reported as legacy -- it never had a pre-fix measurement to recover; got: $out"
pass "routes a literal 'none' snapshot to the unavailable line, not legacy, without crashing"

# 13. THE REAL DAMAGE. A decorated, non-numeric snapshot value (ordinary model
#    drift -- the protocol specifies the field freehand as "<integer, or none
#    if CI/review timed out>" and nothing validates it) must not abort the
#    whole report under `set -euo pipefail`. The crash itself is not the worst
#    part: output stops mid-script, so the LOST TRIALS section -- the only
#    thing that ever surfaces a died-mid-run trial -- never prints, for every
#    record in the dataset, not just the offending one. This case pairs the bad
#    value with a `started` record and asserts LOST TRIALS still appears, and
#    (like case 12) that the value is scored as unavailable, not legacy, and
#    excluded from the findings total, never queried live.
make_fixture "$TMP/l"
record "$TMP/l" 46 started abc123
cat > "$TMP/l/trials/2026-08-07T120000Z-issue-47.md" <<'EOF'
---
run_id: r-47
timestamp: 2026-08-07T12:00:00Z
prompt_sha: abc123
issue: 47
kind: bug
size: size:xs
outcome: pr-opened
wall_clock_seconds: 600
verification_result: pass
ci_result: timeout
coderabbit_findings_first: none (CI timed out)
coderabbit_findings_after: none
fix_rounds: 0
pr: 58
learning_added: none
---
prose
EOF
out="$(report "$TMP/l" 2>&1)" || fail "a decorated non-numeric snapshot aborted the report; got: $out"
echo "$out" | grep -qi "lost" \
    || fail "LOST TRIALS was silenced by an unrelated decorated snapshot value; got: $out"
echo "$out" | grep -qi "unavailable" \
    || fail "decorated non-numeric snapshot was not flagged as unavailable; got: $out"
echo "$out" | grep -qi "legacy" \
    && fail "a decorated non-numeric snapshot must not be reported as legacy; got: $out"
pass "a decorated non-numeric snapshot doesn't abort the report, is unavailable not legacy, and doesn't silence LOST TRIALS"

# 14. `coderabbit_findings_first: unavailable` is the value the protocol
#    instructs the agent to write when 4.1 recognises CodeRabbit's terminal
#    non-review state (e.g. "Review rate limited" reported as a check status,
#    never as a review) and stops waiting for it rather than burning the full
#    900-second cap. Distinct from `none` (case 12, a genuine timeout) and
#    from a malformed value (case 13) in *meaning*, but it must land in the
#    exact same bucket as both: excluded from the findings total, reported on
#    its own "unavailable" line, and never live-queried -- there is no
#    pre-fix number to recover for a run that was told outright no review was
#    coming. This fixture's stub `gh api` (see make_fixture) always has a real
#    Major finding ready to hand back on any query, unconditionally -- so if
#    this record's PR were live-queried by mistake, the total below would
#    read "1 CodeRabbit", not "0 CodeRabbit". That makes "never live-queried"
#    directly observable rather than merely asserted.
make_fixture "$TMP/m"
cat > "$TMP/m/trials/2026-08-07T120000Z-issue-50.md" <<'EOF'
---
run_id: r-50
timestamp: 2026-08-07T12:00:00Z
prompt_sha: abc123
issue: 50
kind: bug
size: size:xs
outcome: pr-opened
wall_clock_seconds: 600
verification_result: pass
ci_result: pass
coderabbit_findings_first: unavailable
coderabbit_findings_after: none
fix_rounds: 0
pr: 59
learning_added: none
---
prose
EOF
out="$(report "$TMP/m" 2>&1)" || fail "report aborted on coderabbit_findings_first: unavailable; got: $out"
echo "$out" | grep -qi "unavailable" \
    || fail "coderabbit_findings_first: unavailable was not flagged as unavailable; got: $out"
echo "$out" | grep -qi "legacy" \
    && fail "coderabbit_findings_first: unavailable must not be reported as legacy; got: $out"
echo "$out" | grep -q "0 CodeRabbit" \
    || fail "coderabbit_findings_first: unavailable must be excluded from the findings total; got: $out"
echo "$out" | grep -q "1 CodeRabbit" \
    && fail "coderabbit_findings_first: unavailable's PR was live-queried -- the stub's ready Major finding leaked into the total; got: $out"
pass "routes coderabbit_findings_first: unavailable to the unavailable line, excluded from the total, never live-queried"

# 15. A record with `ci_result: timeout` but a REAL numeric
#    `coderabbit_findings_first` -- the shape 4.1's cap-exceeded paragraph now
#    produces when a real CodeRabbit review landed before the cap but CI
#    never concluded within it: the leading signal was genuinely captured via
#    4.2's snapshot even though CI itself timed out. This must be counted
#    normally in the findings total -- the case statement keys off
#    `coderabbit_findings_first` alone, never `ci_result`, so a real count
#    must never be excluded, treated as unavailable, or treated as legacy
#    just because CI happened to time out on that same trial.
make_fixture "$TMP/n"
cat > "$TMP/n/trials/2026-08-07T120000Z-issue-51.md" <<'EOF'
---
run_id: r-51
timestamp: 2026-08-07T12:00:00Z
prompt_sha: cafefeed
issue: 51
kind: bug
size: size:xs
outcome: pr-opened
wall_clock_seconds: 900
verification_result: pass
ci_result: timeout
coderabbit_findings_first: 2
coderabbit_findings_after: none
fix_rounds: 0
pr: 60
learning_added: none
---
prose
EOF
out="$(report "$TMP/n" 2>&1)" || fail "report failed on ci_result: timeout with a real findings count; got: $out"
echo "$out" | grep -q "2 CodeRabbit" \
    || fail "a real coderabbit_findings_first must be counted even when ci_result: timeout; got: $out"
echo "$out" | grep -qi "unavailable" \
    && fail "a real numeric coderabbit_findings_first must not be reported as unavailable just because ci_result: timeout; got: $out"
echo "$out" | grep -qi "legacy" \
    && fail "a real numeric coderabbit_findings_first must not be reported as legacy; got: $out"
pass "counts a real coderabbit_findings_first even when ci_result: timeout (review landed, CI did not conclude)"

# 16. RECONCILIATION: an unusable snapshot (`unavailable`), `fix_rounds: 0`,
#    and a PR whose only commit is agent-authored together mean a live query
#    today reads the exact same code the run left behind -- a valid pre-fix
#    count, not a fabrication. This is PR #59's real shape from the
#    experiment. Proven two ways: the live-queried Major finding lands in the
#    total, and the gh-calls log shows both the commits check and the
#    comments query actually fired.
make_recon_fixture "$TMP/o"
cat > "$TMP/o/trials/2026-08-08T000000Z-issue-59.md" <<'EOF'
---
run_id: r-59
timestamp: 2026-08-08T00:00:00Z
prompt_sha: ce934c6
issue: 59
kind: documentation
size: size:xs
outcome: pr-opened
wall_clock_seconds: 568
verification_result: pass
ci_result: pass
coderabbit_findings_first: unavailable
coderabbit_findings_after: none
fix_rounds: 0
pr: 59
learning_added: none
---
prose
EOF
out="$(report "$TMP/o" 2>&1)" || fail "report failed on a reconciliation-eligible record; got: $out"
echo "$out" | grep -qi "reconcil" \
    || fail "an eligible unavailable/fix_rounds:0/all-agent-commits record was not reported as reconciled; got: $out"
echo "$out" | grep -q "1 CodeRabbit" \
    || fail "reconciled record's live-queried Major finding was not added to the findings total; got: $out"
grep -q "pulls/59/commits" "$TMP/o/gh-calls.log" \
    || fail "reconciliation did not check commit authorship; calls were: $(cat "$TMP/o/gh-calls.log")"
grep -q "pulls/59/comments" "$TMP/o/gh-calls.log" \
    || fail "reconciliation did not live-query CodeRabbit comments; calls were: $(cat "$TMP/o/gh-calls.log")"
pass "reconciles an unavailable snapshot when fix_rounds is 0 and every commit is agent-authored"

# 17. REFUSED: a foreign-authored commit exists. This is PR #61's exact shape
#    from the experiment -- `unavailable`, `fix_rounds: 0`, but a human
#    (tyler@tylervick.com) pushed a commit after the loop's own commit, so a
#    later CodeRabbit review would be reviewing the human's code, not the
#    loop's. `fix_rounds: 0` alone is not enough: it only proves the loop
#    itself stopped pushing, not that nobody else did. Proven the same way as
#    case 14 -- the commits check fires (it must, to discover the foreign
#    author), but the comments endpoint must NEVER be reached, so the ready
#    Major finding in review-body.txt cannot leak into the total.
make_recon_fixture "$TMP/p"
printf 'agent-loop@tylervick.com\ntyler@tylervick.com\n' > "$TMP/p/commit-emails.txt"
cat > "$TMP/p/trials/2026-08-08T000000Z-issue-42.md" <<'EOF'
---
run_id: r-42
timestamp: 2026-08-08T00:00:00Z
prompt_sha: ce934c6
issue: 42
kind: bug
size: size:xs
outcome: pr-opened
wall_clock_seconds: 714
verification_result: pass
ci_result: pass
coderabbit_findings_first: unavailable
coderabbit_findings_after: none
fix_rounds: 0
pr: 61
learning_added: none
---
prose
EOF
out="$(report "$TMP/p" 2>&1)" || fail "report failed on a foreign-commit record; got: $out"
echo "$out" | grep -qi "unavailable" \
    || fail "a foreign-authored-commit record must stay on the unavailable line; got: $out"
echo "$out" | grep -qi "not authored by the agent" \
    || fail "an otherwise-eligible record refused for a foreign commit must say so distinctly; got: $out"
echo "$out" | grep -q "0 CodeRabbit" \
    || fail "a foreign-authored-commit record must not contribute to the findings total; got: $out"
grep -q "pulls/61/commits" "$TMP/p/gh-calls.log" \
    || fail "authorship must still be checked when the snapshot is unusable and fix_rounds is 0; calls were: $(cat "$TMP/p/gh-calls.log")"
grep -q "pulls/61/comments" "$TMP/p/gh-calls.log" \
    && fail "a foreign commit must refuse reconciliation BEFORE live-querying CodeRabbit comments; calls were: $(cat "$TMP/p/gh-calls.log")"
pass "refuses reconciliation when a commit on the PR is not authored by the agent identity"

# 18. REFUSED: fix_rounds is non-zero. A run that fixed findings touched the
#    code again, so a review landing later is post-fix, exactly the case the
#    existing unavailable/legacy split already guards against -- reconciling
#    here would be the same fabrication the header warns about. This fixture's
#    commit-emails.txt (via make_recon_fixture's default) is single-author
#    agent-only, so if the code checked fix_rounds loosely it would reconcile;
#    it must not. Proven strongly: the commits endpoint must never even be
#    queried when fix_rounds rules reconciliation out up front.
make_recon_fixture "$TMP/q"
cat > "$TMP/q/trials/2026-08-08T000000Z-issue-99.md" <<'EOF'
---
run_id: r-99
timestamp: 2026-08-08T00:00:00Z
prompt_sha: ce934c6
issue: 99
kind: bug
size: size:xs
outcome: pr-opened
wall_clock_seconds: 900
verification_result: pass
ci_result: pass
coderabbit_findings_first: unavailable
coderabbit_findings_after: 0
fix_rounds: 2
pr: 59
learning_added: none
---
prose
EOF
out="$(report "$TMP/q" 2>&1)" || fail "report failed on a fix_rounds>0 record; got: $out"
echo "$out" | grep -qi "unavailable" \
    || fail "a fix_rounds>0 record with an unusable snapshot must stay on the unavailable line; got: $out"
echo "$out" | grep -q "0 CodeRabbit" \
    || fail "a fix_rounds>0 record must not be reconciled into the findings total; got: $out"
grep -q "commits" "$TMP/q/gh-calls.log" \
    && fail "fix_rounds > 0 must refuse reconciliation without ever checking commit authorship; calls were: $(cat "$TMP/q/gh-calls.log")"
pass "refuses reconciliation when fix_rounds is non-zero, without even checking commit authorship"

# 19. `none` reconciles exactly like `unavailable` (case 16): both mean "no
#    review happened", not "reviewed and found nothing," so a 900s timeout is
#    just as reconcilable as an explicit refusal once fix_rounds is 0 and
#    every commit is agent-authored. This is PR #57's real shape from the
#    experiment. The issue text singles out `unavailable` and says to leave
#    `none` alone -- this case pins that `none` gets the identical treatment,
#    since a timeout is no less reconcilable than a refusal.
make_recon_fixture "$TMP/s"
cat > "$TMP/s/trials/2026-08-08T000000Z-issue-13.md" <<'EOF'
---
run_id: r-13
timestamp: 2026-08-08T00:00:00Z
prompt_sha: c5d5af3
issue: 13
kind: bug
size: size:xs
outcome: pr-opened
wall_clock_seconds: 1765
verification_result: pass
ci_result: timeout
coderabbit_findings_first: none
coderabbit_findings_after: none
fix_rounds: 0
pr: 57
learning_added: none
---
prose
EOF
out="$(report "$TMP/s" 2>&1)" || fail "report failed on a reconciliation-eligible 'none' record; got: $out"
echo "$out" | grep -qi "reconcil" \
    || fail "'none' must reconcile the same as 'unavailable' when fix_rounds is 0 and commits are all agent-authored; got: $out"
echo "$out" | grep -q "1 CodeRabbit" \
    || fail "'none' record's live-queried Major finding was not added to the findings total; got: $out"
pass "reconciles a literal 'none' snapshot the same as 'unavailable'"

echo "All loop-report tests passed."
