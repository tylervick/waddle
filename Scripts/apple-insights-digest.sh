#!/bin/bash
# Posts a weekly digest of what Apple already collects about Waddle to a
# tracking issue (issue #486). Until this existed nobody read it: five
# customer reviews with concrete requests (Heretic/Hexen, aiming, the 2009
# control scheme) sat in App Store Connect unread, and the diagnostics and
# power metrics were never looked at.
#
# One comment per run, always -- an empty week still posts, so the run is
# visibly alive. Four sections:
#
#   1. Diagnostics. For each App Store version that is live on the store
#      (appVersionState READY_FOR_DISTRIBUTION), its
#      build's diagnostic signatures counted by type, the top ones by weight
#      with their logs endpoint, and whether perfPowerMetrics holds any
#      product data or regressions. All empty is ONE line saying so: Apple
#      reports only from devices whose owners opted in, so empty means "too
#      few opted-in devices yet", not "no crashes".
#   2. Customer reviews not posted before. The TRACKING ISSUE IS THE STATE,
#      as for the TestFlight digest (docs/learnings/digest-issue-is-its-own-
#      seen-state.md): each posted review carries a hidden
#      `<!-- review-id: <id> -->` marker, read back at the start of the next
#      run. Posting is the output and the state write in one step, so a run
#      that fails anywhere before the post marks nothing seen. Only markers
#      in comments by a trusted login count: #497 is public,
#      and a stranger's comment carrying a marker would otherwise hide that
#      review for good.
#   3. App Analytics: the latest WEEKLY instance of the App Store engagement
#      and app usage reports, as totals.
#   4. Sales and Trends: the latest weekly sales summary, as UNIT COUNTS
#      ONLY (first-time downloads, re-downloads, updates, other). The issue
#      is public; proceeds and currency amounts are never posted.
#
# Sections 1 and 2 run on the key every App Store Connect script uses, and a
# failure in either FAILS THE RUN with nothing posted. Sections 3 and 4 need
# things only the owner can provide (a key with the Sales and Reports role,
# an ONGOING analytics report request, the vendor number), so each is
# SKIPPED WITH ITS REASON in the comment when they are absent or refused --
# never a failed run, never silent.
#
# READS ONLY. Every request this script makes is a GET; it creates, changes
# and deletes nothing in App Store Connect. Scripts/test-apple-insights-
# digest.sh fails if any other method is ever used.
#
# The repository is public: the vendor number and key ids are never printed,
# and an error from Apple is reduced to its status and message with either
# value scrubbed out.
#
# Usage: Scripts/apple-insights-digest.sh
# Env:
#   DIGEST_ISSUE   the tracking issue's number (required; #497 in CI)
#   DIGEST_REPO    owner/repo of that issue (default: tylervick/waddle)
#   DIGEST_LIMIT   max reviews per comment (default: 20; the rest wait)
#   DIGEST_BYTES   max characters in the whole comment (default: 60000;
#                  GitHub refuses one over 65,536)
#   DIGEST_TODAY   YYYY-MM-DD to treat as today (tests use this)
#   GH_TOKEN       for `gh api` (issues: write)
#   DIGEST_TRUSTED_AUTHORS  space-separated logins whose comments are read
#                  for markers (default: github-actions[bot], which the
#                  workflow's GITHUB_TOKEN posts as, and the owner of
#                  DIGEST_REPO, for a run from a person's checkout). The
#                  set, not one login: the bot and the owner must each see
#                  the other's markers, or each re-posts what the other did.
#                  A post that lands under a login outside it fails the run.
#   ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH          the everyday key
#   ASC_REPORTS_KEY_ID / ASC_REPORTS_ISSUER_ID / ASC_REPORTS_PRIVATE_KEY
#                  the Sales and Reports key (analytics; sales when set).
#                  The private key is the .p8's PEM text or base64 of it;
#                  ASC_REPORTS_KEY_PATH (a .p8 file) may stand in for it.
#   ASC_VENDOR_NUMBER  the account's vendor number (sales)
#   ASC_JWT        override the token minter (tests use this); it is run
#                  with ASC_KEY_ID etc. set to whichever key is wanted
#   plus Scripts/asc-api.sh's API_RETRIES / API_RETRY_MAX_SLEEP / ASC_APP_ID.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

die() { echo "error: $*" >&2; exit 1; }

REPO="${DIGEST_REPO:-tylervick/waddle}"
ISSUE="${DIGEST_ISSUE:-}"
LIMIT="${DIGEST_LIMIT:-20}"
BYTES="${DIGEST_BYTES:-60000}"
[ -n "$ISSUE" ] || { echo "error: DIGEST_ISSUE is not set (the tracking issue's number)" >&2; exit 2; }
case "$ISSUE" in *[!0-9]*) echo "error: DIGEST_ISSUE must be a number, got '$ISSUE'" >&2; exit 2 ;; esac
case "$LIMIT" in ''|*[!0-9]*|0) echo "error: DIGEST_LIMIT must be a positive number, got '$LIMIT'" >&2; exit 2 ;; esac
case "$BYTES" in ''|*[!0-9]*|0) echo "error: DIGEST_BYTES must be a positive number, got '$BYTES'" >&2; exit 2 ;; esac
TODAY="${DIGEST_TODAY:-$(date -u +%Y-%m-%d)}"
case "$TODAY" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) echo "error: DIGEST_TODAY must be YYYY-MM-DD, got '$TODAY'" >&2; exit 2 ;; esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# shellcheck source=Scripts/asc-api.sh
. "$ROOT/Scripts/asc-api.sh"

# The values that identify the account, for scrubbing anything Apple says
# back before it reaches a log or the comment. Exported for the Python below.
export SCRUB_VALUES="${ASC_VENDOR_NUMBER:-} ${ASC_KEY_ID:-} ${ASC_ISSUER_ID:-} ${ASC_REPORTS_KEY_ID:-} ${ASC_REPORTS_ISSUER_ID:-}"

# --- 1. Seen-state from the issue --------------------------------------------
# Status tested directly (masked-exit-status rule): a failed listing is an
# error, never "no comments yet" -- that would re-post every review.
STATE="$WORK/seen"
TRUSTED="${DIGEST_TRUSTED_AUTHORS:-github-actions[bot] ${REPO%%/*}}"
# Each login is spliced into the jq filter below, so each must be a plain
# GitHub login; the filter is built only from logins that passed.
# Globbing off for the split: `[bot]` is a bracket pattern, and a file
# named github-actionsb in the working directory would replace the login.
FILTER=""
set -f
for login in $TRUSTED; do
    printf '%s' "$login" | grep -Eq '^[A-Za-z0-9-]+(\[bot\])?$' \
        || die "DIGEST_TRUSTED_AUTHORS must hold GitHub logins, got '$login'"
    FILTER="${FILTER:+$FILTER or }.user.login == \"$login\""
done
set +f
[ -n "$FILTER" ] || die "DIGEST_TRUSTED_AUTHORS is empty; no comment could be trusted"
if bodies="$(gh api "repos/$REPO/issues/$ISSUE/comments?per_page=100" --paginate \
        --jq ".[] | select($FILTER) | .body")"; then
    printf '%s\n' "$bodies" | grep -o '<!-- review-id: [^ ]* -->' \
        | sed 's/<!-- review-id: \(.*\) -->/\1/' > "$STATE" || :
else
    die "could not read the tracking issue $REPO#$ISSUE; nothing posted"
fi
export STATE

asc_token

# --- 2. Diagnostics (fails the run) -------------------------------------------
resp="$(api GET "$API/v1/apps/$APP_ID/appStoreVersions?filter%5Bplatform%5D=IOS&limit=50")" \
    || die "could not list the app's versions; nothing posted"
printf '%s' "$resp" > "$WORK/versions.json"
more="$(json "(d.get('links') or {}).get('next') or ''" < "$WORK/versions.json")" \
    || die "could not read the version list"
[ -z "$more" ] || die "the app has more than 50 iOS versions; this reads one page and will not call the rest absent"
# Live on the store: appVersionState READY_FOR_DISTRIBUTION. The deprecated
# appStoreState says READY_FOR_SALE for the same versions (measured
# 2026-11-23, all six); it is the fallback only for a version that carries no
# appVersionState at all, should Apple ever drop the field from a response.
json "[f'{v[\"id\"]} {v[\"attributes\"][\"versionString\"]}' for v in d['data'] if (v['attributes'].get('appVersionState') or ('READY_FOR_DISTRIBUTION' if v['attributes'].get('appStoreState') == 'READY_FOR_SALE' else '')) == 'READY_FOR_DISTRIBUTION']" \
    < "$WORK/versions.json" > "$WORK/live" || die "could not read the version list"

: > "$WORK/diag-manifest"
n=0
while read -r vid vstr; do
    [ -n "$vid" ] || continue
    n=$((n + 1))
    api GET "$API/v1/appStoreVersions/$vid/build" > "$WORK/build-$n.json" \
        || die "could not read the build of version $vstr; nothing posted"
    bid="$(json "(d.get('data') or {}).get('id') or ''" < "$WORK/build-$n.json")" \
        || die "could not read the build of version $vstr"
    if [ -n "$bid" ]; then
        api GET "$API/v1/builds/$bid/diagnosticSignatures?limit=200" > "$WORK/sigs-$n.json" \
            || die "could not read the diagnostic signatures of version $vstr; nothing posted"
        ASC_ACCEPT="application/vnd.apple.xcode-metrics+json" \
            api GET "$API/v1/builds/$bid/perfPowerMetrics" > "$WORK/perf-$n.json" \
            || die "could not read the power and performance metrics of version $vstr; nothing posted"
    fi
    printf '%s\t%s\n' "$n" "$vstr" >> "$WORK/diag-manifest"
done < "$WORK/live"
ASC_ACCEPT="application/vnd.apple.xcode-metrics+json" \
    api GET "$API/v1/apps/$APP_ID/perfPowerMetrics" > "$WORK/perf-app.json" \
    || die "could not read the app's power and performance metrics; nothing posted"

# --- 3. Customer reviews (fails the run) --------------------------------------
# Newest first. Page on only while a page still holds something unseen: the
# pages after one that is all seen are older still, so all seen too.
url="$API/v1/apps/$APP_ID/customerReviews?sort=-createdDate&limit=200"
pages=0
while [ -n "$url" ]; do
    pages=$((pages + 1))
    [ "$pages" -le 20 ] || die "more than 20 pages of unseen reviews; refusing to guess which to post"
    api GET "$url" > "$WORK/reviews-$pages.json" || die "could not read the customer reviews; nothing posted, nothing marked seen"
    fresh="$(json "any(r['id'] not in set(open(env['STATE']).read().split()) for r in d['data'])" < "$WORK/reviews-$pages.json")" \
        || die "could not read the customer reviews"
    url=""
    if [ "$fresh" = True ]; then
        url="$(json "(d.get('links') or {}).get('next') or ''" < "$WORK/reviews-$pages.json")" \
            || die "could not read the customer reviews"
    fi
done

# --- Helpers for the two owner-gated parts ------------------------------------
# A gated part that cannot run writes its reason to $WORK/<part>.skip and
# nothing else. The reason never carries an id: a refused request is reduced
# to its HTTP status and Apple's message, scrubbed.
reason_from() { # stderr-file -- prints a one-line reason
    python3 - "$1" <<'PY'
import json, os, re, sys
text = open(sys.argv[1], errors="replace").read()
m = re.search(r"-> HTTP (\d+)", text)
reason = f"HTTP {m.group(1)}" if m else "the request failed before Apple answered"
start = text.find("{")
if m and start >= 0:
    try:
        err = (json.loads(text[start:text.rfind("}") + 1]).get("errors") or [{}])[0]
        said = " ".join(x for x in (err.get("code"), err.get("detail") or err.get("title")) if x)
        if said:
            reason += f" {said}"
    except ValueError:
        pass
for v in os.environ.get("SCRUB_VALUES", "").split():
    if len(v) >= 3:
        reason = reason.replace(v, "[redacted]")
print(" ".join(reason.split())[:300])
PY
}

GATED_REASON=""
# gated_get TOKEN URL OUT [ACCEPT] -- 0 with the body in OUT, or 1 with the
# reason in GATED_REASON. Called directly, never inside $(...), so the reason
# survives (docs/learnings/command-substitution-discards-callee-state.md).
gated_get() {
    local TOKEN="$1"
    if ASC_ACCEPT="${4:-}" api GET "$2" > "$3" 2> "$WORK/gated-err"; then return 0; fi
    GATED_REASON="$(reason_from "$WORK/gated-err")"
    return 1
}

# A presigned download (analytics segments): a plain GET with no Authorization,
# which S3 would refuse alongside its own signature.
fetch_url() { # URL OUT
    local code
    if ! code="$(curl -sS --connect-timeout 10 --max-time 300 -X GET -o "$2" -w '%{http_code}' "$1" 2> "$WORK/gated-err")"; then
        GATED_REASON="a report segment download failed before the server answered"
        return 1
    fi
    case "$code" in 2??) return 0 ;; esac
    GATED_REASON="a report segment download answered HTTP $code"
    return 1
}

REPORTS_TOKEN=""
REPORTS_MISSING=""
REPORTS_KEY_BAD=""
for v in ASC_REPORTS_KEY_ID ASC_REPORTS_ISSUER_ID; do
    if [ -z "${!v:-}" ]; then REPORTS_MISSING="$REPORTS_MISSING $v"; fi
done
# The private key: a file path, or the secret's text -- the .p8's PEM as
# pasted (what the owner set), or base64 of it like ASC_PRIVATE_KEY.
if [ -z "${ASC_REPORTS_KEY_PATH:-}" ]; then
    if [ -z "${ASC_REPORTS_PRIVATE_KEY:-}" ]; then
        REPORTS_MISSING="$REPORTS_MISSING ASC_REPORTS_PRIVATE_KEY"
    else
        ASC_REPORTS_KEY_PATH="$WORK/reports.p8"
        if ! (umask 077; python3 -c '
import base64, binascii, os, sys
text = os.environ["ASC_REPORTS_PRIVATE_KEY"].strip()
if "-----BEGIN" not in text:
    try:
        text = base64.b64decode("".join(text.split()), validate=True).decode("ascii").strip()
    except (binascii.Error, UnicodeDecodeError):
        sys.exit(1)
if "-----BEGIN" not in text:
    sys.exit(1)
open(sys.argv[1], "w").write(text + "\n")' "$ASC_REPORTS_KEY_PATH"); then
            REPORTS_KEY_BAD=1
        fi
    fi
fi
REPORTS_MISSING="${REPORTS_MISSING# }"
if [ -z "$REPORTS_MISSING" ] && [ -z "$REPORTS_KEY_BAD" ]; then
    if ! REPORTS_TOKEN="$(ASC_KEY_ID="$ASC_REPORTS_KEY_ID" ASC_ISSUER_ID="$ASC_REPORTS_ISSUER_ID" \
            ASC_KEY_PATH="$ASC_REPORTS_KEY_PATH" "$ASC_JWT" 2> "$WORK/mint-err")"; then
        REPORTS_TOKEN=""
    elif [ -n "${GITHUB_ACTIONS:-}" ]; then
        echo "::add-mask::$REPORTS_TOKEN"
    fi
fi

# --- 4. App Analytics (skipped with a reason, never fails the run) -------------
analytics() {
    local rid cat rep iid seg i=0
    if [ -n "$REPORTS_MISSING" ]; then
        echo "the Sales and Reports key is not configured (secrets not set: $REPORTS_MISSING)" > "$WORK/analytics.skip"; return 0
    fi
    if [ -n "$REPORTS_KEY_BAD" ]; then
        echo "ASC_REPORTS_PRIVATE_KEY is set but is neither the .p8's PEM text nor base64 of it" > "$WORK/analytics.skip"; return 0
    fi
    if [ -z "$REPORTS_TOKEN" ]; then
        echo "could not mint a token from the Sales and Reports key; check ASC_REPORTS_PRIVATE_KEY" > "$WORK/analytics.skip"; return 0
    fi
    if ! gated_get "$REPORTS_TOKEN" "$API/v1/apps/$APP_ID/analyticsReportRequests?filter%5BaccessType%5D=ONGOING&limit=50" "$WORK/an-requests.json"; then
        echo "Apple refused the report request listing: $GATED_REASON" > "$WORK/analytics.skip"; return 0
    fi
    if ! rid="$(json "([r['id'] for r in d['data'] if not r['attributes'].get('stoppedDueToInactivity')] or [''])[0]" < "$WORK/an-requests.json")"; then
        echo "could not read Apple's report request listing" > "$WORK/analytics.skip"; return 0
    fi
    if [ -z "$rid" ]; then
        echo "no active ONGOING analytics report request exists yet (an Admin creates it once; Apple then needs 1-2 days)" > "$WORK/analytics.skip"; return 0
    fi
    : > "$WORK/an-manifest"
    for cat in APP_STORE_ENGAGEMENT APP_USAGE; do
        if ! gated_get "$REPORTS_TOKEN" "$API/v1/analyticsReportRequests/$rid/reports?filter%5Bcategory%5D=$cat&limit=200" "$WORK/an-reports-$cat.json"; then
            echo "Apple refused the $cat report listing: $GATED_REASON" > "$WORK/analytics.skip"; return 0
        fi
        if ! json "[f'{r[\"id\"]}\t{r[\"attributes\"][\"name\"]}' for r in d['data'] if r['attributes'].get('name', '').endswith(' Standard')]" \
                < "$WORK/an-reports-$cat.json" > "$WORK/an-pick-$cat"; then
            echo "could not read Apple's $cat report listing" > "$WORK/analytics.skip"; return 0
        fi
        while IFS="$(printf '\t')" read -r rep name; do
            [ -n "$rep" ] || continue
            i=$((i + 1))
            if ! gated_get "$REPORTS_TOKEN" "$API/v1/analyticsReports/$rep/instances?filter%5Bgranularity%5D=WEEKLY&limit=200" "$WORK/an-inst-$i.json"; then
                echo "Apple refused the instance listing of \"$name\": $GATED_REASON" > "$WORK/analytics.skip"; return 0
            fi
            if ! iid="$(json "(sorted(d['data'], key=lambda x: x['attributes'].get('processingDate') or '') or [{'id': ''}])[-1]['id']" < "$WORK/an-inst-$i.json")"; then
                echo "could not read the instances of \"$name\"" > "$WORK/analytics.skip"; return 0
            fi
            printf '%s\t%s\t%s\n' "$i" "$name" "$iid" >> "$WORK/an-manifest"
            [ -n "$iid" ] || continue
            if ! gated_get "$REPORTS_TOKEN" "$API/v1/analyticsReportInstances/$iid/segments?limit=200" "$WORK/an-seg-$i.json"; then
                echo "Apple refused the segments of \"$name\": $GATED_REASON" > "$WORK/analytics.skip"; return 0
            fi
            if ! json "[s['attributes']['url'] for s in d['data']]" < "$WORK/an-seg-$i.json" > "$WORK/an-urls-$i"; then
                echo "could not read the segments of \"$name\"" > "$WORK/analytics.skip"; return 0
            fi
            seg=0
            mkdir -p "$WORK/an-data-$i"
            while read -r u; do
                [ -n "$u" ] || continue
                seg=$((seg + 1))
                if ! fetch_url "$u" "$WORK/an-data-$i/$seg"; then
                    echo "$GATED_REASON (\"$name\")" > "$WORK/analytics.skip"; return 0
                fi
            done < "$WORK/an-urls-$i"
        done < "$WORK/an-pick-$cat"
    done
    if [ "$i" = 0 ]; then
        echo "the report request has no Standard engagement or usage reports yet (Apple needs 1-2 days after the request)" > "$WORK/analytics.skip"
    fi
}
analytics

# --- 5. Sales and Trends (skipped with a reason, never fails the run) ----------
# Weekly reports run Monday to Sunday and are dated by their Sunday. Try the
# most recent Sunday before today, then the one before it: the newest week
# may not be published yet when this runs on a Monday.
sales() {
    local tok="$TOKEN" which="the everyday key" d
    if [ -z "${ASC_VENDOR_NUMBER:-}" ]; then
        echo "the vendor number is not configured (secret not set: ASC_VENDOR_NUMBER)" > "$WORK/sales.skip"; return 0
    fi
    case "$ASC_VENDOR_NUMBER" in *[!0-9]*)
        echo "ASC_VENDOR_NUMBER is set but is not a number" > "$WORK/sales.skip"; return 0 ;;
    esac
    if [ -n "$REPORTS_TOKEN" ]; then tok="$REPORTS_TOKEN"; which="the Sales and Reports key"; fi
    for d in $(python3 -c '
import datetime, sys
t = datetime.date.fromisoformat(sys.argv[1])
s = t - datetime.timedelta(days=(t.weekday() + 1) % 7 or 7)
print(s, s - datetime.timedelta(days=7))' "$TODAY"); do
        if gated_get "$tok" "$API/v1/salesReports?filter%5Bfrequency%5D=WEEKLY&filter%5BreportType%5D=SALES&filter%5BreportSubType%5D=SUMMARY&filter%5Bversion%5D=1_1&filter%5BreportDate%5D=$d&filter%5BvendorNumber%5D=$ASC_VENDOR_NUMBER" \
                "$WORK/sales.gz" "application/a-gzip"; then
            echo "$which" > "$WORK/sales.key"
            return 0
        fi
        case "$GATED_REASON" in "HTTP 404"*) continue ;; esac
        break
    done
    echo "Apple refused the weekly sales summary with $which: $GATED_REASON" > "$WORK/sales.skip"
}
sales

# --- 6. Compose ----------------------------------------------------------------
# Plain command with stdout redirected, NOT inside $(...): bash 3.2 scans a
# heredoc inside a command substitution for quotes
# (docs/learnings/bash32-heredoc-inside-command-substitution.md).
WORK="$WORK" LIMIT="$LIMIT" BYTES="$BYTES" TODAY="$TODAY" API="$API" python3 - > "$WORK/counts" <<'PY' \
  || die "could not compose the digest; nothing posted"
import csv, glob, gzip, io, json, os

W = os.environ["WORK"]
limit = int(os.environ["LIMIT"])
budget = int(os.environ["BYTES"])
API = os.environ["API"]
scrub = [v for v in os.environ.get("SCRUB_VALUES", "").split() if len(v) >= 3]

def load(name):
    with open(os.path.join(W, name)) as f:
        return json.load(f)

def safe(text):
    # Untrusted text (a reviewer's words, a symbol name) must not become
    # structure: no HTML comment (a forged review-id marker would mark a
    # review seen), no tags, no @mentions that notify a stranger.
    text = str(text or "")
    for v in scrub:
        text = text.replace(v, "[redacted]")
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("@", "@​")

def plural(n, word):
    return f"{n} {word}{'' if n == 1 else 's'}"

# Diagnostics.
diag, empty = [], True
versions = []
with open(os.path.join(W, "diag-manifest")) as f:
    for line in f:
        n, vstr = line.rstrip("\n").split("\t", 1)
        versions.append((n, vstr))
app_perf = load("perf-app.json")

def perf_line(p):
    data = p.get("productData") or []
    regs = (p.get("insights") or {}).get("regressions") or []
    if not data and not regs:
        return None
    out = f"metrics: {plural(len(data), 'product data set')}, {plural(len(regs), 'regression')}"
    names = [safe(r.get("summaryString") or r.get("metric") or "") for r in regs[:3]]
    names = [x for x in names if x]
    return out + (f" ({'; '.join(names)})" if names else "")

names = []
for n, vstr in versions:
    build = (load(f"build-{n}.json").get("data") or {})
    if not build:
        diag.append(f"- **{safe(vstr)}**: no build attached")
        names.append(safe(vstr))
        continue
    bnum = safe((build.get("attributes") or {}).get("version") or "?")
    names.append(f"{safe(vstr)} (build {bnum})")
    sigs = load(f"sigs-{n}.json")
    rows = sigs.get("data") or []
    perf = perf_line(load(f"perf-{n}.json"))
    if rows or perf:
        empty = False
    bytype = {}
    for r in rows:
        t = r["attributes"].get("diagnosticType") or "UNKNOWN"
        bytype[t] = bytype.get(t, 0) + 1
    head = ", ".join(f"{safe(t)} {c}" for t, c in sorted(bytype.items())) or "no signatures"
    more = " (more on Apple's next page, not counted)" if (sigs.get("links") or {}).get("next") else ""
    diag.append(f"- **{safe(vstr)}** (build {bnum}): {head}{more}; {perf or 'no metrics'}")
    top = sorted(rows, key=lambda r: -(r["attributes"].get("weight") or 0))[:5]
    for r in top:
        a = r["attributes"]
        diag.append(f"  - {safe(a.get('diagnosticType'))}, weight {a.get('weight')}: `{safe(a.get('signature')).replace('`', chr(39))}`"
                    f" -- logs: `GET {API}/v1/diagnosticSignatures/{safe(r['id'])}/logs`")
app_line = perf_line(app_perf)
if app_line:
    empty = False
    diag.append(f"- whole app: {app_line}")
if not versions:
    diag_text = "**Diagnostics:** no App Store version is live (READY_FOR_DISTRIBUTION), so there is nothing to read.\n"
elif empty:
    diag_text = (f"**Diagnostics:** nothing yet. 0 diagnostic signatures and no power or performance data for "
                 f"{', '.join(names)}. Apple reports only from devices whose owners opted in, so empty means too few "
                 f"opted-in devices so far, not no crashes.\n")
else:
    diag_text = "**Diagnostics** (live versions; top signatures by weight):\n\n" + "\n".join(diag) + "\n"

# Analytics.
def table(path):
    raw = open(path, "rb").read()
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    return list(csv.DictReader(io.StringIO(raw.decode("utf-8", "replace")), delimiter="\t"))

def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None

def fmt(x):
    return str(int(x)) if x == int(x) else f"{x:.1f}"

skip = os.path.join(W, "analytics.skip")
if os.path.exists(skip):
    an_text = f"**App Analytics:** skipped: {safe(open(skip).read().strip())}.\n"
else:
    lines = []
    with open(os.path.join(W, "an-manifest")) as f:
        for line in f:
            i, name, iid = line.rstrip("\n").split("\t")
            if not iid:
                lines.append(f"- {safe(name)}: no weekly instance yet")
                continue
            rows = []
            for p in sorted(glob.glob(os.path.join(W, f"an-data-{i}", "*"))):
                rows += table(p)
            if not rows:
                lines.append(f"- {safe(name)}: no rows this week")
                continue
            dates = sorted({r.get("Date") for r in rows if r.get("Date")})
            span = f"{dates[0]} to {dates[-1]}" if dates else "latest week"
            if "Event" in rows[0] and "Counts" in rows[0]:
                tot = {}
                for r in rows:
                    tot[r["Event"]] = tot.get(r["Event"], 0) + (num(r["Counts"]) or 0)
                parts = [f"{safe(k)} {fmt(v)}" for k, v in sorted(tot.items())]
            else:
                parts = []
                for col in rows[0]:
                    low = col.lower()
                    if any(w in low for w in ("date", "identifier", "version", " id")) or low == "id":
                        continue
                    vals = [num(r.get(col)) for r in rows if (r.get(col) or "") != ""]
                    if vals and all(v is not None for v in vals):
                        parts.append(f"{safe(col)} {fmt(sum(vals))}")
            lines.append(f"- {safe(name)} ({span}): {', '.join(parts) or 'no numeric columns'}")
    an_text = "**App Analytics** (latest weekly instance, totals):\n\n" + "\n".join(lines) + "\n"

# Sales: unit counts only. Proceeds, prices and currencies are never read
# into the comment -- the issue is public.
skip = os.path.join(W, "sales.skip")
if os.path.exists(skip):
    sales_text = f"**Sales and Trends:** skipped: {safe(open(skip).read().strip())}.\n"
else:
    rows = table(os.path.join(W, "sales.gz"))
    kinds = {"downloads": 0, "re-downloads": 0, "updates": 0, "other units": 0}
    begin, end = set(), set()
    for r in rows:
        t = (r.get("Product Type Identifier") or "").strip().upper()
        u = num(r.get("Units")) or 0
        if t in ("1", "1F", "1T", "F1"):
            kinds["downloads"] += u
        elif t in ("3", "3F", "3T", "F3"):
            kinds["re-downloads"] += u
        elif t in ("7", "7F", "7T", "F7"):
            kinds["updates"] += u
        else:
            kinds["other units"] += u
        if r.get("Begin Date"): begin.add(r["Begin Date"])
        if r.get("End Date"): end.add(r["End Date"])
    span = f"{min(begin)} to {max(end)}" if begin and end else "latest week"
    sales_text = (f"**Sales and Trends** (week {safe(span)}, units only): "
                  + ", ".join(f"{fmt(v)} {k}" for k, v in kinds.items()) + ".\n")

# Reviews: every unseen one across the fetched pages, oldest first.
seen = set(open(os.environ["STATE"]).read().split())
new, ids = [], set()
for p in sorted(glob.glob(os.path.join(W, "reviews-*.json")), key=lambda x: int(x.rsplit("-", 1)[1][:-5])):
    for r in load(os.path.basename(p))["data"]:
        if r["id"] not in seen and r["id"] not in ids:
            ids.add(r["id"])
            new.append(r)
new.sort(key=lambda r: r["attributes"].get("createdDate") or "")

def review(r):
    a = r["attributes"]
    rating = int(a.get("rating") or 0)
    body = (a.get("body") or "").strip()
    if len(body) > 4000:
        body = body[:4000] + " ... (truncated)"
    quoted = "\n".join("  > " + safe(l) for l in body.splitlines()) or "  > (no text)"
    return (f"- {'★' * rating}{'☆' * (5 - rating)} {rating}/5, {safe(a.get('territory'))}, "
            f"{safe((a.get('createdDate') or '')[:10])}: **{safe(a.get('title')) or '(untitled)'}**\n{quoted}\n")

def compose(kept, deferred):
    out = [f"### Apple insights, {os.environ['TODAY']}\n\n", diag_text, "\n"]
    if kept:
        out.append(f"**Customer reviews:** {plural(len(kept), 'new review')}\n\n")
        out += [review(r) for r in kept]
    else:
        out.append("**Customer reviews:** none new.\n")
    if deferred:
        out.append(f"\n_{plural(deferred, 'more review')} waiting; the next run posts them._\n")
    out += ["\n", an_text, "\n", sales_text]
    out += [f"\n<!-- review-id: {r['id']} -->" for r in kept]
    return "".join(out) + "\n"

kept = []
for r in new[:limit]:
    if len(compose(kept + [r], len(new) - len(kept) - 1).encode()) > budget:
        break
    kept.append(r)
text = compose(kept, len(new) - len(kept))
if len(text.encode()) > budget:
    raise SystemExit(f"the digest is {len(text.encode())} bytes with no reviews in it, over DIGEST_BYTES={budget}")
with open(os.path.join(W, "body.md"), "w") as f:
    f.write(text)
print(len(kept), len(new) - len(kept))
PY
counts="$(cat "$WORK/counts")"
kept="${counts% *}"; deferred="${counts#* }"

# --- 7. Post: the output and the seen-state write in one step ------------------
if ! poster="$(gh api -X POST "repos/$REPO/issues/$ISSUE/comments" -F body=@"$WORK/body.md" --jq .user.login)"; then
    die "could not post the digest to $REPO#$ISSUE; nothing was marked seen"
fi
# The markers just posted count only if the next run trusts this login. One
# outside the set would re-post the same reviews every week, so say so.
case " $TRUSTED " in
    *" $poster "*) ;;
    *) die "the digest was posted as '$poster', which is not in DIGEST_TRUSTED_AUTHORS ('$TRUSTED'); the next run will not see its markers -- add '$poster' to it" ;;
esac
echo "Posted the Apple insights digest to $REPO#$ISSUE ($kept new review(s), $deferred deferred):"
cat "$WORK/body.md"
