#!/bin/bash
# Verifies that every open `agent:eligible` GitHub issue carries the three
# required sections: `## Definition of done`, `## Verification`, and
# `## Provenance`.
#
# This check depends on repo-wide mutable state -- the set of currently open
# `agent:eligible` issues -- not on the contents of any one diff. It used to
# live inside Scripts/check-substrate.sh, run on every PR and every push to
# main; that meant anyone could file an under-specified agent:eligible issue
# through the public issue template and turn main plus every open PR red,
# with an error naming an issue the PR author has no permission to edit and
# no way to bypass. It now runs standalone, in its own workflow
# (.github/workflows/issue-format.yml) triggered by issue events plus a
# weekly backstop, so a malformed issue red-lights that issue, not unrelated
# pull requests.
#
# Needs network and an authenticated `gh`. It skips cleanly when either is
# absent -- CI without a token must not fail here. But once `gh` is installed
# and authenticated, a failure of the query itself (expired/under-scoped
# token, network error, rate limit, or a cwd outside the repo) is NOT a skip
# -- it fails closed, same discipline Scripts/check-engine-fresh.sh documents
# in its own header.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

status=0
err() { echo "error: $*" >&2; status=1; }

# Every open agent:eligible issue carries the three required sections.
#
# `gh` resolves the target repo from the current working directory, not from
# any argument -- the query below runs in a `cd "$ROOT"` subshell so it
# targets this repo even when the guard itself is invoked from elsewhere.
# `--limit 1000` overrides gh's default page size of 30, which this plan's
# own issue count is on track to exceed.
#
# Numbers and bodies come back from a single list call, not one `gh issue
# view` per issue -- that used to cost one API request per open issue, and
# fed a bare `body="$(...)"` assignment that, under `set -e`, aborted the
# whole script on a transient failure with no `error:` line at all. Bodies
# are multi-line, so each one is base64-encoded and paired with its issue
# number on one tab-delimited line -- that survives an ordinary `while read`
# loop without losing the newlines the awk section-extraction below depends
# on.
if ! command -v gh >/dev/null 2>&1; then
    echo "skip - gh not installed; agent:eligible issue format not checked"
elif ! gh auth status >/dev/null 2>&1; then
    echo "skip - gh not authenticated; agent:eligible issue format not checked"
# Deliberately UNFILTERED, with agent:eligible applied in the --jq selector
# below (#171). `--label` resolves through GitHub's search index, which can
# omit an issue whose label is genuinely attached -- measured on this
# repository 2026-08-18, where the label query returned 8 agent:blocked issues
# against the label edge's 9, missing #79 since at least 2026-08-16. An issue
# it drops is never format-checked, and this check goes green having verified
# fewer issues than exist. Its `skip - ` guard only catches checking ZERO, not
# checking SOME, so that omission is invisible.
elif ! issues="$(cd "$ROOT" && gh issue list \
        --state open --limit 1000 --json number,body,labels \
        --jq '.[] | select(any(.labels[]; .name == "agent:eligible"))
                  | "\(.number)\t\(.body // "" | @base64)"')"; then
    err "gh issue list failed -- could not verify agent:eligible issue format (bad token scope, network error, rate limit, or wrong repo)."
else
    while IFS=$'\t' read -r n body_b64; do
        [ -z "$n" ] && continue
        body="$(printf '%s' "$body_b64" | base64 --decode)"
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
    done <<< "$issues"
fi

exit "$status"
