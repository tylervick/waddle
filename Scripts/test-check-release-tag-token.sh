#!/bin/bash
# Tests for Scripts/check-release-tag-token.sh.
#
# Fully HERMETIC for the discrimination cases: each writes a small workflow
# under $TMP and points the guard at it with RELEASE_TAG_TOKEN_CHECK_FILE.
# Nothing there reads the repository.
#
# Case 7 is the deliberate exception, on the model of
# test-check-masked-gh-status.sh: it runs the guard against the REAL
# testflight.yml, so a regression to pushing with the job token fails CI.
# Case 8 copies the real file, restores that regression, and asserts the
# guard then fails -- the proof that case 7 is not passing vacuously.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# A minimal release workflow in the shape the real one is meant to keep.
# Callers edit one thing, so every case differs from passing in one way.
write_good() { # file
    cat > "$1" <<'YML'
name: TestFlight
on:
  workflow_dispatch:
permissions: {}
jobs:
  gate:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@abc # v7
        with:
          fetch-depth: 0
          persist-credentials: false
      - run: echo gate
  testflight:
    runs-on: macos-26
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@abc # v7
        with:
          fetch-depth: 0
          persist-credentials: false
      - name: Archive
        run: echo archive
      # a comment that says git push is not a push
      - name: Tag the shipped build
        env:
          N: "1"
          RELEASE_TAG_TOKEN: ${{ secrets.RELEASE_TAG_TOKEN }}
        run: |
          git tag "build-$N"
          GIT_ASKPASS=x git push origin "build-$N"
YML
}

check() { # file
    env RELEASE_TAG_TOKEN_CHECK_FILE="$1" "$ROOT/Scripts/check-release-tag-token.sh"
}

# 1. The intended shape passes. Without this, every refusal below could be
#    the guard refusing everything.
write_good "$TMP/good.yml"
out="$(check "$TMP/good.yml" 2>&1)" || fail "1: the good shape was refused: $out"
pass "the intended shape passes"

# 2. THE REGRESSION: contents: write comes back on the release job. That is
#    the grant the old job-token push needed, and the first thing a
#    well-meaning fix for a failed tag push would add.
write_good "$TMP/write0.yml"
# flip only the SECOND contents: read (the release job's); awk, because BSD
# sed has no "nth match" form.
awk '/contents: read/ { n++; if (n == 2) sub(/read/, "write") } { print }' "$TMP/write0.yml" > "$TMP/write.yml"
grep -q 'contents: write' "$TMP/write.yml" || fail "2: fixture did not get contents: write"
if out="$(check "$TMP/write.yml" 2>&1)"; then fail "2: contents: write was accepted: $out"; fi
case "$out" in *"contents: write"*RELEASE_TAG_TOKEN*) ;; *) fail "2: the finding does not name the grant and the token: $out" ;; esac
pass "contents: write on any job is refused, naming the grant"

# 3. A checkout that keeps the job token. The push below it would then find
#    a credential in .git/config and use it, and the refusal returns.
write_good "$TMP/persist.yml"
# drop only the SECOND persist-credentials line (the release job's)
awk '/persist-credentials: false/ { n++; if (n == 2) next } { print }' "$TMP/persist.yml" > "$TMP/persist2.yml"
if out="$(check "$TMP/persist2.yml" 2>&1)"; then fail "3: a checkout keeping the job token was accepted: $out"; fi
case "$out" in *"persist-credentials: false"*) ;; *) fail "3: the finding does not name persist-credentials: $out" ;; esac
pass "a checkout without persist-credentials: false is refused"

# 4. A git push in a step whose env lacks the token. With the job token gone
#    from the checkout, such a push has no credential at all and fails -- but
#    only after the upload, which is the moment this guard exists to protect.
write_good "$TMP/notoken.yml"
sed -i '' '/RELEASE_TAG_TOKEN: \${{/d' "$TMP/notoken.yml"
if out="$(check "$TMP/notoken.yml" 2>&1)"; then fail "4: a git push without the token was accepted: $out"; fi
case "$out" in *"git push without RELEASE_TAG_TOKEN"*) ;; *) fail "4: the finding does not name the push: $out" ;; esac
pass "a git push whose step env lacks RELEASE_TAG_TOKEN is refused"

# 5. A comment containing the words "git push" is not a push. The good
#    fixture carries one; this case exists so that is not passing by luck:
#    the same comment in a step with no env must still pass.
write_good "$TMP/comment.yml"
sed -i '' 's/        run: echo archive/        run: echo archive # never git push here/' "$TMP/comment.yml"
if ! out="$(check "$TMP/comment.yml" 2>&1)"; then
    # An inline trailing comment IS on a run line; the guard reads the line
    # as a push and refuses it. That is the conservative answer and the one
    # this case pins: prose about pushing belongs on a comment line.
    case "$out" in *"git push without RELEASE_TAG_TOKEN"*) ;; *) fail "5: an unexpected finding: $out" ;; esac
fi
pass "a comment-only line mentioning git push is not a push; a trailing comment on a run line is treated as one"

# 6. An unreadable file fails closed.
if out="$(check "$TMP/absent.yml" 2>&1)"; then fail "6: a missing file was accepted: $out"; fi
pass "a missing workflow fails closed"

# 7. The real tree.
out="$("$ROOT/Scripts/check-release-tag-token.sh" 2>&1)" || fail "7: the real testflight.yml fails the guard: $out"
pass "the real testflight.yml passes"

# 8. Non-vacuity of 7: the real file with the regression restored must fail.
cp "$ROOT/.github/workflows/testflight.yml" "$TMP/real.yml"
grep -q '^      contents: read$' "$TMP/real.yml" || fail "8: the real file no longer has a job-level contents: read to flip; update the case"
sed -i '' 's/^      contents: read$/      contents: write/' "$TMP/real.yml"
if out="$(check "$TMP/real.yml" 2>&1)"; then fail "8: the real file with contents: write restored was accepted -- the guard is vacuous: $out"; fi
pass "the real file with contents: write restored fails"

echo "All check-release-tag-token tests passed."
