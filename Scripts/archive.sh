#!/bin/bash
# Builds an App Store archive + .ipa. Requires a signed-in Xcode account for
# team 352UZEKYPP. Upload happens via Xcode Organizer or:
#   xcrun altool / Transporter — see docs/app-store/submission-checklist.md
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Optional CI behaviour. All of this is inert when the env vars are unset,
# so a local `Scripts/archive.sh` produces exactly the command lines it
# always has. Scripts/test-release-args.sh proves that, because "inert when
# unset" is easy to get wrong here -- see the array note below.
#
# ASC_KEY_PATH/ASC_KEY_ID/ASC_ISSUER_ID : App Store Connect API key, needed
#   on a clean runner where no Xcode account is signed in. All three or none.
# BUILD_NUMBER  : overrides CURRENT_PROJECT_VERSION for this build only.
# EXPORT_OPTIONS_PLIST : defaults to App/ExportOptions.plist.
# ARCHIVE_PRINT_ONLY   : print the command lines and exit; used by the test.
#
# NOTE the "${ARR[@]+"${ARR[@]}"}" form below. macOS /bin/bash is 3.2.57,
# where `set -u` treats "${ARR[@]}" on an EMPTY array as an unbound variable
# and aborts the script. The plain form would break every local release
# while CI, which always sets these vars, stayed green.
ASC_ARGS=()
if [ -n "${ASC_KEY_PATH:-}" ] && [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ]; then
    ASC_ARGS=(-authenticationKeyPath "$ASC_KEY_PATH"
              -authenticationKeyID "$ASC_KEY_ID"
              -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi
VERSION_ARGS=()
if [ -n "${BUILD_NUMBER:-}" ]; then
    VERSION_ARGS=("CURRENT_PROJECT_VERSION=$BUILD_NUMBER")
fi
EXPORT_PLIST="${EXPORT_OPTIONS_PLIST:-App/ExportOptions.plist}"
ARCHIVE="$ROOT/Vendor/archive/WADdle.xcarchive"

if [ "${ARCHIVE_PRINT_ONLY:-}" = "1" ]; then
    echo "ARCHIVE: xcodebuild -project App/WADdle.xcodeproj -scheme WADdle" \
         "-destination generic/platform=iOS -configuration Release" \
         "-archivePath $ARCHIVE" \
         "${ASC_ARGS[@]+"${ASC_ARGS[@]}"}" "${VERSION_ARGS[@]+"${VERSION_ARGS[@]}"}" "archive"
    echo "EXPORT: xcodebuild -exportArchive -archivePath $ARCHIVE" \
         "-exportOptionsPlist $EXPORT_PLIST" \
         "-exportPath $ROOT/Vendor/archive/export" \
         "${ASC_ARGS[@]+"${ASC_ARGS[@]}"}" "-allowProvisioningUpdates"
    exit 0
fi

# Defense in depth against the one irreversible failure mode. With API-key
# auth available, automatic signing + the export step's -allowProvisioningUpdates
# is the full "create certificates" configuration (man xcodebuild): xcodebuild
# would MINT a new Apple Distribution certificate whose key dies with the
# runner. Apple caps those at 2-3 per account and cleanup is manual revocation
# in the portal. Refuse rather than trust a caller to have set the plist.
if [ -n "${ASC_KEY_PATH:-}" ] && [ -z "${EXPORT_OPTIONS_PLIST:-}" ]; then
    echo "error: ASC key auth requires an explicit manual-signing export plist." >&2
    echo "       set EXPORT_OPTIONS_PLIST (e.g. App/ExportOptions-ci.plist)." >&2
    exit 1
fi

"$ROOT/Scripts/check-engine-fresh.sh"

cd "$ROOT/App" && xcodegen generate && cd "$ROOT"
# -allowProvisioningUpdates is deliberately NOT here. On the archive step
# with automatic signing it lets xcodebuild MINT a new distribution
# certificate when the identity is not found; Apple caps those at 2-3 per
# account and the only cleanup is manual revocation in the portal. CI signs
# manually with a pre-installed profile, so there is nothing to update.
xcodebuild -project App/WADdle.xcodeproj -scheme WADdle \
  -destination 'generic/platform=iOS' -configuration Release \
  -archivePath "$ARCHIVE" \
  "${ASC_ARGS[@]+"${ASC_ARGS[@]}"}" "${VERSION_ARGS[@]+"${VERSION_ARGS[@]}"}" \
  archive
rm -rf "$ROOT/Vendor/archive/export"
# The export MUST use the system rsync (/usr/bin/rsync, openrsync). A Homebrew
# rsync 3.4.x earlier on PATH makes Xcode's IPA-copy step die with
#   rsync error: syntax or usage error (code 1) at main.c(1806)  ->  "Copy failed"
# so prepend /usr/bin. -allowProvisioningUpdates lets a first-time bundle id
# mint its distribution profile on the LOCAL path, which uses automatic
# signing; CI passes a manual-signing plist where it is a no-op.
# (The DVTDeveloperAccountManager warning about a stale "kagi@tylervick.com"
# account is non-fatal -- the correct account is tylerjvick@gmail.com; see
# docs/app-store/submission-checklist.md §0.)
PATH="/usr/bin:$PATH" xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -exportPath "$ROOT/Vendor/archive/export" \
  "${ASC_ARGS[@]+"${ASC_ARGS[@]}"}" \
  -allowProvisioningUpdates
echo "IPA at Vendor/archive/export/"
