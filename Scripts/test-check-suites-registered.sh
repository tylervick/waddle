#!/bin/bash
# Tests for Scripts/check-suites-registered.sh.
#
# HERMETIC except where noted: every case points the check at a fixture suites
# directory and a fixture workflow under $TMP through SUITES_DIR and
# SUITE_WORKFLOW. The fixtures are laid out as ci.yml is (two-space indents, a
# `testflight` job whose needs: is the release gate), because the check reads
# that layout and asks Scripts/check-release-gate.sh which jobs the release
# waits for. The deliberate exceptions are the LIVE cases at the end, which run
# the check against the real ci.yml -- as it is, so a suite added later
# without being registered fails CI, and mutated, so the live run is shown to
# bite rather than assumed to.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/Scripts/check-suites-registered.sh"
CI="$ROOT/.github/workflows/ci.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

mkdir -p "$TMP/Scripts"
for s in test-alpha.sh test-beta.sh test-gamma.sh; do
  printf '#!/bin/bash\n' > "$TMP/Scripts/$s"
done

# Writes a workflow to $TMP/<name>.yml: the jobs given on stdin under `jobs:`,
# then a `testflight` job that needs the jobs named in $2.
workflow() {
  {
    printf 'on:\n  pull_request:\n\njobs:\n'
    cat
    printf '  testflight:\n    needs: [%s]\n' "$2"
    printf "    if: github.event_name == 'push' && github.ref == 'refs/heads/main'\n"
    printf '    uses: ./.github/workflows/testflight.yml\n'
  } > "$TMP/$1.yml"
}

# Runs the check against the fixture suites and the workflow named.
run() {
  SUITES_DIR="$TMP/Scripts" SUITE_WORKFLOW="$TMP/$1.yml" "$CHECK" > "$TMP/out" 2> "$TMP/err"
}

# Asserts that the workflow is refused and that test-beta.sh, and only it, is
# named as not counted.
refused_beta() {
  if run "$1"; then fail "$2 was accepted"; fi
  grep -q 'Scripts/test-beta.sh is ' "$TMP/err" || fail "$2: test-beta.sh not named: $(cat "$TMP/err")"
  if grep -q 'test-alpha.sh\|test-gamma.sh' "$TMP/err"; then
    fail "$2: a counted suite was reported: $(cat "$TMP/err")"
  fi
}

# 1. Every suite run in a block scalar in a job the release waits for, in the
#    shapes ci.yml uses: a plain line, a line after a comment, one with a
#    trailing comment, one with an argument, and `./`.
workflow all helpers <<'EOF'
  helpers:
    runs-on: xcode-27
    steps:
      - uses: actions/checkout@v7
      - name: Verify the build-script helpers
        run: |
          Scripts/test-alpha.sh
          # The next one guards something.
          Scripts/test-beta.sh --verbose   # trailing remark

          ./Scripts/test-gamma.sh
EOF
run all || fail "a fully registered tree was refused: $(cat "$TMP/err")"
pass "every suite run in a gated, unconditional step passes"

# 2. The shape issue #454 found: a suite named nowhere. It is named in the
#    error, and the registered ones are not.
workflow missing helpers <<'EOF'
  helpers:
    steps:
      - run: |
          Scripts/test-alpha.sh
          Scripts/test-gamma.sh
EOF
refused_beta missing "an unregistered suite"
grep -q 'Scripts/test-beta.sh is run by no pull-request workflow' "$TMP/err" \
  || fail "the never-named message was not used: $(cat "$TMP/err")"
pass "an unregistered suite is refused, and named"

# 3. A mention in a comment runs nothing -- neither a whole-line comment
#    inside the run block, nor a trailing one, nor a YAML comment above the
#    step, nor the step's name. The workflow comment that said "this list must
#    name EVERY suite" is exactly the kind of text that must not count.
workflow comment helpers <<'EOF'
  helpers:
    steps:
      # Scripts/test-beta.sh is run below. (It is not.)
      - name: Run Scripts/test-beta.sh
        run: |
          Scripts/test-alpha.sh
          # Scripts/test-beta.sh
          Scripts/test-gamma.sh  # and Scripts/test-beta.sh
EOF
refused_beta comment "a suite mentioned only in comments or a step name"
pass "a suite mentioned only in comments or a step name is refused"

# 4. Text after the run block ends is not run. A dedented `env:` or the next
#    step must close the block, or a name in them would count.
workflow after helpers <<'EOF'
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
refused_beta after "a name after the run block"
pass "the run block ends where its indentation does"

# 5. An inline `run:`, and a `>-` block scalar, both count.
workflow inline helpers <<'EOF'
  helpers:
    steps:
      - run: Scripts/test-alpha.sh
      - name: folded
        run: >-
          Scripts/test-beta.sh

          Scripts/test-gamma.sh
EOF
run inline || fail "inline and folded run blocks were not read: $(cat "$TMP/err")"
pass "an inline run and a folded block scalar both count"

# 6. A longer name that merely contains the suite's does not register it:
#    test-beta.sh.bak and test-beta.shx are not test-beta.sh.
workflow prefix helpers <<'EOF'
  helpers:
    steps:
      - run: |
          Scripts/test-alpha.sh
          Scripts/test-beta.sh.bak
          Scripts/test-beta.shx
          Scripts/test-gamma.sh
EOF
refused_beta prefix "a longer name"
pass "only the suite's whole name registers it"

# 7. The review of PR #473, first shape: a job the release does not wait for.
#    ci.yml's changed-paths is `if: false && ...`; such a job's steps never
#    fail anything. The error says the suite was found, but not where it counts.
workflow notneeded helpers <<'EOF'
  helpers:
    steps:
      - run: |
          Scripts/test-alpha.sh
          Scripts/test-gamma.sh
  changed-paths:
    if: false && github.event_name == 'pull_request'
    steps:
      - run: Scripts/test-beta.sh
EOF
refused_beta notneeded "a suite only in a job the release does not wait for"
grep -q 'Scripts/test-beta.sh is named in .*but not where its failure fails every pull request' "$TMP/err" \
  || fail "the named-but-not-counted message was not used: $(cat "$TMP/err")"
pass "a suite only in a job the release does not wait for is refused"

# 8. Second shape: a push-only job, like revyl-main, which needs the checks
#    but is not one. Not in the release's needs:, so it does not count.
workflow pushonly helpers <<'EOF'
  helpers:
    steps:
      - run: |
          Scripts/test-alpha.sh
          Scripts/test-gamma.sh
  publish-main:
    needs: [helpers]
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    steps:
      - run: Scripts/test-beta.sh
EOF
refused_beta pushonly "a suite only in a push-only job"
pass "a suite only in a push-only job is refused"

# 8b. A job with no if: at all that the release still does not wait for. Both
#     jobs above are also conditional, so without this case nothing would show
#     that it is the release's needs:, and not the job's if:, that decides.
workflow unneeded helpers <<'EOF'
  helpers:
    steps:
      - run: |
          Scripts/test-alpha.sh
          Scripts/test-gamma.sh
  lint:
    runs-on: ubuntu-latest
    steps:
      - run: Scripts/test-beta.sh
EOF
refused_beta unneeded "a suite only in an unconditional job the release does not need"
pass "a suite only in a job outside the release's needs: is refused"

# 9. Third shape: a step with an if:, in a job the release does need. Before
#    the run: and after it, since GitHub reads a step's keys in any order.
for where in before after; do
  if [ "$where" = before ]; then
    step='      - if: false
        run: Scripts/test-beta.sh'
  else
    step='      - run: Scripts/test-beta.sh
        if: github.event_name == '"'"'push'"'"
  fi
  workflow "stepif-$where" helpers <<EOF
  helpers:
    steps:
      - run: |
          Scripts/test-alpha.sh
          Scripts/test-gamma.sh
$step
EOF
  refused_beta "stepif-$where" "a suite only in a step with an if: ($where its run:)"
done
pass "a suite only in a step with an if: is refused, wherever the if: is"

# 10. Fourth shape: continue-on-error on the step, so its failure is green.
#     `continue-on-error: false` is the default spelled out and still counts.
workflow stepcoe helpers <<'EOF'
  helpers:
    steps:
      - name: Optional suites
        continue-on-error: true
        run: |
          Scripts/test-beta.sh
      - continue-on-error: false
        run: |
          Scripts/test-alpha.sh
          Scripts/test-gamma.sh
EOF
refused_beta stepcoe "a suite only in a continue-on-error step"
pass "a suite only in a continue-on-error step is refused; continue-on-error: false counts"

# 11. The same, one level up: a needed job with an if: or continue-on-error of
#     its own (check-release-gate.sh refuses this too; this guard does not rely
#     on running after it). A job-level if: written after the steps counts.
workflow jobif "helpers, more" <<'EOF'
  helpers:
    steps:
      - run: |
          Scripts/test-alpha.sh
          Scripts/test-gamma.sh
  more:
    steps:
      - run: Scripts/test-beta.sh
    if: github.event_name == 'push'
EOF
refused_beta jobif "a suite in a needed job with a job-level if:"
workflow jobcoe "helpers, more" <<'EOF'
  helpers:
    steps:
      - run: |
          Scripts/test-alpha.sh
          Scripts/test-gamma.sh
  more:
    continue-on-error: true
    steps:
      - run: Scripts/test-beta.sh
EOF
refused_beta jobcoe "a suite in a needed job with continue-on-error"
pass "a needed job with its own if: or continue-on-error does not count"

# 12. Lines that name the suite and still cannot fail the step: an || that
#     swallows the status, a pipe (the default run shell has no pipefail), a
#     background job, an echo. And a step that cannot fail on a non-final
#     line at all: `set +e`, or a custom shell without -e.
i=0
for line in 'Scripts/test-beta.sh || true' 'Scripts/test-beta.sh | tee out.txt' \
            'Scripts/test-beta.sh &' 'echo skipping Scripts/test-beta.sh' \
            'Scripts/test-beta.sh; true'; do
  i=$((i + 1))
  workflow "mask$i" helpers <<EOF
  helpers:
    steps:
      - run: |
          Scripts/test-alpha.sh
          $line
          Scripts/test-gamma.sh
EOF
  refused_beta "mask$i" "'$line'"
done
workflow sete helpers <<'EOF'
  helpers:
    steps:
      - run: |
          Scripts/test-alpha.sh
          Scripts/test-gamma.sh
      - run: |
          set +e
          Scripts/test-beta.sh
EOF
refused_beta sete "a suite in a set +e step"
workflow shell helpers <<'EOF'
  helpers:
    steps:
      - run: |
          Scripts/test-alpha.sh
          Scripts/test-gamma.sh
      - shell: bash {0}
        run: |
          Scripts/test-beta.sh
          echo done
EOF
refused_beta shell "a suite in a step with a custom shell"
workflow shellbash helpers <<'EOF'
  helpers:
    steps:
      - shell: bash
        run: |
          Scripts/test-alpha.sh
          Scripts/test-beta.sh
          Scripts/test-gamma.sh
EOF
run shellbash || fail "shell: bash was refused: $(cat "$TMP/err")"
pass "a line or step that masks the suite's status is refused; shell: bash counts"

# 12b. `set +e` hidden among other flags (review of PR #473, round 2): the
#      first cut matched only `set +e` and `set +o errexit` with the flag
#      first, so `set +x +e` and `set +xe` passed.
i=0
for line in 'set +x +e' 'set +xe' 'set -x +o errexit'; do
  i=$((i + 1))
  workflow "setflags$i" helpers <<EOF
  helpers:
    steps:
      - run: |
          Scripts/test-alpha.sh
          Scripts/test-gamma.sh
      - run: |
          $line
          Scripts/test-beta.sh
EOF
  refused_beta "setflags$i" "a suite after '$line'"
done
workflow setminus helpers <<'EOF'
  helpers:
    steps:
      - run: |
          set -x -e
          Scripts/test-alpha.sh
          Scripts/test-beta.sh
          Scripts/test-gamma.sh
EOF
run setminus || fail "set -x -e was refused: $(cat "$TMP/err")"
pass "set +e among other flags is refused; set -x -e counts"

# 12c. The custom-shell rule one and two levels up (same review): a shell
#      from `defaults: run: shell:` applies to every step under it without a
#      `shell:` of its own, so `bash {0}` -- no -e -- there masks a failing
#      line just as it does on a step. Job level masks that job's suites;
#      workflow level, before or after `jobs:`, masks every suite.
workflow jobdefaults helpers <<'EOF'
  helpers:
    defaults:
      run:
        shell: bash {0}
    steps:
      - run: |
          Scripts/test-beta.sh
  other:
    steps:
      - run: |
          Scripts/test-alpha.sh
          Scripts/test-gamma.sh
EOF
sed -i '' 's/needs: \[helpers\]/needs: [helpers, other]/' "$TMP/jobdefaults.yml"
refused_beta jobdefaults "a suite in a job whose defaults shell is bash {0}"
for where in before after; do
  workflow "wfdefaults-$where" helpers <<'EOF'
  helpers:
    steps:
      - run: |
          Scripts/test-alpha.sh
          Scripts/test-beta.sh
          Scripts/test-gamma.sh
EOF
  defaults='defaults:
  run:
    shell: bash {0}'
  if [ "$where" = before ]; then
    { printf '%s\n' "$defaults"; cat "$TMP/wfdefaults-$where.yml"; } > "$TMP/wf.tmp"
  else
    { cat "$TMP/wfdefaults-$where.yml"; printf '%s\n' "$defaults"; } > "$TMP/wf.tmp"
  fi
  mv "$TMP/wf.tmp" "$TMP/wfdefaults-$where.yml"
  if run "wfdefaults-$where"; then fail "a workflow-level bash {0} default ($where jobs:) was accepted"; fi
  for s in alpha beta gamma; do
    grep -q "Scripts/test-$s.sh is " "$TMP/err" \
      || fail "workflow-level default ($where jobs:): test-$s.sh not named: $(cat "$TMP/err")"
  done
done
workflow defaultsbash helpers <<'EOF'
  helpers:
    defaults:
      run:
        shell: bash
        working-directory: .
    steps:
      - run: |
          Scripts/test-alpha.sh
          Scripts/test-beta.sh
          Scripts/test-gamma.sh
EOF
run defaultsbash || fail "a job defaults shell of bash was refused: $(cat "$TMP/err")"
pass "a defaults shell without -e is refused at job and workflow level; bash counts"

# 13. Fail closed, exit 2, on input the check cannot read: a missing workflow,
#     a directory with no suites (a wrong path must not read as "all
#     registered"), a workflow with no release gate, and a gate that waits for
#     nothing.
expect2() {
  set +e
  SUITES_DIR="$1" SUITE_WORKFLOW="$2" "$CHECK" > /dev/null 2> "$TMP/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "$4 exited $rc, not 2"
  grep -q "$3" "$TMP/err" || fail "$4 not reported: $(cat "$TMP/err")"
}
mkdir -p "$TMP/empty"
expect2 "$TMP/Scripts" "$TMP/nope.yml" 'cannot read workflow' "a missing workflow"
expect2 "$TMP/empty" "$TMP/all.yml" 'no test-\*.sh suites' "an empty suites directory"
printf 'on:\n  pull_request:\njobs:\n  helpers:\n    steps:\n      - run: Scripts/test-alpha.sh\n' > "$TMP/nogate.yml"
expect2 "$TMP/Scripts" "$TMP/nogate.yml" 'could not read the release gate' "a workflow with no testflight job"
printf "jobs:\n  helpers:\n    steps:\n      - run: Scripts/test-alpha.sh\n  testflight:\n    if: github.event_name == 'push'\n" > "$TMP/noneeds.yml"
expect2 "$TMP/Scripts" "$TMP/noneeds.yml" 'waits for no job' "a release that waits for nothing"
pass "an unreadable workflow, an empty suites directory, or no gate fails closed"

# 14. An exemption with a reason excuses a suite; one without a reason, or
#     one naming a suite that does not exist, is refused.
printf 'test-beta.sh|needs a physical device\n' > "$TMP/exempt-ok"
SUITES_EXEMPT_FILE="$TMP/exempt-ok" run missing \
  || fail "an exempt suite was refused: $(cat "$TMP/err")"
grep -q '^exempt - test-beta.sh' "$TMP/out" || fail "exemption not reported: $(cat "$TMP/out")"
printf 'test-beta.sh\n' > "$TMP/exempt-bare"
if SUITES_EXEMPT_FILE="$TMP/exempt-bare" run missing; then
  fail "an exemption without a reason was accepted"
fi
grep -q 'exemption for test-beta.sh gives no reason' "$TMP/err" \
  || fail "reasonless exemption not named: $(cat "$TMP/err")"
printf 'test-beta.sh|needs a device\ntest-gone.sh|was deleted\n' > "$TMP/exempt-stale"
if SUITES_EXEMPT_FILE="$TMP/exempt-stale" run missing; then
  fail "an exemption for a missing suite was accepted"
fi
grep -q 'exemption names test-gone.sh, which is not a suite' "$TMP/err" \
  || fail "stale exemption not named: $(cat "$TMP/err")"
pass "an exemption needs a reason and a suite that exists"

# 15. LIVE: the real tree. Every Scripts/test-*.sh is run by ci.yml where it
#     counts, so a suite added later without a line in the helper step fails
#     here, by name.
"$CHECK" > "$TMP/out" 2> "$TMP/err" \
  || fail "the real tree has a suite that does not count: $(cat "$TMP/err")"
pass "every suite in this tree is run where its failure fails a pull request"

# 16. LIVE, the real ci.yml mutated: test-glyph-source.sh's line deleted from
#     the helper step, then (except for the first) put back somewhere that
#     never fails a pull request -- the four places the review of PR #473
#     found the first version of this guard accepted. Each must be refused,
#     naming the suite.
SUITE_LINE='^ *Scripts/test-glyph-source\.sh$'
grep -q "$SUITE_LINE" "$CI" || fail "ci.yml does not run test-glyph-source.sh on a line of its own"
grep -q '^  changed-paths:$' "$CI" || fail "ci.yml has no changed-paths job to mutate"
grep -q '^  revyl-main:$' "$CI" || fail "ci.yml has no revyl-main job to mutate"
helper_step='^      - name: Verify the build-script helpers$'
grep -q "$helper_step" "$CI" || fail "ci.yml has no helper step to mutate"
# Prints ci.yml without the suite's line and with $1 (an awk program run on
# every line before it is printed) applied.
mutated() { awk -v pat="$SUITE_LINE" '$0 ~ pat { next } '"$1"' { print }' "$CI"; }
STEP='      - run: Scripts/test-glyph-source.sh'
n=0
live_mutant() {
  mutated "$2" > "$TMP/ci-mutant.yml"
  if SUITE_WORKFLOW="$TMP/ci-mutant.yml" "$CHECK" > /dev/null 2> "$TMP/err"; then
    fail "the real ci.yml, $1, was accepted"
  fi
  grep -q 'Scripts/test-glyph-source.sh is ' "$TMP/err" \
    || fail "the real ci.yml, $1: test-glyph-source.sh not named: $(cat "$TMP/err")"
  n=$((n + 1))
}
live_mutant "with the line deleted" ''
live_mutant "moved into the changed-paths job" \
  '/^  [a-z-]+:$/ { j = $0 } j == "  changed-paths:" && /^    steps:$/ { print; print "'"$STEP"'"; next }'
live_mutant "moved into the revyl-main job" \
  '/^  [a-z-]+:$/ { j = $0 } j == "  revyl-main:" && /^    steps:$/ { print; print "'"$STEP"'"; next }'
live_mutant "moved into an if: false step" \
  '/'"$helper_step"'/ { print "      - if: false"; print "        run: Scripts/test-glyph-source.sh" }'
live_mutant "moved into a continue-on-error step" \
  '/'"$helper_step"'/ { print "      - continue-on-error: true"; print "        run: Scripts/test-glyph-source.sh" }'
# And the same move into a plain step of the helper job is accepted: the
# refusals above are about where it went, not about moving it.
mutated '/'"$helper_step"'/ { print "'"$STEP"'" }' > "$TMP/ci-moved.yml"
SUITE_WORKFLOW="$TMP/ci-moved.yml" "$CHECK" > /dev/null 2> "$TMP/err" \
  || fail "the real ci.yml with the suite in its own plain helper step was refused: $(cat "$TMP/err")"
pass "real ci.yml: $n ways of not running a suite on a pull request are each refused"

echo "All check-suites-registered tests passed."
