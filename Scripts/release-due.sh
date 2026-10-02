#!/bin/bash
# Answers the one question testflight.yml's gate asks before it spends a macOS
# runner on a merge to main: has anything that goes into the binary changed
# since the last build shipped?
#
# Prints `yes` or `no` on stdout and exits 0 for BOTH. A merge that ships
# nothing is a normal answer, not a failure. A non-zero exit for "nothing to
# ship" would paint every docs merge red, and a red run nobody needs to act on
# is how the real ones stop being read.
#
# "Goes into the binary" is defined by exclusion, in NON_BINARY_PATHS below: a
# path not listed there is assumed to reach a tester, so a new top-level
# directory ships until someone says otherwise. The other default -- an
# allowlist of build inputs -- would quietly stop shipping the day a source
# directory was added or renamed, and nothing would be red.
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

# What does NOT reach a tester. Each entry is a git pathspec exclusion, applied
# on top of `.` in the diff below. Deliberately short and deliberately
# conservative: Scripts/ as a whole stays IN, because archive.sh, build-engine.sh,
# vendor-woof.sh and patches/ decide what the binary is, and only the suites
# and the CI guards are named out. mise.toml stays in for the same reason (it
# pins xcodegen and the toolchain). Design/ is out because its rendered output
# is committed under App/, which is what ships.
#
# Note the ORDER of consequences when this list is wrong. An entry too broad
# means a code change ships one merge late (the next binary-touching merge
# carries it, since the range is measured from the tag, not from the previous
# merge). An entry too narrow means a build nobody needed. Both are cheap;
# neither is silent, because Scripts/test-release-due.sh pins the shape.
NON_BINARY_PATHS=(
    ':(exclude)docs/'
    ':(exclude)Design/'
    ':(exclude)App/Tests/'
    ':(exclude)App/UITests/'
    ':(exclude)Scripts/test-*.sh'
    ':(exclude)Scripts/check-*.sh'
    ':(exclude)Scripts/fixtures/'
    ':(exclude).github/'
    ':(exclude)*.md'
    ':(exclude)COPYING'
    ':(exclude)renovate.json'
    ':(exclude)orca.yaml'
)

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
    if [ "$ahead" -eq 0 ]; then echo no; exit 0; fi

    # main moved. Did any of it reach the binary? `git diff --name-only`
    # with pathspec exclusions lists what changed OUTSIDE the non-binary
    # paths; an empty list means every change since the tag was docs, tests,
    # workflow or tooling, and a tester holding this build could not tell it
    # from the last one. Captured as an assignment rather than piped to
    # `wc -l`, for the same reason as `--count` above: a failed diff must
    # abort under `set -e` rather than read as "nothing changed".
    changed="$(git diff --name-only "$last_build" HEAD -- . "${NON_BINARY_PATHS[@]}")"
    if [ -n "$changed" ]; then echo yes; else echo no; fi
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

# Genuinely never shipped. The first release should not need a human.
echo yes
