#!/bin/bash
# Refreshes the pinned Blink CLI download in mise.toml.
#
# Blink ships from the vendor's own CDN with no GitHub repository, no release
# tag and no mise registry entry, so Renovate has nothing to query and the pin
# is maintained by hand -- by this script, rather than by editing four URLs and
# checksums in mise.toml and hoping they still agree with each other.
#
# What "the pin" is: the CDN publishes <platform>.sha256 holding the SHA-256 of
# the current gzipped binary, and serves that binary at a URL containing the
# same hash. The URL is therefore content-addressed -- the download location
# and its checksum are one fact, not two that can drift -- which is what makes
# a bare URL an acceptable pin here rather than a version-shaped guess.
#
# Usage:
#   Scripts/update-blink-pin.sh            # show what the pin would become
#   Scripts/update-blink-pin.sh --write    # rewrite mise.toml
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$ROOT/mise.toml"
BASE="${BLINK_DOWNLOAD_BASE_URL:-https://blink.review/downloads/cli}"
BASE="${BASE%/}"

WRITE=false
case "${1:-}" in
  --write) WRITE=true ;;
  "") ;;
  *) echo "usage: $(basename "$0") [--write]" >&2; exit 2 ;;
esac

# The vendor's platform name on the left, mise's on the right. Only the two
# macOS pairs: this project builds an iOS app with Xcode, so a Linux
# contributor does not exist and a Linux pin nobody can run is a pin nobody
# would notice going stale.
PLATFORMS="darwin-arm64:macos-arm64 darwin-x64:macos-x64"

# Which build this machine can actually execute, and therefore the only one we
# can ask for a version number. The CDN serves one release across platforms,
# so that answer stands for both pins.
case "$(uname -m)" in
  arm64|aarch64) HOST_PLATFORM="darwin-arm64" ;;
  x86_64|amd64)  HOST_PLATFORM="darwin-x64" ;;
  *) echo "ERROR: Blink ships for x86-64 and ARM64 only" >&2; exit 1 ;;
esac
[ "$(uname -s)" = "Darwin" ] || { echo "ERROR: run this on macOS" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

VERSION=""
BLOCK="$TMP/block"
: > "$BLOCK"

for pair in $PLATFORMS; do
  vendor="${pair%%:*}"
  mise_name="${pair##*:}"

  sha="$(curl -fsSL --retry 2 "$BASE/$vendor.sha256")"
  # Validate before interpolating it into a URL. A truncated or HTML response
  # would otherwise be pinned verbatim and fail much later, at `mise install`
  # on someone else's machine.
  case "$sha" in
    *[!0-9a-f]*|"") echo "ERROR: $vendor.sha256 is not a hex digest: $sha" >&2; exit 1 ;;
  esac
  [ "${#sha}" -eq 64 ] || { echo "ERROR: $vendor.sha256 is not 64 characters: $sha" >&2; exit 1; }

  url="$BASE/blink-$vendor-$sha.gz"
  curl -fsSL --retry 2 -o "$TMP/$vendor.gz" "$url"

  # Verify rather than trust. The published digest and the download come from
  # the same host, so this proves only that the transfer was intact -- but that
  # is the failure this catches, and pinning a hash we never checked against
  # its own bytes would make the mise-side checksum decorative.
  actual="$(shasum -a 256 "$TMP/$vendor.gz" | awk '{print $1}')"
  if [ "$actual" != "$sha" ]; then
    echo "ERROR: checksum mismatch for $vendor" >&2
    echo "  published: $sha" >&2
    echo "  actual:    $actual" >&2
    exit 1
  fi

  if [ "$vendor" = "$HOST_PLATFORM" ]; then
    gzip -dc "$TMP/$vendor.gz" > "$TMP/blink"
    chmod 755 "$TMP/blink"
    # Also the only proof the download is a runnable binary at all.
    VERSION="$("$TMP/blink" --version)"
  fi

  printf 'platforms.%s.url = "%s"\n' "$mise_name" "$url" >> "$BLOCK"
  printf 'platforms.%s.checksum = "sha256:%s"\n' "$mise_name" "$sha" >> "$BLOCK"
done

case "$VERSION" in
  *[!0-9.]*|"") echo "ERROR: --version did not report a version: $VERSION" >&2; exit 1 ;;
esac

NEW="$TMP/new-block"
{
  echo "# blink-pin:begin -- managed by Scripts/update-blink-pin.sh, do not hand-edit"
  echo '[tools."http:blink"]'
  printf 'version = "%s"\n' "$VERSION"
  cat "$BLOCK"
  echo "# blink-pin:end"
} > "$NEW"

# Compare against what is pinned now, so a no-op run says so instead of
# touching the file and leaving an empty-looking diff to interpret.
CURRENT="$TMP/current-block"
awk '/^# blink-pin:begin/,/^# blink-pin:end/' "$CONFIG" > "$CURRENT"
if [ ! -s "$CURRENT" ]; then
  echo "ERROR: no blink-pin markers in $CONFIG" >&2
  exit 1
fi

if cmp -s "$CURRENT" "$NEW"; then
  echo "Blink $VERSION is already pinned; nothing to do."
  exit 0
fi

echo "--- currently pinned"
sed 's/^/  /' "$CURRENT"
echo "+++ published now (Blink $VERSION)"
sed 's/^/  /' "$NEW"

if [ "$WRITE" != true ]; then
  echo
  echo "Re-run with --write to apply."
  exit 0
fi

# Replace the marked region in place. awk rather than sed -i: the replacement
# is multi-line and contains URLs full of characters sed would treat as
# delimiters or backreferences.
awk -v blockfile="$NEW" '
  /^# blink-pin:begin/ { while ((getline line < blockfile) > 0) print line; skip = 1; next }
  /^# blink-pin:end/   { skip = 0; next }
  !skip                { print }
' "$CONFIG" > "$TMP/mise.toml"
mv "$TMP/mise.toml" "$CONFIG"

echo
echo "Pinned Blink $VERSION in mise.toml. Verify with: mise install"
