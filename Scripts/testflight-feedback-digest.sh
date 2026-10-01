#!/bin/bash
# Posts NEW TestFlight feedback to a digest issue, once per submission, from a
# runner that keeps no state between runs (issue #192).
#
# Scripts/fetch-testflight-feedback.sh already prints what has not been seen
# before, tracking seen ids in a local state file. That file is correct for a
# human at a checkout and meaningless in a fresh CI container, where every
# scheduled run would re-report everything from the beginning of time. So
# here the DIGEST ISSUE IS THE STATE: every posted comment carries one hidden
# `<!-- tf-feedback-id: <id> -->` marker per submission it reports, and each
# run rebuilds the fetcher's state file from the markers already in the
# issue before fetching. Posting the comment is the output AND the write of
# the seen-state, in one step, so a run that fails anywhere before the post
# leaves the issue untouched and the next run re-surfaces the same
# submissions -- the fetcher's own append-after-output discipline, kept.
#
# Bounded: at most DIGEST_LIMIT submissions per comment; the rest wait for
# the next run (and the comment says how many). A backlog or a broken run
# cannot flood the issue.
#
# Usage: Scripts/testflight-feedback-digest.sh
# Env:
#   DIGEST_ISSUE   the digest issue's number (required)
#   DIGEST_REPO    owner/repo of that issue (default: tylervick/waddle)
#   DIGEST_LIMIT   max submissions per comment (default: 20)
#   GH_TOKEN       for `gh api` (issues: write)
#   FETCH_SCRIPT   override the fetcher (tests use this)
#   plus whatever the fetcher needs: ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH,
#   or ASC_JWT to override the token minter.
#
# Exit 0 with "No new feedback." when there is nothing to post. Non-zero,
# with an `error:` line, when the issue cannot be read (a failed listing must
# NOT read as "no comments yet" -- that would replay the whole backlog), when
# the fetcher fails, or when the post fails.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

REPO="${DIGEST_REPO:-tylervick/waddle}"
LIMIT="${DIGEST_LIMIT:-20}"
FETCH="${FETCH_SCRIPT:-$ROOT/Scripts/fetch-testflight-feedback.sh}"
ISSUE="${DIGEST_ISSUE:-}"
[ -n "$ISSUE" ] || { echo "error: DIGEST_ISSUE is not set (the digest issue's number)" >&2; exit 2; }
case "$ISSUE" in ''|*[!0-9]*) echo "error: DIGEST_ISSUE must be a number, got '$ISSUE'" >&2; exit 2 ;; esac
case "$LIMIT" in ''|*[!0-9]*|0) echo "error: DIGEST_LIMIT must be a positive number, got '$LIMIT'" >&2; exit 2 ;; esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STATE="$WORK/seen"
RENDER="$WORK/render.md"
BODY="$WORK/body.md"

# 1. Seen-state from the issue. Status tested directly (masked-exit-status
#    rule): a failed listing is an error, never an empty list. An EMPTY
#    successful listing is a fully measured zero -- the cold start.
if bodies="$(gh api "repos/$REPO/issues/$ISSUE/comments?per_page=100" --paginate --jq '.[].body')"; then
    printf '%s\n' "$bodies" | grep -o '<!-- tf-feedback-id: [^ ]* -->' \
        | sed 's/<!-- tf-feedback-id: \(.*\) -->/\1/' > "$STATE" || :
else
    echo "error: could not read the digest issue $REPO#$ISSUE" >&2
    exit 1
fi

# 2. Fetch. The fetcher prints every submission not in STATE and appends the
#    ids to STATE afterwards; STATE is scratch here, the markers below are
#    what persists.
FEEDBACK_STATE="$STATE" "$FETCH" > "$RENDER" \
  || { echo "error: the feedback fetch failed; nothing posted" >&2; exit 1; }

# 3. Split the rendering into submissions (one `## <kind> <id>` heading
#    each), keep the first LIMIT, and compose the comment with a marker per
#    kept id. Prints the number kept and the number deferred on stdout.
counts="$(RENDER="$RENDER" BODY="$BODY" LIMIT="$LIMIT" python3 - <<'PY'
import datetime, os, sys

limit = int(os.environ["LIMIT"])
sections = []  # (id, lines)
with open(os.environ["RENDER"]) as f:
    for line in f:
        line = line.rstrip("\n")
        if line.startswith("## "):
            sid = line.split()[-1]
            sections.append((sid, [line]))
        elif sections:
            sections[-1][1].append(line)

kept, deferred = sections[:limit], sections[limit:]
if kept:
    today = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    with open(os.environ["BODY"], "w") as out:
        n = len(kept)
        out.write(f"### TestFlight feedback, {today}: {n} new submission{'s' if n != 1 else ''}\n\n")
        for sid, lines in kept:
            out.write("\n".join(lines).rstrip("\n") + "\n\n")
        if deferred:
            m = len(deferred)
            out.write(f"_{m} more submission{'s' if m != 1 else ''} waiting; the next run posts them._\n\n")
        for sid, _ in kept:
            out.write(f"<!-- tf-feedback-id: {sid} -->\n")
print(len(kept), len(deferred))
PY
)" || { echo "error: could not parse the fetcher's output" >&2; exit 1; }
kept="${counts% *}"; deferred="${counts#* }"

if [ "$kept" = 0 ]; then
    echo "No new feedback."
    exit 0
fi

# 4. Post. This is the output and the state write in one; a failure here
#    leaves the issue exactly as it was, and the next run starts over.
if ! gh api -X POST "repos/$REPO/issues/$ISSUE/comments" -F body=@"$BODY" > /dev/null; then
    echo "error: could not post the digest comment to $REPO#$ISSUE; nothing was marked seen" >&2
    exit 1
fi
echo "Posted $kept submission(s) to $REPO#$ISSUE ($deferred deferred to the next run):"
cat "$BODY"
