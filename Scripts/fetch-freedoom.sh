#!/bin/bash
# Downloads the pinned Freedoom release, verifies checksums, and stages the
# IWADs + license into App/Resources/GameData.
set -euo pipefail

# Renovate opens a pull request when this falls behind: the `# renovate:` line
# is read by the custom regex manager in renovate.json and must stay DIRECTLY
# above the pin. Never automerged -- this is the game data the app ships. A
# bump is this one line: the checksum below is read from the same release, so
# there is no hash to update here, and equally it proves the download is
# intact, not that the release is the one upstream meant to publish. See
# "Renovate pull requests for the native pins" in Engine/WOOF_UPSTREAM.md.
# renovate: datasource=github-releases depName=freedoom/freedoom versioning=semver extractVersion=^v(?<version>.+)$
FREEDOOM_VERSION="0.13.0"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/App/Resources/GameData"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

BASE="https://github.com/freedoom/freedoom/releases/download/v${FREEDOOM_VERSION}"
# One DNS blip on the runner used to fail the whole TestFlight job after the
# engine build (issue #531). Each download is tried 6 times in all, 2 s apart.
# --retry-all-errors is what makes a dropped connection (35, 52, 56) count, not
# just the resolve and timeout errors plain --retry covers; the price is that
# a 404 is retried too, so it fails after about 10 s with the same curl
# message instead of at once. Nothing here weakens the checksum check below:
# a download that "succeeds" with the wrong bytes still fails it.
#
# --speed-limit/--speed-time is the stall guard: a transfer that connects and
# then moves under 1000 bytes/s for 30 s in a row is abandoned (exit 28) and
# retried, instead of hanging until the job's own timeout. It is a rate, not a
# --max-time, so it does not have to be sized to the zip or to a slow runner:
# GitHub's release CDN sends megabytes a second, and at 1 KB/s the ~30 MB zip
# would take over eight hours anyway.
FETCH=(curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors --connect-timeout 20
       --speed-limit 1000 --speed-time 30)
"${FETCH[@]}" "$BASE/freedoom-${FREEDOOM_VERSION}.zip" -o "$TMP/freedoom.zip"
"${FETCH[@]}" "$BASE/freedoom-${FREEDOOM_VERSION}-CHECKSUM" -o "$TMP/CHECKSUM"

# The CHECKSUM file uses BSD format: SHA256 (filename) = hash
# Extract the hash for the pinned zip and verify it.
# `|| true` keeps a failed grep (no match) from killing the script via
# `set -e -o pipefail` before the explicit -z check below can report it.
EXPECTED_HASH=$(grep "SHA256 (freedoom-${FREEDOOM_VERSION}.zip)" "$TMP/CHECKSUM" | awk -F' = ' '{print $2}' || true)
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
# Pick the license file deterministically: multiple COPYING* matches would
# otherwise each overwrite the destination, with filesystem order deciding
# which one wins. (sed, not `head -1`: head exiting early would SIGPIPE the
# producer and trip pipefail.)
COPYING_SRC=$(find "$TMP/unzipped" -iname 'COPYING*' | sort | sed -n '1p')
if [ -z "$COPYING_SRC" ]; then
  echo "ERROR: no COPYING* license file found in Freedoom zip"
  exit 1
fi
cp "$COPYING_SRC" "$DEST/FREEDOOM-COPYING.txt"
ls -l "$DEST"
