#!/bin/bash
# Assigns an ALREADY-UPLOADED TestFlight build to a named beta group
# (issue #165): "promote, do not rebuild". It consumes no build number, runs
# no archive and uploads nothing; the bits the external group receives are
# the bits the internal group already tested.
#
# Usage: Scripts/promote-build.sh <build-number> <group-name>
# Env:
#   ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH   for Scripts/asc-jwt.sh
#   ASC_JWT   override the token minter (tests use this)
#
# Exit status names the case, because each wants a different response from
# whoever is at the terminal:
#   0  the build is in the group (assigned now, or already was -- a promotion
#      that is already true is not a failure; the tag may be pushed twice)
#   1  App Store Connect could not be reached or answered unparseably
#   2  usage
#   3  no build with that number exists for this app
#   4  the build exists but its processingState is not VALID (a build still
#      processing cannot be distributed; the silent version of this is a tag
#      that looks like it worked)
#   5  no beta group with that name exists for this app
#   6  the assignment call returned success but the read-back does not show
#      the build in the group (a 2xx is not proof the intended state landed)
#
# Endpoints, checked against Apple's App Store Connect OpenAPI specification
# (openapi.oas.json, 2026-09-30): GET /v1/builds with filter[app],
# filter[version] and filter[betaGroups]; GET /v1/betaGroups with filter[app]
# and filter[name]; POST /v1/builds/{id}/relationships/betaGroups with
# {"data":[{"type":"betaGroups","id":…}]}; processingState is one of
# PROCESSING, FAILED, INVALID, VALID.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

BUILD="${1:-}"; GROUP="${2:-}"
if [ -z "$BUILD" ] || [ -z "$GROUP" ] || [ $# -ne 2 ]; then
    echo "usage: $0 <build-number> <group-name>" >&2; exit 2
fi
case "$BUILD" in ''|*[!0-9]*) echo "error: build number must be digits, got '$BUILD'" >&2; exit 2 ;; esac

API="https://api.appstoreconnect.apple.com"
BUNDLE_ID="com.tylervick.waddle"
ASC_JWT="${ASC_JWT:-$ROOT/Scripts/asc-jwt.sh}"

TOKEN="$("$ASC_JWT")" \
  || { echo "error: could not mint an App Store Connect API token" >&2; exit 1; }
if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::add-mask::$TOKEN"; fi

# Status tested directly, never masked (masked-exit-status rule); explicit
# timeouts so a stalled connection cannot hang the run.
api_get() { # url
    curl -sS -f --connect-timeout 10 --max-time 120 \
        -H "Authorization: Bearer $TOKEN" "$1"
}
api_post() { # url body
    curl -sS -f --connect-timeout 10 --max-time 120 -X POST \
        -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
        --data "$2" "$1"
}
# JSON helpers: a parse failure exits non-zero and aborts the caller.
first_id() { # response -> data[0].id or "" when data is empty
    printf '%s' "$1" | python3 -c '
import json, sys
items = json.load(sys.stdin).get("data") or []
print(items[0]["id"] if items else "")
'
}
count() { # response -> len(data)
    printf '%s' "$1" | python3 -c 'import json, sys; print(len(json.load(sys.stdin).get("data") or []))'
}
attr() { # response name -> data[0].attributes[name]
    printf '%s' "$1" | python3 -c '
import json, sys
items = json.load(sys.stdin).get("data") or []
print(((items[0].get("attributes") or {}).get(sys.argv[1]) or "") if items else "")
' "$2"
}
urlencode() { printf '%s' "$1" | python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe=""))'; }

# 1. The app.
APPS="$(api_get "$API/v1/apps?filter%5BbundleId%5D=$BUNDLE_ID")" \
  || { echo "error: could not resolve the app id for $BUNDLE_ID" >&2; exit 1; }
APP_ID="$(first_id "$APPS")" || { echo "error: unparseable apps response" >&2; exit 1; }
[ -n "$APP_ID" ] || { echo "error: no app matching $BUNDLE_ID" >&2; exit 1; }

# 2. The build, by number. filter[version] is the build number string.
BUILDS="$(api_get "$API/v1/builds?filter%5Bapp%5D=$APP_ID&filter%5Bversion%5D=$BUILD&limit=2")" \
  || { echo "error: could not list builds for $BUNDLE_ID" >&2; exit 1; }
BUILD_ID="$(first_id "$BUILDS")" || { echo "error: unparseable builds response" >&2; exit 1; }
if [ -z "$BUILD_ID" ]; then
    echo "error: build $BUILD does not exist for $BUNDLE_ID (was it ever uploaded?)" >&2; exit 3
fi
STATE="$(attr "$BUILDS" processingState)" || { echo "error: unparseable builds response" >&2; exit 1; }
if [ "$STATE" != "VALID" ]; then
    echo "error: build $BUILD is $STATE, not VALID; a build that is still processing (or failed) cannot be distributed" >&2; exit 4
fi

# 3. The group, by name.
GROUP_RESP="$(api_get "$API/v1/betaGroups?filter%5Bapp%5D=$APP_ID&filter%5Bname%5D=$(urlencode "$GROUP")&limit=2")" \
  || { echo "error: could not list beta groups for $BUNDLE_ID" >&2; exit 1; }
GROUP_ID="$(first_id "$GROUP_RESP")" || { echo "error: unparseable betaGroups response" >&2; exit 1; }
if [ -z "$GROUP_ID" ]; then
    echo "error: no TestFlight group named '$GROUP' exists for $BUNDLE_ID" >&2; exit 5
fi

# 4. Already there? Then there is nothing to do and that is success.
in_group() { # -> 0 when the build is listed in the group
    local resp n
    resp="$(api_get "$API/v1/builds?filter%5Bapp%5D=$APP_ID&filter%5Bversion%5D=$BUILD&filter%5BbetaGroups%5D=$GROUP_ID&limit=2")" \
      || return 2
    n="$(count "$resp")" || return 2
    [ "$n" -gt 0 ]
}
if in_group; then
    echo "build $BUILD is already in '$GROUP'; nothing to do"; exit 0
elif [ $? -eq 2 ]; then
    echo "error: could not check whether build $BUILD is in '$GROUP'" >&2; exit 1
fi

# 5. Assign, then read back: a 2xx is not proof the intended state landed.
BODY="$(printf '{"data":[{"type":"betaGroups","id":"%s"}]}' "$GROUP_ID")"
api_post "$API/v1/builds/$BUILD_ID/relationships/betaGroups" "$BODY" > /dev/null \
  || { echo "error: assigning build $BUILD to '$GROUP' failed" >&2; exit 1; }
if in_group; then
    echo "promoted build $BUILD ($BUILD_ID) to '$GROUP' ($GROUP_ID)"; exit 0
elif [ $? -eq 2 ]; then
    echo "error: assignment returned success but the read-back could not be made" >&2; exit 1
else
    echo "error: assignment returned success but build $BUILD is not listed in '$GROUP'" >&2; exit 6
fi
