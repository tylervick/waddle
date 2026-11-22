#!/bin/bash
# Tests for Scripts/check-release-gate.sh.
#
# Fully HERMETIC for the discrimination cases: each writes a throwaway ci.yml
# under $TMP and points the guard at it with RELEASE_GATE_CI_FILE. Nothing
# there reads the repository.
#
# Cases 11 to 13 and 20 are the deliberate exception, on the model of
# test-check-called-workflow-secrets.sh: 11 runs the guard against the REAL
# ci.yml, so that opening the release gate fails CI; 12, 13 and the sweep in
# 20 copy the real file, open the gate one way each, and assert the guard
# then fails -- the proof that case 11 is not passing vacuously.
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

# --- found in review of pull request 448 ---------------------------------------
#
# Each of 14 to 19 passed the guard as first written; the review of pull
# request 448 found 14, 15 and 17 by mutating the real ci.yml.

# 14. Expression functions are case-insensitive to GitHub, so a capital
#     letter must not get a status function past the guard.
for spelling in 'Always()' '!Cancelled()' 'FAILURE()' 'Success() || failure()'; do
    write_ci "$NEEDS" "    if: $spelling && github.event_name == 'push' && github.ref == 'refs/heads/main'"
    refused "calls a status function" "a status function spelled '$spelling'"
done
pass "refuses a status function whatever its capitalisation"

# 15. A job is a job with a comment after its id, or with its id in quotes.
#     Neither was seen, so a new check written either way was waited for by
#     nobody and the guard said ok.
write_ci "$NEEDS" "$IF" '  lint: # a new check
    runs-on: ubuntu-latest
    steps:
      - run: exit 1'
refused "job 'lint' is not in" "a new job whose id line carries a comment"
write_ci "$NEEDS" "$IF" '  "lint":
    runs-on: ubuntu-latest
    steps:
      - run: exit 1'
refused "job 'lint' is not in" "a new job whose id is quoted"
pass "sees a job whose id line has a trailing comment or quotes"

# 16. And a line at job depth it still cannot read as an id is refused, not
#     passed over: an unseen job is the failure 15 was.
write_ci "$NEEDS" "$IF" '  ? lint
  : runs-on: ubuntu-latest'
refused "not a job id this guard can read" "a job written as a complex key"
pass "refuses a line at job depth it cannot read as a job id"

# 17. The other half of the gate: a push, to main. Deleted, loosened with ||,
#     turned round with !=, or with one of its two tests gone.
write_ci "$NEEDS" '    # no if'
refused "does not test github.event_name=='push'" "a release job with no if:"
write_ci "$NEEDS" "    if: github.event_name == 'push'"
refused "does not test github.ref=='refs/heads/main'" "a release on a push to any branch"
write_ci "$NEEDS" "    if: github.ref == 'refs/heads/main'"
refused "does not test github.event_name=='push'" "a release on any event on main"
write_ci "$NEEDS" "    if: github.event_name == 'pull_request' || (github.event_name == 'push' && github.ref == 'refs/heads/main')"
refused "contains ||" "a release that also runs on pull requests"
write_ci "$NEEDS" "    if: github.event_name == 'push' && github.ref == 'refs/heads/main' && github.actor != 'x'"
refused "negates something" "a release condition with a negation in it"
pass "refuses a release job that is no longer limited to a push to main"

# 18. The spacing of the condition is not pinned, only its content, and the
#     \${{ }} wrapper is allowed.
write_ci "$NEEDS" "    if: \${{ github.event_name=='push'   &&   github.ref  ==  'refs/heads/main' }}"
check > /dev/null || fail "a correct condition with different spacing was refused"
pass "accepts the same condition spelled with other spacing"

# 19. A needed job with an if: of its own. Skipped, it skips the release, and
#     nothing is red: the trap the guard's own advice used to lead into.
write_ci '    needs: [helper-suites, unit-tests, pr-only]' "$IF" "  pr-only:
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - run: echo pr"
refused "'pr-only' has an if: of its own" "a needed job that only runs on pull requests"
pass "refuses a needed job that can be skipped"

# 19b. --print-needs prints the jobs the release waits for, one per line and
#      nothing else, in all three spellings of needs:, even when the gate is
#      open. Scripts/check-suites-registered.sh reads it to decide where a
#      suite counts as run, so the list must be the parsed needs:, not a verdict.
for spelling in '    needs: [helper-suites, unit-tests]' '    needs:
      - helper-suites
      - unit-tests # every leg'; do
    write_ci "$spelling" "$IF"
    out="$(RELEASE_GATE_CI_FILE="$TMP/ci.yml" "$ROOT/Scripts/check-release-gate.sh" --print-needs)" \
        || fail "--print-needs failed on a well-formed fixture"
    [ "$out" = "$(printf 'helper-suites\nunit-tests')" ] || fail "--print-needs printed: $out"
done
write_ci '    needs: unit-tests' "$IF"
out="$(RELEASE_GATE_CI_FILE="$TMP/ci.yml" "$ROOT/Scripts/check-release-gate.sh" --print-needs)" \
    || fail "--print-needs failed on an open gate; it reports the list, the plain run judges it"
[ "$out" = "unit-tests" ] || fail "--print-needs on a scalar needs: printed: $out"
pass "--print-needs prints the release's needs:, one job per line"

# 20. LIVE, a sweep: the real ci.yml, opened one way at a time. Every one of
#     these must be refused. The first argument is an awk program run over
#     the real file; `T` is true inside the testflight job.
REAL="$ROOT/.github/workflows/ci.yml"
swept=0
mutant() { # what, awk-program
    awk "
        /^  [A-Za-z0-9_.\"-]+:/ { T = (\$0 ~ /^  testflight:/); U = (\$0 ~ /^  unit-tests:/); H = (\$0 ~ /^  helper-suites:/) }
        $2
        { print }
    " "$REAL" > "$TMP/ci.yml"
    cmp -s "$TMP/ci.yml" "$REAL" && fail "sweep: '$1' changed nothing in the real ci.yml"
    local out rc
    set +e; out="$(check 2>&1)"; rc=$?; set -e
    [ "$rc" -ne 0 ] || fail "sweep: the real ci.yml with $1 passed the guard: $out"
    swept=$((swept + 1))
}
mutant "helper-suites dropped from needs"   'T && /^    needs:/ { sub(/helper-suites, /, "") }'
mutant "unit-tests dropped from needs"      'T && /^    needs:/ { sub(/, unit-tests/, "") }'
mutant "needs removed"                      'T && /^    needs:/ { next }'
mutant "needs emptied"                      'T && /^    needs:/ { $0 = "    needs: []" }'
mutant "always() on the release"            'T && /^    if:/ { sub(/if: /, "if: always() \\&\\& ") }'
mutant "Always() on the release"            'T && /^    if:/ { sub(/if: /, "if: Always() \\&\\& ") }'
mutant "!cancelled() on the release"        'T && /^    if:/ { sub(/if: /, "if: !cancelled() \\&\\& ") }'
mutant "!Cancelled() on the release"        'T && /^    if:/ { sub(/if: /, "if: !Cancelled() \\&\\& ") }'
mutant "!failure() on the release"          'T && /^    if:/ { sub(/if: /, "if: !failure() \\&\\& ") }'
mutant "success() || failure()"             'T && /^    if:/ { sub(/if: /, "if: (success() || failure()) \\&\\& ") }'
mutant "the release if: removed"            'T && /^    if:/ { next }'
mutant "the release if: true on pull requests" 'T && /^    if:/ { $0 = "    if: github.event_name == \"pull_request\"" }'
mutant "the main test removed"              'T && /^    if:/ { sub(/ && github.ref == .refs\/heads\/main./, "") }'
mutant "the push test removed"              'T && /^    if:/ { sub(/github.event_name == .push. && /, "") }'
mutant "an || added to the release if:"     'T && /^    if:/ { $0 = $0 " || github.event_name == \"schedule\"" }'
mutant "continue-on-error on unit-tests"    'U && /^    runs-on:/ { print "    continue-on-error: true" }'
mutant "continue-on-error as an expression" 'H && /^    runs-on:/ { print "    continue-on-error: ${{ true }}" }'
mutant "an if: on unit-tests"               'U && /^    runs-on:/ { print "    if: github.event_name == \"pull_request\"" }'
mutant "a new job after helper-suites"      '/^  unit-tests:$/ { print "  lint:\n    runs-on: ubuntu-latest\n    steps:\n      - run: exit 1" }'
mutant "a new job with a trailing comment"  '/^  unit-tests:$/ { print "  lint: # a new check\n    runs-on: ubuntu-latest\n    steps:\n      - run: exit 1" }'
mutant "a new job with a quoted id"         '/^  unit-tests:$/ { print "  \"lint\":\n    runs-on: ubuntu-latest\n    steps:\n      - run: exit 1" }'
mutant "the release job renamed"            '/^  testflight:$/ { $0 = "  ship:" }'
mutant "a needs: naming no job"             'T && /^    needs:/ { sub(/unit-tests/, "unit-test") }'
pass "real repo: $swept ways of opening the gate are each refused"

echo "All check-release-gate tests passed."
