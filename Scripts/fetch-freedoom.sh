#!/bin/bash
# Downloads the pinned Freedoom release, verifies checksums, and stages the
# IWADs + license into App/Resources/GameData.
set -euo pipefail

FREEDOOM_VERSION="0.13.0"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/App/Resources/GameData"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

BASE="https://github.com/freedoom/freedoom/releases/download/v${FREEDOOM_VERSION}"
curl -fsSL "$BASE/freedoom-${FREEDOOM_VERSION}.zip" -o "$TMP/freedoom.zip"
curl -fsSL "$BASE/freedoom-${FREEDOOM_VERSION}-CHECKSUM" -o "$TMP/CHECKSUM"

# The CHECKSUM file uses BSD format: SHA256 (filename) = hash
# Extract the hash for freedoom-0.13.0.zip and verify it
EXPECTED_HASH=$(grep "SHA256 (freedoom-${FREEDOOM_VERSION}.zip)" "$TMP/CHECKSUM" | awk -F' = ' '{print $2}')
if [ -z "$EXPECTED_HASH" ]; then
  echo "ERROR: Could not extract hash from CHECKSUM file"
  exit 1
fi

ACTUAL_HASH=$(shasum -a 256 "$TMP/freedoom.zip" | awk '{print $1}')

if [ "$EXPECTED_HASH" != "$ACTUAL_HASH" ]; then
  echo "ERROR: Checksum mismatch for freedoom-${FREEDOOM_VERSION}.zip"
  echo "Expected: $EXPECTED_HASH"
  echo "Actual:   $ACTUAL_HASH"
  exit 1
fi

echo "OK"

unzip -o "$TMP/freedoom.zip" -d "$TMP/unzipped"
mkdir -p "$DEST"
find "$TMP/unzipped" -name 'freedoom1.wad' -exec cp {} "$DEST/" \;
find "$TMP/unzipped" -name 'freedoom2.wad' -exec cp {} "$DEST/" \;
find "$TMP/unzipped" -iname 'COPYING*' -exec cp {} "$DEST/FREEDOOM-COPYING.txt" \;
ls -l "$DEST"
