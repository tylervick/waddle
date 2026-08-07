#!/bin/bash
# Structural checks for the agent substrate's tracked files: CLAUDE.md and
# docs/learnings/.
#
# These two artifacts are conventions, and conventions decay silently. An
# unindexed learning is invisible to anyone who reads only the index; a
# CLAUDE.md that grows without bound stops being read at all. Each failure is
# quiet and each is cheap to catch mechanically, so it is caught mechanically.
#
# Reports EVERY problem in one run rather than stopping at the first, so a
# fix-up is one round trip.
#
# Deliberately offline: this script checks only what is in the diff under
# review and needs no network, no token, and no `gh`. It used to also verify
# the format of open `agent:eligible` GitHub issues, but that check depends on
# repo-wide mutable state -- once such issues exist, anyone can file an
# under-specified one through the public issue template and turn main plus
# every open PR red, with an error naming an issue the PR author has no
# permission to edit and no way to bypass. That check now lives in
# Scripts/check-issue-format.sh, wired into its own workflow
# (.github/workflows/issue-format.yml) triggered by issue events, so a
# malformed issue red-lights that issue, not unrelated pull requests.
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
        # -c counts matching *lines*, so two links to the same file on one
        # INDEX.md line would count as one entry and pass; -o plus a line
        # count counts each match, however many share a line.
        n="$(grep -oF "]($base)" "$INDEX" | wc -l | tr -d '[:space:]' || true)"
        if [ "$n" -ne 1 ]; then
            err "docs/learnings/$base has $n index entries in INDEX.md, expected exactly 1."
        fi
    done < <(find "$LEARNINGS" -maxdepth 1 -name '*.md' ! -name 'INDEX.md' | sort)

    while IFS= read -r target; do
        [ -f "$LEARNINGS/$target" ] \
            || err "INDEX.md points at missing file: $target"
    done < <(grep -oE '\]\([^)]+\.md\)' "$INDEX" | sed -E 's/^\]\(//; s/\)$//' | sort -u)
fi

exit "$status"
