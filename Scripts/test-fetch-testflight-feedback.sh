#!/bin/bash
# Tests for Scripts/fetch-testflight-feedback.sh.
#
# HERMETIC: curl is a stub on PATH routing canned fixtures by URL; the JWT
# comes from a fake ASC_JWT. Nothing here contacts App Store Connect.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# --- fixtures ---------------------------------------------------------------
mkdir -p "$TMP/bin" "$TMP/fixtures"

cat > "$TMP/fixtures/apps.json" <<'JSON'
{"data":[{"type":"apps","id":"APP123","attributes":{"bundleId":"com.tylervick.waddle"}}]}
JSON

# Screenshot feedback arrives in two pages so links.next traversal is
# exercised, not just tolerated. Image objects live in attributes.screenshots
# (the real attribute name -- not screenshotImages).
cat > "$TMP/fixtures/screenshots-page1.json" <<'JSON'
{"data":[
  {"type":"betaFeedbackScreenshotSubmissions","id":"shot-1",
   "attributes":{"createdDate":"2026-08-12T01:02:03Z","comment":"Fire button drifts",
     "deviceModel":"iPhone17,1","osVersion":"26.0",
     "screenshots":[{"url":"https://example.invalid/shot-1.png"}]}}
],"links":{"next":"https://api.appstoreconnect.apple.com/v1/apps/APP123/betaFeedbackScreenshotSubmissions?cursor=page2"}}
JSON

cat > "$TMP/fixtures/screenshots-page2.json" <<'JSON'
{"data":[
  {"type":"betaFeedbackScreenshotSubmissions","id":"shot-2",
   "attributes":{"createdDate":"2026-08-11T09:00:00Z","comment":"Love it",
     "deviceModel":"iPad16,3","osVersion":"26.0","screenshots":[]}}
]}
JSON

cat > "$TMP/fixtures/crashes.json" <<'JSON'
{"data":[
  {"type":"betaFeedbackCrashSubmissions","id":"crash-1",
   "attributes":{"createdDate":"2026-08-12T05:06:07Z","comment":"Died loading my WAD",
     "deviceModel":"iPhone17,1","osVersion":"26.0.1"}}
]}
JSON

# The crash log itself lives behind the submission's crashLog relationship,
# as a JSON resource whose attributes carry the raw report in logText.
cat > "$TMP/fixtures/crashlog.json" <<'JSON'
{"data":{"type":"betaCrashLogs","id":"log-1",
 "attributes":{"logText":"Incident Identifier: TEST-123\nThread 0 Crashed:\n0  WADdle  I_CacheRumble + 1344\n"}}}
JSON

# curl stub: routes by URL substring, appends each URL to curl.log. `-o FILE`
# (used by --download for screenshot images) writes a marker file instead of
# printing to stdout.
cat > "$TMP/bin/curl" <<STUB
#!/bin/bash
url=""; out=""
prev=""
for a in "\$@"; do
    case "\$prev" in -o) out="\$a" ;; esac
    case "\$a" in https://*|http://*) url="\$a" ;; esac
    prev="\$a"
done
echo "\$url" >> "$TMP/curl.log"
if [ -f "$TMP/fail-marker" ]; then exit 22; fi
# Targeted failure for the crash-log fetch alone, so its
# state-file-untouched discipline is testable without failing everything.
case "\$url" in *"/crashLog"*) if [ -f "$TMP/fail-crashlog" ]; then exit 22; fi ;; esac
body=""
# Specific routes before the generic /v1/apps lookup: the app-scoped
# feedback URLs contain "/v1/apps" too.
case "\$url" in
    *"/v1/betaFeedbackCrashSubmissions/crash-1/crashLog"*) body="\$(cat "$TMP/fixtures/crashlog.json")" ;;
    *betaFeedbackScreenshotSubmissions*cursor=page2*)      body="\$(cat "$TMP/fixtures/screenshots-page2.json")" ;;
    *"/v1/apps/APP123/betaFeedbackScreenshotSubmissions"*) body="\$(cat "$TMP/fixtures/screenshots-page1.json")" ;;
    *"/v1/apps/APP123/betaFeedbackCrashSubmissions"*)      body="\$(cat "$TMP/fixtures/crashes.json")" ;;
    *"/v1/apps?"*)                                         body="\$(cat "$TMP/fixtures/apps.json")" ;;
    *example.invalid*)                                     body="PNGBYTES" ;;
    *) exit 22 ;;
esac
if [ -n "\$out" ]; then printf '%s' "\$body" > "\$out"; else printf '%s' "\$body"; fi
STUB
chmod +x "$TMP/bin/curl"

cat > "$TMP/bin/fake-jwt" <<'STUB'
#!/bin/bash
echo "fake.jwt.token"
STUB
chmod +x "$TMP/bin/fake-jwt"

run_fetch() { # extra args...
    env PATH="$TMP/bin:$PATH" ASC_JWT="$TMP/bin/fake-jwt" \
        FEEDBACK_STATE="$TMP/state" \
        "$ROOT/Scripts/fetch-testflight-feedback.sh" "$@"
}

# 1. First run prints every submission as markdown, newest info intact.
out="$(run_fetch)" || fail "first run exited non-zero: $out"
echo "$out" | grep -q "shot-1" || fail "missing shot-1; got: $out"
echo "$out" | grep -q "Fire button drifts" || fail "missing shot-1 comment; got: $out"
echo "$out" | grep -q "iPhone17,1" || fail "missing device model; got: $out"
echo "$out" | grep -q "shot-2" || fail "missing shot-2; got: $out"
echo "$out" | grep -q "crash-1" || fail "missing crash-1; got: $out"
echo "$out" | grep -q "Died loading my WAD" || fail "missing crash comment; got: $out"
grep -q "cursor=page2" "$TMP/curl.log" || fail "did not follow links.next to page 2"
grep -q "/crashLog" "$TMP/curl.log" && fail "a plain run must not fetch crash logs (that is --download's job)"
pass "prints screenshot and crash submissions as markdown, across pages"

# 2. All three ids are now in the state file.
for id in shot-1 shot-2 crash-1; do
    grep -qx "$id" "$TMP/state" || fail "state file missing $id"
done
pass "records seen ids in the state file"

# 3. Second run prints nothing new.
out="$(run_fetch)" || fail "second run exited non-zero: $out"
echo "$out" | grep -qi "no new feedback" || fail "second run should say no new feedback; got: $out"
echo "$out" | grep -q "shot-1" && fail "second run re-printed shot-1"
pass "a second run reports nothing new"

# 4. A failed API call exits non-zero and does NOT update the state file.
rm -f "$TMP/state"
touch "$TMP/fail-marker"
if out="$(run_fetch 2>&1)"; then
    fail "succeeded despite curl failing: $out"
fi
[ ! -s "$TMP/state" ] || fail "state file was written on a failed run"
rm -f "$TMP/fail-marker"
pass "a failed API call exits non-zero and leaves the state file alone"

# 5. Malformed JSON exits non-zero.
printf 'not json' > "$TMP/fixtures/screenshots-page1.json"
rm -f "$TMP/state"
if out="$(run_fetch 2>&1)"; then
    fail "succeeded despite malformed JSON: $out"
fi
pass "malformed JSON is a failure, not an empty result"
# restore fixture for the next case (single page: no links.next)
cat > "$TMP/fixtures/screenshots-page1.json" <<'JSON'
{"data":[{"type":"betaFeedbackScreenshotSubmissions","id":"shot-1",
 "attributes":{"createdDate":"2026-08-12T01:02:03Z","comment":"Fire button drifts",
   "deviceModel":"iPhone17,1","osVersion":"26.0",
   "screenshots":[{"url":"https://example.invalid/shot-1.png"}]}}]}
JSON

# 6. --download DIR saves each new submission's JSON, fetches image URLs, and
#    follows each crash submission's crashLog relationship into <id>.crash.
rm -f "$TMP/state"
mkdir -p "$TMP/dl"
out="$(run_fetch --download "$TMP/dl")" || fail "--download run failed: $out"
[ -f "$TMP/dl/shot-1.json" ] || fail "shot-1.json not saved"
[ -f "$TMP/dl/crash-1.json" ] || fail "crash-1.json not saved"
ls "$TMP/dl"/shot-1*.png >/dev/null 2>&1 || fail "screenshot image not downloaded"
[ -f "$TMP/dl/crash-1.crash" ] || fail "crash-1.crash not saved from the crashLog relationship"
grep -q "Thread 0 Crashed" "$TMP/dl/crash-1.crash" || fail "crash log text not extracted from logText"
pass "--download saves submission JSON, screenshot images, and crash logs"

# 7. A failed crash-log fetch exits non-zero and does NOT update the state
#    file -- the submissions must re-surface on the next run.
rm -f "$TMP/state" "$TMP/dl"/*
touch "$TMP/fail-crashlog"
if out="$(run_fetch --download "$TMP/dl" 2>&1)"; then
    fail "succeeded despite the crash-log fetch failing: $out"
fi
[ ! -s "$TMP/state" ] || fail "state file was written when the crash-log fetch failed"
rm -f "$TMP/fail-crashlog"
pass "a failed crash-log fetch exits non-zero and leaves the state file alone"

echo "All fetch-testflight-feedback tests passed."
