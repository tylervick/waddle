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
# GET  repos/<r>/issues/<n>/comments  -> the bodies in $TMP/posted, in order
#                                        (what `--jq '.[].body'` would print)
# POST repos/<r>/issues/<n>/comments  -> stores the -F body=@FILE payload as
#                                        the next posted body
# Markers: fail-get / fail-post make the matching call exit 1. Anything else
# is a loud failure, so an unexpected call cannot pass silently.
cat > "$TMP/bin/gh" <<STUB
#!/bin/bash
[ "\$1" = "api" ] || { echo "stub gh: unhandled args: \$*" >&2; exit 64; }
shift
method=GET; body_file=""; endpoint=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -X) method="\$2"; shift ;;
        -F|-f) case "\$2" in body=@*) body_file="\${2#body=@}" ;; esac; shift ;;
        --paginate|--jq) [ "\$1" = "--jq" ] && shift ;;
        repos/*) endpoint="\$1" ;;
        *) echo "stub gh: unhandled arg: \$1" >&2; exit 64 ;;
    esac
    shift
done
case "\$endpoint" in repos/*/issues/*/comments*) ;; *) echo "stub gh: unhandled endpoint: \$endpoint" >&2; exit 64 ;; esac
echo "\$method \$endpoint" >> "$TMP/gh.log"
if [ "\$method" = GET ]; then
    [ -f "$TMP/fail-get" ] && { echo "stub gh: HTTP 502" >&2; exit 1; }
    for f in "$TMP"/posted/*.md; do [ -f "\$f" ] && cat "\$f"; done
    exit 0
fi
if [ "\$method" = POST ]; then
    [ -f "$TMP/fail-post" ] && { echo "stub gh: HTTP 502" >&2; exit 1; }
    [ -n "\$body_file" ] || { echo "stub gh: POST without -F body=@file" >&2; exit 64; }
    n=\$(ls "$TMP"/posted | wc -l | tr -d ' ')
    cp "\$body_file" "$TMP/posted/\$(printf '%03d' \$((n + 1))).md"
    echo '{"id": 1}'
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
reset_world() { rm -rf "$TMP/posted"; mkdir -p "$TMP/posted"; rm -f "$TMP/gh.log" "$TMP"/fail-*; }
posted_count() { ls "$TMP/posted" | wc -l | tr -d ' '; }
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
grep -q 'comment: about shot-1' "$body" || fail "case 1: submission fields not carried into the comment"
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

echo "All testflight-feedback-digest tests passed."
