#!/bin/bash
# Builds an App Store archive + .ipa. Requires a signed-in Xcode account for
# team 352UZEKYPP. Upload happens via Xcode Organizer or:
#   xcrun altool / Transporter — see docs/app-store/submission-checklist.md
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/App" && xcodegen generate && cd "$ROOT"
ARCHIVE="$ROOT/Vendor/archive/BoomBox.xcarchive"
xcodebuild -project App/BoomBox.xcodeproj -scheme BoomBox \
  -destination 'generic/platform=iOS' -configuration Release \
  -archivePath "$ARCHIVE" archive
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist App/ExportOptions.plist \
  -exportPath "$ROOT/Vendor/archive/export"
echo "IPA at Vendor/archive/export/"
