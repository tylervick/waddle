#!/bin/bash
# Builds an App Store archive + .ipa. Requires a signed-in Xcode account for
# team 352UZEKYPP. Upload happens via Xcode Organizer or:
#   xcrun altool / Transporter — see docs/app-store/submission-checklist.md
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/App" && xcodegen generate && cd "$ROOT"
ARCHIVE="$ROOT/Vendor/archive/WADdle.xcarchive"
xcodebuild -project App/WADdle.xcodeproj -scheme WADdle \
  -destination 'generic/platform=iOS' -configuration Release \
  -archivePath "$ARCHIVE" archive
rm -rf "$ROOT/Vendor/archive/export"
# The export MUST use the system rsync (/usr/bin/rsync, openrsync). A Homebrew
# rsync 3.4.x earlier on PATH makes Xcode's IPA-copy step die with
#   rsync error: syntax or usage error (code 1) at main.c(1806)  ->  "Copy failed"
# so prepend /usr/bin. -allowProvisioningUpdates lets a first-time bundle id
# mint its distribution profile. (The DVTDeveloperAccountManager warning about
# a stale "kagi@tylervick.com" account is non-fatal — the correct account is
# tylerjvick@gmail.com; see submission-checklist.md §0.)
PATH="/usr/bin:$PATH" xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist App/ExportOptions.plist \
  -exportPath "$ROOT/Vendor/archive/export" \
  -allowProvisioningUpdates
echo "IPA at Vendor/archive/export/"
