#!/bin/bash
# Prints NEW TestFlight beta feedback (screenshot + crash submissions) as
# markdown, tracking already-seen submission ids in a state file so each run
# shows only what arrived since the last one.
#
# Usage:
#   Scripts/fetch-testflight-feedback.sh                 print new feedback
#   Scripts/fetch-testflight-feedback.sh --download DIR  also save each new
#       submission's raw JSON to DIR/<id>.json and download any screenshot
#       images to DIR/<id>-<n>.png
#
# Env:
#   ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH   for Scripts/asc-jwt.sh
#   ASC_JWT          override the JWT minter (tests use this)
#   FEEDBACK_STATE   override the state file (default: <repo>/.testflight-feedback-seen)
#
# The state file is APPENDED ONLY AFTER all output for the run has been
# printed: a failed run must leave it untouched so the next run re-surfaces
# the same submissions instead of silently swallowing them. Same discipline
# as docs/learnings/masked-exit-status-fails-open.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

API="https://api.appstoreconnect.apple.com"
BUNDLE_ID="com.tylervick.waddle"
ASC_JWT="${ASC_JWT:-$ROOT/Scripts/asc-jwt.sh}"
STATE_FILE="${FEEDBACK_STATE:-$ROOT/.testflight-feedback-seen}"

DOWNLOAD_DIR=""
if [ "${1:-}" = "--download" ]; then
    DOWNLOAD_DIR="${2:?usage: $0 [--download DIR]}"
    mkdir -p "$DOWNLOAD_DIR"
elif [ -n "${1:-}" ]; then
    echo "usage: $0 [--download DIR]" >&2; exit 2
fi

TOKEN="$("$ASC_JWT")" \
  || { echo "error: could not mint an App Store Connect API token" >&2; exit 1; }
if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::add-mask::$TOKEN"; fi

api_get() { # absolute-url -- status tested directly, never masked; explicit
            # timeouts so a stalled connection cannot hang the run
    curl -sS -f --connect-timeout 10 --max-time 120 \
        -H "Authorization: Bearer $TOKEN" "$1"
}

# Resolve the app id from the bundle id (same two-step as whats-to-test.sh:
# curl status first, parse second, so a failed call never reads as empty).
APPS_RESP="$(api_get "$API/v1/apps?filter%5BbundleId%5D=$BUNDLE_ID")" \
  || { echo "error: could not resolve the app id for $BUNDLE_ID" >&2; exit 1; }
APP_ID="$(printf '%s' "$APPS_RESP" | python3 -c '
import json, sys
items = json.load(sys.stdin).get("data") or []
if not items: sys.exit(3)
print(items[0]["id"])
')" || { echo "error: no app matching $BUNDLE_ID (or unparseable response)" >&2; exit 1; }

# links.next from a response document; empty when there is none. A parse
# failure exits non-zero and aborts the caller (masked-exit-status rule).
next_link() { # response
    printf '%s' "$1" | python3 -c '
import json, sys
print((json.load(sys.stdin).get("links") or {}).get("next") or "")
'
}

PAGES_DIR="$(mktemp -d)"
trap 'rm -rf "$PAGES_DIR"' EXIT

# Walks links.next until exhausted, one file per page: a backlog larger than
# one page must not be silently dropped -- unseen submissions beyond page one
# would otherwise never surface, since only rendered ids become "seen".
fetch_all() { # first-url, file-prefix
    url="$1"; n=0
    while [ -n "$url" ]; do
        n=$((n + 1))
        resp="$(api_get "$url")" || return 1
        printf '%s' "$resp" > "$PAGES_DIR/$2-$n.json"
        url="$(next_link "$resp")" || return 1
    done
}

fetch_all "$API/v1/apps/$APP_ID/betaFeedbackScreenshotSubmissions?limit=50" shots \
  || { echo "error: could not fetch screenshot feedback" >&2; exit 1; }
fetch_all "$API/v1/apps/$APP_ID/betaFeedbackCrashSubmissions?limit=50" crash \
  || { echo "error: could not fetch crash feedback" >&2; exit 1; }

[ -f "$STATE_FILE" ] || : > "$STATE_FILE"

# One python pass renders the markdown for every UNSEEN submission, writes
# per-submission JSON into DOWNLOAD_DIR when set, emits the list of image
# URLs to fetch on fd 3, and the list of newly-seen ids on fd 4. Ids only
# reach the state file after this whole pipeline has succeeded.
RENDER_OUT="$(mktemp)"; URLS_OUT="$(mktemp)"; IDS_OUT="$(mktemp)"
trap 'rm -f "$RENDER_OUT" "$URLS_OUT" "$IDS_OUT"; rm -rf "$PAGES_DIR"' EXIT

PAGES="$PAGES_DIR" STATE_PATH="$STATE_FILE" DL_DIR="$DOWNLOAD_DIR" \
python3 - 3>"$URLS_OUT" 4>"$IDS_OUT" >"$RENDER_OUT" <<'PY'
import glob, json, os, sys

seen = set()
with open(os.environ["STATE_PATH"]) as f:
    seen = {line.strip() for line in f if line.strip()}

dl_dir = os.environ.get("DL_DIR") or None
urls = os.fdopen(3, "w")
ids = os.fdopen(4, "w")

def field(attrs, name):
    v = attrs.get(name)
    return str(v) if v not in (None, "") else "-"

def render(kind, pattern):
    for path in sorted(glob.glob(pattern)):
        with open(path) as f:
            try:
                items = json.load(f).get("data") or []
            except json.JSONDecodeError:
                sys.exit(f"error: unparseable {kind} response")
        for item in items:
            sid = item.get("id", "")
            if not sid or sid in seen:
                continue
            attrs = item.get("attributes") or {}
            print(f"## {kind} {sid}")
            print(f"- created: {field(attrs, 'createdDate')}")
            print(f"- device: {field(attrs, 'deviceModel')} ({field(attrs, 'osVersion')})")
            print(f"- comment: {field(attrs, 'comment')}")
            print()
            if dl_dir:
                with open(os.path.join(dl_dir, f"{sid}.json"), "w") as f:
                    json.dump(item, f, indent=2)
                images = attrs.get("screenshots") or []
                for n, img in enumerate(images, 1):
                    url = (img or {}).get("url")
                    if url:
                        urls.write(f"{dl_dir}/{sid}-{n}.png\t{url}\n")
            ids.write(sid + "\n")

pages = os.environ["PAGES"]
render("Screenshot feedback", os.path.join(pages, "shots-*.json"))
render("Crash feedback", os.path.join(pages, "crash-*.json"))
PY

if [ -s "$RENDER_OUT" ]; then
    cat "$RENDER_OUT"
else
    echo "No new feedback."
fi

# Screenshot downloads: the image URLs are pre-signed and need no auth header.
while IFS=$'\t' read -r dest url; do
    [ -n "$dest" ] || continue
    curl -sS -f --connect-timeout 10 --max-time 120 -o "$dest" "$url" \
      || { echo "error: could not download $url" >&2; exit 1; }
done < "$URLS_OUT"

# Everything succeeded -- only now do the new ids become "seen".
cat "$IDS_OUT" >> "$STATE_FILE"
