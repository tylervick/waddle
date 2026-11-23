#!/bin/bash
# Verifies that every open `needs:owner` GitHub issue says what it needs: a
# non-empty `## Needs the owner` section.
#
# An issue filed by the owner or their agent is open to any agent unless it
# carries `needs:owner`, and that label is only useful if the issue names the
# step that needs the owner (a device, a
# decision, a credential, an approval) and what would unblock it. A blocked
# issue with no stated reason cannot be re-checked against the code, and that
# is how blocked reasons went stale unnoticed (three of ten, reviewed
# 2026-11-20). This is a floor: it proves the section exists, not that it is
# still true.
#
# Until 2026-11-20 this checked `## Definition of done`, `## Verification` and
# `## Provenance` on `agent:eligible` issues, for the unattended loop
# (docs/archive/unattended-loop/). Those sections are still the house format
# (.claude/skills/waddle-filing-an-issue), but nothing enforces them: with no
# opt-in label left, the only key would be "every open issue", and two open
# issues are machine-maintained and rightly have none (Renovate's dashboard and
# the TestFlight feedback digest). The retired labels `agent:eligible` and
# `agent:blocked` are ignored here, so an issue still carrying one passes.
#
# `needs:triage` (issues filed from outside, e.g. by the in-app bug form) is
# deliberately not checked: those are written by the public, owe no format,
# and must never turn this workflow red. They are not agent work until the
# owner removes the label, so a format rule for them would buy nothing.
#
# This check depends on repo-wide mutable state -- the set of currently open
# issues -- not on the contents of any one diff, so it runs in its own workflow
# (.github/workflows/issue-format.yml) on issue events plus a weekly backstop.
# Inside ci.yml, one malformed issue turned main and every open pull request
# red with an error the author could not fix.
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

# Every open needs:owner issue carries the required section.
#
# `gh` resolves the target repo from the current working directory, not from
# any argument -- the query below runs in a `cd "$ROOT"` subshell so it
# targets this repo even when the guard itself is invoked from elsewhere.
# `--limit 1000` overrides gh's default page size of 30.
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
    echo "skip - gh not installed; needs:owner issue format not checked"
elif ! gh auth status >/dev/null 2>&1; then
    echo "skip - gh not authenticated; needs:owner issue format not checked"
# Deliberately UNFILTERED, with needs:owner applied in the --jq selector
# below (#171). `--label` resolves through GitHub's search index, which can
# omit an issue whose label is genuinely attached -- measured on this
# repository 2026-08-18, where a label query returned 8 issues against the
# label edge's 9, missing #79 since at least 2026-08-16. An issue it drops is
# never format-checked, and this check goes green having verified fewer issues
# than exist. See docs/learnings/label-filtered-issue-queries-omit-issues.md.
elif ! issues="$(cd "$ROOT" && gh issue list \
        --state open --limit 1000 --json number,body,labels \
        --jq '.[] | select(any(.labels[]; .name == "needs:owner"))
                  | "\(.number)\t\(.body // "" | @base64)"')"; then
    err "gh issue list failed -- could not verify needs:owner issue format (bad token scope, network error, rate limit, or wrong repo)."
else
    while IFS=$'\t' read -r n body_b64; do
        [ -z "$n" ] && continue
        body="$(printf '%s' "$body_b64" | base64 --decode)"
        for heading in 'Needs the owner'; do
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
                err "issue #$n is needs:owner but has no content under '## $heading' -- name the step that needs the owner and what would unblock it."
            fi
        done
    done <<< "$issues"
fi

exit "$status"
