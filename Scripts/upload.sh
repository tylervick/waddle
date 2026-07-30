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
IPA="${1:-$ROOT/Vendor/archive/export/WADdle.ipa}"

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
    exit "$RC"
fi
if printf '%s' "$OUT" | grep -qE 'ERROR ITMS-|error:'; then
    echo "error: altool reported an error but exited 0 (known Xcode 26 behaviour)." >&2
    echo "       treating this as a FAILED upload. Verify in App Store Connect." >&2
    exit 1
fi
