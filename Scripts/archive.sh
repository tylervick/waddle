#!/bin/bash
# Builds an App Store archive + .ipa. Requires a signed-in Xcode account for
# team 352UZEKYPP. Upload happens via Xcode Organizer or:
#   xcrun altool / Transporter — see docs/app-store/submission-checklist.md
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Guard against archiving a STALE engine. The heavy engine build (SDL/OpenAL +
# Woof -> Vendor/out/WoofEngine.xcframework) is deliberately NOT part of
# archiving, but a framework older than its sources silently ships stale bits —
# that is how a missing SDL_CAMERA=OFF (ITMS-90683) or an unbuilt engine fix can
# reach App Review. Fail loudly instead; rebuild is a separate, explicit step.
FW="$ROOT/Vendor/out/WoofEngine.xcframework"
if [ ! -d "$FW" ]; then
  echo "error: $FW is missing." >&2
  echo "       build the engine first: mise run bootstrap" >&2
  echo "       (or: Scripts/build-deps.sh && Scripts/build-engine.sh)" >&2
  exit 1
fi
# Any engine source or build script newer than the built framework => stale.
STALE=$(find "$ROOT/Engine/woof/src" \
             "$ROOT/Scripts/build-engine.sh" \
             "$ROOT/Scripts/build-deps.sh" \
             -newer "$FW" -print -quit 2>/dev/null || true)
if [ -n "$STALE" ]; then
  echo "error: engine sources/scripts changed since WoofEngine.xcframework was" >&2
  echo "       built (e.g. $STALE)." >&2
  echo "       rebuild before archiving: Scripts/build-deps.sh && Scripts/build-engine.sh" >&2
  echo "       (build-deps.sh is only needed when SDL/OpenAL config changed)" >&2
  exit 1
fi

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
