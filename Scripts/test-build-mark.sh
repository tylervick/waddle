#!/bin/bash
# Tests for Scripts/build-mark.py.
#
# Hermetic: runs the real compositor against the committed glyph PNGs into a
# temp dir. Asserts the properties the .icon package depends on -- above all
# that the layer is TRANSPARENT, because actool derives the Dark and Tinted
# appearances from the layer artwork and a baked-in ground degrades both.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

( cd "$ROOT" && uv run --quiet "$ROOT/Scripts/build-mark.py" --out-dir "$TMP" ) >/dev/null \
    || fail "build-mark.py exited non-zero"
pass "build-mark.py runs"

[ -f "$TMP/waddle-mark.png" ]      || fail "waddle-mark.png was not written"
[ -f "$TMP/waddle-mark-flat.svg" ] || fail "waddle-mark-flat.svg was not written"
pass "both outputs exist"

uv run --quiet --with pillow python - "$TMP" <<'PY' || exit 1
import sys
from pathlib import Path
from PIL import Image
d = Path(sys.argv[1])
im = Image.open(d / "waddle-mark.png")
if im.size != (1024, 1024):
    sys.exit(f"FAIL: mark is {im.size}, expected (1024, 1024)")
if im.mode != "RGBA":
    sys.exit(f"FAIL: mark mode is {im.mode}, expected RGBA")
p = im.load()
if p[0, 0][3] != 0:
    sys.exit("FAIL: corner pixel is opaque — a ground was baked into the layer")
px = [p[x, y] for y in range(im.height) for x in range(im.width)]
opaque = [q for q in px if q[3] == 255]
if not opaque:
    sys.exit("FAIL: mark is entirely transparent")
# Hue check: the tint must be green — G dominant on the brightest pixels.
bright = sorted(opaque, key=lambda q: q[0] + q[1] + q[2])[-200:]
if not all(q[1] > q[0] and q[1] > q[2] for q in bright):
    sys.exit("FAIL: brightest pixels are not green-dominant — tint ramp is wrong")
# Bevel check: a hue-preserving ramp keeps many distinct greens.
if len({q[:3] for q in opaque}) < 8:
    sys.exit("FAIL: too few distinct colours — the bevel was flattened")
print("ok - 1024 RGBA, transparent ground, green-dominant, bevel intact")
PY
pass "mark png has the properties the .icon package needs"

grep -q "<rect" "$TMP/waddle-mark-flat.svg" || fail "flat svg has no <rect> elements"
grep -q "currentColor" "$TMP/waddle-mark-flat.svg" || fail "flat svg does not use currentColor"
if grep -q "<path" "$TMP/waddle-mark-flat.svg"; then
    fail "flat svg contains a <path> — it should be rects, not a trace"
fi
pass "flat svg is a rect grid using currentColor"

echo "all build-mark tests passed"
