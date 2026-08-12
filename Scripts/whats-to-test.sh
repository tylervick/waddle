#!/bin/bash
# Assembles TestFlight "What to Test" notes and (in Task 3) attaches them to a
# build in App Store Connect.
#
# Usage:
#   Scripts/whats-to-test.sh --print            assemble and print, no network
#
# The notes are an optional hand-written preamble followed by a changelog
# computed from git. The changelog is DERIVED, not stored, and that is the
# point: a tracked notes file goes stale silently -- it is not empty, so an
# empty-check passes, and the build ships the previous release's text. A
# computed changelog cannot be stale. See
# docs/superpowers/specs/2026-08-11-whats-to-test-design.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PREAMBLE_FILE="docs/app-store/whats-to-test.md"

# The most recent build-* tag by version order, not by tag date: build numbers
# skip when a validate-only run consumes a run number, so lexical or
# chronological ordering would both pick the wrong anchor.
prev_tag() { git tag --list 'build-*' --sort=-v:refname 2>/dev/null | head -1; }

# One bullet per change. For a GitHub merge commit the useful title is the
# FIRST LINE OF THE BODY -- git's own subject is "Merge pull request #N from
# owner/branch", which tells a tester nothing. Direct commits use their
# subject. Both shapes occur in this repo.
changelog() { # range (may be empty, meaning "recent history")
    range="$1"
    while IFS= read -r sha; do
        [ -n "$sha" ] || continue
        subj="$(git log -1 --format=%s "$sha")"
        case "$subj" in
            "Merge pull request #"*)
                num="$(printf '%s' "$subj" | sed -n 's/^Merge pull request #\([0-9][0-9]*\).*/\1/p')"
                title="$(git log -1 --format=%b "$sha" | sed -n '1p')"
                [ -n "$title" ] || title="$subj"
                printf -- '- %s (#%s)\n' "$title" "$num"
                ;;
            *) printf -- '- %s\n' "$subj" ;;
        esac
    done < <(git log --first-parent --format=%H $range)
}

MODE="${1:---print}"
[ "$MODE" = "--print" ] || { echo "usage: $0 --print" >&2; exit 2; }

PREAMBLE=""
if [ -f "$PREAMBLE_FILE" ]; then
    PREAMBLE="$(sed -e 's/[[:space:]]*$//' "$PREAMBLE_FILE" | sed -e '/./,$!d')"
fi

TAG="$(prev_tag)"
NOTE=""
if [ -n "$TAG" ]; then
    HEADING="Changes since build ${TAG#build-}:"
    BODY="$(changelog "$TAG..HEAD")"
else
    # Bootstrap: no release has ever been tagged. Failing here would block a
    # release for a condition that is true exactly once, so fall back -- but
    # disclose it, because the range is a guess rather than a fact.
    HEADING="Recent changes (no previous build tag; showing the last 20 commits):"
    BODY="$(changelog "--max-count=20")"
    NOTE="disclosed-fallback"
fi

if [ -z "$PREAMBLE" ] && [ -z "$BODY" ]; then
    echo "error: no changes since ${TAG:-the start of history} and $PREAMBLE_FILE is empty." >&2
    echo "       Nothing to tell a tester. Write a preamble or ship a build with changes in it." >&2
    exit 1
fi

if [ -n "$PREAMBLE" ]; then
    printf '%s\n' "$PREAMBLE"
    [ -n "$BODY" ] && printf '\n'
fi
if [ -n "$BODY" ]; then
    printf '%s\n' "$HEADING"
    printf '%s\n' "$BODY"
fi
