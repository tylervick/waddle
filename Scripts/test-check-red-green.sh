#!/bin/bash
# Tests for Scripts/check-red-green.sh.
#
# Fully HERMETIC: every case builds a throwaway git repository in $TMP and
# runs the guard inside it. Nothing here reads or writes the real checkout.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# The fixture repos must not inherit the developer's git config -- signing in
# particular, since commit.gpgsign here routes through the 1Password agent and
# would make this hermetic test depend on the agent being unlocked. See
# docs/learnings/git-fixtures-inherit-signing-config.md.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

# Builds a git repo with a base commit, then applies $2 as a shell script that
# edits the tree, and commits that as HEAD. Prints the repo path.
make_repo() { # name, mutate-script
    d="$TMP/$1"; mkdir -p "$d"; cd "$d"
    git init -q .; git config user.email t@e.st; git config user.name T
    mkdir -p App/Sources App/Tests Scripts
    echo 'let x = 1' > App/Sources/Thing.swift
    echo 'nothing' > README.md
    # The guard under test must be committed as of base, not copied in after
    # head: copied in later it would sit untracked and trip the guard's own
    # dirty-tree refusal, and copied in as part of head it would show up as a
    # shell-domain source change in every fixture's diff.
    cp "$ROOT/Scripts/check-red-green.sh" Scripts/check-red-green.sh
    chmod +x Scripts/check-red-green.sh
    git add -A; git commit -qm base
    git branch -f base-ref
    eval "$2"
    git add -A; git commit -qm head
    cd - >/dev/null
    echo "$d"
}

verdict() { (cd "$1" && ./Scripts/check-red-green.sh base-ref); }

# 1. No source file changed at all -> n/a.
r="$(make_repo na 'echo more >> README.md')"
[ "$(verdict "$r")" = "n/a" ] || fail "docs-only change should be n/a, got: $(verdict "$r")"
pass "a change touching no source file is n/a"

# 2. Source changed, no test touched -> no-test.
r="$(make_repo notest 'echo "let y = 2" >> App/Sources/Thing.swift')"
[ "$(verdict "$r")" = "no-test" ] || fail "source-only change should be no-test, got: $(verdict "$r")"
pass "source changed with no test touched is no-test"

# 3. A test-only change is n/a, not no-test -- there is no source to revert.
r="$(make_repo testonly 'echo "// t" > App/Tests/ThingTests.swift')"
[ "$(verdict "$r")" = "n/a" ] || fail "test-only change should be n/a, got: $(verdict "$r")"
pass "a test-only change is n/a, not no-test"

# 4. Scripts/loop-prompt.md is not source in either domain.
r="$(make_repo promptmd 'echo hi > Scripts/loop-prompt.md')"
[ "$(verdict "$r")" = "n/a" ] || fail "loop-prompt.md should be n/a, got: $(verdict "$r")"
pass "a non-.sh file under Scripts/ is not source in either domain"

# 5. A dirty working tree is refused outright, not silently worked around.
r="$(make_repo dirty 'echo "let y = 2" >> App/Sources/Thing.swift')"
echo scratch > "$r/App/Sources/Dirty.swift"
if (cd "$r" && ./Scripts/check-red-green.sh base-ref >"$TMP/d.out" 2>&1); then
    fail "ran against a dirty working tree instead of refusing"
fi
grep -q "working tree" "$TMP/d.out" || fail "refusal did not say why; got: $(cat "$TMP/d.out")"
pass "refuses to run against a dirty working tree"

echo "All check-red-green tests passed."
