#!/bin/bash
# Writes the App Store listing text of one app version -- description, What's
# New, promotional text, keywords, App Review notes -- from the plain-text
# files in docs/app-store/listing/, and optionally selects its build, through
# the App Store Connect API.
#
# Dry run by default: it resolves the version, checks every file against
# Apple's length limits, and prints a diff of what is on App Store Connect
# against the repo, field by field. Nothing changes without --apply.
#
# Why this exists: through 1.1 the listing was pasted by hand from markdown
# blockquotes in docs/app-store/metadata.md, which is how promotional text sat
# drafted-but-empty for all of 1.0 (metadata.md §3). The files hold the exact
# text, so what the repo says is what the store shows, and the dry run makes
# any drift visible before it is overwritten.
#
# Up to three writes (localization, App Review notes, build) with no
# transaction across them -- App Store Connect offers none, and a rollback would
# be more writes that can fail the same way. A failure part-way leaves an
# editable, not-yet-live version partly updated, and a re-run converges: every
# run diffs first and writes only what still differs. The build is checked
# before any write, so the one refusal that is foreseeable happens up front.
#
# Usage:
#   Scripts/update-store-listing.sh [--apply] [--version X.Y] [--build N]
#
# Env: see Scripts/asc-api.sh; plus
#   LISTING_DIR   override docs/app-store/listing (tests use this)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LISTING_DIR="${LISTING_DIR:-$ROOT/docs/app-store/listing}"

# file : API attribute : Apple's limit in characters. The first four live on
# the version's en-US localization; `notes` lives on its App Review detail.
FIELDS="description.txt:description:4000
whats-new.txt:whatsNew:4000
promotional-text.txt:promotionalText:170
keywords.txt:keywords:100
review-notes.txt:notes:4000"

usage() { echo "usage: $0 [--apply] [--version X.Y] [--build N]" >&2; exit 2; }
die() { echo "error: $*" >&2; exit 1; }

APPLY=0; VERSION=""; BUILD=""
while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1 ;;
        --version) VERSION="${2:-}"; [ -n "$VERSION" ] || usage; shift ;;
        --build) BUILD="${2:-}"; [ -n "$BUILD" ] || usage; shift ;;
        *) usage ;;
    esac
    shift
done
if [ -z "$VERSION" ]; then
    VERSION="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([0-9.]+)"?.*/\1/p' "$ROOT/App/project.yml" | head -1)"
    [ -n "$VERSION" ] || die "no --version given and no MARKETING_VERSION in App/project.yml"
fi
# Both reach API filters, so hold them to their shapes first.
printf '%s' "$VERSION" | grep -Eq '^[0-9]+(\.[0-9]+){0,2}$' || die "not a version number: $VERSION"
if [ -n "$BUILD" ]; then
    printf '%s' "$BUILD" | grep -Eq '^[0-9]+$' || die "not a build number: $BUILD"
fi
export VERSION BUILD

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# shellcheck source=Scripts/asc-api.sh
. "$ROOT/Scripts/asc-api.sh"

# ---- local checks: every file, before any network call --------------------

# The repo's files carry one trailing newline; the store text does not.
file_text() { # path -- prints the text without its final newline
    python3 -c 'import sys; sys.stdout.write(open(sys.argv[1], encoding="utf-8").read().rstrip("\n"))' "$1"
}

while IFS=: read -r file attr limit; do
    f="$LISTING_DIR/$file"
    [ -f "$f" ] || die "missing $f"
    n="$(python3 -c 'import sys; print(len(open(sys.argv[1], encoding="utf-8").read().rstrip("\n")))' "$f")" \
        || die "$f is not readable UTF-8 text"
    [ "$n" -gt 0 ] || die "$f is empty"
    [ "$n" -le "$limit" ] || die "$f is $n characters; App Store Connect allows $limit for $attr"
done <<EOF
$FIELDS
EOF
echo "ok - local files: 5 fields, each within Apple's limit"

# ---- read what is there ---------------------------------------------------

asc_token
asc_resolve_editable_version listing

LOC_ID="$(asc_localization_id "$VERSION_ID")" || die "could not list version $VERSION's localizations"
[ -n "$LOC_ID" ] || die "version $VERSION has no $LOCALE localization"
api GET "$API/v1/appStoreVersionLocalizations/$LOC_ID" > "$WORK/loc.json" \
    || die "could not read the $LOCALE localization"

api GET "$API/v1/appStoreVersions/$VERSION_ID/appStoreReviewDetail" > "$WORK/review.json" \
    || die "could not read version $VERSION's App Review detail"
REVIEW_ID="$(json "(d.get('data') or {}).get('id')" < "$WORK/review.json")" \
    || die "could not read version $VERSION's App Review detail"
# Creating one needs the reviewer contact details too, which live only in
# App Store Connect's UI; refuse rather than invent them.
[ -n "$REVIEW_ID" ] || die "version $VERSION has no App Review detail yet -- fill in App Review Information in App Store Connect once, then re-run"

# Per field: print a diff, and record the changed ones for --apply.
: > "$WORK/changed"
while IFS=: read -r file attr limit; do
    if [ "$attr" = notes ]; then doc="$WORK/review.json"; else doc="$WORK/loc.json"; fi
    file_text "$LISTING_DIR/$file" > "$WORK/want"
    ATTR="$attr" json "(d['data']['attributes'].get(env['ATTR']) or '').replace('\r\n', '\n')" < "$doc" > "$WORK/have" \
        || die "could not read $attr from App Store Connect"
    # json() prints with a trailing newline; the comparison is on the text.
    # Exit 3 means "differs" -- an answer, not a failure -- so capture it
    # in an `if` rather than letting set -e read it as one.
    if python3 - "$WORK/have" "$WORK/want" "$attr" > "$WORK/diff" <<'PY'
import difflib, sys
have = open(sys.argv[1], encoding="utf-8").read()
have = have[:-1] if have.endswith("\n") else have
want = open(sys.argv[2], encoding="utf-8").read()
if have == want:
    sys.exit(0)
for line in difflib.unified_diff(have.splitlines(), want.splitlines(),
                                 f"{sys.argv[3]} (App Store Connect)", f"{sys.argv[3]} (repo)", lineterm=""):
    print(line)
sys.exit(3)
PY
    then rc=0; else rc=$?; fi
    case "$rc" in
        0) echo "ok - $attr: unchanged" ;;
        3) echo "$attr: differs"; sed 's/^/    /' "$WORK/diff"; echo "$file:$attr" >> "$WORK/changed" ;;
        *) die "could not compare $attr" ;;
    esac
done <<EOF
$FIELDS
EOF

# The build, when one is asked for: it must belong to this version and be done
# processing, or App Store Connect would refuse it at submission, not here.
BUILD_ID=""
if [ -n "$BUILD" ]; then
    api GET "$API/v1/builds?filter%5Bapp%5D=$APP_ID&filter%5Bversion%5D=$BUILD&filter%5BpreReleaseVersion.version%5D=$VERSION&limit=2" \
        > "$WORK/builds.json" || die "could not look up build $BUILD"
    row="$(json "[f'{b[\"id\"]} {b[\"attributes\"].get(\"processingState\")} {b[\"attributes\"].get(\"expired\")}' for b in d['data']]" < "$WORK/builds.json")" \
        || die "could not read the build list"
    [ -n "$row" ] || die "no build $BUILD for version $VERSION on App Store Connect"
    read -r BUILD_ID build_state build_expired <<EOF
$row
EOF
    [ "$build_state" = VALID ] || die "build $BUILD is $build_state, not VALID -- wait for processing to finish"
    [ "$build_expired" = False ] || die "build $BUILD has expired"
    api GET "$API/v1/appStoreVersions/$VERSION_ID/build" > "$WORK/current-build.json" \
        || die "could not read version $VERSION's current build"
    current="$(json "' '.join(str(x) for x in [((d.get('data') or {}).get('id') or ''), ((d.get('data') or {}).get('attributes') or {}).get('version') or 'none'])" < "$WORK/current-build.json")" \
        || die "could not read version $VERSION's current build"
    if [ "${current%% *}" = "$BUILD_ID" ]; then
        echo "ok - build: $BUILD already selected"
        BUILD_ID=""
    else
        echo "build: would change from ${current#* } to $BUILD"
    fi
fi

if [ "$APPLY" = 0 ]; then
    echo "dry run: nothing written. Re-run with --apply to write the differing fields${BUILD:+ and select build $BUILD}."
    exit 0
fi

# ---- apply ----------------------------------------------------------------

# A JSON:API update body carrying the given files' text as attributes. The
# text goes through json.dumps; it is never spliced into JSON by hand.
update_body() { # type id file:attr...
    python3 - "$LISTING_DIR" "$@" <<'PY'
import json, sys
listing, kind, ident, pairs = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
attrs = {}
for pair in pairs:
    name, attr = pair.split(":")
    attrs[attr] = open(f"{listing}/{name}", encoding="utf-8").read().rstrip("\n")
print(json.dumps({"data": {"type": kind, "id": ident, "attributes": attrs}}))
PY
}

loc_pairs="$(grep -v ':notes$' "$WORK/changed" | tr '\n' ' ' || true)"
if [ -n "$loc_pairs" ]; then
    # shellcheck disable=SC2086 -- one word per changed field, by construction
    body="$(update_body appStoreVersionLocalizations "$LOC_ID" $loc_pairs)" || die "could not build the localization update"
    api PATCH "$API/v1/appStoreVersionLocalizations/$LOC_ID" "$body" > "$WORK/loc-after.json" \
        || die "App Store Connect refused the localization update"
    echo "wrote: $(echo $loc_pairs | sed 's/[^ ]*://g')"
fi
if grep -q ':notes$' "$WORK/changed"; then
    body="$(update_body appStoreReviewDetails "$REVIEW_ID" review-notes.txt:notes)" || die "could not build the review-notes update"
    api PATCH "$API/v1/appStoreReviewDetails/$REVIEW_ID" "$body" > /dev/null \
        || die "App Store Connect refused the App Review notes"
    echo "wrote: notes"
fi
if [ -n "$BUILD_ID" ]; then
    api PATCH "$API/v1/appStoreVersions/$VERSION_ID/relationships/build" \
        "{\"data\":{\"type\":\"builds\",\"id\":\"$BUILD_ID\"}}" > /dev/null \
        || die "App Store Connect refused build $BUILD"
    echo "selected build $BUILD"
fi

# ---- verify: read everything back -----------------------------------------

api GET "$API/v1/appStoreVersionLocalizations/$LOC_ID" > "$WORK/loc.json" || die "could not re-read the localization"
api GET "$API/v1/appStoreVersions/$VERSION_ID/appStoreReviewDetail" > "$WORK/review.json" || die "could not re-read the App Review detail"
while IFS=: read -r file attr limit; do
    if [ "$attr" = notes ]; then doc="$WORK/review.json"; else doc="$WORK/loc.json"; fi
    file_text "$LISTING_DIR/$file" > "$WORK/want"
    ATTR="$attr" json "(d['data']['attributes'].get(env['ATTR']) or '').replace('\r\n', '\n')" < "$doc" > "$WORK/have" \
        || die "could not re-read $attr"
    python3 -c '
import sys
have = open(sys.argv[1], encoding="utf-8").read()
have = have[:-1] if have.endswith("\n") else have
sys.exit(0 if have == open(sys.argv[2], encoding="utf-8").read() else 1)
' "$WORK/have" "$WORK/want" || die "$attr on App Store Connect does not match $file after writing"
done <<EOF
$FIELDS
EOF
if [ -n "$BUILD" ]; then
    api GET "$API/v1/appStoreVersions/$VERSION_ID/build" > "$WORK/current-build.json" || die "could not re-read the build"
    now="$(json "(d.get('data') or {}).get('attributes', {}).get('version')" < "$WORK/current-build.json")" \
        || die "could not re-read the build"
    [ "$now" = "$BUILD" ] || die "version $VERSION has build ${now:-none} selected after writing, not $BUILD"
fi
echo "ok - App Store Connect matches the repo${BUILD:+, build $BUILD selected}"
