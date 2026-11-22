#!/bin/bash
# Tests for Scripts/check-release-gate.sh.
#
# Fully HERMETIC for the discrimination cases: each writes a throwaway ci.yml
# under $TMP and points the guard at it with RELEASE_GATE_CI_FILE. Nothing
# there reads the repository.
#
# Cases 11 to 13 are the deliberate exception, on the model of
# test-check-called-workflow-secrets.sh: 11 runs the guard against the REAL
# ci.yml, so that opening the release gate fails CI; 12 and 13 copy the real
# file, open the gate one way each, and assert the guard then fails -- the
# proof that case 11 is not passing vacuously.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# The shape ci.yml has: two check jobs (one a matrix), the jobs that are not
# checks, and the release job. $1 is the release job's `needs:` line(s), $2
# its `if:` line(s), $3 extra text appended as further jobs or keys.
write_ci() { # needs-lines, if-lines, [extra]
    {
        cat <<'YML'
name: CI
on:
  push:
permissions:
  contents: read
env:
  # A top-level key after which `jobs:` must still be found.
  PIN: "1"
jobs:
  # A comment naming testflight and needs: must not be read as either.
  helper-suites:
    name: Build-script helpers
    runs-on: ubuntu-latest
    steps:
      - run: echo suites
        # A step's own keys are not the job's.
        if: always()
        continue-on-error: true
  unit-tests:
    name: Unit tests (${{ matrix.leg }})
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        include:
          - leg: iPhone
    steps:
      - run: echo test
  changed-paths:
    if: false && github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - run: echo paths
  revyl-preview:
    needs: changed-paths
    if: >-
      false
      && github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - run: echo preview
        continue-on-error: true
  revyl-main:
    needs: [helper-suites, unit-tests]
    if: false && github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      - run: echo main
  testflight:
YML
        printf '%s\n' "$1" "$2"
        cat <<'YML'
    permissions:
      contents: read
    uses: ./.github/workflows/testflight.yml
    secrets: inherit
YML
        if [ -n "${3:-}" ]; then printf '%s\n' "$3"; fi
    } > "$TMP/ci.yml"
}

check() {
    env RELEASE_GATE_CI_FILE="$TMP/ci.yml" "$ROOT/Scripts/check-release-gate.sh"
}

# Runs the guard expecting a refusal whose message contains $1.
refused() { # needle, what
    local out rc
    set +e
    out="$(check 2>&1)"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "$2: the guard passed; output: $out"
    case "$out" in
        *"$1"*) ;;
        *) fail "$2: refused, but not for the expected reason; output: $out" ;;
    esac
}

NEEDS='    needs: [helper-suites, unit-tests]'
IF="    if: github.event_name == 'push' && github.ref == 'refs/heads/main'"

# 1. The shape the repository is meant to be in -> exit 0, and the message
#    names both jobs. Without this case every refusal below could be the
#    guard refusing everything. It also pins what must NOT count: a step's
#    `if: always()` and `continue-on-error`, a `needs:` on another job, and
#    comments that mention the words.
write_ci "$NEEDS" "$IF"
out="$(check)" || fail "the well-formed fixture was refused: $out"
case "$out" in
    *"helper-suites unit-tests"*) ;;
    *) fail "the ok line does not name the jobs waited for: $out" ;;
esac
pass "passes when the release waits for every check job"

# 2. A matrix job dropped from the list: the mistake the split made possible.
write_ci '    needs: [helper-suites]' "$IF"
refused "job 'unit-tests' is not in" "a release that does not wait for the unit tests"
pass "refuses a release that does not wait for the unit-test legs"

# 3. The other one dropped, spelled as a scalar.
write_ci '    needs: unit-tests' "$IF"
refused "job 'helper-suites' is not in" "a release that does not wait for the helper suites"
pass "refuses a release that does not wait for the helper suites (scalar needs)"

# 4. No `needs:` at all.
write_ci '    # no needs' "$IF"
refused "job 'unit-tests' is not in" "a release with no needs"
pass "refuses a release job with no needs: at all"

# 5. The block-list spelling is read, with a trailing comment on an item.
write_ci '    needs:
      - helper-suites
      - unit-tests # every leg' "$IF"
check > /dev/null || fail "a block-list needs: was not read"
pass "reads needs: written as a block list"

# 6. A job added to the workflow and not to the list: a new check a release
#    would not wait for.
write_ci "$NEEDS" "$IF" '  lint:
    runs-on: ubuntu-latest
    steps:
      - run: echo lint'
refused "job 'lint' is not in" "a new job nobody waits for"
pass "refuses a new job that is neither waited for nor declared not a check"

# 7. `!cancelled()` on the release: a cancelled leg would no longer skip it.
write_ci "$NEEDS" "    if: \${{ !cancelled() && github.ref == 'refs/heads/main' }}"
refused "calls a status function" "a release that runs after a cancelled leg"
pass "refuses a status function in the release job's if:"

# 8. The same, hidden on the second line of a folded `if:`.
write_ci "$NEEDS" "    if: >-
      github.event_name == 'push'
      && always()"
refused "calls a status function" "a folded if: with always()"
pass "refuses a status function on a later line of a folded if:"

# 9. A needed job that swallows its own failure.
write_ci "$NEEDS" "$IF"
awk '{ print } /^  unit-tests:$/ { print "    continue-on-error: true" }' "$TMP/ci.yml" > "$TMP/ci.new"
mv "$TMP/ci.new" "$TMP/ci.yml"
refused "'unit-tests' sets continue-on-error" "a needed job with continue-on-error"
pass "refuses continue-on-error on a job the release needs"

# 10. Fails closed: no release job to check, and no file.
write_ci "$NEEDS" "$IF"
sed 's/^  testflight:$/  ship:/' "$TMP/ci.yml" > "$TMP/ci.new"
mv "$TMP/ci.new" "$TMP/ci.yml"
refused "has no 'testflight' job" "a workflow with the release job renamed"
rm -f "$TMP/ci.yml"
refused "is not readable" "a missing workflow"
pass "fails closed when the release job or the file is missing"

# 11. LIVE: the real ci.yml.
"$ROOT/Scripts/check-release-gate.sh" > /dev/null \
    || fail "the real ci.yml does not pass; run Scripts/check-release-gate.sh"
pass "real repo: the release waits for every check job in ci.yml"

# 12. The live case bites: the real file with the unit tests taken out of the
#     release job's needs (and only that job's) must be refused.
awk '
    /^  testflight:$/ { in_job = 1 }
    in_job && /^    needs:/ { sub(/, unit-tests/, ""); in_job = 0 }
    { print }
' "$ROOT/.github/workflows/ci.yml" > "$TMP/ci.yml"
cmp -s "$TMP/ci.yml" "$ROOT/.github/workflows/ci.yml" \
    && fail "case 12 changed nothing: the real needs: line is not spelled as this case expects"
refused "job 'unit-tests' is not in" "the real ci.yml with unit-tests dropped from the gate"
pass "real repo: dropping the unit tests from the gate is refused"

# 13. And the real file with `!cancelled()` put on the release job's if:.
awk '
    /^  testflight:$/ { in_job = 1 }
    in_job && /^    if:/ { sub(/if: /, "if: !cancelled() \\&\\& "); in_job = 0 }
    { print }
' "$ROOT/.github/workflows/ci.yml" > "$TMP/ci.yml"
cmp -s "$TMP/ci.yml" "$ROOT/.github/workflows/ci.yml" \
    && fail "case 13 changed nothing: the real if: line is not spelled as this case expects"
refused "calls a status function" "the real ci.yml with !cancelled() on the release"
pass "real repo: a status function on the release job is refused"

echo "All check-release-gate tests passed."
