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

echo "All loop-report tests passed."
