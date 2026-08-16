#!/bin/bash
# Tests for Scripts/release-due.sh.
#
# Fully HERMETIC: every case builds a throwaway git repository in $TMP, copies
# the script under test into it, and runs it there. Nothing here reads the real
# checkout's history, and nothing reaches App Store Connect or GitHub.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# The fixture repos must not inherit the developer's git config. Two settings
# in particular break this suite for one developer and not another:
# commit.gpgsign routes through the 1Password agent, and tag.gpgSign makes the
# plain `git tag build-1` below fail with `fatal: no tag message?` -- an error
# naming neither signing nor config. See
# docs/learnings/git-fixtures-inherit-signing-config.md.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

# Cases 10 and 11 assert on what the script does with NO repository. git
# searches upward for one, so without a ceiling those cases would silently
# measure whatever repository happens to contain $TMPDIR -- passing here and
# meaning nothing.
export GIT_CEILING_DIRECTORIES="$TMP"

# Builds a repo containing the script under test at the path it expects, and
# leaves the shell inside it. The script resolves its own ROOT from $0 and
# cd's there, exactly as every other guard in Scripts/ does, so copying it in
# is what makes the fixture -- not the real checkout -- the repo it measures.
make_repo() { # name
    d="$TMP/$1"; mkdir -p "$d/Scripts"; cd "$d"
    git init -q .
    cp "$ROOT/Scripts/release-due.sh" Scripts/release-due.sh
    chmod +x Scripts/release-due.sh
    git add -A; git commit -qm base
}

# A commit with no tag, so the fixtures can express "main moved".
commit() { # message
    echo "$1" >> log.txt; git add -A; git commit -qm "$1"
}

# Runs the script under test in the current fixture and prints its verdict.
# The status is captured rather than allowed to abort under `set -e`, because
# several cases below assert on a NON-zero status; `run` is only ever called
# from an `if` or with its status immediately tested.
run() {
    RUN_OUT=""; RUN_STATUS=0
    RUN_OUT="$(./Scripts/release-due.sh 2>"$TMP/stderr")" || RUN_STATUS=$?
    RUN_ERR="$(cat "$TMP/stderr")"
}

# 1. The once-ever bootstrap. A repo that has never shipped has no build-*
#    tag to measure from, and the honest answer is "ship" -- not "error",
#    which would make the very first scheduled run need a human.
make_repo bootstrap
run
[ "$RUN_STATUS" -eq 0 ] || fail "1: bootstrap exited $RUN_STATUS: $RUN_ERR"
[ "$RUN_OUT" = "yes" ] || fail "1: bootstrap said '$RUN_OUT', want yes"
pass "no build-* tag anywhere is a bootstrap yes"

# 2. The quiet night this whole script exists for. A tag on HEAD means the
#    last release already carries every commit, and a build made now would be
#    byte-identical to the last one with an empty changelog behind it.
make_repo quiet
git tag build-201
run
[ "$RUN_STATUS" -eq 0 ] || fail "2: quiet night exited $RUN_STATUS: $RUN_ERR"
[ "$RUN_OUT" = "no" ] || fail "2: quiet night said '$RUN_OUT', want no"
pass "tag on HEAD is no"

# 3. One merge since the last release is enough to ship.
make_repo one-commit
git tag build-201
commit "a fix"
run
[ "$RUN_STATUS" -eq 0 ] || fail "3: exited $RUN_STATUS: $RUN_ERR"
[ "$RUN_OUT" = "yes" ] || fail "3: said '$RUN_OUT', want yes"
pass "one commit since the tag is yes"

# 4. The ordinary active day: several merges since the last release.
make_repo many-commits
git tag build-201
commit one; commit two; commit three
run
[ "$RUN_STATUS" -eq 0 ] || fail "4: exited $RUN_STATUS: $RUN_ERR"
[ "$RUN_OUT" = "yes" ] || fail "4: said '$RUN_OUT', want yes"
pass "several commits since the tag is yes"

# 5. The lexical-sort trap, and the reason this uses `git describe` rather
#    than `git tag -l | sort | tail -1`. Sorted as text, build-9 comes after
#    build-10, so a naive implementation would measure from the OLDER tag,
#    find commits behind it, and ship a duplicate build every single night
#    once the build number crossed into two digits. Ordered by ancestry,
#    build-10 is the nearest tag and the answer is no.
make_repo lexical-trap
git tag build-9
commit "after nine"
git tag build-10
run
[ "$RUN_STATUS" -eq 0 ] || fail "5: exited $RUN_STATUS: $RUN_ERR"
[ "$RUN_OUT" = "no" ] || fail "5: said '$RUN_OUT', want no -- build-9 sorts after build-10 as text"
pass "picks the nearest tag by ancestry, not the lexically largest"

# 6. The same shape as 5, but with real work after the newest tag.
make_repo lexical-trap-moved
git tag build-9
commit "after nine"
git tag build-10
commit "after ten"
run
[ "$RUN_STATUS" -eq 0 ] || fail "6: exited $RUN_STATUS: $RUN_ERR"
[ "$RUN_OUT" = "yes" ] || fail "6: said '$RUN_OUT', want yes"
pass "commits after the newest of several tags is yes"

# 7. Only build-* tags count. A repo tagged v1.0 but never shipped is still a
#    bootstrap: matching every tag would measure from v1.0 and report `no` on
#    a repo that has never uploaded anything at all.
make_repo other-tags-only
git tag v1.0
run
[ "$RUN_STATUS" -eq 0 ] || fail "7: exited $RUN_STATUS: $RUN_ERR"
[ "$RUN_OUT" = "yes" ] || fail "7: said '$RUN_OUT', want yes"
pass "a non-build-* tag does not count as a shipped build"

# 8. And a non-build-* tag laid down after the last release does not mask the
#    commits behind it.
make_repo other-tags-newer
git tag build-201
commit "a fix"
git tag v1.1
run
[ "$RUN_STATUS" -eq 0 ] || fail "8: exited $RUN_STATUS: $RUN_ERR"
[ "$RUN_OUT" = "yes" ] || fail "8: said '$RUN_OUT', want yes"
pass "a newer non-build-* tag does not hide commits since the last build"

# 9. The shallow-clone fail-open, and the case that costs the most if it is
#    wrong. testflight.yml checks out with fetch-depth: 0 precisely because a
#    depth-1 clone has neither the build-* tags nor the history behind them --
#    a trap this repo already documents for Scripts/whats-to-test.sh. If that
#    setting is ever dropped, the tags are present but unreachable from HEAD,
#    and treating that as a bootstrap would ship a build EVERY night forever
#    while reporting success. It must fail closed instead.
make_repo unreachable-tag
git tag build-201
git checkout -q --orphan detached
git rm -r -q -f .
mkdir -p Scripts
cp "$ROOT/Scripts/release-due.sh" Scripts/release-due.sh
chmod +x Scripts/release-due.sh
git add -A; git commit -qm orphan
run
[ "$RUN_STATUS" -ne 0 ] || fail "9: unreachable tag exited 0 saying '$RUN_OUT'; want a non-zero fail-closed"
case "$RUN_ERR" in *error:*) ;; *) fail "9: stderr lacks an error: line: $RUN_ERR" ;; esac
pass "build-* tags that exist but are unreachable fail closed"

# 10. Not a git repository at all. Distinguished from case 1 on purpose: both
#     are "no tag found", but only one of them is a repo whose history was
#     genuinely measured. Answering `yes` here would be a guess.
mkdir -p "$TMP/norepo/Scripts"; cd "$TMP/norepo"
cp "$ROOT/Scripts/release-due.sh" Scripts/release-due.sh
chmod +x Scripts/release-due.sh
run
[ "$RUN_STATUS" -ne 0 ] || fail "10: non-repo exited 0 saying '$RUN_OUT'; want a non-zero fail-closed"
case "$RUN_ERR" in *error:*) ;; *) fail "10: stderr lacks an error: line: $RUN_ERR" ;; esac
pass "outside a git repository fails closed"

# 11. A repo with no commits yet. `git describe` and `git rev-list` both fail
#     against an unborn HEAD, and the failure must read as unanswerable rather
#     than as a bootstrap.
mkdir -p "$TMP/empty/Scripts"; cd "$TMP/empty"; git init -q .
cp "$ROOT/Scripts/release-due.sh" Scripts/release-due.sh
chmod +x Scripts/release-due.sh
run
[ "$RUN_STATUS" -ne 0 ] || fail "11: empty repo exited 0 saying '$RUN_OUT'; want a non-zero fail-closed"
case "$RUN_ERR" in *error:*) ;; *) fail "11: stderr lacks an error: line: $RUN_ERR" ;; esac
pass "a repo with no commits fails closed"

# 12. The verdict is the whole of stdout, with no decoration. testflight.yml
#     compares it with `=`, so a stray banner or a trailing period would make
#     the gate read every night as `no` and silently stop releasing -- a
#     failure that looks exactly like a quiet week.
make_repo stdout-shape
git tag build-201
commit "a fix"
run
[ "$RUN_OUT" = "yes" ] || fail "12: stdout was '$RUN_OUT', want exactly yes"
pass "stdout is the bare verdict and nothing else"

echo "All release-due tests passed."
