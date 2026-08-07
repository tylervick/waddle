#!/bin/bash
# Structural checks for the agent substrate: CLAUDE.md, docs/learnings/, and
# the format of agent-eligible GitHub issues.
#
# These three artifacts are conventions, and conventions decay silently. An
# unindexed learning is invisible to anyone who reads only the index; a
# CLAUDE.md that grows without bound stops being read at all; an issue with no
# stated definition of done invites an agent to declare victory early. Each
# failure is quiet and each is cheap to catch mechanically, so it is caught
# mechanically.
#
# Reports EVERY problem in one run rather than stopping at the first, so a
# fix-up is one round trip.
#
# The issue-format check needs network and an authenticated `gh`. It skips
# cleanly when either is absent -- CI without a token must not fail here. But
# once `gh` is installed and authenticated, a failure of the query itself
# (expired/under-scoped token, network error, rate limit, or a cwd outside
# the repo) is NOT a skip -- it fails closed like the checks above it, same
# discipline Scripts/check-engine-fresh.sh documents in its own header.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE_MD="$ROOT/CLAUDE.md"
LEARNINGS="$ROOT/docs/learnings"
INDEX="$LEARNINGS/INDEX.md"
CAP=50

status=0
err() { echo "error: $*" >&2; status=1; }

# 1. CLAUDE.md exists and stays within the cap.
if [ ! -f "$CLAUDE_MD" ]; then
    err "CLAUDE.md is missing — the always-on rules file is required substrate."
else
    lines="$(wc -l < "$CLAUDE_MD" | tr -d '[:space:]')"
    if [ "$lines" -gt "$CAP" ]; then
        err "CLAUDE.md is $lines lines, over the ${CAP}-line cap — move detail into docs/learnings/."
    fi
fi

# 2. INDEX.md and the learning files are in exact bijection.
if [ ! -f "$INDEX" ]; then
    err "$INDEX is missing."
else
    while IFS= read -r f; do
        base="$(basename "$f")"
        n="$(grep -cF "]($base)" "$INDEX" || true)"
        if [ "$n" -ne 1 ]; then
            err "docs/learnings/$base has $n index entries in INDEX.md, expected exactly 1."
        fi
    done < <(find "$LEARNINGS" -maxdepth 1 -name '*.md' ! -name 'INDEX.md' | sort)

    while IFS= read -r target; do
        [ -f "$LEARNINGS/$target" ] \
            || err "INDEX.md points at missing file: $target"
    done < <(grep -oE '\]\([^)]+\.md\)' "$INDEX" | sed -E 's/^\]\(//; s/\)$//' | sort -u)
fi

# 3. Every open agent:eligible issue carries the three required sections.
#
# `gh` resolves the target repo from the current working directory, not from
# any argument -- every call below runs in a `cd "$ROOT"` subshell so the
# query targets this repo even when the guard itself is invoked from
# elsewhere. `--limit 1000` overrides gh's default page size of 30, which
# this plan's own issue count is on track to exceed.
if ! command -v gh >/dev/null 2>&1; then
    echo "skip - gh not installed; agent:eligible issue format not checked"
elif ! gh auth status >/dev/null 2>&1; then
    echo "skip - gh not authenticated; agent:eligible issue format not checked"
elif ! issue_numbers="$(cd "$ROOT" && gh issue list --label agent:eligible \
        --state open --limit 1000 --json number --jq '.[].number')"; then
    err "gh issue list failed -- could not verify agent:eligible issue format (bad token scope, network error, rate limit, or wrong repo)."
else
    for n in $issue_numbers; do
        body="$(cd "$ROOT" && gh issue view "$n" --json body --jq .body)"
        for heading in 'Definition of done' 'Verification' 'Provenance'; do
            # The first rule strips a trailing \r so issues filed through the
            # GitHub web form (CRLF bodies) match the same as API-created
            # ones (LF only) -- otherwise every heading here silently
            # mismatches and every section reads as empty.
            section="$(printf '%s\n' "$body" | awk -v h="## $heading" '
                { sub(/\r$/, "") }
                $0 == h { inside = 1; next }
                inside && /^## / { exit }
                inside { print }
            ')"
            if [ -z "$(printf '%s' "$section" | tr -d '[:space:]')" ]; then
                err "issue #$n is agent:eligible but has no content under '## $heading'."
            fi
        done
    done
fi

exit "$status"
