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
# Bounded twice: at most DIGEST_LIMIT submissions per comment, and the
# complete comment within DIGEST_BYTES characters (GitHub refuses a comment
# over 65,536; a TestFlight comment alone can be 4,000); the rest wait for
# the next run (and the comment says how many). A backlog or a broken run
# cannot flood the issue, and an oversized batch cannot wedge it.
#
# Usage: Scripts/testflight-feedback-digest.sh
# Env:
#   DIGEST_ISSUE   the digest issue's number (required)
#   DIGEST_REPO    owner/repo of that issue (default: tylervick/waddle)
#   DIGEST_LIMIT   max submissions per comment (default: 20)
#   DIGEST_BYTES   max characters in one comment, everything included
#                  (default: 60000)
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
BYTES="${DIGEST_BYTES:-60000}"
case "$BYTES" in ''|*[!0-9]*|0) echo "error: DIGEST_BYTES must be a positive number, got '$BYTES'" >&2; exit 2 ;; esac

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
#    what persists. The copy taken first is how step 3 knows which ids are
#    new without trusting the rendering's shape.
SEEN_BEFORE="$WORK/seen-before"
cp "$STATE" "$SEEN_BEFORE"
FEEDBACK_STATE="$STATE" "$FETCH" > "$RENDER" \
  || { echo "error: the feedback fetch failed; nothing posted" >&2; exit 1; }

# 3. Split the rendering into submissions (one `## <kind> <id>` heading
#    each), keep as many as fit LIMIT and the BYTES budget, and compose the
#    comment with a marker per kept id. Prints the number kept and the
#    number deferred on stdout.
#
#    A boundary is a heading line naming an id the fetcher JUST appended to
#    STATE (the ids in STATE now and not in SEEN_BEFORE) -- never a bare
#    `## ` prefix. Tester comments are printed verbatim with their newlines,
#    so a comment containing "## Steps" must stay inside its submission; a
#    bare prefix split would make it a submission of its own, and the real
#    one at the bound could be marked seen with its tail never posted.
#    Plain command with its stdout redirected, NOT `counts="$(python3 …)"`:
#    macOS bash 3.2 scans a heredoc inside $(…) for quotes, and the `$"` in
#    the regex below unbalanced them ("unexpected EOF while looking for
#    matching"). See docs/learnings/bash32-heredoc-inside-command-substitution.md.
RENDER="$RENDER" BODY="$BODY" LIMIT="$LIMIT" BYTES="$BYTES" \
SEEN_BEFORE="$SEEN_BEFORE" STATE_AFTER="$STATE" python3 - > "$WORK/counts" <<'PY' \
  || { echo "error: could not parse the fetcher's output" >&2; exit 1; }
import datetime, os, re, sys

limit = int(os.environ["LIMIT"])
budget = int(os.environ["BYTES"])

def ids(path):
    with open(path) as f:
        return {line.strip() for line in f if line.strip()}
new_ids = ids(os.environ["STATE_AFTER"]) - ids(os.environ["SEEN_BEFORE"])

heading = re.compile(r"^## (Screenshot feedback|Crash feedback) (\S+)$")
sections = []  # (id, lines)
with open(os.environ["RENDER"]) as f:
    for line in f:
        line = line.rstrip("\n")
        m = heading.match(line)
        if m and m.group(2) in new_ids:
            sections.append((m.group(2), [line]))
        elif sections:
            # Continuation of a multi-line field (a tester's comment): keep it
            # inside the list item so it cannot read as structure of its own.
            if line and not line.startswith("- "):
                line = "  " + line
            sections[-1][1].append(line)

today = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
MARK = "<!-- tf-feedback-id: {} -->\n"

def body(kept, deferred):
    n = len(kept)
    out = [f"### TestFlight feedback, {today}: {n} new submission{'s' if n != 1 else ''}\n\n"]
    for sid, lines in kept:
        out.append("\n".join(lines).rstrip("\n") + "\n\n")
    if deferred:
        out.append(f"_{deferred} more submission{'s' if deferred != 1 else ''} waiting; the next run posts them._\n\n")
    for sid, _ in kept:
        out.append(MARK.format(sid))
    return "".join(out)

def size(text):
    # Bytes, not characters: conservative against GitHub's character limit,
    # and what `wc -c` measures when the suite checks the posted body.
    return len(text.encode("utf-8"))

def truncated(section, deferred):
    # A single submission larger than the whole budget would block the queue
    # forever; cut its text until the complete body fits, and say so.
    sid, lines = section
    note = "\n  ... (truncated: the submission is larger than one comment allows)"
    text = "\n".join(lines)
    while True:
        candidate = (sid, (text + note).split("\n"))
        over = size(body([candidate], deferred)) - budget
        if over <= 0 or len(text) <= len(lines[0]):
            return candidate
        text = text[:max(len(lines[0]), len(text) - over)]

# Greedy: add submissions while the COMPLETE body (header, deferred line and
# markers included) stays within the budget. GitHub rejects a comment over
# 65,536 characters, and a rejected post marks nothing seen, so an oversized
# batch would be retried identically every day and never drain.
kept = []
total = len(sections)
for i, section in enumerate(sections[:limit]):
    candidate = kept + [section]
    if size(body(candidate, total - len(candidate))) <= budget:
        kept = candidate
        continue
    if not kept:
        kept = [truncated(section, total - 1)]
    break
deferred = total - len(kept)

if kept:
    with open(os.environ["BODY"], "w") as out:
        out.write(body(kept, deferred))
print(len(kept), deferred)
PY
counts="$(cat "$WORK/counts")"
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
