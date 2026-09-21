#!/bin/bash
# Refuses to proceed when the committed icon assets do not match the source
# render that should have produced them. Exits 0 and prints nothing when they
# are current; exits 1 with regeneration guidance otherwise.
#
# Compares CONTENT, not mtimes -- the same reason check-engine-fresh.sh does:
# a fresh worktree checkout and a restored CI cache both produce newer
# timestamps on identical bytes, and a guard that fires on those is a guard
# people learn to bypass.
#
# TWO MODES, because they need different things installed:
#
#   --sync-only  Verifies App/AppIcon.icon/Assets/duck.png is byte-identical to
#                Design/waddle-duck.png. Pure file comparison, no tooling. This
#                catches the realistic drift -- someone regenerates Design/ and
#                forgets the package, or edits the package directly -- and is
#                what CI runs, since the runner does not have uv.
#
#   (default)    Re-runs BOTH derivations into a temp dir and compares all four
#                derived files. Proves the committed assets really are what
#                their sources produce. Needs uv.
#
# TWO sources since the duck became the app icon: the Freedoom glyphs still
# produce the WADDLE wordmark for docs and print, and Design/source/duck/
# produces the duck the icon shows. Both stay guarded -- an unguarded derived
# asset drifts silently, which is the whole reason this file exists.
#
# The narrower CI mode is a deliberately scoped check, not a fail-open one:
# within its scope it fails closed, and it never silently downgrades from the
# full check -- you get the mode you asked for or an error.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/Design/source/freedoom-glyphs"
MARK="$ROOT/Design/waddle-mark.png"
FLAT="$ROOT/Design/waddle-mark-flat.svg"
DUCK_SOURCE="$ROOT/Design/source/duck/duck-66px.png"
DUCK="$ROOT/Design/waddle-duck.png"
DUCK_FLAT="$ROOT/Design/waddle-duck-flat.svg"
ICON_ASSET="$ROOT/App/AppIcon.icon/Assets/duck.png"

SYNC_ONLY=0
case "${1:-}" in
  --sync-only) SYNC_ONLY=1 ;;
  "")          ;;
  *)           echo "usage: $(basename "$0") [--sync-only]" >&2; exit 2 ;;
esac

fail() {
  echo "error: $1" >&2
  echo "       regenerate: mise run icons" >&2
  exit 1
}

for g in W A D L E; do
  [ -f "$SOURCE/$g.png" ] || fail "Design/source/freedoom-glyphs/$g.png is missing."
done
for f in "$DUCK_SOURCE" "$MARK" "$FLAT" "$DUCK" "$DUCK_FLAT" "$ICON_ASSET"; do
  [ -f "$f" ] || fail "${f#"$ROOT"/} is missing."
done

# Always: the package's copy must match the Design/ original. The package shows
# the DUCK -- the wordmark is a brand asset, not the app icon.
cmp -s "$DUCK" "$ICON_ASSET" \
  || fail "App/AppIcon.icon/Assets/duck.png differs from Design/waddle-duck.png."

[ "$SYNC_ONLY" -eq 1 ] && exit 0

for tool in uv; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "error: $tool is not on PATH, so the full check cannot run." >&2
    echo "       install it, or run with --sync-only for the toolless subset." >&2
    exit 1
  }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fails CLOSED: a failed regeneration refuses rather than passing on the
# assumption that nothing changed.
uv run --quiet "$ROOT/Scripts/build-mark.py" --out-dir "$TMP" >/dev/null \
  || fail "could not rebuild the mark from Design/source/freedoom-glyphs/."
uv run --quiet "$ROOT/Scripts/build-duck.py" --out-dir "$TMP" >/dev/null \
  || fail "could not rebuild the duck from Design/source/duck/duck-66px.png."

cmp -s "$MARK" "$TMP/waddle-mark.png" \
  || fail "Design/waddle-mark.png does not match what the glyph source produces."
cmp -s "$FLAT" "$TMP/waddle-mark-flat.svg" \
  || fail "Design/waddle-mark-flat.svg does not match what the glyph source produces."
cmp -s "$DUCK" "$TMP/waddle-duck.png" \
  || fail "Design/waddle-duck.png does not match what the duck source produces."
cmp -s "$DUCK_FLAT" "$TMP/waddle-duck-flat.svg" \
  || fail "Design/waddle-duck-flat.svg does not match what the duck source produces."
