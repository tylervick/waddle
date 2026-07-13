#!/bin/bash
# Vendors the pinned Woof! release into Engine/woof.
# WARNING: re-running clobbers local iOS patches — see Engine/WOOF_UPSTREAM.md.
set -euo pipefail
WOOF_TAG="woof_15.3.0"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Engine/woof"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fsSL "https://github.com/fabiangreffrath/woof/archive/refs/tags/${WOOF_TAG}.tar.gz" \
    -o "$TMP/woof.tar.gz"
rm -rf "$DEST"
mkdir -p "$DEST"
tar -xzf "$TMP/woof.tar.gz" -C "$DEST" --strip-components=1
echo "Vendored Woof! ${WOOF_TAG} into Engine/woof"
