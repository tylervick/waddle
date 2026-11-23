#!/bin/bash
# Tests for Scripts/testflight-feedback-digest.sh.
#
# Fully HERMETIC: `gh` is a stub on PATH that plays the digest issue (its
# comment list is a directory of posted bodies, so a POST is visible to the
# next GET exactly as on GitHub), and the feedback fetcher is a stub that
# renders whatever ids the fixture says are pending. One case runs the REAL
# Scripts/fetch-testflight-feedback.sh behind a curl stub, so the heading
# shape the digest parses is pinned against the script that produces it.
# Nothing here reaches GitHub or App Store Connect.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

mkdir -p "$TMP/bin" "$TMP/posted" "$TMP/fixtures"

# --- gh stub ----------------------------------------------------------------
# GET  repos/<r>/issues/<n>/comments  -> the bodies in $TMP/posted, in order,
#                                        filtered as the digest's jq would
# POST repos/<r>/issues/<n>/comments  -> stores the -F body=@FILE payload as
#                                        the next posted body
# Each posted comment NNN.md has an author in NNN.author (default
# github-actions[bot], as the workflow posts). A GET applies the one filter
# the digest builds -- `select(.user.login == "A" or .user.login == "B")` --
# and prints every body when the filter has none, as real jq would. A POST
# is authored by $TMP/poster (default github-actions[bot]) and
# `--jq .user.login` prints it. The repository is example/repo, so its
# owner -- the person who might run the digest by hand -- is `example`.
# Markers: fail-get / fail-post make the matching call exit 1. Anything else
# is a loud failure, so an unexpected call cannot pass silently.
cat > "$TMP/bin/gh" <<STUB
#!/bin/bash
[ "\$1" = "api" ] || { echo "stub gh: unhandled args: \$*" >&2; exit 64; }
shift
method=GET; body_file=""; endpoint=""; jq=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -X) method="\$2"; shift ;;
        -F|-f) case "\$2" in body=@*) body_file="\${2#body=@}" ;; esac; shift ;;
        --paginate) ;;
        --jq) jq="\$2"; shift ;;
        repos/*) endpoint="\$1" ;;
        *) echo "stub gh: unhandled arg: \$1" >&2; exit 64 ;;
    esac
    shift
done
case "\$endpoint" in repos/*/issues/*/comments*) ;; *) echo "stub gh: unhandled endpoint: \$endpoint" >&2; exit 64 ;; esac
echo "\$method \$endpoint" >> "$TMP/gh.log"
if [ "\$method" = GET ]; then
    [ -f "$TMP/fail-get" ] && { echo "stub gh: HTTP 502" >&2; exit 1; }
    # The trusted logins, one per line, from every '.user.login == "X"'.
    want="\$(printf '%s' "\$jq" | grep -o '\.user\.login == "[^"]*"' | sed 's/.*== "\(.*\)"/\1/' || :)"
    for f in "$TMP"/posted/*.md; do
        [ -f "\$f" ] || continue
        a='github-actions[bot]'; [ -f "\${f%.md}.author" ] && a="\$(cat "\${f%.md}.author")"
        if [ -z "\$want" ] || printf '%s\n' "\$want" | grep -qxF -- "\$a"; then cat "\$f"; fi
    done
    exit 0
fi
if [ "\$method" = POST ]; then
    [ -f "$TMP/fail-post" ] && { echo "stub gh: HTTP 502" >&2; exit 1; }
    [ -n "\$body_file" ] || { echo "stub gh: POST without -F body=@file" >&2; exit 64; }
    n=\$(ls "$TMP"/posted/*.md 2>/dev/null | wc -l | tr -d ' ')
    f="$TMP/posted/\$(printf '%03d' \$((n + 1)))"
    cp "\$body_file" "\$f.md"
    p='github-actions[bot]'; [ -f "$TMP/poster" ] && p="\$(cat "$TMP/poster")"
    echo "\$p" > "\$f.author"
    [ "\$jq" = .user.login ] || { echo "stub gh: POST expected --jq .user.login" >&2; exit 64; }
    echo "\$p"
    exit 0
fi
echo "stub gh: unhandled method \$method" >&2; exit 64
STUB
chmod +x "$TMP/bin/gh"

# --- fetch stub -------------------------------------------------------------
# Renders, in the real script's shape, every id in fixtures/pending.txt that
# the state file does not already hold; appends them to the state file after
# printing, as the real script does. fail-fetch makes it exit 1 first.
cat > "$TMP/bin/fake-fetch" <<STUB
#!/bin/bash
set -euo pipefail
[ -f "$TMP/fail-fetch" ] && { echo "error: could not fetch screenshot feedback" >&2; exit 1; }
[ -n "\${FEEDBACK_STATE:-}" ] || { echo "fake-fetch: FEEDBACK_STATE unset" >&2; exit 64; }
[ -f "\$FEEDBACK_STATE" ] || : > "\$FEEDBACK_STATE"
new=""
while IFS= read -r id; do
    [ -n "\$id" ] || continue
    grep -qxF "\$id" "\$FEEDBACK_STATE" && continue
    case "\$id" in crash-*) kind="Crash feedback" ;; *) kind="Screenshot feedback" ;; esac
    # A per-id comment fixture, printed VERBATIM (newlines and all) as the
    # real fetcher does; otherwise a one-liner.
    if [ -f "$TMP/fixtures/comment-\$id.txt" ]; then comment="\$(cat "$TMP/fixtures/comment-\$id.txt")"; else comment="about \$id"; fi
    printf '## %s %s\n- created: 2026-09-30T10:00:00Z\n- device: iPhone17,1 (27.0)\n- comment: %s\n\n' "\$kind" "\$id" "\$comment"
    new="\$new\$id
"
done < "$TMP/fixtures/pending.txt"
[ -n "\$new" ] || echo "No new feedback."
printf '%s' "\$new" >> "\$FEEDBACK_STATE"
STUB
chmod +x "$TMP/bin/fake-fetch"

run_digest() { # [env assignments...]
    env PATH="$TMP/bin:/usr/bin:/bin" GH_TOKEN=stub \
        DIGEST_REPO=example/repo DIGEST_ISSUE=42 FETCH_SCRIPT="$TMP/bin/fake-fetch" "$@" \
        "$ROOT/Scripts/testflight-feedback-digest.sh"
}
reset_world() { rm -rf "$TMP/posted"; mkdir -p "$TMP/posted"; rm -f "$TMP/gh.log" "$TMP/poster" "$TMP"/fail-*; }
posted_count() { ls "$TMP"/posted/*.md 2>/dev/null | wc -l | tr -d ' '; }
# The lines of a posted body that a CommonMark renderer would NOT put inside
# a fenced code block -- the lines where Markdown, HTML, mentions and
# references are live. A fence closes on the first line that is a run of the
# same character at least as long as the opening one (indentation allowed),
# or -- for a fence inside a list item -- on a non-blank line indented less
# than the fence, which ends the item. Lines are split as CommonMark splits
# them: at \n, \r\n AND a lone \r (Python's universal newlines).
outside_fences() {
    python3 - "$1" <<'PY'
import re, sys
fence = None
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.rstrip("\n")
    s = line.lstrip(" ")
    indent = len(line) - len(s)
    if fence is not None and s and indent < fence[1]:
        fence = None
    if fence is None:
        m = re.match(r"^(`{3,}|~{3,})", s)
        # A backtick fence's info string holds no backtick: ```x``` is a span.
        if m and indent <= 5 and not (m.group(1)[0] == "`" and "`" in s[len(m.group(1)):]):
            fence = (m.group(1), indent)
            continue
        print(line)
    else:
        m = re.match(r"^(`{3,}|~{3,})\s*$", s)
        if m and m.group(1)[0] == fence[0][0] and len(m.group(1)) >= len(fence[0]):
            fence = None
PY
}
# Drops inline code spans (a run of N backticks to the next run of exactly
# N), where nothing renders either; what is left is live text.
no_spans() { python3 -c 'import re, sys; sys.stdout.write(re.sub(r"(?<!`)(`+)(?!`).*?(?<!`)\1(?!`)", "", sys.stdin.read()))'; }
markers_in() { grep -o '<!-- tf-feedback-id: [^ ]* -->' "$1" | sed 's/.*id: \(.*\) -->/\1/'; }

printf 'shot-1\nshot-2\ncrash-1\n' > "$TMP/fixtures/pending.txt"

# 1. Cold start: an issue with no comments and three pending submissions
#    posts ONE comment carrying all three sections and all three id markers.
#    This is the shape the first scheduled run will actually have.
reset_world
out="$(run_digest 2>&1)" || fail "case 1: digest exited non-zero: $out"
[ "$(posted_count)" = 1 ] || fail "case 1: expected one posted comment, got $(posted_count)"
body="$TMP/posted/001.md"
grep -q '^## Screenshot feedback shot-1' "$body" || fail "case 1: shot-1 section missing"
grep -q '^## Screenshot feedback shot-2' "$body" || fail "case 1: shot-2 section missing"
grep -q '^## Crash feedback crash-1' "$body" || fail "case 1: crash-1 section missing"
[ "$(markers_in "$body" | sort | tr '\n' ' ')" = "crash-1 shot-1 shot-2 " ] \
  || fail "case 1: markers were: $(markers_in "$body" | tr '\n' ' ')"
grep -A2 -x -- '- comment:' "$body" | grep -qxF '  ` about shot-1 `' || fail "case 1: the comment was not carried, as a code span, into the comment"
grep -qxF -- '- device: ` iPhone17,1 (27.0) `' "$body" || fail "case 1: submission fields not carried into the comment"
pass "cold start posts one comment with every submission and marker"

# 2. A submission reported in one run is NOT reported in the next: the
#    markers in the posted comment are the seen-state, and nothing is posted
#    when nothing is new (no noise on a quiet day).
out="$(run_digest 2>&1)" || fail "case 2: digest exited non-zero: $out"
[ "$(posted_count)" = 1 ] || fail "case 2: a second comment was posted with nothing new"
grep -q 'No new feedback' <<<"$out" || fail "case 2: expected 'No new feedback', got: $out"
pass "second run reports nothing and posts nothing"

# 3. A new arrival is reported alone: the earlier ids stay seen.
printf 'shot-1\nshot-2\ncrash-1\nshot-3\n' > "$TMP/fixtures/pending.txt"
run_digest >/dev/null 2>&1 || fail "case 3: digest exited non-zero"
[ "$(posted_count)" = 2 ] || fail "case 3: expected two posted comments, got $(posted_count)"
body="$TMP/posted/002.md"
[ "$(markers_in "$body" | tr '\n' ' ')" = "shot-3 " ] || fail "case 3: markers were: $(markers_in "$body" | tr '\n' ' ')"
grep -q 'shot-1' "$body" && fail "case 3: an already-seen submission was re-reported"
pass "a new arrival is reported once, alone"

# 4. The per-comment bound: with a limit of 2 and three pending, the comment
#    carries two sections, two markers and a line saying one more waits; the
#    NEXT run posts the remaining one. A broken backlog cannot spam the issue,
#    and nothing is lost to the bound.
reset_world
printf 'shot-1\nshot-2\ncrash-1\n' > "$TMP/fixtures/pending.txt"
run_digest DIGEST_LIMIT=2 >/dev/null 2>&1 || fail "case 4: digest exited non-zero"
body="$TMP/posted/001.md"
[ "$(markers_in "$body" | wc -l | tr -d ' ')" = 2 ] || fail "case 4: expected two markers, got $(markers_in "$body" | wc -l)"
[ "$(grep -c '^## ' "$body")" = 2 ] || fail "case 4: expected two sections, got $(grep -c '^## ' "$body")"
grep -q '1 more submission' "$body" || fail "case 4: the overflow line is missing"
run_digest DIGEST_LIMIT=2 >/dev/null 2>&1 || fail "case 4: second digest exited non-zero"
[ "$(posted_count)" = 2 ] || fail "case 4: the overflow was not posted on the next run"
[ "$(markers_in "$TMP/posted/002.md" | wc -l | tr -d ' ')" = 1 ] || fail "case 4: second comment should carry the one remaining id"
grep -q 'more submission' "$TMP/posted/002.md" && fail "case 4: second comment claims an overflow that does not exist"
run_digest DIGEST_LIMIT=2 >/dev/null 2>&1 || fail "case 4: third digest exited non-zero"
[ "$(posted_count)" = 2 ] || fail "case 4: a third comment was posted with nothing left"
pass "the per-comment bound defers the overflow to the next run and loses nothing"

# 5. A failed POST exits non-zero and leaves the issue untouched, so the next
#    run re-surfaces the same submissions: the comment is the state, and it
#    is written only when the output is delivered.
reset_world
touch "$TMP/fail-post"
if out="$(run_digest 2>&1)"; then fail "case 5: a failed post exited 0"; fi
grep -q 'error: could not post' <<<"$out" || fail "case 5: expected a post error, got: $out"
[ "$(posted_count)" = 0 ] || fail "case 5: a comment was stored despite the failed post"
rm -f "$TMP/fail-post"
run_digest >/dev/null 2>&1 || fail "case 5: retry exited non-zero"
[ "$(markers_in "$TMP/posted/001.md" | sort | tr '\n' ' ')" = "crash-1 shot-1 shot-2 " ] \
  || fail "case 5: the retry did not re-surface every submission"
pass "a failed post exits non-zero and the next run re-surfaces the same submissions"

# 6. A failed comment LISTING exits non-zero and posts nothing. A listing
#    failure must not read as "no comments yet": that would replay the whole
#    backlog into the issue as if it were a cold start.
reset_world
run_digest >/dev/null 2>&1 || fail "case 6: seeding run exited non-zero"
touch "$TMP/fail-get"
if out="$(run_digest 2>&1)"; then fail "case 6: a failed listing exited 0"; fi
grep -q 'error: could not read the digest issue' <<<"$out" || fail "case 6: expected a listing error, got: $out"
[ "$(posted_count)" = 1 ] || fail "case 6: a failed listing was treated as a cold start and replayed the backlog"
rm -f "$TMP/fail-get"
pass "a failed comment listing fails closed instead of replaying everything"

# 7. A failed fetch exits non-zero and posts nothing.
reset_world
touch "$TMP/fail-fetch"
if out="$(run_digest 2>&1)"; then fail "case 7: a failed fetch exited 0"; fi
[ "$(posted_count)" = 0 ] || fail "case 7: a comment was posted after a failed fetch"
rm -f "$TMP/fail-fetch"
pass "a failed fetch exits non-zero and posts nothing"

# 8. Usage: no DIGEST_ISSUE is a usage error, not a run against issue "".
reset_world
if out="$(env PATH="$TMP/bin:/usr/bin:/bin" GH_TOKEN=stub DIGEST_REPO=example/repo \
        FETCH_SCRIPT="$TMP/bin/fake-fetch" "$ROOT/Scripts/testflight-feedback-digest.sh" 2>&1)"; then
    fail "case 8: missing DIGEST_ISSUE exited 0"
fi
grep -qi 'DIGEST_ISSUE' <<<"$out" || fail "case 8: the error does not name DIGEST_ISSUE: $out"
[ -f "$TMP/gh.log" ] && fail "case 8: gh was called without an issue number"
pass "a missing DIGEST_ISSUE is refused before any call"

# 9. Contract with the REAL fetcher: run Scripts/fetch-testflight-feedback.sh
#    behind a curl stub and confirm the digest's markers are exactly the ids
#    the real script rendered. If the fetcher's heading shape ever changes,
#    this is the case that notices.
reset_world
mkdir -p "$TMP/real/bin"
cat > "$TMP/real/bin/curl" <<STUB
#!/bin/bash
url=""; for a in "\$@"; do case "\$a" in https://*) url="\$a" ;; esac; done
case "\$url" in
    *"/v1/apps/APP123/betaFeedbackScreenshotSubmissions"*)
        printf '%s' '{"data":[{"type":"betaFeedbackScreenshotSubmissions","id":"real-shot-9","attributes":{"createdDate":"2026-09-30T01:00:00Z","comment":"Real shape","deviceModel":"iPhone17,1","osVersion":"27.0","screenshots":[]}}]}' ;;
    *"/v1/apps/APP123/betaFeedbackCrashSubmissions"*)
        printf '%s' '{"data":[{"type":"betaFeedbackCrashSubmissions","id":"real-crash-7","attributes":{"createdDate":"2026-09-30T02:00:00Z","comment":"Real crash","deviceModel":"iPad16,3","osVersion":"27.0"}}]}' ;;
    *"/v1/apps?"*) printf '%s' '{"data":[{"type":"apps","id":"APP123"}]}' ;;
    *) echo "stub curl: unhandled url \$url" >&2; exit 64 ;;
esac
STUB
chmod +x "$TMP/real/bin/curl"
printf '#!/bin/bash\necho fake.jwt.token\n' > "$TMP/real/bin/jwt"; chmod +x "$TMP/real/bin/jwt"
env PATH="$TMP/real/bin:$TMP/bin:/usr/bin:/bin" GH_TOKEN=stub ASC_JWT="$TMP/real/bin/jwt" \
    DIGEST_REPO=example/repo DIGEST_ISSUE=42 "$ROOT/Scripts/testflight-feedback-digest.sh" >/dev/null 2>&1 \
  || fail "case 9: digest over the real fetcher exited non-zero"
[ "$(markers_in "$TMP/posted/001.md" | sort | tr '\n' ' ')" = "real-crash-7 real-shot-9 " ] \
  || fail "case 9: markers from the real fetcher were: $(markers_in "$TMP/posted/001.md" | tr '\n' ' ')"
grep -q '^## Crash feedback real-crash-7' "$TMP/posted/001.md" || fail "case 9: the real crash section is missing"
pass "the digest parses the real fetcher's output"

# 10. A tester's comment is printed verbatim, newlines included, so one that
#     contains a "## Steps" line must stay INSIDE its submission. Split on a
#     bare `## ` it would become a submission of its own, and with the real
#     one in the last slot its tail would be dropped while its id was marked
#     seen -- never delivered. The multi-line comment sits at the bound.
reset_world
printf 'shot-1\nshot-2\ncrash-1\n' > "$TMP/fixtures/pending.txt"
printf 'Crashed on load.\n## Steps\n1. open the WAD\n2. ## not a heading either\n' > "$TMP/fixtures/comment-shot-2.txt"
run_digest DIGEST_LIMIT=2 >/dev/null 2>&1 || fail "case 10: digest exited non-zero"
body="$TMP/posted/001.md"
[ "$(markers_in "$body" | sort | tr '\n' ' ')" = "shot-1 shot-2 " ] \
  || fail "case 10: markers were: $(markers_in "$body" | tr '\n' ' ')"
[ "$(grep -c '^## ' "$body")" = 2 ] || fail "case 10: the comment's '## Steps' line became a heading"
grep -q '2. ## not a heading either' "$body" || fail "case 10: the tail of the multi-line comment was dropped"
grep -q '1 more submission' "$body" || fail "case 10: crash-1 should have been deferred, not swallowed"
run_digest DIGEST_LIMIT=2 >/dev/null 2>&1 || fail "case 10: second digest exited non-zero"
[ "$(markers_in "$TMP/posted/002.md" | tr '\n' ' ')" = "crash-1 " ] || fail "case 10: crash-1 was never delivered"
rm -f "$TMP/fixtures/comment-shot-2.txt"
pass "a multi-line comment with a '## ' line stays inside its submission at the bound"

# 11. The size budget: twenty submissions with 4,000-character comments do
#     not fit one GitHub comment. The digest must post what fits (complete
#     body within DIGEST_BYTES, markers included), defer the rest, and drain
#     the whole backlog over the following runs -- never post a body the
#     API would reject and then retry it identically forever.
reset_world
: > "$TMP/fixtures/pending.txt"
for i in $(seq 1 20); do
    echo "big-$i" >> "$TMP/fixtures/pending.txt"
    head -c 4000 /dev/zero | tr '\0' 'x' > "$TMP/fixtures/comment-big-$i.txt"
done
run_digest DIGEST_BYTES=30000 >/dev/null 2>&1 || fail "case 11: first digest exited non-zero"
body="$TMP/posted/001.md"
[ "$(wc -c < "$body")" -le 30000 ] || fail "case 11: the body is $(wc -c < "$body") characters, over the budget"
first=$(markers_in "$body" | wc -l | tr -d ' ')
[ "$first" -ge 5 ] && [ "$first" -lt 20 ] || fail "case 11: expected a partial batch, got $first markers"
grep -q "$((20 - first)) more submission" "$body" || fail "case 11: the deferred count is wrong"
runs=1
while [ $runs -lt 10 ]; do
    out="$(run_digest DIGEST_BYTES=30000 2>&1)" || fail "case 11: run $((runs + 1)) exited non-zero: $out"
    runs=$((runs + 1))
    grep -q 'No new feedback' <<<"$out" && break
done
total=$(cat "$TMP"/posted/*.md | grep -o '<!-- tf-feedback-id: [^ ]* -->' | sort -u | wc -l | tr -d ' ')
[ "$total" = 20 ] || fail "case 11: $total of 20 submissions were delivered after $runs runs"
for f in "$TMP"/posted/*.md; do
    [ "$(wc -c < "$f")" -le 30000 ] || fail "case 11: a later body is over the budget: $f"
done
pass "the character budget posts what fits and drains the backlog across runs"

# 12. One submission larger than the entire budget is truncated rather than
#     left to block the queue: it posts (marked seen, with a truncation
#     note) and the next one follows on the next run.
reset_world
printf 'huge-1\nshot-1\n' > "$TMP/fixtures/pending.txt"
head -c 9000 /dev/zero | tr '\0' 'y' > "$TMP/fixtures/comment-huge-1.txt"
run_digest DIGEST_BYTES=5000 >/dev/null 2>&1 || fail "case 12: digest exited non-zero"
body="$TMP/posted/001.md"
[ "$(wc -c < "$body")" -le 5000 ] || fail "case 12: truncated body still over budget: $(wc -c < "$body")"
[ "$(markers_in "$body" | tr '\n' ' ')" = "huge-1 " ] || fail "case 12: markers were: $(markers_in "$body" | tr '\n' ' ')"
grep -q 'truncated' "$body" || fail "case 12: no truncation note"
run_digest DIGEST_BYTES=5000 >/dev/null 2>&1 || fail "case 12: second digest exited non-zero"
[ "$(markers_in "$TMP/posted/002.md" | tr '\n' ' ')" = "shot-1 " ] || fail "case 12: the queue did not move past the huge submission"
rm -f "$TMP"/fixtures/comment-*.txt
pass "a submission larger than the whole budget is truncated, not left to wedge the queue"

# 13. #299 is public and unlocked: a marker in a comment by anyone outside
#     the trusted set must not count, or a stranger could hide a submission
#     for good. shot-1's marker here is in a stranger's comment, so shot-1 is
#     still posted.
reset_world
printf 'shot-1\nshot-2\n' > "$TMP/fixtures/pending.txt"
printf 'hello\n<!-- tf-feedback-id: shot-1 -->\n' > "$TMP/posted/001.md"; echo stranger > "$TMP/posted/001.author"
out="$(run_digest 2>&1)" || fail "case 13: digest exited non-zero: $out"
[ "$(markers_in "$TMP/posted/002.md" | sort | tr '\n' ' ')" = "shot-1 shot-2 " ] \
  || fail "case 13: a stranger's marker suppressed a submission: $(markers_in "$TMP/posted/002.md" | tr '\n' ' ')"
pass "a marker in another author's comment does not suppress the submission"

# 14. The workflow (github-actions[bot]) and the repository's owner running
#     the digest by hand must each see the other's markers: trusting only
#     "whoever posts" would make each re-post what the other did. Both orders.
reset_world
out="$(run_digest 2>&1)" || fail "case 14: the bot's run exited non-zero: $out"
echo example > "$TMP/poster"
out="$(run_digest 2>&1)" || fail "case 14: the owner's run exited non-zero: $out"
[ "$(posted_count)" = 1 ] || fail "case 14: the owner re-posted the bot's submissions"
grep -q 'No new feedback' <<<"$out" || fail "case 14: the owner's run should have found nothing new: $out"
reset_world
echo example > "$TMP/poster"
out="$(run_digest 2>&1)" || fail "case 14: the owner's first run exited non-zero: $out"
rm -f "$TMP/poster"
out="$(run_digest 2>&1)" || fail "case 14: the bot's run exited non-zero: $out"
[ "$(posted_count)" = 1 ] || fail "case 14: the bot re-posted the owner's submissions"
pass "the bot and the repository owner each see the other's markers"

# 15. DIGEST_TRUSTED_AUTHORS replaces the set; every login in it is checked
#     before it reaches the jq filter, so a quote cannot widen the filter;
#     an empty set is refused. Both refusals come before any read.
reset_world
printf 'shot-1\nshot-2\n' > "$TMP/fixtures/pending.txt"
printf 'x\n<!-- tf-feedback-id: shot-1 -->\n' > "$TMP/posted/001.md"; echo helper > "$TMP/posted/001.author"
out="$(run_digest DIGEST_TRUSTED_AUTHORS='github-actions[bot] helper' 2>&1)" || fail "case 15: override exited non-zero: $out"
[ "$(markers_in "$TMP/posted/002.md" | tr '\n' ' ')" = "shot-2 " ] || fail "case 15: the overriding set was not used"
reset_world
if out="$(run_digest DIGEST_TRUSTED_AUTHORS='github-actions[bot] x" or true or "y' 2>&1)"; then fail "case 15: a non-login was accepted"; fi
grep -q 'DIGEST_TRUSTED_AUTHORS must hold GitHub logins' <<<"$out" || fail "case 15: wrong error: $out"
[ -f "$TMP/gh.log" ] && fail "case 15: the issue was read with an unchecked login"
if out="$(run_digest DIGEST_TRUSTED_AUTHORS=' ' 2>&1)"; then fail "case 15: an empty set was accepted"; fi
grep -q 'DIGEST_TRUSTED_AUTHORS is empty' <<<"$out" || fail "case 15: wrong error for an empty set: $out"
[ -f "$TMP/gh.log" ] && fail "case 15: the issue was read with no trusted login"
pass "the trusted set can be overridden, each login is validated, and an empty set is refused"

# 16. `[bot]` is a shell bracket pattern: split unguarded, the default set
#     would become `github-actionsb` in a directory holding such a file, and
#     the bot's markers would stop counting.
reset_world
printf 'shot-1\nshot-2\ncrash-1\n' > "$TMP/fixtures/pending.txt"
run_digest >/dev/null 2>&1 || fail "case 16: seeding run exited non-zero"
mkdir -p "$TMP/globdir"; touch "$TMP/globdir/github-actionsb"
out="$(cd "$TMP/globdir" && run_digest 2>&1)" || fail "case 16: run from the glob directory exited non-zero: $out"
[ "$(posted_count)" = 1 ] || fail "case 16: the login was glob-expanded and the bot's submissions re-posted"
pass "the trusted set is not glob-expanded"

# 17. A post that comes back under another login fails the run: its markers
#     would be invisible tomorrow and the same submissions re-posted daily.
reset_world
echo someone-else > "$TMP/poster"
if out="$(run_digest 2>&1)"; then fail "case 17: a post under the wrong login exited 0"; fi
grep -q "error: the digest was posted as 'someone-else', which is not in DIGEST_TRUSTED_AUTHORS" <<<"$out" \
  || fail "case 17: wrong error: $out"
grep -q "add 'someone-else' to it" <<<"$out" || fail "case 17: the error does not name the login to add: $out"
pass "a post under a login outside the trusted set fails the run"

# 18. A tester cannot forge the seen-state, inject HTML or ping anyone: the
#     comment is posted as code spans, where GitHub renders no
#     tag, mention or reference, and an HTML comment opener is broken so no
#     marker can be read back from the raw body. The text stays readable.
reset_world
printf 'shot-evil\n' > "$TMP/fixtures/pending.txt"
printf '<!-- tf-feedback-id: shot-victim -->\n<b>bold</b> & @someone look\n' > "$TMP/fixtures/comment-shot-evil.txt"
out="$(run_digest 2>&1)" || fail "case 18: digest exited non-zero: $out"
body="$TMP/posted/001.md"
[ "$(markers_in "$body" | tr '\n' ' ')" = "shot-evil " ] || fail "case 18: a forged marker survived: $(markers_in "$body" | tr '\n' ' ')"
live="$(outside_fences "$body" | no_spans)"
grep -q 'shot-victim' <<<"$live" && fail "case 18: the forged marker is outside the fence"
grep -q '<b>' <<<"$live" && fail "case 18: HTML from a tester is live in the comment"
grep -q '@someone' <<<"$live" && fail "case 18: a mention from a tester would notify someone"
grep -qxF '  ` <b>bold</b> & @someone look `' "$body" || fail "case 18: the tester's text is no longer readable: $(cat "$body")"
rm -f "$TMP"/fixtures/comment-*.txt
pass "a tester's comment cannot forge a marker, inject HTML or mention anyone"

# 19. Markdown in a tester's comment stays text. Each line below would be
#     structure if it were live: a heading, a setext h2 (the '---' under a
#     line), a fake field, a fake submission heading, cross-references,
#     a mention, and a fence longer than three backticks that tries to close
#     the block early so the rest becomes live. Text in the tester's own
#     backticks keeps its characters (entities are shown literally in code).
reset_world
printf 'shot-hostile\n' > "$TMP/fixtures/pending.txt"
cat > "$TMP/fixtures/comment-shot-hostile.txt" <<'TXT'
first line
# Fake heading
looks like h2
---
- device: fake
## Crash feedback shot-fake
see #1 and owner/repo#2 and @someone
use `<b>` here
````
```<b>bold</b>```
<!-- tf-feedback-id: shot-victim -->
TXT
out="$(run_digest 2>&1)" || fail "case 19: digest exited non-zero: $out"
body="$TMP/posted/001.md"
[ "$(markers_in "$body" | tr '\n' ' ')" = "shot-hostile " ] || fail "case 19: markers were: $(markers_in "$body" | tr '\n' ' ')"
live="$(outside_fences "$body" | no_spans)"
for pat in 'Fake heading' 'looks like h2' '^---' 'device: fake' 'shot-fake' '#1' 'repo#2' '@someone' '<b>' 'shot-victim'; do
    grep -q -- "$pat" <<<"$live" && fail "case 19: '$pat' from the tester is live Markdown: $live"
done
[ "$(grep -c '^## ' "$body")" = 1 ] || fail "case 19: the tester added a heading"
grep -qxF '  `` use `<b>` here ``\' "$body" || fail "case 19: text in the tester's backticks was changed: $(cat "$body")"
grep -q '&lt;\|&amp;' "$body" && fail "case 19: entities were written where they show literally"
grep -qxF '  ` # Fake heading `\' "$body" || fail "case 19: the tester's text is no longer all there"
rm -f "$TMP"/fixtures/comment-*.txt
pass "Markdown in a tester's comment is inert, and no line can close its code span"

# 20. A lone CR or a CRLF ends a line for CommonMark and GitHub as surely as
#     a LF does. Text after one must not start a live line of its own -- a
#     heading, a top-level list item, a reference or a mention.
reset_world
printf 'shot-cr\n' > "$TMP/fixtures/pending.txt"
printf 'Line one\r# CR heading\r- CR list item\r\n#1 and @octocat' > "$TMP/fixtures/comment-shot-cr.txt"
out="$(run_digest 2>&1)" || fail "case 20: digest exited non-zero: $out"
body="$TMP/posted/001.md"
live="$(outside_fences "$body" | no_spans)"
for pat in 'CR heading' 'CR list item' '#1' '@octocat' 'Line one'; do
    grep -q -- "$pat" <<<"$live" && fail "case 20: '$pat' after a CR is live Markdown: $live"
done
grep -q "$(printf '\r')" "$body" && fail "case 20: a CR reached the posted body"
grep -qxF '  ` # CR heading `\' "$body" || fail "case 20: the text after a CR was lost: $(cat "$body")"
grep -qxF '  ` #1 and @octocat `' "$body" || fail "case 20: the text after a CRLF was lost: $(cat "$body")"
[ "$(markers_in "$body" | tr '\n' ' ')" = "shot-cr " ] || fail "case 20: markers were: $(markers_in "$body" | tr '\n' ' ')"
rm -f "$TMP"/fixtures/comment-*.txt
pass "a lone CR or a CRLF in a tester's comment starts no live line"

# 21. A long paragraph wraps: it is posted as a code span (which GitHub
#     wraps), not inside a fenced block (shown white-space: pre, one line
#     scrolling sideways). Lines of a paragraph are joined by hard breaks;
#     a blank line starts a new paragraph inside the list item.
reset_world
printf 'shot-long\n' > "$TMP/fixtures/pending.txt"
{ for i in $(seq 1 120); do printf 'word%s ' "$i"; done; printf '\nsecond line\n\nnew paragraph\n'; } > "$TMP/fixtures/comment-shot-long.txt"
out="$(run_digest 2>&1)" || fail "case 21: digest exited non-zero: $out"
body="$TMP/posted/001.md"
outside_fences "$body" | grep -q 'word120' || fail "case 21: the long paragraph is inside a fenced block, which does not wrap"
outside_fences "$body" | no_spans | grep -q 'word' && fail "case 21: the long paragraph is not inert"
grep -q '^  ` word1 .* word120 *`\\$' "$body" || fail "case 21: the paragraph's first line has no hard break: $(cat "$body")"
grep -qxF '  ` second line `' "$body" || fail "case 21: the second line is missing"
grep -A1 -xF '  ` second line `' "$body" | tail -1 | grep -qx '' || fail "case 21: a blank line no longer starts a new paragraph"
grep -qxF '  ` new paragraph `' "$body" || fail "case 21: the second paragraph is missing"
rm -f "$TMP"/fixtures/comment-*.txt
pass "a long paragraph is posted as wrapping code spans with hard breaks"

echo "All testflight-feedback-digest tests passed."
