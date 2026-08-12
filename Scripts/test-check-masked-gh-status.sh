#!/bin/bash
# Tests for Scripts/check-masked-gh-status.sh.
#
# Fully HERMETIC: every case builds fake scripts in a temp dir and points the
# guard at that dir. Case 8 is the one deliberate exception -- it runs the
# guard against the repo's real Scripts/, which is the assertion that the
# trap this guard exists for is actually absent from production code today.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

check() { "$ROOT/Scripts/check-masked-gh-status.sh" "$1"; }

# 1. The shape the guard must accept: status tested directly on the command
#    substitution. This is the idiom PR #66 established and issue #68 spread
#    to the last call site; if the guard rejected it there would be no
#    conforming way to call `gh api` at all.
mkdir -p "$TMP/t1"
cat > "$TMP/t1/good.sh" <<'EOF'
#!/bin/bash
if bodies="$(gh api "repos/{owner}/{repo}/pulls/$pr/comments" --paginate \
      --jq '.[] | .body' 2>/dev/null)"; then
    c="$(printf '%s' "$bodies" | grep -c -E "$MARKERS" || true)"
fi
EOF
check "$TMP/t1" || fail "the exit-status-tested idiom must pass"
pass "accepts a gh api call whose status is tested directly"

# 2. THE BUG, in the exact multi-line shape it had in both places it bit:
#    loop-report.sh's reconciliation path (PR #66) and its legacy path
#    (issue #68). The `|| true` binds to the whole pipeline, so a failed
#    `gh api` becomes a count of 0 and is indistinguishable from a real one.
mkdir -p "$TMP/t2"
cat > "$TMP/t2/bad.sh" <<'EOF'
#!/bin/bash
c="$(gh api "repos/{owner}/{repo}/pulls/$pr/comments" --paginate \
      --jq '.[] | .body' 2>/dev/null \
      | grep -c -E "$MARKERS" || true)"
EOF
out="$(check "$TMP/t2" 2>&1)" && fail "a gh api pipeline masked by || true must be refused; got: $out"
echo "$out" | grep -q "bad.sh" || fail "the offending file must be named; got: $out"
pass "refuses a gh api pipeline whose status is masked by || true"

# 3. THE DISCRIMINATION THAT MAKES THIS CHECK WRITABLE AT ALL. The learning
#    file recorded for months that a naive grep could not tell these apart.
#    `grep -c` exits 1 on no-match, which is the expected answer and carries
#    no failure information, so `|| true` on a pipeline reading a SHELL
#    VARIABLE is correct and must pass. Only `gh api` in the same pipeline
#    makes it a masked query.
mkdir -p "$TMP/t3"
cat > "$TMP/t3/legit.sh" <<'EOF'
#!/bin/bash
c="$(printf '%s' "$bodies" | grep -c -E "$MARKERS" || true)"
n="$(printf '%s' "$out" | grep -c foo || true)"
EOF
check "$TMP/t3" || fail "grep -c ... || true on a variable is legitimate and must pass"
pass "accepts grep -c ... || true when no gh api is in the pipeline"

# 4. `|| skip` HANDLES the failure rather than masking it -- loop-precheck.sh's
#    idiom, which aborts the run with a reason. Flagging it would push that
#    script toward a worse shape.
mkdir -p "$TMP/t4"
cat > "$TMP/t4/handled.sh" <<'EOF'
#!/bin/bash
applied="$(gh api --paginate "repos/{owner}/{repo}/issues/$n/timeline" 2>/dev/null \
             | python3 -c 'pass')" || skip "gh api timeline failed for #$n"
issues="$(gh api foo 2>/dev/null)" || err "gh api failed"
EOF
check "$TMP/t4" || fail "|| skip and || err handle the failure and must pass"
pass "accepts a gh api call whose failure is handled by || skip or || err"

# 5. The other fabrication shape: substituting an invented value for the
#    answer. `|| echo '{}'` is the same defect as `|| true` wearing different
#    clothes -- the caller cannot tell the fallback from a real reply.
mkdir -p "$TMP/t5"
cat > "$TMP/t5/fabricated.sh" <<'EOF'
#!/bin/bash
state="$(gh api "repos/{owner}/{repo}/pulls/$pr" 2>/dev/null || echo '{}')"
EOF
out="$(check "$TMP/t5" 2>&1)" && fail "|| echo fabricates an answer and must be refused; got: $out"
pass "refuses a gh api call that fabricates a fallback value with || echo"

# 6. Comments must never trip the guard. This matters concretely: the fixed
#    call sites in loop-report.sh now carry comments that quote the bad shape
#    verbatim to explain why it is wrong, and docs quote it too. A guard that
#    fired on its own explanation would push people to delete the explanation.
mkdir -p "$TMP/t6"
cat > "$TMP/t6/commented.sh" <<'EOF'
#!/bin/bash
# Piping straight into `gh api ... | grep -c ... || true` collapses a failed
# call to 0 -- do not do this.
#     c="$(gh api foo | grep -c bar || true)"
if out="$(gh api foo)"; then :; fi
EOF
check "$TMP/t6" || fail "a full-line comment quoting the bad shape must not trip the guard"
pass "ignores the bad shape when it appears in a comment"

# 7. Continuation by trailing pipe, not backslash -- valid bash, and the shape
#    a reformat could easily produce. Without joining on a trailing `|` the
#    `|| true` lands on its own logical line, `gh api` is nowhere near it, and
#    the guard would report clean on a genuine instance of the bug.
mkdir -p "$TMP/t7"
cat > "$TMP/t7/piped.sh" <<'EOF'
#!/bin/bash
c="$(gh api foo |
    grep -c bar || true)"
EOF
out="$(check "$TMP/t7" 2>&1)" && fail "a pipe-continued masked gh api must be refused; got: $out"
pass "joins pipe-continued lines and refuses the masked gh api inside them"

# 8. THE PRODUCTION ASSERTION. Every `gh api` call site in the real Scripts/
#    tests its status. Issue #68 fixed the last one that did not; this case is
#    what stops a new one appearing.
check "$ROOT/Scripts" || fail "the repo's own Scripts/ must be free of masked gh api calls"
pass "the repo's production scripts contain no masked gh api call"

# 9. test-*.sh is skipped on purpose: a test suite's fixtures deliberately
#    contain the bad shape (this file is full of it), so scanning them would
#    make the guard fire on the very tests that prove it works.
mkdir -p "$TMP/t9"
cat > "$TMP/t9/test-thing.sh" <<'EOF'
#!/bin/bash
c="$(gh api foo | grep -c bar || true)"
EOF
check "$TMP/t9" || fail "test-*.sh fixtures must be skipped, not scanned"
pass "skips test-*.sh, whose fixtures contain the bad shape deliberately"

echo "All check-masked-gh-status tests passed."
