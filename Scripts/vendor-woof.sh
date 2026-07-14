#!/bin/bash
# Vendors the pinned Woof! commit into Engine/woof.
# WARNING: re-running clobbers local iOS patches — see Engine/WOOF_UPSTREAM.md.
set -euo pipefail
WOOF_COMMIT="798acebd52b6cc1623dde556d3e3a236a25a41d1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Engine/woof"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fsSL "https://github.com/fabiangreffrath/woof/archive/${WOOF_COMMIT}.tar.gz" \
    -o "$TMP/woof.tar.gz"
rm -rf "$DEST"
mkdir -p "$DEST"
tar -xzf "$TMP/woof.tar.gz" -C "$DEST" --strip-components=1
echo "Vendored Woof! ${WOOF_COMMIT} into Engine/woof"
