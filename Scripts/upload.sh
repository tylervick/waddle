#!/bin/bash
# Uploads (or, with --validate, just validates) the exported IPA to App Store
# Connect using an App Store Connect API key — no Apple ID / Transporter needed.
#
# Requires:
#   - the API key .p8 at ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8
#   - Scripts/.appstore.env (gitignored) defining ASC_KEY_ID and ASC_ISSUER_ID
#
# Usage:
#   Scripts/upload.sh [--validate] [path-to-ipa]
# Defaults to the archive produced by Scripts/archive.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

ACTION="--upload-app"
if [ "${1:-}" = "--validate" ]; then ACTION="--validate-app"; shift; fi
IPA="${1:-$ROOT/Vendor/archive/export/Waddle.ipa}"

# shellcheck disable=SC1091
[ -f "$ROOT/Scripts/.appstore.env" ] && source "$ROOT/Scripts/.appstore.env"
: "${ASC_KEY_ID:?set ASC_KEY_ID in Scripts/.appstore.env}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID in Scripts/.appstore.env}"
[ -f "$IPA" ] || { echo "IPA not found: $IPA (run Scripts/archive.sh first)"; exit 1; }

# ASC_KEY_PATH (optional): pass the .p8 explicitly rather than relying on
# altool's implicit search of ./private_keys, ~/private_keys,
# ~/.private_keys and ~/.appstoreconnect/private_keys. The first of those is
# relative to the current directory, which is ambiguous in CI.
KEY_ARGS=()
if [ -n "${ASC_KEY_PATH:-}" ]; then
    KEY_ARGS=(--p8-file-path "$ASC_KEY_PATH")
fi

echo "${ACTION#--} $IPA"

# Said on every refusal of an upload whose transcript contains UPLOAD
# SUCCEEDED, whichever check refused it. A refusal stops the job before
# "Tag the shipped build", and that step is the only other place the repair
# is printed (issue 390).
warn_possible_delivery() {
    [ "$ACTION" = "--upload-app" ] || return 0
    grep -q 'UPLOAD SUCCEEDED' <<<"$OUT" || return 0
    echo "error: altool ALSO printed UPLOAD SUCCEEDED, so the build MAY be in" >&2
    echo "       App Store Connect. If it is, this run stopped before it could" >&2
    echo "       record the build-N tag: push that tag by hand at the commit" >&2
    echo "       that shipped (docs/app-store/submission-checklist.md, \"A CI" >&2
    echo "       upload whose tag failed to push\") BEFORE the next merge, or" >&2
    echo "       that merge derives the same build number and is refused as" >&2
    echo "       a duplicate." >&2
}
# Capture rather than stream: Xcode 26's altool has been observed printing an
# ITMS error and STILL exiting 0, reporting "Successfully uploaded" for an
# upload that did not happen. Trusting the exit code alone would make a
# failed release look green. See the design spec's upload section.
set +e
OUT="$(xcrun altool "$ACTION" -f "$IPA" -t ios \
        --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" \
        "${KEY_ARGS[@]+"${KEY_ARGS[@]}"}" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT"
if [ "$RC" -ne 0 ]; then
    echo "error: altool exited $RC" >&2
    warn_possible_delivery
    exit "$RC"
fi
# Herestring rather than a pipe: `grep -q` can exit before its producer
# finishes, and under `pipefail` a SIGPIPEd producer could in principle make
# the pipeline report non-zero and so MISS an error it actually matched. Not
# reproducible on macOS/bash 3.2 (448KB payloads detect correctly), but the
# herestring costs nothing and removes the question entirely -- and this check
# is the thing standing between a silently-failed upload and a green run.
#
# Three shapes, because altool has printed all three while exiting 0:
#   - `ITMS-` codes (the Xcode 26 case this guard was written for);
#   - `UPLOAD FAILED` / `VALIDATION FAILED` summary lines;
#   - an `ERROR:` or `error:` line in either case -- the 2026-09-19 409
#     "train version '1.1' is closed" rejection printed `ERROR:` in caps with
#     no ITMS code, matched neither of the old pattern's halves, and shipped
#     a green step, a phantom build tag and a 15-minute wait for a build
#     that did not exist (issue #240). The word-boundary keeps "no errors"
#     and ".../error-codes" URLs -- which a clean transcript contains -- from
#     tripping it. Scripts/test-upload.sh pins every one of these.
#
# Matching is the rule; the block below carves out the single transcript
# where an `ERROR:` line is known not to mean a failed upload.
if grep -qiE 'ITMS-|UPLOAD FAILED|VALIDATION FAILED|(^|[^[:alnum:]_/-])error:' <<<"$OUT"; then
    # One exception, and it is deliberately the width of one transcript.
    # On 2026-11-17 (issue 390) altool's own App Store Connect lookup got two
    # 500s, printed each as `ERROR:`, retried, and then delivered build 293:
    # "UPLOAD SUCCEEDED with no errors" and a Delivery UUID. Failing the step
    # there stopped the job before the tag step, so App Store Connect held a
    # build no `build-*` tag recorded and the next merge would have derived
    # the same number and been refused as a duplicate.
    #
    # So an `ERROR:` line is forgiven only when ALL of this holds:
    #   - nothing in the transcript is an ITMS code or a FAILED summary;
    #   - every error-shaped line is altool reporting a 5xx from an App Store
    #     Connect API call (`[CDASCAPI.…] APP STORE CONNECT API <call>:
    #     received status code 5xx`) -- a 4xx is an answer, not a hiccup;
    #   - after the last of them altool printed exactly one
    #     `UPLOAD SUCCEEDED with no errors`, and the very next line is a
    #     `Delivery UUID:` carrying a whole UUID.
    # Anything else -- the issue 240 rejection, a 5xx with no success block,
    # an error after the success block, --validate (which has no delivery
    # to confirm) -- falls through to the refusal below, as before.
    DELIVERY=""
    if [ "$ACTION" = "--upload-app" ]; then
        DELIVERY="$(awk '
            # 8-4-4-4-12 hex, checked by group length rather than with
            # {n} intervals, which not every awk this runs under supports.
            function whole_uuid(s,    g, n) {
                if (s !~ /^Delivery UUID: [0-9A-Fa-f-]+$/) return 0
                n = split(substr(s, 16), g, "-")
                return n == 5 && length(g[1]) == 8 && length(g[2]) == 4 \
                    && length(g[3]) == 4 && length(g[4]) == 4 && length(g[5]) == 12
            }
            { line = tolower($0) }
            line ~ /itms-|upload failed|validation failed/ { bad = 1 }
            line ~ /(^|[^[:alnum:]_\/-])error:/ {
                if ($0 ~ /ERROR: \[CDASCAPI\.[0-9A-Fa-f]+\] APP STORE CONNECT API [a-z-]+: received status code 5[0-9][0-9];/ && !succeeded) {
                    transient++
                } else {
                    bad = 1
                }
            }
            prev == "UPLOAD SUCCEEDED with no errors" {
                if (whole_uuid($0)) { uuid = $0 } else { bad = 1 }
            }
            $0 == "UPLOAD SUCCEEDED with no errors" { succeeded++ }
            { prev = $0 }
            END {
                if (prev == "UPLOAD SUCCEEDED with no errors") bad = 1
                if (!bad && transient > 0 && succeeded == 1 && uuid != "") {
                    print transient " transient App Store Connect error(s), then " uuid
                    exit 0
                }
                exit 1
            }' <<<"$OUT")" || DELIVERY=""
    fi
    if [ -n "$DELIVERY" ]; then
        echo "note: altool printed $DELIVERY." >&2
        echo "      Its own lookup failed and was retried before the upload went" >&2
        echo "      through; treating this as a SUCCESSFUL upload (issue 390)." >&2
        exit 0
    fi
    echo "error: altool reported an error but exited 0 (known Xcode 26 behaviour)." >&2
    echo "       treating this as a FAILED upload. Verify in App Store Connect." >&2
    warn_possible_delivery
    exit 1
fi
