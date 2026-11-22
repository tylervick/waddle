#!/bin/bash
# Tests for Scripts/check-suites-registered.sh.
#
# HERMETIC except where noted: every case points the check at a fixture suites
# directory and fixture workflows under $TMP through SUITES_DIR and
# SUITE_WORKFLOWS. The deliberate exceptions are the last cases, which run the
# check against the real tree -- once as it is, so a suite added later without
# being registered fails CI, and once against a copy of ci.yml with a line
# deleted, so the live run is shown to bite rather than assumed to.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/Scripts/check-suites-registered.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

mkdir -p "$TMP/Scripts"
for s in test-alpha.sh test-beta.sh test-gamma.sh; do
  printf '#!/bin/bash\n' > "$TMP/Scripts/$s"
done

# Runs the check against the fixture suites and the workflow(s) given.
run() {
  SUITES_DIR="$TMP/Scripts" SUITE_WORKFLOWS="$1" "$CHECK" > "$TMP/out" 2> "$TMP/err"
}

# 1. Every suite run in a block scalar, in the shapes ci.yml uses: a plain
#    line, a line after a comment, one with a trailing comment, and `./`.
cat > "$TMP/all.yml" <<'EOF'
jobs:
  helpers:
    steps:
      - name: Verify the build-script helpers
        run: |
          Scripts/test-alpha.sh
          # The next one guards something.
          Scripts/test-beta.sh   # trailing remark

          ./Scripts/test-gamma.sh
EOF
run "$TMP/all.yml" || fail "a fully registered tree was refused: $(cat "$TMP/err")"
pass "every suite run in a run block passes"

# 2. The shape issue #454 found: a suite named nowhere. It is named in the
#    error, and the registered ones are not.
cat > "$TMP/missing.yml" <<'EOF'
jobs:
  helpers:
    steps:
      - run: |
          Scripts/test-alpha.sh
          Scripts/test-gamma.sh
EOF
if run "$TMP/missing.yml"; then fail "an unregistered suite was accepted"; fi
grep -q 'Scripts/test-beta.sh is run by no pull-request workflow' "$TMP/err" \
  || fail "the missing suite was not named: $(cat "$TMP/err")"
if grep -q 'test-alpha.sh\|test-gamma.sh' "$TMP/err"; then
  fail "a registered suite was reported missing: $(cat "$TMP/err")"
fi
pass "an unregistered suite is refused, and named"

# 3. A mention in a comment runs nothing -- neither a whole-line comment
#    inside the run block, nor a trailing one, nor a YAML comment above the
#    step, nor the step's name. The workflow comment that said "this list must
#    name EVERY suite" is exactly the kind of text that must not count.
cat > "$TMP/comment.yml" <<'EOF'
jobs:
  helpers:
    steps:
      # Scripts/test-beta.sh is run below. (It is not.)
      - name: Run Scripts/test-beta.sh
        run: |
          Scripts/test-alpha.sh
          # Scripts/test-beta.sh
          Scripts/test-gamma.sh  # and Scripts/test-beta.sh
EOF
if run "$TMP/comment.yml"; then fail "a suite mentioned only in comments was accepted"; fi
grep -q 'Scripts/test-beta.sh is run by no' "$TMP/err" \
  || fail "the commented-out suite was not named: $(cat "$TMP/err")"
pass "a suite mentioned only in comments or a step name is refused"

# 4. Text after the run block ends is not run. A dedented `env:` or the next
#    step must close the block, or a name in them would count.
cat > "$TMP/after.yml" <<'EOF'
jobs:
  helpers:
    steps:
      - run: |
          Scripts/test-alpha.sh
          Scripts/test-gamma.sh
        env:
          NOTE: Scripts/test-beta.sh
      - uses: actions/upload-artifact@v4
        with:
          path: Scripts/test-beta.sh
EOF
if run "$TMP/after.yml"; then fail "a name after the run block was counted"; fi
pass "the run block ends where its indentation does"

# 5. An inline `run:`, and a `>-` block scalar, both count.
cat > "$TMP/inline.yml" <<'EOF'
jobs:
  a:
    steps:
      - run: Scripts/test-alpha.sh
      - name: folded
        run: >-
          Scripts/test-beta.sh
          && Scripts/test-gamma.sh
EOF
run "$TMP/inline.yml" || fail "inline and folded run blocks were not read: $(cat "$TMP/err")"
pass "an inline run and a folded block scalar both count"

# 6. A longer name that merely contains the suite's does not register it:
#    test-alpha.sh.bak and test-alpha.shx are not test-alpha.sh.
cat > "$TMP/prefix.yml" <<'EOF'
jobs:
  a:
    steps:
      - run: |
          Scripts/test-alpha.sh.bak
          Scripts/test-alpha.shx
          Scripts/test-beta.sh
          Scripts/test-gamma.sh
EOF
if run "$TMP/prefix.yml"; then fail "a longer name registered test-alpha.sh"; fi
grep -q 'Scripts/test-alpha.sh is run by no' "$TMP/err" \
  || fail "test-alpha.sh not named: $(cat "$TMP/err")"
pass "only the suite's whole name registers it"

# 7. Suites may be spread across several counted workflows.
cat > "$TMP/one.yml" <<'EOF'
jobs:
  a:
    steps:
      - run: Scripts/test-alpha.sh
EOF
cat > "$TMP/two.yml" <<'EOF'
jobs:
  b:
    steps:
      - run: |
          Scripts/test-beta.sh
          Scripts/test-gamma.sh
EOF
run "$TMP/one.yml:$TMP/two.yml" || fail "two workflows were not both read: $(cat "$TMP/err")"
pass "every counted workflow is read"

# 8. Fail closed, exit 2, on input the check cannot read: a missing workflow,
#    and a directory with no suites (a wrong path must not read as "all
#    registered").
set +e
SUITES_DIR="$TMP/Scripts" SUITE_WORKFLOWS="$TMP/nope.yml" "$CHECK" > /dev/null 2> "$TMP/err"
rc=$?
mkdir -p "$TMP/empty"
SUITES_DIR="$TMP/empty" SUITE_WORKFLOWS="$TMP/all.yml" "$CHECK" > /dev/null 2> "$TMP/err2"
rc2=$?
set -e
[ "$rc" -eq 2 ] || fail "a missing workflow exited $rc, not 2"
grep -q 'cannot read workflow' "$TMP/err" || fail "missing workflow not reported: $(cat "$TMP/err")"
[ "$rc2" -eq 2 ] || fail "an empty suites directory exited $rc2, not 2"
grep -q 'no test-\*.sh suites' "$TMP/err2" || fail "empty directory not reported: $(cat "$TMP/err2")"
pass "an unreadable workflow or an empty suites directory fails closed"

# 9. An exemption with a reason excuses a suite; one without a reason, or
#    one naming a suite that does not exist, is refused.
printf 'test-beta.sh|needs a physical device\n' > "$TMP/exempt-ok"
SUITES_EXEMPT_FILE="$TMP/exempt-ok" run "$TMP/missing.yml" \
  || fail "an exempt suite was refused: $(cat "$TMP/err")"
grep -q '^exempt - test-beta.sh' "$TMP/out" || fail "exemption not reported: $(cat "$TMP/out")"
printf 'test-beta.sh\n' > "$TMP/exempt-bare"
if SUITES_EXEMPT_FILE="$TMP/exempt-bare" run "$TMP/missing.yml"; then
  fail "an exemption without a reason was accepted"
fi
grep -q 'exemption for test-beta.sh gives no reason' "$TMP/err" \
  || fail "reasonless exemption not named: $(cat "$TMP/err")"
printf 'test-beta.sh|needs a device\ntest-gone.sh|was deleted\n' > "$TMP/exempt-stale"
if SUITES_EXEMPT_FILE="$TMP/exempt-stale" run "$TMP/missing.yml"; then
  fail "an exemption for a missing suite was accepted"
fi
grep -q 'exemption names test-gone.sh, which is not a suite' "$TMP/err" \
  || fail "stale exemption not named: $(cat "$TMP/err")"
pass "an exemption needs a reason and a suite that exists"

# 10. LIVE: the real tree. Every Scripts/test-*.sh is run by ci.yml, so a
#     suite added later without a line in the helper step fails here, by name.
"$CHECK" > "$TMP/out" 2> "$TMP/err" \
  || fail "the real tree has an unregistered suite: $(cat "$TMP/err")"
pass "every suite in this tree is run by ci.yml"

# 11. LIVE, and the proof the check bites on the real file: a copy of ci.yml
#     with this suite's own line deleted is refused, naming it. (Issue #454's
#     verification step, kept as a case so it cannot rot.)
grep -q '^ *Scripts/test-check-suites-registered\.sh$' "$ROOT/.github/workflows/ci.yml" \
  || fail "ci.yml does not run this suite on a line of its own"
grep -v '^ *Scripts/test-check-suites-registered\.sh$' "$ROOT/.github/workflows/ci.yml" \
  > "$TMP/ci-minus-one.yml"
if SUITE_WORKFLOWS="$TMP/ci-minus-one.yml" "$CHECK" > /dev/null 2> "$TMP/err"; then
  fail "ci.yml without this suite's line was accepted"
fi
grep -q 'Scripts/test-check-suites-registered.sh is run by no' "$TMP/err" \
  || fail "the deleted suite was not named: $(cat "$TMP/err")"
pass "the real ci.yml with one suite's line deleted is refused, naming it"

echo "All check-suites-registered tests passed."
