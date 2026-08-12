#!/bin/bash
# Tests for Scripts/whats-to-test.sh.
#
# HERMETIC: every case builds a throwaway git repository under $TMP and runs
# the script inside it. Nothing here reads the real checkout or the network.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# Builds a repo with a build-206 tag, then applies $2 to add history on top.
# Signing and the user's global config are isolated -- see
# docs/learnings/git-fixtures-inherit-signing-config.md.
make_repo() { # name, mutate-script
    d="$TMP/$1"; mkdir -p "$d/docs/app-store" "$d/Scripts"; cd "$d"
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    git init -q .; git config user.email t@e.st; git config user.name T
    git config commit.gpgsign false; git config tag.gpgSign false
    cp "$ROOT/Scripts/whats-to-test.sh" Scripts/whats-to-test.sh
    chmod +x Scripts/whats-to-test.sh
    : > docs/app-store/whats-to-test.md
    git add -A; git commit -qm base
    git tag build-206
    eval "$2"
    cd - >/dev/null
    echo "$d"
}

# A merge commit shaped exactly as GitHub writes them: the subject names the
# PR, the body's first line is the PR title.
merge_pr() { # number, title
    git checkout -q -b "pr-$1"
    git commit -q --allow-empty -m "wip"
    git checkout -q -
    git merge -q --no-ff "pr-$1" -m "Merge pull request #$1 from tylervick/pr-$1

$2"
}

notes() { (cd "$1" && ./Scripts/whats-to-test.sh --print 2>&1); }

# 1. Merged PRs since the tag become one bullet each, titled by the PR title
#    rather than git's "Merge pull request" subject.
r="$(make_repo derived 'merge_pr 78 "fix(ui): plural alert copy"; merge_pr 79 "chore: tidy"')"
out="$(notes "$r")" || fail "exited non-zero: $out"
echo "$out" | grep -q -- "- fix(ui): plural alert copy (#78)" || fail "missing PR 78 bullet; got: $out"
echo "$out" | grep -q -- "- chore: tidy (#79)" || fail "missing PR 79 bullet; got: $out"
echo "$out" | grep -qi "since build 206" || fail "does not name the previous build; got: $out"
pass "derives one bullet per merged PR since the last build tag"

# 2. A preamble is included verbatim, above the changelog.
r="$(make_repo preamble 'printf "Focus on the Library screen.\n" > docs/app-store/whats-to-test.md; git add -A; git commit -qm p; merge_pr 80 "fix: thing"')"
out="$(notes "$r")"
echo "$out" | grep -q "Focus on the Library screen." || fail "preamble missing; got: $out"
[ "$(echo "$out" | grep -n "Focus on the Library" | cut -d: -f1)" -lt \
  "$(echo "$out" | grep -n "since build 206" | cut -d: -f1)" ] \
  || fail "preamble is not above the changelog"
pass "includes a preamble verbatim, above the changelog"

# 3. An empty preamble is normal, not an error -- the derived half carries it.
r="$(make_repo emptypre 'merge_pr 81 "fix: thing"')"
notes "$r" >/dev/null || fail "an empty preamble should not fail the run"
pass "an empty preamble is not an error"

# 4. No commits since the tag AND no preamble -> fails. Nothing to say.
r="$(make_repo nothing '')"
if notes "$r" >"$TMP/o4" 2>&1; then fail "should have failed with nothing to report"; fi
grep -qi "no changes" "$TMP/o4" || fail "error did not explain; got: $(cat "$TMP/o4")"
pass "fails when there are no changes and no preamble"

# 5. No commits since the tag but a preamble exists -> succeeds on the
#    preamble alone. A re-release with hand-written framing is legitimate.
r="$(make_repo onlypre 'printf "Re-testing build 206 signing.\n" > docs/app-store/whats-to-test.md; git add -A; git commit -qm p')"
out="$(notes "$r")" || fail "should succeed on a preamble alone"
echo "$out" | grep -q "Re-testing build 206 signing." || fail "preamble missing; got: $out"
pass "succeeds on a preamble alone when nothing merged"

# 6. No build-* tag at all (the bootstrap case, true exactly once) -> falls
#    back to recent history and SAYS SO, rather than failing a release.
r="$(make_repo notag 'git tag -d build-206 >/dev/null; merge_pr 82 "fix: thing"')"
out="$(notes "$r")" || fail "bootstrap case should not fail; got: $out"
echo "$out" | grep -qi "no previous build tag" || fail "did not disclose the fallback; got: $out"
pass "falls back to recent history when no build tag exists, and says so"

# 7. Direct commits to the branch (no merge commit) still appear.
r="$(make_repo direct 'git commit -q --allow-empty -m "fix(engine): direct commit"')"
out="$(notes "$r")"
echo "$out" | grep -q -- "- fix(engine): direct commit" || fail "direct commit missing; got: $out"
pass "includes direct commits, not only merges"

echo "All whats-to-test tests passed."
