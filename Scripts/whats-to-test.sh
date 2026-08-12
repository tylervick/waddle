#!/bin/bash
# Assembles TestFlight "What to Test" notes and attaches them to a build in
# App Store Connect.
#
# Usage:
#   Scripts/whats-to-test.sh --print            assemble and print, no network
#   Scripts/whats-to-test.sh <build-number>      assemble and attach via ASC
#
# The notes are an optional hand-written preamble followed by a changelog
# computed from git. The changelog is DERIVED, not stored, and that is the
# point: a tracked notes file goes stale silently -- it is not empty, so an
# empty-check passes, and the build ships the previous release's text. A
# computed changelog cannot be stale. See
# docs/superpowers/specs/2026-08-11-whats-to-test-design.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PREAMBLE_FILE="docs/app-store/whats-to-test.md"

API="https://api.appstoreconnect.apple.com"
BUNDLE_ID="com.tylervick.waddle"
# Overridable so the hermetic suite never really sleeps.
POLL_ATTEMPTS="${WHATS_TO_TEST_POLL_ATTEMPTS:-30}"
POLL_DELAY="${WHATS_TO_TEST_POLL_DELAY:-30}"
ASC_JWT="${ASC_JWT:-$ROOT/Scripts/asc-jwt.sh}"

# One bullet per change. For a GitHub merge commit the useful title is the
# FIRST LINE OF THE BODY -- git's own subject is "Merge pull request #N from
# owner/branch", which tells a tester nothing. Direct commits use their
# subject. Both shapes occur in this repo.
changelog() { # range (may be empty, meaning "recent history")
    range="$1"
    while IFS= read -r sha; do
        [ -n "$sha" ] || continue
        subj="$(git log -1 --format=%s "$sha")"
        case "$subj" in
            "Merge pull request #"*)
                num="$(printf '%s' "$subj" | sed -n 's/^Merge pull request #\([0-9][0-9]*\).*/\1/p')"
                title="$(git log -1 --format=%b "$sha" | sed -n '1p')"
                [ -n "$title" ] || title="$subj"
                printf -- '- %s (#%s)\n' "$title" "$num"
                ;;
            *) printf -- '- %s\n' "$subj" ;;
        esac
    done < <(git log --first-parent --format=%H $range)
}

# Assembles the preamble + derived changelog and prints the result to stdout.
# Shared by --print (called directly, so its output goes straight to the
# terminal) and the attach path below (captured via `NOTES="$(assemble_notes)"`
# to build a request body). assemble_notes has no side effects beyond writing
# stdout and its own exit status, so capturing it this way is safe -- see
# docs/learnings/command-substitution-discards-callee-state.md for the
# failure mode this would otherwise risk (it applies to functions that need
# their global writes or their `exit` to reach the caller; this one needs
# neither).
assemble_notes() {
    PREAMBLE=""
    if [ -f "$PREAMBLE_FILE" ]; then
        PREAMBLE="$(sed -e 's/[[:space:]]*$//' "$PREAMBLE_FILE" | sed -e '/./,$!d')"
    fi

    # The most recent build-* tag by version order, not by tag date: build
    # numbers skip when a validate-only run consumes a run number, so lexical
    # or chronological ordering would both pick the wrong anchor.
    #
    # The list command's status is tested directly rather than masked with
    # `2>/dev/null` and read as data: a genuine `git tag` failure (corrupt
    # refs, a shallow or partial checkout) produces the same empty output as
    # "no build tag yet", so masking it would silently route a broken
    # repository into the once-ever bootstrap fallback below and compute the
    # changelog from the last 20 commits instead of the true range -- without
    # saying anything is wrong. See
    # docs/learnings/masked-exit-status-fails-open.md. A real failure here is
    # not the bootstrap condition the fallback exists for, so it fails the
    # run rather than falling back.
    if ! TAG_LIST="$(git tag --list 'build-*' --sort=-v:refname 2>&1)"; then
        echo "error: git tag --list failed; cannot determine the previous build tag." >&2
        printf '%s\n' "$TAG_LIST" >&2
        exit 1
    fi
    TAG="$(printf '%s\n' "$TAG_LIST" | head -1)"

    if [ -n "$TAG" ]; then
        HEADING="Changes since build ${TAG#build-}:"
        BODY="$(changelog "$TAG..HEAD")"
    else
        # Bootstrap: no release has ever been tagged. Failing here would
        # block a release for a condition that is true exactly once, so fall
        # back -- but disclose it, because the range is a guess rather than a
        # fact.
        HEADING="Recent changes (no previous build tag; showing the last 20 commits):"
        BODY="$(changelog "--max-count=20")"
    fi

    if [ -z "$PREAMBLE" ] && [ -z "$BODY" ]; then
        echo "error: no changes since ${TAG:-the start of history} and $PREAMBLE_FILE is empty." >&2
        echo "       Nothing to tell a tester. Write a preamble or ship a build with changes in it." >&2
        exit 1
    fi

    if [ -n "$PREAMBLE" ]; then
        printf '%s\n' "$PREAMBLE"
        [ -n "$BODY" ] && printf '\n'
    fi
    if [ -n "$BODY" ]; then
        printf '%s\n' "$HEADING"
        printf '%s\n' "$BODY"
    fi
}

# Extracts a top-level JSON string field from the first element of `data`.
# python3 stdlib rather than jq: jq is not guaranteed on a runner and this
# script must add no dependencies.
json_first() { # field-path e.g. "id" or "attributes.processingState"
    python3 -c '
import json, sys
doc = json.load(sys.stdin)
items = doc.get("data") or []
if not items:
    sys.exit(3)
cur = items[0]
for part in sys.argv[1].split("."):
    cur = (cur or {}).get(part)
print(cur if cur is not None else "")
' "$1"
}

api_get() { # path
    # Status tested directly, never masked: a failed call must not read as an
    # empty result. See docs/learnings/masked-exit-status-fails-open.md.
    curl -sS -f -H "Authorization: Bearer $TOKEN" "$API$1"
}

# Reads one field from a JSON response that has already been confirmed to
# come from a successful call (i.e. the caller tested api_get's own status
# first -- see api_get above). This function's only remaining job is to
# distinguish json_first's own exit 3, "data is empty" -- the ONE legitimate
# reading of "nothing here yet" -- from any other non-zero exit (malformed
# JSON, an unexpected shape), which is a parse failure and must abort rather
# than be folded into that same "empty" reading. Folding the two together is
# exactly how a failed request reads as a successful empty one: see
# docs/learnings/masked-exit-status-fails-open.md. Prints the field's value
# and returns 0 on success, prints nothing and returns 3 on "no items",
# prints nothing and returns 1 on anything else.
read_json_field() { # response, field-path
    local val rc
    # rc is captured in an explicit `else`, not by reading $? after a
    # bodyless `if`: with no `else` clause, POSIX defines a not-taken `if`'s
    # own exit status as 0 regardless of the condition's real status, which
    # would silently turn every failure here into a false "success".
    #
    # json_first's own stderr (a raw python traceback on malformed input) is
    # discarded, not its exit status -- every caller of this function prints
    # its own purpose-built diagnostic immediately on a non-3 return, so the
    # traceback would only ever precede and obscure that message, never
    # replace the failure signal itself.
    if val="$(printf '%s' "$1" | json_first "$2" 2>/dev/null)"; then
        printf '%s' "$val"
        return 0
    else
        rc=$?
    fi
    [ "$rc" -eq 3 ] && return 3
    return 1
}

# POSTs or PATCHes. `--fail-with-body` (not bare `-f`) so a non-2xx still
# writes Apple's error body -- which explains *why* the write failed (a
# validation error, a conflicting locale, ...) -- rather than throwing that
# reason away and leaving the operator with only "it failed". The body is
# captured rather than streamed straight out, specifically so it can be
# withheld on success (never useful there) and shown only on failure. The
# request body travels over stdin (`--data-binary @-`) rather than as a
# command-line argument, so arbitrarily long or oddly-shaped JSON is never
# reinterpreted by the shell.
api_send() { # method, path, json-body
    local resp
    if resp="$(curl -sS --fail-with-body -X "$1" \
            -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/json" \
            --data-binary @- \
            "$API$2" <<< "$3")"; then
        return 0
    fi
    printf '%s\n' "$resp" >&2
    return 1
}

# Builds the JSON body for creating (no loc-id) or updating (loc-id given) the
# en-US beta build localization. Built with python3's json.dumps rather than
# shell string interpolation: NOTES is release-notes text that can contain
# newlines, quotes, and backslashes verbatim, and passing it through
# json.dumps is what guarantees both that those characters survive intact and
# that the result is syntactically valid JSON -- a naive `"whatsNew": "$NOTES"`
# would corrupt on the first embedded quote or literal newline. Values cross
# into python via the environment (not as `-c` script text) for the same
# reason asc-jwt.sh escapes its claims: nothing here is interpolated into code
# python parses.
loc_body() { # build-id, notes, [loc-id]
    LOC_BUILD_ID="$1" LOC_NOTES="$2" LOC_LOC_ID="${3:-}" python3 -c '
import json, os
build_id = os.environ["LOC_BUILD_ID"]
notes = os.environ["LOC_NOTES"]
loc_id = os.environ.get("LOC_LOC_ID") or None
data = {"type": "betaBuildLocalizations", "attributes": {"whatsNew": notes}}
if loc_id:
    data["id"] = loc_id
else:
    data["attributes"]["locale"] = "en-US"
    data["relationships"] = {"build": {"data": {"type": "builds", "id": build_id}}}
print(json.dumps({"data": data}))
'
}

MODE="${1:---print}"

if [ "$MODE" = "--print" ]; then
    assemble_notes
    exit 0
fi

BUILD="$MODE"
case "$BUILD" in ''|*[!0-9]*) echo "usage: $0 --print | <build-number>" >&2; exit 2 ;; esac

NOTES="$(assemble_notes)" \
  || { echo "error: could not assemble What-to-Test notes for build $BUILD" >&2; exit 1; }
TOKEN="$("$ASC_JWT")" \
  || { echo "error: could not mint an App Store Connect API token for build $BUILD" >&2; exit 1; }

# Two curl calls, not one piped into json_first, so a failed lookup is
# diagnosed by our own clean message rather than by a python traceback from
# json_first choking on the empty stdin a failed `-f` call leaves behind
# (curl's status is tested and handled before json_first ever runs).
APPS_RESP="$(api_get "/v1/apps?filter%5BbundleId%5D=$BUNDLE_ID")" \
  || { echo "error: could not resolve the app id for $BUNDLE_ID (build $BUILD)" >&2; exit 1; }
APP_ID="$(printf '%s' "$APPS_RESP" | json_first id)" \
  || { echo "error: could not parse App Store Connect's response resolving the app id for $BUNDLE_ID (build $BUILD)" >&2; exit 1; }

# Both initialized before the loop, not just STATE: with `set -u`, a
# WHATS_TO_TEST_POLL_ATTEMPTS of 0 or a negative/non-numeric override means
# the loop body below never runs even once, and either variable being
# referenced afterward while still unset would abort with a bare "unbound
# variable" -- naming neither the build nor what went wrong.
STATE=""
BUILD_ID=""
attempt=1
while [ "$attempt" -le "$POLL_ATTEMPTS" ]; do
    RESP="$(api_get "/v1/builds?filter%5Bapp%5D=$APP_ID&filter%5Bversion%5D=$BUILD")" \
      || { echo "error: could not query App Store Connect for build $BUILD" >&2; exit 1; }

    if BUILD_ID="$(read_json_field "$RESP" id)"; then
        :
    else
        rc=$?
        [ "$rc" -eq 3 ] || { echo "error: could not parse App Store Connect's response while polling build $BUILD" >&2; exit 1; }
    fi
    if STATE="$(read_json_field "$RESP" attributes.processingState)"; then
        :
    else
        rc=$?
        [ "$rc" -eq 3 ] || { echo "error: could not parse App Store Connect's response while polling build $BUILD" >&2; exit 1; }
    fi

    [ -n "$BUILD_ID" ] || { echo "error: App Store Connect has no build $BUILD for $BUNDLE_ID" >&2; exit 1; }
    [ "$STATE" = "PROCESSING" ] || break
    attempt=$((attempt + 1))
    [ "$attempt" -le "$POLL_ATTEMPTS" ] && sleep "$POLL_DELAY"
done
if [ -z "$BUILD_ID" ]; then
    echo "error: build $BUILD was never polled -- WHATS_TO_TEST_POLL_ATTEMPTS must be at least 1." >&2
    exit 1
fi
if [ "$STATE" = "PROCESSING" ]; then
    echo "error: build $BUILD is still PROCESSING after $POLL_ATTEMPTS attempts; notes not attached." >&2
    exit 1
fi

# Find an existing en-US localization for this build. Filtered server-side by
# both build and locale, so at most one result is possible and `data: []`
# unambiguously means "none exists yet" -- once the call itself is confirmed
# to have succeeded. That confirmation happens above, on api_get's own exit
# status via `||`, before LOC_RESP is ever treated as data: a failed call
# aborts right here and never reaches the "is it empty" question at all, so
# "no existing localization" and "the request failed" cannot be confused with
# each other. Nor can a malformed-but-200 body: read_json_field's own
# distinction between exit 3 ("no items", benign) and anything else (a parse
# failure) means a garbled response can't be misread as "no localization
# yet" either. See docs/learnings/masked-exit-status-fails-open.md.
LOC_RESP="$(api_get "/v1/betaBuildLocalizations?filter%5Bbuild%5D=$BUILD_ID&filter%5Blocale%5D=en-US")" \
  || { echo "error: could not look up beta build localizations for build $BUILD" >&2; exit 1; }
if LOC_ID="$(read_json_field "$LOC_RESP" id)"; then
    :
else
    rc=$?
    [ "$rc" -eq 3 ] || { echo "error: could not parse App Store Connect's beta build localization response for build $BUILD" >&2; exit 1; }
fi

BODY="$(loc_body "$BUILD_ID" "$NOTES" "$LOC_ID")" \
  || { echo "error: could not build the request body for build $BUILD" >&2; exit 1; }
if [ -n "$LOC_ID" ]; then
    api_send PATCH "/v1/betaBuildLocalizations/$LOC_ID" "$BODY" \
      || { echo "error: failed to update the What-to-Test localization for build $BUILD" >&2; exit 1; }
else
    api_send POST "/v1/betaBuildLocalizations" "$BODY" \
      || { echo "error: failed to create the What-to-Test localization for build $BUILD" >&2; exit 1; }
fi

echo "Attached What-to-Test notes to build $BUILD."
