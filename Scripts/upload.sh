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

echo "${ACTION#--} $IPA"
xcrun altool "$ACTION" -f "$IPA" -t ios \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
