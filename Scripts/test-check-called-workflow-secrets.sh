#!/bin/bash
# Tests for Scripts/check-called-workflow-secrets.sh.
#
# Fully HERMETIC for the discrimination cases: each builds a throwaway
# .github/workflows directory under $TMP and points the guard at it with
# CALLED_WORKFLOW_CHECK_DIR. Nothing there reads the repository.
#
# Cases 8 and 9 are the deliberate exception, on the model of
# test-check-masked-gh-status.sh: 8 runs the guard against the REAL tree, so
# that dropping `secrets: inherit` from ci.yml's testflight job fails CI; 9
# copies the real tree, strips that one line, and asserts the guard then
# fails -- the proof that case 8 is not passing vacuously.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# A called workflow that reads secrets, the shape testflight.yml has.
write_callee_with_secrets() { # dir
    cat > "$1/release.yml" <<'YML'
name: Release
on:
  workflow_call:
jobs:
  ship:
    runs-on: ubuntu-latest
    environment: app-store
    steps:
      - run: echo "$KEY"
        env:
          KEY: ${{ secrets.ASC_KEY_ID }}
YML
}

# A called workflow that reads none.
write_callee_without_secrets() { # dir
    cat > "$1/lint.yml" <<'YML'
name: Lint
on:
  workflow_call:
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: echo lint
YML
}

# A caller with one ordinary job (whose step-level `- uses:` must not be read
# as a call) and one calling job whose body is given by $2.
write_caller() { # dir, calling-job-body
    {
        cat <<'YML'
name: CI
on:
  push:
permissions:
  contents: read
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: echo test
YML
        printf '%s\n' "$2"
    } > "$1/ci.yml"
}

check() { # dir
    env CALLED_WORKFLOW_CHECK_DIR="$1" "$ROOT/Scripts/check-called-workflow-secrets.sh"
}

# 1. The shape the repository is meant to be in: the calling job inherits,
#    the callee reads secrets -> exit 0. Without this case every later case
#    could be passing for the wrong reason.
d="$TMP/good"; mkdir -p "$d"
write_callee_with_secrets "$d"
write_caller "$d" '  release:
    needs: test
    permissions:
      contents: write
    uses: ./.github/workflows/release.yml
    secrets: inherit'
out="$(check "$d" 2>&1)" || fail "1: a caller that inherits was refused: $out"
pass "a job that inherits secrets into a secret-reading callee passes"

# 2. THE INCIDENT SHAPE (CI run 37060983966): the callee reads secrets, the
#    callee's job even declares an environment, and the caller passes nothing.
#    Must fail, and must name the job and the called file so the finding can
#    be acted on without reading the guard.
d="$TMP/none"; mkdir -p "$d"
write_callee_with_secrets "$d"
write_caller "$d" '  release:
    needs: test
    permissions:
      contents: write
    uses: ./.github/workflows/release.yml'
if out="$(check "$d" 2>&1)"; then fail "2: a caller passing no secrets was accepted: $out"; fi
case "$out" in *"job 'release'"*release.yml*inherit*) ;; *) fail "2: the finding does not name the job, the callee and the fix: $out" ;; esac
pass "a job that passes nothing into a secret-reading callee fails, naming job, callee and fix"

# 3. A callee that reads no secrets needs none passed. Flagging it would teach
#    people to add `secrets: inherit` everywhere, which widens what every
#    called workflow can reach for no reason.
d="$TMP/noneed"; mkdir -p "$d"
write_callee_without_secrets "$d"
write_caller "$d" '  lint:
    uses: ./.github/workflows/lint.yml'
out="$(check "$d" 2>&1)" || fail "3: a call into a secret-free callee was refused: $out"
pass "a call into a callee that reads no secrets passes without a secrets key"

# 4. Named secrets are as good as inherit: the key is present, so the caller
#    has made a decision the guard has no business second-guessing.
d="$TMP/named"; mkdir -p "$d"
write_callee_with_secrets "$d"
write_caller "$d" '  release:
    uses: ./.github/workflows/release.yml
    secrets:
      ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}'
out="$(check "$d" 2>&1)" || fail "4: a caller passing named secrets was refused: $out"
pass "a job that passes named secrets passes"

# 5. Key order inside the job is not a convention the guard may rely on:
#    `secrets:` before `uses:` is valid YAML and must be seen.
d="$TMP/order"; mkdir -p "$d"
write_callee_with_secrets "$d"
write_caller "$d" '  release:
    secrets: inherit
    uses: ./.github/workflows/release.yml'
out="$(check "$d" 2>&1)" || fail "5: secrets: before uses: was not seen: $out"
pass "a secrets key written before the uses key is seen"

# 6. A prose mention of "secrets." in a comment is not a read. The guard is
#    anchored to the expression opener so testflight.yml's own comments about
#    secrets do not make a secret-free callee look like one that reads them.
d="$TMP/comment"; mkdir -p "$d"
cat > "$d/lint.yml" <<'YML'
name: Lint
# No secrets here: the environment's secrets. are resolved elsewhere.
on:
  workflow_call:
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - run: echo lint
YML
write_caller "$d" '  lint:
    uses: ./.github/workflows/lint.yml'
out="$(check "$d" 2>&1)" || fail "6: a comment mentioning secrets. was read as a secret reference: $out"
pass "a comment mentioning secrets is not a secret read"

# 7. A call to a workflow that does not exist fails closed. A typo in the
#    path would otherwise be a call the guard silently has no opinion on.
d="$TMP/missing"; mkdir -p "$d"
write_caller "$d" '  release:
    uses: ./.github/workflows/relaese.yml
    secrets: inherit'
if out="$(check "$d" 2>&1)"; then fail "7: a call to a missing workflow was accepted: $out"; fi
case "$out" in *"does not exist"*) ;; *) fail "7: the finding does not say the callee is missing: $out" ;; esac
pass "a call to a workflow that does not exist fails closed"

# 8. The real tree. This is the assertion that bites: ci.yml's testflight job
#    must keep passing secrets into testflight.yml.
out="$("$ROOT/Scripts/check-called-workflow-secrets.sh" 2>&1)" || fail "8: the real tree fails the guard: $out"
case "$out" in *"ok - "[1-9]*) ;; *) fail "8: the real tree was not actually measured (no call counted): $out" ;; esac
pass "the real .github/workflows passes, with at least one call measured"

# 9. Non-vacuity of 8: the real tree with the one load-bearing line removed
#    must FAIL. This is the tree the first on-merge release ran from.
d="$TMP/real-minus-inherit"; mkdir -p "$d"
cp "$ROOT"/.github/workflows/*.yml "$d/"
grep -q '^    secrets: inherit$' "$d/ci.yml" || fail "9: ci.yml no longer has the 'secrets: inherit' line this case removes; update the case"
sed -i '' '/^    secrets: inherit$/d' "$d/ci.yml"
if out="$(check "$d" 2>&1)"; then fail "9: the real tree minus 'secrets: inherit' was accepted -- the guard is vacuous: $out"; fi
case "$out" in *"job 'testflight'"*testflight.yml*) ;; *) fail "9: the finding does not name ci.yml's testflight job: $out" ;; esac
pass "the real tree minus its secrets: inherit line fails, naming the testflight job"

echo "All check-called-workflow-secrets tests passed."
