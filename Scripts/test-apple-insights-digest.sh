#!/bin/bash
# Tests for Scripts/apple-insights-digest.sh.
#
# Fully HERMETIC: the REAL script runs behind a strict `curl` stub that plays
# App Store Connect (and the presigned report download host) from fixture
# files, a `gh` stub that plays the tracking issue (its comment list is a
# directory of posted bodies, so a POST is visible to the next GET, as on
# GitHub), and a fake token minter. Nothing here reaches GitHub or Apple.
# Every identifier in the fixtures is made up.
#
# The curl stub REFUSES any method but GET and records the attempt: the
# digest is read-only, and every case asserts nothing else was ever sent.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# Made-up account values. The digest must never print any of them.
VENDOR=87654321
KEY_ID=TESTKEY001
ISSUER=00000000-1111-2222-3333-444444444444
RKEY_ID=REPKEY0002
RISSUER=99999999-8888-7777-6666-555555555555

mkdir -p "$TMP/bin" "$TMP/posted" "$TMP/fix"
# The minter stub refuses a key file without a PEM header, so a key the
# digest decoded wrongly cannot mint.
PEM="-----BEGIN PRIVATE KEY-----
TUFERS1VUC1OT1QtQS1SRUFMLUtFWQ==
-----END PRIVATE KEY-----"
printf '%s\n' "$PEM" > "$TMP/reports.p8"; printf '%s\n' "$PEM" > "$TMP/main.p8"

# --- gh stub (the tracking issue) ---------------------------------------------
# Each posted comment NNN.md has an author in NNN.author (default
# github-actions[bot], as the workflow posts). A GET applies the one filter
# the digest builds -- `select(.user.login == "A" or .user.login == "B")` --
# and prints every body when the filter has none, as real jq would. A POST
# is authored by $TMP/poster (default github-actions[bot]) and
# `--jq .user.login` prints it. The repository is example/repo, so its
# owner -- the person who might run the digest by hand -- is `example`.
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
case "\$endpoint" in repos/example/repo/issues/42/comments*) ;; *) echo "stub gh: unhandled endpoint: \$endpoint" >&2; exit 64 ;; esac
echo "\$method \$endpoint" >> "$TMP/gh.log"
if [ "\$method" = GET ]; then
    [ -f "$TMP/fail-gh-get" ] && { echo "stub gh: HTTP 502" >&2; exit 1; }
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
    [ -f "$TMP/fail-gh-post" ] && { echo "stub gh: HTTP 502" >&2; exit 1; }
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

# --- token minter: the token names the key it was minted from ------------------
cat > "$TMP/bin/jwt" <<'STUB'
#!/bin/bash
[ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] && [ -f "${ASC_KEY_PATH:-/nonexistent}" ] \
  && grep -q -- '-----BEGIN PRIVATE KEY-----' "$ASC_KEY_PATH" \
  || { echo "stub jwt: incomplete key" >&2; exit 1; }
echo "jwt-$ASC_KEY_ID"
STUB
chmod +x "$TMP/bin/jwt"

# --- curl stub (App Store Connect + the segment host) --------------------------
# Each URL maps to a fixture NAME; $TMP/fix/NAME is the body and
# $TMP/fix/NAME.code the status (default 200). A NAME with no fixture is a
# loud failure. The gated endpoints answer 403 unless the token is the
# reports key's, which is how Apple behaves for a key without the role.
cat > "$TMP/bin/curl" <<STUB
#!/bin/bash
method=GET; out=""; url=""; auth=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -X) method="\$2"; shift ;;
        -o) out="\$2"; shift ;;
        -D|-w|--connect-timeout|--max-time|--data-binary) shift ;;
        -H) case "\$2" in "Authorization: Bearer "*) auth="\${2#Authorization: Bearer }" ;; esac; shift ;;
        -sS) ;;
        https://*) url="\$1" ;;
        *) echo "stub curl: unhandled arg: \$1" >&2; exit 64 ;;
    esac
    shift
done
if [ "\$method" != GET ]; then
    echo "\$method \$url" >> "$TMP/non-get.log"
    echo "stub curl: refusing \$method -- the digest is read-only" >&2; exit 64
fi
echo "GET \$auth \$url" >> "$TMP/curl.log"
A="https://api.appstoreconnect.apple.com/v1"
gated=""
case "\$url" in
    "\$A/apps/APP1/appStoreVersions?"*) name=versions ;;
    "\$A/appStoreVersions/"*"/build") name="build-\$(echo "\$url" | sed 's#.*/appStoreVersions/\([^/]*\)/build#\1#')" ;;
    "\$A/builds/"*"/diagnosticSignatures?"*) name="sigs-\$(echo "\$url" | sed 's#.*/builds/\([^/]*\)/.*#\1#')" ;;
    "\$A/builds/"*"/perfPowerMetrics") name="perf-\$(echo "\$url" | sed 's#.*/builds/\([^/]*\)/.*#\1#')" ;;
    "\$A/apps/APP1/perfPowerMetrics") name=perf-app ;;
    "\$A/apps/APP1/customerReviews?sort=-createdDate&limit=200") name=reviews ;;
    "\$A/apps/APP1/customerReviews?cursor="*) name="reviews-\${url##*cursor=}" ;;
    "\$A/apps/APP1/analyticsReportRequests?filter%5BaccessType%5D=ONGOING&limit=50") name=an-requests; gated=1 ;;
    "\$A/analyticsReportRequests/REQ1/reports?filter%5Bcategory%5D=APP_STORE_ENGAGEMENT&limit=200") name=an-reports-eng; gated=1 ;;
    "\$A/analyticsReportRequests/REQ1/reports?filter%5Bcategory%5D=APP_USAGE&limit=200") name=an-reports-usage; gated=1 ;;
    "\$A/analyticsReports/"*"/instances?filter%5Bgranularity%5D=WEEKLY&limit=200") name="an-inst-\$(echo "\$url" | sed 's#.*/analyticsReports/\([^/]*\)/.*#\1#')"; gated=1 ;;
    "\$A/analyticsReportInstances/"*"/segments?limit=200") name="an-seg-\$(echo "\$url" | sed 's#.*/analyticsReportInstances/\([^/]*\)/.*#\1#')"; gated=1 ;;
    "https://segments.example.invalid/"*) name="seg-\${url##*/}" ;;
    "\$A/salesReports?filter%5Bfrequency%5D=WEEKLY&filter%5BreportType%5D=SALES&filter%5BreportSubType%5D=SUMMARY&filter%5Bversion%5D=1_1&filter%5BreportDate%5D="*"&filter%5BvendorNumber%5D=$VENDOR")
        d="\${url#*reportDate%5D=}"; name="sales-\${d%%&*}" ;;
    *) echo "stub curl: unhandled url \$url" >&2; exit 64 ;;
esac
case "\$url" in https://segments.example.invalid/*) [ -z "\$auth" ] || { echo "stub curl: Authorization sent to the segment host" >&2; exit 64; } ;; esac
f="$TMP/fix/\$name"
if [ -n "\$gated" ] && [ "\$auth" != "jwt-$RKEY_ID" ]; then
    printf '%s' '{"errors":[{"status":"403","code":"FORBIDDEN_ERROR","title":"This request is forbidden for security reasons","detail":"The API key in use does not allow this request"}]}' > "\$out"
    printf 403; exit 0
fi
[ -f "\$f" ] || { echo "stub curl: no fixture \$name for \$url" >&2; exit 64; }
cp "\$f" "\$out"
if [ -f "\$f.code" ]; then cat "\$f.code"; else printf 200; fi
STUB
chmod +x "$TMP/bin/curl"

# --- fixtures -----------------------------------------------------------------
FIX="$TMP/fix"
fx() { printf '%s' "$2" > "$FIX/$1"; }
code() { printf '%s' "$2" > "$FIX/$1.code"; }

base_fixtures() {
    rm -rf "$FIX"; mkdir -p "$FIX"
    fx versions '{"data":[
      {"id":"V15","attributes":{"versionString":"1.5","appVersionState":"READY_FOR_DISTRIBUTION","appStoreState":"READY_FOR_SALE"}},
      {"id":"V14","attributes":{"versionString":"1.4","appVersionState":"PROCESSING_FOR_DISTRIBUTION","appStoreState":"PROCESSING_FOR_APP_STORE"}},
      {"id":"V16","attributes":{"versionString":"1.6","appVersionState":"PREPARE_FOR_SUBMISSION","appStoreState":"PREPARE_FOR_SUBMISSION"}}],"links":{}}'
    fx build-V15 '{"data":{"type":"builds","id":"B295","attributes":{"version":"295"}}}'
    fx sigs-B295 '{"data":[],"links":{}}'
    fx perf-B295 '{"productData":[],"insights":{"trendingUp":[],"regressions":[]}}'
    fx perf-app '{"productData":[],"insights":{"trendingUp":[],"regressions":[]}}'
    fx reviews '{"data":[
      {"id":"rev-2","attributes":{"rating":4,"title":"Aiming","body":"Please add aim assist.","territory":"FRA","createdDate":"2026-11-10T08:00:00Z"}},
      {"id":"rev-1","attributes":{"rating":5,"title":"Great","body":"Heretic next?\nThanks.","territory":"USA","createdDate":"2026-10-28T08:00:00Z"}}],"links":{}}'
}

# A gzip'd TSV fixture.
gz() { # NAME -- TSV on stdin
    python3 -c 'import gzip, sys; open(sys.argv[1], "wb").write(gzip.compress(sys.stdin.buffer.read()))' "$FIX/$1"
}

analytics_fixtures() {
    fx an-requests '{"data":[{"id":"REQ1","attributes":{"accessType":"ONGOING","stoppedDueToInactivity":false}}]}'
    fx an-reports-eng '{"data":[
      {"id":"RENG","attributes":{"name":"App Store Discovery and Engagement Standard","category":"APP_STORE_ENGAGEMENT"}},
      {"id":"RENGD","attributes":{"name":"App Store Discovery and Engagement Detailed","category":"APP_STORE_ENGAGEMENT"}}]}'
    fx an-reports-usage '{"data":[{"id":"RSES","attributes":{"name":"App Sessions Standard","category":"APP_USAGE"}}]}'
    fx an-inst-RENG '{"data":[
      {"id":"I-OLD","attributes":{"granularity":"WEEKLY","processingDate":"2026-11-09"}},
      {"id":"I-NEW","attributes":{"granularity":"WEEKLY","processingDate":"2026-11-16"}}]}'
    fx an-inst-RSES '{"data":[{"id":"I-SES","attributes":{"granularity":"WEEKLY","processingDate":"2026-11-16"}}]}'
    fx an-seg-I-NEW '{"data":[{"id":"S1","attributes":{"url":"https://segments.example.invalid/eng1"}},{"id":"S2","attributes":{"url":"https://segments.example.invalid/eng2"}}]}'
    fx an-seg-I-SES '{"data":[{"id":"S3","attributes":{"url":"https://segments.example.invalid/ses1"}}]}'
    printf 'Date\tApp Name\tApp Apple Identifier\tEvent\tPage Type\tCounts\tUnique Counts\n2026-11-10\tWaddle\t111\tImpression\tProduct page\t120\t100\n2026-11-11\tWaddle\t111\tPage view\tProduct page\t30\t25\n' | gz seg-eng1
    printf 'Date\tApp Name\tApp Apple Identifier\tEvent\tPage Type\tCounts\tUnique Counts\n2026-11-12\tWaddle\t111\tImpression\tSearch\t5\t5\n' | gz seg-eng2
    printf 'Date\tApp Name\tApp Apple Identifier\tApp Version\tDevice\tSessions\tTotal Session Duration\tUnique Devices\n2026-11-10\tWaddle\t111\t1.5\tiPhone\t40\t3600\t12\n2026-11-11\tWaddle\t111\t1.5\tiPad\t2\t60\t1\n' | gz seg-ses1
}

sales_fixture() { # NAME
    printf 'Provider\tProvider Country\tSKU\tDeveloper\tTitle\tVersion\tProduct Type Identifier\tUnits\tDeveloper Proceeds\tBegin Date\tEnd Date\tCustomer Currency\tCountry Code\tCurrency of Proceeds\tApple Identifier\tCustomer Price\n' > "$TMP/sales.tsv"
    printf 'APPLE\tUS\tsku-x\tSome Dev\tWaddle\t1.5\t1F\t9\t7.77\t11/10/2026\t11/16/2026\tEUR\tFR\tEUR\t111\t9.99\n' >> "$TMP/sales.tsv"
    printf 'APPLE\tUS\tsku-x\tSome Dev\tWaddle\t1.5\t7F\t21\t0\t11/10/2026\t11/16/2026\tUSD\tUS\tUSD\t111\t0\n' >> "$TMP/sales.tsv"
    printf 'APPLE\tUS\tsku-x\tSome Dev\tWaddle\t1.5\t3F\t2\t0\t11/10/2026\t11/16/2026\tUSD\tUS\tUSD\t111\t0\n' >> "$TMP/sales.tsv"
    gz "$1" < "$TMP/sales.tsv"
}

reset_world() { rm -rf "$TMP/posted"; mkdir -p "$TMP/posted"; rm -f "$TMP"/*.log "$TMP"/fail-* "$TMP/poster"; }
posted_count() { ls "$TMP"/posted/*.md 2>/dev/null | wc -l | tr -d ' ' || :; }
markers_in() { grep -o '<!-- review-id: [^ ]* -->' "$1" | sed 's/.*id: \(.*\) -->/\1/' || :; }

ALL_OUT="$TMP/all-output"
: > "$ALL_OUT"
# run_digest [VAR=value ...] -- the everyday key only, unless the caller adds
# the reports key or the vendor number. Today is a Monday.
run_digest() {
    local rc=0
    env PATH="$TMP/bin:/usr/bin:/bin" GH_TOKEN=stub GITHUB_ACTIONS= \
        DIGEST_REPO=example/repo DIGEST_ISSUE=42 DIGEST_TODAY=2026-11-23 \
        ASC_APP_ID=APP1 ASC_JWT="$TMP/bin/jwt" API_RETRIES=0 \
        ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" ASC_KEY_PATH="$TMP/main.p8" \
        "$@" "$ROOT/Scripts/apple-insights-digest.sh" > "$TMP/out" 2>&1 || rc=$?
    cat "$TMP/out" >> "$ALL_OUT"
    return $rc
}
WITH_REPORTS="ASC_REPORTS_KEY_ID=$RKEY_ID ASC_REPORTS_ISSUER_ID=$RISSUER ASC_REPORTS_KEY_PATH=$TMP/reports.p8"
only_get() { [ ! -f "$TMP/non-get.log" ] || fail "$1: a non-GET request was made: $(cat "$TMP/non-get.log")"; }
no_ids() { # file case
    for v in "$VENDOR" "$KEY_ID" "$ISSUER" "$RKEY_ID" "$RISSUER"; do
        if grep -qF "$v" "$1"; then fail "$2: an account identifier was printed in $1"; fi
    done
}

# 1. Empty signatures and metrics: ONE "nothing yet" line naming the live
#    version and saying why empty is not "no crashes"; the two gated parts
#    skipped with reasons naming the secrets they need; exit 0. Cold start:
#    both reviews posted, with markers. This is today's real shape.
reset_world; base_fixtures
run_digest || fail "case 1: exited non-zero: $(cat "$TMP/out")"
[ "$(posted_count)" = 1 ] || fail "case 1: expected one comment, got $(posted_count)"
body="$TMP/posted/001.md"
[ "$(grep -c '^\*\*Diagnostics:\*\* nothing yet' "$body")" = 1 ] || fail "case 1: no single 'nothing yet' line"
grep -q '1.5 (build 295)' "$body" || fail "case 1: the live version is not named"
grep -q 'not no crashes' "$body" || fail "case 1: the line does not say empty is not 'no crashes'"
grep -qF -e '1.4' -e '1.6' "$body" && fail "case 1: a version that is not READY_FOR_SALE was read"
grep -q '^\*\*App Analytics:\*\* skipped: .*ASC_REPORTS_KEY_ID ASC_REPORTS_ISSUER_ID ASC_REPORTS_PRIVATE_KEY' "$body" \
  || fail "case 1: analytics skip does not name the missing secrets"
grep -q '^\*\*Sales and Trends:\*\* skipped: .*ASC_VENDOR_NUMBER' "$body" || fail "case 1: sales skip does not name ASC_VENDOR_NUMBER"
[ "$(markers_in "$body" | sort | tr '\n' ' ')" = "rev-1 rev-2 " ] || fail "case 1: markers were: $(markers_in "$body" | tr '\n' ' ')"
grep -q 'analyticsReportRequests\|salesReports' "$TMP/curl.log" && fail "case 1: a gated part ran without its secrets"
only_get "case 1"
pass "empty diagnostics post one 'nothing yet' line; gated parts skip with the secrets they need"

# 1b. Live means appVersionState READY_FOR_DISTRIBUTION, which is what Apple
#     returns (measured 2026-11-23). The deprecated appStoreState is the
#     fallback only when the current field is absent; a READY_FOR_SALE there
#     never overrides a current field that says otherwise.
reset_world; base_fixtures
fx versions '{"data":[
  {"id":"V15","attributes":{"versionString":"1.5","appVersionState":"READY_FOR_DISTRIBUTION"}},
  {"id":"V14","attributes":{"versionString":"1.4","appStoreState":"READY_FOR_SALE"}},
  {"id":"V13","attributes":{"versionString":"1.3","appVersionState":"REPLACED_WITH_NEW_VERSION","appStoreState":"READY_FOR_SALE"}}],"links":{}}'
fx build-V14 '{"data":{"type":"builds","id":"B282","attributes":{"version":"282"}}}'
fx sigs-B282 '{"data":[],"links":{}}'
fx perf-B282 '{"productData":[],"insights":{"trendingUp":[],"regressions":[]}}'
run_digest || fail "case 1b: exited non-zero: $(cat "$TMP/out")"
grep -q 'for 1.5 (build 295), 1.4 (build 282)\.' "$TMP/posted/001.md" || fail "case 1b: wrong versions read: $(grep Diagnostics "$TMP/posted/001.md")"
grep -q 'appStoreVersions/V13' "$TMP/curl.log" && fail "case 1b: a version whose current state is not live was read"
fx versions '{"data":[{"id":"V16","attributes":{"versionString":"1.6","appVersionState":"PREPARE_FOR_SUBMISSION","appStoreState":"PREPARE_FOR_SUBMISSION"}}],"links":{}}'
run_digest || fail "case 1b: no live version exited non-zero"
grep -q 'no App Store version is live (READY_FOR_DISTRIBUTION)' "$TMP/posted/002.md" || fail "case 1b: no-live wording wrong"
pass "live versions are matched on READY_FOR_DISTRIBUTION, with the deprecated field as a fallback"

# 2. Signatures present: counted by type, listed by weight descending with
#    the logs endpoint; regressions reported. No "nothing yet" line.
reset_world; base_fixtures
fx sigs-B295 '{"data":[
  {"id":"SIG-LOW","attributes":{"diagnosticType":"HANGS","signature":"low_frame","weight":1.5}},
  {"id":"SIG-HIGH","attributes":{"diagnosticType":"DISK_WRITES","signature":"high_frame","weight":42.0}},
  {"id":"SIG-MID","attributes":{"diagnosticType":"HANGS","signature":"mid_frame","weight":10.0}}],"links":{}}'
fx perf-B295 '{"productData":[{"x":1}],"insights":{"trendingUp":[],"regressions":[{"metric":"launchTime","summaryString":"Launch time regressed"}]}}'
run_digest || fail "case 2: exited non-zero: $(cat "$TMP/out")"
body="$TMP/posted/001.md"
grep -q 'nothing yet' "$body" && fail "case 2: 'nothing yet' posted with signatures present"
grep -q 'DISK_WRITES 1, HANGS 2' "$body" || fail "case 2: counts by type missing: $(cat "$body")"
order="$(grep -o '`[a-z]*_frame`' "$body" | tr -d '`' | tr '\n' ' ')"
[ "$order" = "high_frame mid_frame low_frame " ] || fail "case 2: signatures not sorted by weight: $order"
grep -q 'diagnosticSignatures/SIG-HIGH/logs' "$body" || fail "case 2: the logs link is missing"
grep -q '1 regression (Launch time regressed)' "$body" || fail "case 2: the regression is not reported"
only_get "case 2"
pass "signatures are counted by type and listed by weight with their logs link"

# 3. A new review alongside an already-posted one: only the new one is
#    posted. The marker in the earlier comment is the seen-state.
reset_world; base_fixtures
printf 'earlier digest\n<!-- review-id: rev-1 -->\n' > "$TMP/posted/001.md"
run_digest || fail "case 3: exited non-zero: $(cat "$TMP/out")"
body="$TMP/posted/002.md"
[ "$(markers_in "$body" | tr '\n' ' ')" = "rev-2 " ] || fail "case 3: markers were: $(markers_in "$body" | tr '\n' ' ')"
grep -q 'Heretic' "$body" && fail "case 3: the already-posted review was posted again"
grep -q 'aim assist' "$body" || fail "case 3: the new review's body is missing"
grep -q '4/5, FRA, 2026-11-10: \*\*Aiming\*\*' "$body" || fail "case 3: rating, territory, date or title missing"
run_digest || fail "case 3: second run exited non-zero"
grep -q 'Customer reviews:\*\* none new' "$TMP/posted/003.md" || fail "case 3: a quiet week did not say 'none new'"
[ -z "$(markers_in "$TMP/posted/003.md")" ] || fail "case 3: a quiet week re-posted a review"
pass "a review is posted once; a quiet week still posts and says none new"

# 3b. Issue #497 is public: a marker in a comment by anyone but the posting
#     account must not count, or a stranger could hide a review for good.
#     The marker for rev-1 here is in a stranger's comment, so rev-1 is
#     still posted.
reset_world; base_fixtures
printf 'hello\n<!-- review-id: rev-1 -->\n' > "$TMP/posted/001.md"; echo stranger > "$TMP/posted/001.author"
run_digest || fail "case 3b: exited non-zero: $(cat "$TMP/out")"
[ "$(markers_in "$TMP/posted/002.md" | sort | tr '\n' ' ')" = "rev-1 rev-2 " ] \
  || fail "case 3b: a stranger's marker suppressed a review: $(markers_in "$TMP/posted/002.md" | tr '\n' ' ')"
pass "a marker in another author's comment does not suppress the review"

# 3c. The workflow (github-actions[bot]) and the repository's owner running
#     it by hand must each see the other's markers: trusting only "whoever
#     posts" made a person's run re-post every review the bot had posted,
#     and the bot re-post every review the person had. Both orders.
reset_world; base_fixtures
run_digest || fail "case 3c: the bot's run exited non-zero"
echo example > "$TMP/poster"
run_digest || fail "case 3c: the owner's run exited non-zero: $(cat "$TMP/out")"
[ -z "$(markers_in "$TMP/posted/002.md")" ] || fail "case 3c: the owner re-posted the bot's reviews: $(markers_in "$TMP/posted/002.md" | tr '\n' ' ')"
reset_world; base_fixtures
echo example > "$TMP/poster"
run_digest || fail "case 3c: the owner's first run exited non-zero"
rm -f "$TMP/poster"
run_digest || fail "case 3c: the bot's run exited non-zero"
[ -z "$(markers_in "$TMP/posted/002.md")" ] || fail "case 3c: the bot re-posted the owner's reviews: $(markers_in "$TMP/posted/002.md" | tr '\n' ' ')"
pass "the bot and the repository owner each see the other's markers"

# 3c2. DIGEST_TRUSTED_AUTHORS replaces the set; every login in it is checked
#      before it reaches the jq filter, so a quote cannot widen the filter.
reset_world; base_fixtures
printf 'x\n<!-- review-id: rev-1 -->\n' > "$TMP/posted/001.md"; echo helper > "$TMP/posted/001.author"
run_digest DIGEST_TRUSTED_AUTHORS='github-actions[bot] helper' || fail "case 3c2: override exited non-zero: $(cat "$TMP/out")"
[ "$(markers_in "$TMP/posted/002.md" | tr '\n' ' ')" = "rev-2 " ] || fail "case 3c2: the overriding set was not used"
reset_world; base_fixtures
if run_digest DIGEST_TRUSTED_AUTHORS='github-actions[bot] x" or true or "y'; then fail "case 3c2: a non-login was accepted"; fi
grep -q 'DIGEST_TRUSTED_AUTHORS must hold GitHub logins' "$TMP/out" || fail "case 3c2: wrong error: $(cat "$TMP/out")"
[ -f "$TMP/gh.log" ] && fail "case 3c2: the issue was read with an unchecked login"
pass "the trusted set can be overridden, and each login is validated first"

# 3c3. `[bot]` is a shell bracket pattern: split unguarded, the default set
#      would become `github-actionsb` in a directory holding such a file,
#      and the bot's markers would stop counting.
reset_world; base_fixtures
run_digest || fail "case 3c3: seeding run exited non-zero"
mkdir -p "$TMP/globdir"; touch "$TMP/globdir/github-actionsb"
(cd "$TMP/globdir" && run_digest) || fail "case 3c3: run from the glob directory exited non-zero: $(cat "$TMP/out")"
[ -z "$(markers_in "$TMP/posted/002.md")" ] || fail "case 3c3: the login was glob-expanded and the bot's reviews re-posted"
pass "the trusted set is not glob-expanded"

# 3d. A post that comes back under another login fails the run: its markers
#     would be invisible next week and the same reviews re-posted forever.
reset_world; base_fixtures
echo someone-else > "$TMP/poster"
if run_digest; then fail "case 3d: a post under the wrong login exited 0"; fi
grep -q "posted as 'someone-else', which is not in DIGEST_TRUSTED_AUTHORS" "$TMP/out" || fail "case 3d: wrong error: $(cat "$TMP/out")"
pass "a post under a login outside the trusted set fails the run"

# 4. A 403 on analytics (a key without the role) skips that part with
#    Apple's reason and the run still succeeds. The key ids stay out of it.
reset_world; base_fixtures; analytics_fixtures
run_digest ASC_REPORTS_KEY_ID="$KEY_ID" ASC_REPORTS_ISSUER_ID="$ISSUER" ASC_REPORTS_KEY_PATH="$TMP/main.p8" \
  || fail "case 4: a 403 on analytics failed the run: $(cat "$TMP/out")"
body="$TMP/posted/001.md"
grep -q '^\*\*App Analytics:\*\* skipped: Apple refused the report request listing: HTTP 403 FORBIDDEN_ERROR The API key in use does not allow this request' "$body" \
  || fail "case 4: the skip reason is missing: $(grep Analytics "$body")"
[ "$(markers_in "$body" | wc -l | tr -d ' ')" = 2 ] || fail "case 4: the reviews were not posted alongside the skip"
no_ids "$body" "case 4"; no_ids "$TMP/out" "case 4"
only_get "case 4"
pass "a 403 on analytics is skipped with Apple's reason, and the run succeeds"

# 5. A non-200 on reviews fails the run, posts nothing and so marks nothing
#    seen; the next good run posts every review.
reset_world; base_fixtures
code reviews 500; fx reviews '{"errors":[{"status":"500","code":"UNEXPECTED_ERROR"}]}'
if run_digest; then fail "case 5: a failed review read exited 0"; fi
grep -q 'error: could not read the customer reviews' "$TMP/out" || fail "case 5: wrong error: $(cat "$TMP/out")"
[ "$(posted_count)" = 0 ] || fail "case 5: something was posted after a failed review read"
base_fixtures
run_digest || fail "case 5: the retry exited non-zero"
[ "$(markers_in "$TMP/posted/001.md" | sort | tr '\n' ' ')" = "rev-1 rev-2 " ] || fail "case 5: the retry did not post every review"
pass "a failed review read fails the run and marks nothing seen"

# 5b. A failed diagnostics read fails the run the same way.
reset_world; base_fixtures
code sigs-B295 500
if run_digest; then fail "case 5b: a failed diagnostics read exited 0"; fi
[ "$(posted_count)" = 0 ] || fail "case 5b: something was posted after a failed diagnostics read"
pass "a failed diagnostics read fails the run and posts nothing"

# 6. Analytics with the reports key: the latest weekly instance of each
#    Standard report, as totals. Detailed reports are not downloaded, the
#    older instance is not read, and the segment host gets no Authorization.
reset_world; base_fixtures; analytics_fixtures
# shellcheck disable=SC2086
run_digest $WITH_REPORTS || fail "case 6: exited non-zero: $(cat "$TMP/out")"
body="$TMP/posted/001.md"
grep -q 'App Store Discovery and Engagement Standard (2026-11-10 to 2026-11-12): Impression 125, Page view 30' "$body" \
  || fail "case 6: engagement totals wrong: $(grep Engagement "$body")"
grep -q 'App Sessions Standard (2026-11-10 to 2026-11-11): .*Sessions 42.*Unique Devices 13' "$body" \
  || fail "case 6: session totals wrong: $(grep Sessions "$body")"
grep -q 'Identifier' "$body" && fail "case 6: an identifier column was summed"
grep -q 'RENGD\|I-OLD' "$TMP/curl.log" && fail "case 6: a Detailed report or an older instance was read"
grep -q "GET jwt-$RKEY_ID .*analyticsReportRequests" "$TMP/curl.log" || fail "case 6: analytics did not use the reports key"
no_ids "$body" "case 6"; no_ids "$TMP/out" "case 6"
only_get "case 6"
pass "analytics posts the latest weekly Standard reports as totals with the reports key"

# 6f. The reports key as the secret's TEXT, in each form the owner may set:
#     the .p8's PEM as pasted (what is set today), base64 of it, and neither
#     -- which is a stated "did not decode", not "secrets not set".
for form in pem base64 garbage; do
    reset_world; base_fixtures; analytics_fixtures
    case "$form" in
        pem) key="$PEM" ;;
        base64) key="$(printf '%s\n' "$PEM" | /usr/bin/base64 | tr -d '\n')" ;;
        garbage) key="not a key at all!" ;;
    esac
    run_digest ASC_REPORTS_KEY_ID="$RKEY_ID" ASC_REPORTS_ISSUER_ID="$RISSUER" ASC_REPORTS_PRIVATE_KEY="$key" \
      || fail "case 6f ($form): exited non-zero: $(cat "$TMP/out")"
    if [ "$form" = garbage ]; then
        grep -q 'App Analytics:\*\* skipped: ASC_REPORTS_PRIVATE_KEY is set but is neither' "$TMP/posted/001.md" \
          || fail "case 6f ($form): $(grep Analytics "$TMP/posted/001.md")"
    else
        grep -q 'App Sessions Standard' "$TMP/posted/001.md" || fail "case 6f ($form): analytics did not run: $(grep Analytics "$TMP/posted/001.md")"
    fi
    grep -q 'BEGIN PRIVATE KEY' "$TMP/out" && fail "case 6f ($form): the key text was printed"
done
pass "the reports key works as PEM text or base64, and anything else is a stated skip"

# 6b. The reports key works but no ONGOING request exists yet: skipped, saying so.
reset_world; base_fixtures; analytics_fixtures
fx an-requests '{"data":[]}'
# shellcheck disable=SC2086
run_digest $WITH_REPORTS || fail "case 6b: exited non-zero"
grep -q 'App Analytics:\*\* skipped: no active ONGOING analytics report request' "$TMP/posted/001.md" || fail "case 6b: no reason given"
pass "no report request yet is a stated skip"

# 6c. A failed segment download skips analytics with a reason, not the run.
reset_world; base_fixtures; analytics_fixtures
code seg-ses1 403
# shellcheck disable=SC2086
run_digest $WITH_REPORTS || fail "case 6c: a failed download failed the run"
grep -q 'App Analytics:\*\* skipped: a report segment download answered HTTP 403' "$TMP/posted/001.md" || fail "case 6c: no reason given"
pass "a failed segment download is a stated skip"

# 6d. The request exists but Apple has generated nothing yet (its first
#     reports take 1-2 days): a stated line, not a failure.
reset_world; base_fixtures; analytics_fixtures
fx an-reports-eng '{"data":[]}'; fx an-reports-usage '{"data":[]}'
# shellcheck disable=SC2086
run_digest $WITH_REPORTS || fail "case 6d: a request with no reports failed the run"
grep -q 'App Analytics:\*\* skipped: the report request has no Standard engagement or usage reports yet' "$TMP/posted/001.md" \
  || fail "case 6d: no reason given: $(grep Analytics "$TMP/posted/001.md")"
only_get "case 6d"
pass "a request with no reports yet is a stated line"

# 6e. Reports exist but have no weekly instance yet: each says so, and the
#     section is not a failure or a skip.
reset_world; base_fixtures; analytics_fixtures
fx an-inst-RENG '{"data":[]}'; fx an-inst-RSES '{"data":[]}'
# shellcheck disable=SC2086
run_digest $WITH_REPORTS || fail "case 6e: reports with no instances failed the run"
[ "$(grep -c ': no weekly instance yet$' "$TMP/posted/001.md")" = 2 ] \
  || fail "case 6e: expected two 'no weekly instance yet' lines: $(grep -A3 Analytics "$TMP/posted/001.md")"
grep -q 'analyticsReportInstances' "$TMP/curl.log" && fail "case 6e: segments were requested for a missing instance"
only_get "case 6e"
pass "reports with no weekly instance yet are stated, report by report"

# 7. Sales with the vendor number: unit counts by kind for the latest week,
#    and NOTHING about money or the account -- no proceeds, prices or
#    currencies, no vendor number. The newest Sunday has no report yet
#    (404), so the week before is used.
reset_world; base_fixtures
fx sales-2026-11-22 '{"errors":[{"status":"404","code":"NOT_FOUND","detail":"There were no sales for the date specified."}]}'
code sales-2026-11-22 404
sales_fixture sales-2026-11-15
run_digest ASC_VENDOR_NUMBER="$VENDOR" || fail "case 7: exited non-zero: $(cat "$TMP/out")"
body="$TMP/posted/001.md"
grep -q 'Sales and Trends\*\* (week 11/10/2026 to 11/16/2026, units only): 9 downloads, 2 re-downloads, 21 updates, 0 other units' "$body" \
  || fail "case 7: sales line wrong: $(grep Sales "$body")"
for money in 7.77 9.99 EUR USD 'Some Dev' sku-x; do
    if grep -qF "$money" "$body"; then fail "case 7: '$money' from the sales report reached the comment"; fi
done
grep -q "GET jwt-$KEY_ID .*salesReports" "$TMP/curl.log" || fail "case 7: without a reports key, sales should use the everyday key"
no_ids "$body" "case 7"; no_ids "$TMP/out" "case 7"
only_get "case 7"
pass "sales posts unit counts only, falling back a week when the newest is not out"

# 7b. Sales prefers the reports key when it is configured.
reset_world; base_fixtures; analytics_fixtures; sales_fixture sales-2026-11-22
# shellcheck disable=SC2086
run_digest $WITH_REPORTS ASC_VENDOR_NUMBER="$VENDOR" || fail "case 7b: exited non-zero"
grep -q "GET jwt-$RKEY_ID .*salesReports" "$TMP/curl.log" || fail "case 7b: sales did not use the reports key"
pass "sales uses the reports key when it exists"

# 7c. Sales refused (Apple's answer to a wrong vendor number): skipped with
#     the reason, exit 0, and the number is not echoed anywhere.
reset_world; base_fixtures
fx sales-2026-11-22 "{\"errors\":[{\"status\":\"400\",\"code\":\"PARAMETER_ERROR.INVALID\",\"detail\":\"Invalid vendor number specified: $VENDOR\"}]}"
code sales-2026-11-22 400
run_digest ASC_VENDOR_NUMBER="$VENDOR" || fail "case 7c: a refused sales read failed the run"
grep -q 'Sales and Trends:\*\* skipped: Apple refused the weekly sales summary with the everyday key: HTTP 400 PARAMETER_ERROR.INVALID Invalid vendor number specified: \[redacted\]' "$TMP/posted/001.md" \
  || fail "case 7c: reason wrong: $(grep Sales "$TMP/posted/001.md")"
no_ids "$TMP/posted/001.md" "case 7c"; no_ids "$TMP/out" "case 7c"
pass "a refused sales read is a stated skip that does not echo the vendor number"

# 8. A failed comment listing fails closed: it must not read as a cold
#    start and re-post every review.
reset_world; base_fixtures
touch "$TMP/fail-gh-get"
if run_digest; then fail "case 8: a failed listing exited 0"; fi
grep -q 'error: could not read the tracking issue' "$TMP/out" || fail "case 8: wrong error: $(cat "$TMP/out")"
[ "$(posted_count)" = 0 ] || fail "case 8: posted after a failed listing"
[ -f "$TMP/curl.log" ] && fail "case 8: Apple was queried after the listing failed"
pass "a failed comment listing fails closed"

# 9. A failed post exits non-zero; the next run posts the same reviews.
reset_world; base_fixtures
touch "$TMP/fail-gh-post"
if run_digest; then fail "case 9: a failed post exited 0"; fi
grep -q 'nothing was marked seen' "$TMP/out" || fail "case 9: wrong error: $(cat "$TMP/out")"
rm -f "$TMP/fail-gh-post"
run_digest || fail "case 9: retry exited non-zero"
[ "$(markers_in "$TMP/posted/001.md" | sort | tr '\n' ' ')" = "rev-1 rev-2 " ] || fail "case 9: the retry lost a review"
pass "a failed post marks nothing seen"

# 10. A reviewer cannot forge the seen-state or ping anyone: a marker or a
#     mention inside a review is neutralised, so it neither hides another
#     review next week nor notifies a stranger.
reset_world; base_fixtures
fx reviews '{"data":[
  {"id":"rev-evil","attributes":{"rating":1,"title":"<b>hi</b>","body":"<!-- review-id: rev-victim -->\n@someone look","territory":"USA","createdDate":"2026-11-01T00:00:00Z"}}],"links":{}}'
run_digest || fail "case 10: exited non-zero"
[ "$(markers_in "$TMP/posted/001.md" | tr '\n' ' ')" = "rev-evil " ] || fail "case 10: a forged marker survived: $(markers_in "$TMP/posted/001.md" | tr '\n' ' ')"
grep -q '<b>' "$TMP/posted/001.md" && fail "case 10: HTML from a review reached the comment"
grep -q '@someone' "$TMP/posted/001.md" && fail "case 10: a mention from a review would notify someone"
pass "a review's text cannot forge a marker, inject HTML or mention anyone"

# 11. The per-comment bound defers reviews to the next run and loses none;
#     reviews on a second page are read when the first page is all new.
reset_world; base_fixtures
fx reviews '{"data":[
  {"id":"rev-3","attributes":{"rating":5,"title":"c","body":"c","territory":"USA","createdDate":"2026-11-12T00:00:00Z"}},
  {"id":"rev-2","attributes":{"rating":5,"title":"b","body":"b","territory":"USA","createdDate":"2026-11-11T00:00:00Z"}}],
  "links":{"next":"https://api.appstoreconnect.apple.com/v1/apps/APP1/customerReviews?cursor=2"}}'
fx reviews-2 '{"data":[{"id":"rev-1","attributes":{"rating":5,"title":"a","body":"a","territory":"USA","createdDate":"2026-11-10T00:00:00Z"}}],"links":{}}'
run_digest DIGEST_LIMIT=2 || fail "case 11: exited non-zero"
[ "$(markers_in "$TMP/posted/001.md" | tr '\n' ' ')" = "rev-1 rev-2 " ] || fail "case 11: first run posted: $(markers_in "$TMP/posted/001.md" | tr '\n' ' ')"
grep -q '1 more review waiting' "$TMP/posted/001.md" || fail "case 11: the deferral is not stated"
run_digest DIGEST_LIMIT=2 || fail "case 11: second run exited non-zero"
[ "$(markers_in "$TMP/posted/002.md" | tr '\n' ' ')" = "rev-3 " ] || fail "case 11: the deferred review was not posted next"
pass "the bound defers reviews to the next run and a second page is read"

# 12. Usage: no DIGEST_ISSUE is refused before any call.
reset_world; base_fixtures
if out="$(env PATH="$TMP/bin:/usr/bin:/bin" GH_TOKEN=stub "$ROOT/Scripts/apple-insights-digest.sh" 2>&1)"; then
    fail "case 12: a missing DIGEST_ISSUE exited 0"
fi
grep -q DIGEST_ISSUE <<<"$out" || fail "case 12: the error does not name DIGEST_ISSUE"
[ -f "$TMP/gh.log" ] || [ -f "$TMP/curl.log" ] && fail "case 12: a call was made without an issue number"
pass "a missing DIGEST_ISSUE is refused before any call"

# 13. Across every run above, nothing but GET reached the stub, and no
#     account identifier was ever printed.
only_get "case 13"
no_ids "$ALL_OUT" "case 13"
pass "every request in every case was a GET, and no identifier was printed"

echo "All apple-insights-digest tests passed."
