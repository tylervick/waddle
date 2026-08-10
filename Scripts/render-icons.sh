#!/bin/bash
# Regenerates every derived icon asset from the committed source render.
#
# Design/source/waddle-logo.png is the only hand-supplied icon input. Everything
# else -- the extracted mark, the flat vector, and the artwork inside the Icon
# Composer package -- is produced from it by this script, so a new logo means
# replacing that one file and re-running.
#
# Deliberately NOT an icon-size generator. An iOS appiconset has been a single
# 1024 PNG since Xcode 14 and a .icon package holds the artwork once, so the
# retired 20/29/40/60/76/83.5 matrix has nothing to generate. This script exists
# so the mark stops being an un-editable binary blob, not to fan out sizes.
#
# Verify with Scripts/check-icons-fresh.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${1:-$ROOT/Design}"
ICON_ASSET="$ROOT/App/AppIcon.icon/Assets/mark.png"

for tool in uv potrace; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: $tool is not on PATH." >&2
    case "$tool" in
      uv)      echo "       install it: https://docs.astral.sh/uv/" >&2 ;;
      potrace) echo "       install it: brew install potrace" >&2 ;;
    esac
    exit 1
  fi
done

uv run --quiet "$ROOT/Scripts/extract-mark.py" --out-dir "$OUT_DIR"

# The .icon package carries its own copy of the artwork rather than a symlink:
# actool reads the package as a self-contained unit, and a dangling link would
# fail at build time instead of here. check-icons-fresh.sh --sync-only is what
# keeps the copy honest.
if [ "$OUT_DIR" = "$ROOT/Design" ]; then
  mkdir -p "$(dirname "$ICON_ASSET")"
  cp "$OUT_DIR/waddle-mark.png" "$ICON_ASSET"
  echo "  synced $(basename "$ICON_ASSET") into AppIcon.icon/Assets"
fi
