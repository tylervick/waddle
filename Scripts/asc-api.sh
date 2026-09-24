#!/bin/bash
# App Store Connect API client shared by the scripts that write the App Store
# listing: Scripts/upload-screenshots.sh and Scripts/update-store-listing.sh.
# SOURCED, not run. One copy, so a fix to the retry or parsing rules reaches
# every writer at once instead of drifting between two.
#
# The caller must define, before sourcing:
#   ROOT   the repository root
#   WORK   a private temp directory (responses are written there)
#   die    a function that prints its arguments as an error and exits
#
# Env (all optional):
#   ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH   for Scripts/asc-jwt.sh
#   ASC_JWT              override the JWT minter (tests use this)
#   ASC_APP_ID           override the App Store Connect app id
#   API_RETRIES          429 retries before failing (default 4)
#   API_RETRY_MAX_SLEEP  cap on one Retry-After wait, seconds (default 120)

API="https://api.appstoreconnect.apple.com"
APP_ID="${ASC_APP_ID:-6792905089}"
ASC_JWT="${ASC_JWT:-$ROOT/Scripts/asc-jwt.sh}"
export LOCALE="en-US"
# App Store Connect rate-limits per key and answers 429 with Retry-After.
RETRIES="${API_RETRIES:-4}"
RETRY_MAX_SLEEP="${API_RETRY_MAX_SLEEP:-120}"

# Version states in which Apple allows a version's listing to be edited.
EDITABLE_STATES=" PREPARE_FOR_SUBMISSION DEVELOPER_REJECTED REJECTED METADATA_REJECTED "

# Every numeric knob feeds a `[ -le ]`/`-lt` comparison or `sleep`. A
# non-integer there makes the test error instead of answering, and an erroring
# bound is a loop that never stops -- so refuse it before any network call.
asc_require_int() { # NAME VALUE
    case "$2" in
        ''|*[!0-9]*) echo "error: $1 must be a non-negative integer, got '$2'" >&2; exit 2 ;;
    esac
}
asc_require_int API_RETRIES "$RETRIES"
asc_require_int API_RETRY_MAX_SLEEP "$RETRY_MAX_SLEEP"

asc_token() { # sets TOKEN
    TOKEN="$("$ASC_JWT")" || die "could not mint an App Store Connect API token"
    if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::add-mask::$TOKEN"; fi
}

# Seconds to wait from a response-header file's Retry-After, as an integer;
# prints nothing when there is no usable value.
retry_after_seconds() { # headers-file
    python3 - "$1" <<'PY'
import email.utils, sys, time
for line in open(sys.argv[1], errors="replace"):
    name, _, value = line.partition(":")
    if name.strip().lower() != "retry-after":
        continue
    value = value.strip()
    if value.isdigit():
        print(int(value))
    else:
        try:
            when = email.utils.parsedate_to_datetime(value).timestamp()
        except (TypeError, ValueError):
            break
        print(max(0, int(when - time.time() + 0.999)))
    break
PY
}

# api METHOD URL [BODY_JSON] -- response body on stdout. The HTTP status is
# checked here and never masked: a non-2xx prints Apple's error document and
# fails, so a failed call can never be read as an empty answer. A 429 is the
# one status retried: Apple is saying "later", and says when in Retry-After.
api() {
    local method="$1" url="$2" body="${3:-}" out="$WORK/resp" hdrs="$WORK/resp-headers" code wait asked n=0
    if [ -n "$body" ]; then printf '%s' "$body" > "$WORK/req"; fi
    while :; do
        rm -f "$out" "$hdrs"
        if [ -n "$body" ]; then
            code="$(curl -sS --connect-timeout 10 --max-time 120 -X "$method" \
                -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
                --data-binary "@$WORK/req" -D "$hdrs" -o "$out" -w '%{http_code}' "$url")" || return 1
        else
            code="$(curl -sS --connect-timeout 10 --max-time 120 -X "$method" \
                -H "Authorization: Bearer $TOKEN" -D "$hdrs" -o "$out" -w '%{http_code}' "$url")" || return 1
        fi
        [ "$code" = 429 ] || break
        n=$((n + 1))
        if [ "$n" -gt "$RETRIES" ]; then
            echo "error: $method $url -> HTTP 429 after $RETRIES retries" >&2
            return 1
        fi
        # Retry-After is delay-seconds or an HTTP-date (RFC 9110 10.2.3); a
        # date becomes the seconds until it. Absent or unparseable waits 30.
        # Either way RETRY_MAX_SLEEP caps it.
        asked="$(retry_after_seconds "$hdrs")" || asked=""
        wait="${asked:-30}"
        [ "$wait" -le "$RETRY_MAX_SLEEP" ] || wait="$RETRY_MAX_SLEEP"
        echo "rate limited on $method $url; retrying in ${wait}s (server asked ${asked:-nothing}${asked:+s}) ($n/$RETRIES)" >&2
        sleep "$wait"
    done
    case "$code" in
        2??) if [ -f "$out" ]; then cat "$out"; fi; return 0 ;;
        *) echo "error: $method $url -> HTTP $code" >&2
           if [ -f "$out" ]; then cat "$out" >&2; fi
           echo >&2
           return 1 ;;
    esac
}

# jq-free JSON reads. Each exits non-zero on a parse failure or a missing
# field, which aborts the caller: an unparseable answer is never "none".
# The expression is always a literal written in the calling script. Any VALUE
# it needs (a version, an id from an API response) is read from `env`, never
# spliced into the expression text: an id containing a quote must stay data.
json() { # python-expression-over-d-and-env -- reads the document on stdin
    python3 -c '
import json, os, sys
d = json.load(sys.stdin)
r = eval(sys.argv[1], {"d": d, "env": os.environ})
if isinstance(r, list):
    for x in r: print(x)
elif r is not None:
    print(r)
' "$1"
}

# Resolves the iOS version named by $VERSION into VERSION_ID and VERSION_STATE
# (both exported), leaving the app's version list in $WORK/versions.json, and
# dies unless the version is editable. PURPOSE names what the caller wants to
# change, for the refusal message.
asc_resolve_editable_version() { # PURPOSE
    local resp row
    resp="$(api GET "$API/v1/apps/$APP_ID/appStoreVersions?filter%5Bplatform%5D=IOS&limit=50")" \
        || die "could not list the app's versions"
    printf '%s' "$resp" > "$WORK/versions.json"
    row="$(json "[f'{v[\"id\"]} {v[\"attributes\"].get(\"appVersionState\") or v[\"attributes\"].get(\"appStoreState\")}' for v in d['data'] if v['attributes']['versionString'] == env['VERSION']]" < "$WORK/versions.json")" \
        || die "could not read the version list"
    if [ -z "$row" ]; then
        echo "error: no iOS version $VERSION on App Store Connect -- create it first. It has:" >&2
        json "[f'  {v[\"attributes\"][\"versionString\"]} ({v[\"attributes\"].get(\"appVersionState\") or v[\"attributes\"].get(\"appStoreState\")})' for v in d['data']] or ['  (no versions)']" \
            < "$WORK/versions.json" >&2 || echo "  (and the list could not be read)" >&2
        exit 1
    fi
    read -r VERSION_ID VERSION_STATE <<EOF
$row
EOF
    export VERSION_ID VERSION_STATE
    case "$EDITABLE_STATES" in
        *" $VERSION_STATE "*) ;;
        *) die "version $VERSION is $VERSION_STATE; its $1 cannot be edited" ;;
    esac
    echo "ok - version $VERSION ($VERSION_ID) is $VERSION_STATE"
}

# The version's en-US localization id, or nothing when it has none.
asc_localization_id() { # version-id
    local r
    r="$(api GET "$API/v1/appStoreVersions/$1/appStoreVersionLocalizations?limit=50")" || return 1
    printf '%s' "$r" | json "[l['id'] for l in d['data'] if l['attributes']['locale'] == env['LOCALE']]"
}
