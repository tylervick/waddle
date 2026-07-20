#!/bin/bash
# Copies local test WADs into the booted simulator's WADdle Documents dir
# so the app's loose-file adoption imports them on next launch.
# Usage: Scripts/provision-test-wads.sh [device-name]
set -euo pipefail
DEVICE="${1:-iPhone 17 Pro}"
SRC="$HOME/Downloads/doom-test-wads"
BUNDLE_ID="com.tylervick.waddle"

xcrun simctl boot "$DEVICE" 2>/dev/null || true
CONTAINER="$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE_ID" data)"
DOCS="$CONTAINER/Documents"
mkdir -p "$DOCS"

cp "$SRC/scythe/SCYTHE.WAD" "$DOCS/"
cp "$SRC/sunlust/sunlust/sunlust.wad" "$DOCS/"
cp "$SRC/eviternityii/Eviternity II.wad" "$DOCS/"

# Synthetic 12-byte "IWAD" fixture for the negative test (RealWADTests.
# testWrongIWADPairingFailsSoft): header "IWAD" + numLumps=0 + dirOffset=12.
# Passes the app's own WADParser (magic + in-bounds empty directory) and gets
# classified/imported as an IWAD, but Woof's own CheckIWAD()/IdentifyVersion()
# (Engine/woof/src/d_main.c) can't determine a gamemode from an unrecognized
# filename with zero lumps, so it fails fast with I_Error("Unknown or invalid
# IWAD file.") before the title screen ever renders.
#
# This replaces the originally-planned "real MAPxx megawad on a Doom-1-format
# IWAD" pairing (e.g. sunlust.wad on Freedoom Phase 1): verified empirically
# and by reading the engine source that this does NOT fail — Woof never
# auto-warps into a level without a -warp flag (which this app's argv
# builder never passes), so a mismatched session just idles on the title
# screen for its whole autoquit window and exits 0. R_InitTextures also
# treats missing/mismatched patches as non-fatal (substitutes a dummy
# patch), and DEHACKED's hard-fail path is dead code upstream. An
# unrecognized IWAD is the reliable, argv-only way to make the engine
# actually error out.
printf 'IWAD\x00\x00\x00\x00\x0c\x00\x00\x00' > "$DOCS/badiwad.wad"

ls -la "$DOCS"
echo "Provisioned. Launch the app to adopt the files."
