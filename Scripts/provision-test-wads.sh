#!/bin/bash
# Copies local test WADs into the booted simulator's Waddle Documents dir
# so the app's loose-file adoption imports them on next launch.
# Usage: Scripts/provision-test-wads.sh [device-name]
#
# The default device is the one the whole-scheme leg of `mise run test` runs
# RealWADTests on (SIMULATOR_DEVICE in ci.yml); Scripts/check-simulator-pins.sh
# refuses a tree where the two differ.
set -euo pipefail
DEVICE="${1:-iPhone 18 Pro}"
SRC="$HOME/Downloads/doom-test-wads"
BUNDLE_ID="com.tylervick.waddle"

xcrun simctl boot "$DEVICE" 2>/dev/null || true
CONTAINER="$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE_ID" data)"
DOCS="$CONTAINER/Documents"
mkdir -p "$DOCS"

cp "$SRC/scythe/SCYTHE.WAD" "$DOCS/"
cp "$SRC/sunlust/sunlust/sunlust.wad" "$DOCS/"
cp "$SRC/eviternityii/Eviternity II.wad" "$DOCS/"

# No synthetic badiwad.wad any more: UnrecognizedIWADTests, the negative
# case, writes its own through the WADDLE_TEST_LOOSE_FILE seam (issue #513).

ls -la "$DOCS"
echo "Provisioned. Launch the app to adopt the files."
