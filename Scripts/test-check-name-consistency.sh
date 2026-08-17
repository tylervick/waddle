#!/bin/bash
# Tests for Scripts/check-name-consistency.sh.
#
# Fully HERMETIC: builds throwaway git repos in a temp dir and runs the guard
# there. Nothing here reads the real working tree, so the suite gives the same
# verdict before and after the rename it exists to enforce.
#
# GIT_CONFIG_GLOBAL/SYSTEM are cut off rather than patched per-command: this
# machine sets commit.gpgsign and tag.gpgSign through the 1Password agent, and
# an inherited signing config makes fixture commits hang or fail with errors
# that name neither signing nor config. See
# docs/learnings/git-fixtures-inherit-signing-config.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# A fixture repo whose only wordmark spellings sit in exempt paths.
make_fixture() { # dest
    mkdir -p "$1/Scripts" "$1/Design" "$1/App/Sources" \
             "$1/docs/superpowers/specs" "$1/docs/superpowers/plans" \
             "$1/docs/learnings"
    cp "$ROOT/Scripts/check-name-consistency.sh" "$1/Scripts/"
    printf 'Waddle is the name.\n'                  > "$1/README.md"
    printf 'wordmark studies: WADdle\n'             > "$1/Design/README.md"
    printf 'ran -scheme WADdle back then\n'         > "$1/docs/superpowers/specs/2026-01-01-old-design.md"
    printf 'and -only-testing:WADdleTests\n'        > "$1/docs/superpowers/plans/2026-01-01-old-plan.md"
    printf 'forbids the WADdle spelling\n'          > "$1/docs/learnings/the-name-is-waddle.md"
    printf '<string>WADdle App Store CI</string>\n' > "$1/App/ExportOptions-ci.plist"
    printf 'struct WaddleApp {}\n'                  > "$1/App/Sources/WaddleApp.swift"
    ( cd "$1" && git init -q . && git add -A && git commit -qm base )
}
check() { "$1/Scripts/check-name-consistency.sh"; }

# 1. Only exempt paths carry the spelling -> pass, silently.
make_fixture "$TMP/a"
check "$TMP/a" >"$TMP/out" 2>&1 || fail "refused a clean tree: $(cat "$TMP/out")"
[ ! -s "$TMP/out" ] || fail "should be silent on success, printed: $(cat "$TMP/out")"
pass "passes a clean tree silently"

# 2. A tracked source file carrying the spelling -> refuse, and name the file.
make_fixture "$TMP/b"
printf 'let name = "WADdle"\n' > "$TMP/b/App/Sources/Thing.swift"
( cd "$TMP/b" && git add -A && git commit -qm add )
if check "$TMP/b" >"$TMP/out" 2>&1; then fail "passed a tree spelling the name WADdle"; fi
grep -q "App/Sources/Thing.swift" "$TMP/out" || fail "error did not name the offending file"
pass "fails and names a tracked file carrying the wordmark spelling"

# 3. Design/ is exempt by rule -- the wordmark lives there.
make_fixture "$TMP/c"
printf 'WADdle WADdle WADdle\n' > "$TMP/c/Design/wordmark-notes.md"
( cd "$TMP/c" && git add -A && git commit -qm add )
check "$TMP/c" >"$TMP/out" 2>&1 || fail "refused Design/: $(cat "$TMP/out")"
pass "exempts Design/"

# 4. Dated records under docs/superpowers/ are exempt by rule.
make_fixture "$TMP/d"
printf 'xcodebuild -scheme WADdle\n' > "$TMP/d/docs/superpowers/specs/2026-02-02-another.md"
( cd "$TMP/d" && git add -A && git commit -qm add )
check "$TMP/d" >"$TMP/out" 2>&1 || fail "refused a dated spec: $(cat "$TMP/out")"
pass "exempts dated plans and specs"

# 5. Untracked files are not ours to spell.
make_fixture "$TMP/e"
printf 'WADdle\n' > "$TMP/e/App/Sources/Untracked.swift"
check "$TMP/e" >"$TMP/out" 2>&1 || fail "refused an untracked file: $(cat "$TMP/out")"
pass "ignores untracked files"

# 6. Every offender is reported in one run, not just the first.
make_fixture "$TMP/f"
printf 'WADdle\n' > "$TMP/f/App/Sources/One.swift"
printf 'WADdle\n' > "$TMP/f/App/Sources/Two.swift"
( cd "$TMP/f" && git add -A && git commit -qm add )
if check "$TMP/f" >"$TMP/out" 2>&1; then fail "passed a tree with two offenders"; fi
grep -q "App/Sources/One.swift" "$TMP/out" || fail "did not report the first offender"
grep -q "App/Sources/Two.swift" "$TMP/out" || fail "did not report the second offender"
pass "reports every offender in one run"

echo "all check-name-consistency tests passed"
