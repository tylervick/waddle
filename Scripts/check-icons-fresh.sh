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
#   --sync-only  Verifies App/AppIcon.icon/Assets/mark.png is byte-identical to
#                Design/waddle-mark.png. Pure file comparison, no tooling. This
#                catches the realistic drift -- someone regenerates Design/ and
#                forgets the package, or edits the package directly -- and is
#                what CI runs, since the runner has neither uv nor potrace.
#
#   (default)    Re-runs the extraction into a temp dir and compares both
#                derived files as well. Proves the committed assets really are
#                what the source produces. Needs uv and potrace.
#
# The narrower CI mode is a deliberately scoped check, not a fail-open one:
# within its scope it fails closed, and it never silently downgrades from the
# full check -- you get the mode you asked for or an error.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/Design/source/waddle-logo.png"
MARK="$ROOT/Design/waddle-mark.png"
FLAT="$ROOT/Design/waddle-mark-flat.svg"
ICON_ASSET="$ROOT/App/AppIcon.icon/Assets/mark.png"

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

for f in "$SOURCE" "$MARK" "$FLAT" "$ICON_ASSET"; do
  [ -f "$f" ] || fail "${f#"$ROOT"/} is missing."
done

# Always: the package's copy must match the Design/ original.
cmp -s "$MARK" "$ICON_ASSET" \
  || fail "App/AppIcon.icon/Assets/mark.png differs from Design/waddle-mark.png."

[ "$SYNC_ONLY" -eq 1 ] && exit 0

for tool in uv potrace; do
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
uv run --quiet "$ROOT/Scripts/extract-mark.py" --out-dir "$TMP" >/dev/null \
  || fail "could not regenerate the mark from Design/source/waddle-logo.png."

cmp -s "$MARK" "$TMP/waddle-mark.png" \
  || fail "Design/waddle-mark.png does not match what the source render produces."
cmp -s "$FLAT" "$TMP/waddle-mark-flat.svg" \
  || fail "Design/waddle-mark-flat.svg does not match what the source render produces."
