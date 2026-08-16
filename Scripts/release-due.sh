#!/bin/bash
# Answers the one question testflight.yml's nightly schedule asks before it
# spends a macOS runner: has main moved since the last build shipped?
#
# Prints `yes` or `no` on stdout and exits 0 for BOTH. A quiet day is a normal
# answer, not a failure. A non-zero exit for "nothing to ship" would paint
# every uneventful night red, and a red run nobody needs to act on is how the
# real ones stop being read.
#
# Exits non-zero only when the question cannot be answered at all: outside a
# git repository, against an unborn HEAD, or when build-* tags exist but none
# is reachable from HEAD.
#
# That last case is why this does not simply treat "no tag found" as a
# bootstrap. testflight.yml checks out with fetch-depth: 0 because a depth-1
# clone has neither the build-* tags nor the history behind them -- the trap
# already documented in that file for Scripts/whats-to-test.sh, which quietly
# takes its bootstrap fallback and ships the wrong notes. The equivalent
# silent fallback here would be worse: a `yes` every night forever, shipping a
# duplicate build each time while reporting success. So it fails closed.
#
# The measurement is `git describe`, which orders tags by ANCESTRY. Ranking
# them as text instead puts build-9 above build-10 and measures from the older
# tag -- see case 5 of Scripts/test-release-due.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Settle the repository question before interpreting any later failure as "no
# tag". Without this, `git describe` failing outside a repository is
# indistinguishable from it failing in a repository that has never shipped --
# and those two want opposite answers.
if ! git rev-parse --verify -q HEAD >/dev/null 2>&1; then
    echo "error: no HEAD commit to measure from -- not a git repository, or one with no commits yet" >&2
    exit 1
fi

# `--match 'build-*'`: those are the only tags a release pushes. v* tags mark
# marketing versions and move on a different cadence, so matching every tag
# would measure from whichever happened to be newest.
#
# A failure here means no matching tag is reachable. The repository question is
# already settled above, so the non-zero status IS the answer rather than an
# error, and the `if` is what keeps `set -e` from treating it as fatal.
if last_build="$(git describe --tags --match 'build-*' --abbrev=0 HEAD 2>/dev/null)"; then
    # `--count` rather than a pipe to `wc -l`: an empty rev-list prints
    # nothing, and `wc -l` would answer 0 for both "no commits since" and a
    # walk that failed outright. This form aborts under `set -e` instead.
    ahead="$(git rev-list --count "$last_build..HEAD")"
    if [ "$ahead" -gt 0 ]; then echo yes; else echo no; fi
    exit 0
fi

# No reachable build-* tag. Two very different situations arrive here and only
# one of them is safe to ship on, so the tag list is measured rather than
# assumed. Testing the status separately from the output is deliberate: a
# masked failure would read as an empty list, which is the permissive answer.
# See docs/learnings/masked-exit-status-fails-open.md.
if ! build_tags="$(git tag -l 'build-*')"; then
    echo "error: could not list tags to tell a bootstrap from a truncated history" >&2
    exit 1
fi

if [ -n "$build_tags" ]; then
    echo "error: build-* tags exist but none is reachable from HEAD; refusing to guess." >&2
    echo "error: a shallow clone looks exactly like this -- check out with fetch-depth: 0." >&2
    exit 1
fi

# Genuinely never shipped. The first scheduled run should not need a human.
echo yes
