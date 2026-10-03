#!/bin/bash
# Submits one App Store version for App Review through the App Store Connect
# API, after re-reading the gates docs/app-store/submission-checklist.md §5
# asks a human to confirm before tapping Submit.
#
# Dry run by default: it resolves the version, checks that a build is
# selected, that the app's content-rights declaration is answered, and that
# both licence-agreement fields are still empty (metadata.md §14: Apple's
# standard EULA, by decision -- a non-empty value means someone set a custom
# agreement without updating that section). It prints what it would submit
# and stops. Nothing is sent without --apply.
#
# With --apply it creates a review submission for the app, adds the version
# to it, marks it submitted, and reads the submission's state back rather
# than trusting the 2xx. An unsubmitted review submission that already
# exists on the app is a refusal, not something to reuse: two hands in that
# state is how a submission ends up carrying the wrong items.
#
# What this cannot check, and the checklist leaves to the owner: that the
# complete corresponding source for the selected build is on `main` (the
# GPL posture check's first bullet), and the App Privacy questionnaire, which
# the REST API does not expose.
#
# Usage:
#   Scripts/submit-for-review.sh [--apply] [--version X.Y]
#
# Env: see Scripts/asc-api.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage() { echo "usage: $0 [--apply] [--version X.Y]" >&2; exit 2; }
die() { echo "error: $*" >&2; exit 1; }

APPLY=0; VERSION=""
while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1 ;;
        --version) VERSION="${2:-}"; [ -n "$VERSION" ] || usage; shift ;;
        *) usage ;;
    esac
    shift
done
if [ -z "$VERSION" ]; then
    VERSION="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([0-9.]+)"?.*/\1/p' "$ROOT/App/project.yml" | head -1)"
    [ -n "$VERSION" ] || die "no --version given and no MARKETING_VERSION in App/project.yml"
fi
printf '%s' "$VERSION" | grep -Eq '^[0-9]+(\.[0-9]+){0,2}$' || die "not a version number: $VERSION"
export VERSION

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# shellcheck source=Scripts/asc-api.sh
. "$ROOT/Scripts/asc-api.sh"

asc_token
asc_resolve_editable_version submission

# ---- gates, every one before any write -----------------------------------
api GET "$API/v1/appStoreVersions/$VERSION_ID/build" > "$WORK/build.json" \
    || die "could not read version $VERSION's build"
BUILD_NUMBER="$(json "(((d.get('data') or {}).get('attributes') or {}).get('version')) or ''" < "$WORK/build.json")" \
    || die "could not read version $VERSION's build"
[ -n "$BUILD_NUMBER" ] || die "version $VERSION has no build selected; select one with the listing workflow first"
echo "ok - build $BUILD_NUMBER is selected"

api GET "$API/v1/apps/$APP_ID?fields%5Bapps%5D=contentRightsDeclaration" > "$WORK/app.json" \
    || die "could not read the app's content-rights declaration"
RIGHTS="$(json "((d.get('data') or {}).get('attributes') or {}).get('contentRightsDeclaration') or ''" < "$WORK/app.json")" \
    || die "could not read the app's content-rights declaration"
[ -n "$RIGHTS" ] || die "the app's content-rights declaration is unanswered (checklist §4); the submit flow would refuse"
echo "ok - content rights: $RIGHTS"

# metadata.md §14: both licence fields empty, by decision. The beta agreement
# is a resource whose text must be empty; the EULA is a relationship that is
# simply not set, which the API reports as 404.
api GET "$API/v1/apps/$APP_ID/betaLicenseAgreement" > "$WORK/beta.json" \
    || die "could not read the beta licence agreement"
BETA="$(json "((d.get('data') or {}).get('attributes') or {}).get('agreementText') or ''" < "$WORK/beta.json")" \
    || die "could not read the beta licence agreement"
[ -z "$BETA" ] || die "betaLicenseAgreement.agreementText is set; metadata.md §14 says it must be empty -- reconcile before submitting"
ACCEPT_404=1 api GET "$API/v1/apps/$APP_ID/endUserLicenseAgreement" > "$WORK/eula.json" \
    || die "could not read the end-user licence agreement"
if [ -s "$WORK/eula.json" ]; then
    EULA="$(json "((d.get('data') or {}).get('id')) or ''" < "$WORK/eula.json")" \
        || die "could not read the end-user licence agreement"
    [ -z "$EULA" ] || die "a custom endUserLicenseAgreement ($EULA) is set; metadata.md §14 says it must be empty -- reconcile before submitting"
fi
echo "ok - licence agreements: both empty (Apple's standard EULA, metadata.md §14)"

api GET "$API/v1/apps/$APP_ID/reviewSubmissions?filter%5Bstate%5D=READY_FOR_REVIEW,WAITING_FOR_REVIEW,IN_REVIEW,UNRESOLVED_ISSUES&limit=10" \
    > "$WORK/submissions.json" || die "could not list the app's review submissions"
OPEN="$(json "' '.join(f\"{s['id']}:{s['attributes'].get('state')}\" for s in d['data'])" < "$WORK/submissions.json")" \
    || die "could not read the review submissions"
[ -z "$OPEN" ] || die "the app already has an open review submission ($OPEN); finish or cancel it in App Store Connect before submitting again"
echo "ok - no open review submission"

if [ "$APPLY" = 0 ]; then
    echo "dry run: would submit version $VERSION (build $BUILD_NUMBER) for App Review. Re-run with --apply to submit."
    exit 0
fi

# ---- submit ---------------------------------------------------------------
body="$(APP_ID="$APP_ID" python3 -c '
import json, os
print(json.dumps({"data": {"type": "reviewSubmissions", "attributes": {"platform": "IOS"},
    "relationships": {"app": {"data": {"type": "apps", "id": os.environ["APP_ID"]}}}}}))')" \
    || die "could not build the review submission body"
SUB_ID="$(api POST "$API/v1/reviewSubmissions" "$body" | json "d['data']['id']")" \
    || die "App Store Connect refused to create the review submission"
echo "created: review submission $SUB_ID"

body="$(SUB_ID="$SUB_ID" VERSION_ID="$VERSION_ID" python3 -c '
import json, os
print(json.dumps({"data": {"type": "reviewSubmissionItems",
    "relationships": {"reviewSubmission": {"data": {"type": "reviewSubmissions", "id": os.environ["SUB_ID"]}},
                      "appStoreVersion": {"data": {"type": "appStoreVersions", "id": os.environ["VERSION_ID"]}}}}}))')" \
    || die "could not build the review submission item body"
api POST "$API/v1/reviewSubmissionItems" "$body" > /dev/null \
    || die "App Store Connect refused to add version $VERSION to the review submission"
echo "added: version $VERSION (build $BUILD_NUMBER) to the submission"

body="$(SUB_ID="$SUB_ID" python3 -c '
import json, os
print(json.dumps({"data": {"type": "reviewSubmissions", "id": os.environ["SUB_ID"], "attributes": {"submitted": True}}}))')" \
    || die "could not build the submit body"
api PATCH "$API/v1/reviewSubmissions/$SUB_ID" "$body" > /dev/null \
    || die "App Store Connect refused to submit the review submission"

# Read back rather than trust the 2xx: the state is what the reviewer sees.
api GET "$API/v1/reviewSubmissions/$SUB_ID" > "$WORK/after.json" || die "could not read the submission back"
STATE="$(json "d['data']['attributes'].get('state') or ''" < "$WORK/after.json")" || die "could not read the submission's state"
case "$STATE" in
    WAITING_FOR_REVIEW|IN_REVIEW) echo "ok - submitted: version $VERSION (build $BUILD_NUMBER) is $STATE" ;;
    *) die "submitted, but the review submission reads $STATE rather than WAITING_FOR_REVIEW -- check App Store Connect" ;;
esac
