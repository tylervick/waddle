#!/bin/bash
# Tests for Scripts/build-duck.py.
#
# Hermetic: runs the real compositor against the committed 66x66 grid into a
# temp dir. Asserts the properties the .icon package and the pixel-art look
# depend on -- above all that the layer is TRANSPARENT (actool derives the Dark
# and Tinted appearances from the layer artwork, and a baked-in ground degrades
# both) and that scaling stayed INTEGER, since the source was recovered from an
# anti-aliased render and a fractional resize would undo that.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

( cd "$ROOT" && uv run --quiet "$ROOT/Scripts/build-duck.py" --out-dir "$TMP" ) >/dev/null \
    || fail "build-duck.py exited non-zero"
pass "build-duck.py runs"

[ -f "$TMP/waddle-duck.png" ]      || fail "waddle-duck.png was not written"
[ -f "$TMP/waddle-duck-flat.svg" ] || fail "waddle-duck-flat.svg was not written"
pass "both outputs exist"

uv run --quiet --with pillow python - "$TMP" "$ROOT" <<'PY' || exit 1
import sys
from pathlib import Path
from PIL import Image
d, root = Path(sys.argv[1]), Path(sys.argv[2])
im = Image.open(d / "waddle-duck.png")
if im.size != (1024, 1024):
    sys.exit(f"FAIL: duck is {im.size}, expected (1024, 1024)")
if im.mode != "RGBA":
    sys.exit(f"FAIL: duck mode is {im.mode}, expected RGBA")
p = im.load()
if p[0, 0][3] != 0:
    sys.exit("FAIL: corner pixel is opaque -- a ground was baked into the layer")
px = [p[x, y] for y in range(im.height) for x in range(im.width)]
opaque = [q for q in px if q[3] == 255]
if not opaque:
    sys.exit("FAIL: duck is entirely transparent")
# Alpha must be strictly binary. Any partial value means something resampled:
# the whole point of the 66x66 source is that edges are hard.
if any(0 < q[3] < 255 for q in px):
    sys.exit("FAIL: partially transparent pixels -- the art was resampled, not "
             "integer-scaled")
# The palette must survive intact. A fractional resize or a mode conversion
# would invent intermediate colours, and the count is the cheapest way to see it.
src = Image.open(root / "Design/source/duck/duck-66px.png").convert("RGBA")
sp = src.load()
want = {sp[x, y][:3] for y in range(src.height)
        for x in range(src.width) if sp[x, y][3] > 0}
got = {q[:3] for q in opaque}
if got != want:
    sys.exit(f"FAIL: palette changed -- source has {len(want)} colours, "
             f"output has {len(got)}")
# Integer scale: every run of identical pixels along a row must be a multiple
# of the scale factor, so measure one and check the art divides by it.
bbox = im.getchannel("A").getbbox()
w, h = bbox[2] - bbox[0], bbox[3] - bbox[1]
sbox = src.getchannel("A").getbbox()
sw, sh = sbox[2] - sbox[0], sbox[3] - sbox[1]
if w % sw or h % sh or (w // sw) != (h // sh):
    sys.exit(f"FAIL: art is {w}x{h} from a {sw}x{sh} source -- not an integer scale")
print(f"ok - 1024 RGBA, transparent ground, hard alpha, {len(got)} colours, x{w // sw}")
PY
pass "duck png has the properties the .icon package needs"

grep -q "<rect" "$TMP/waddle-duck-flat.svg" || fail "flat svg has no <rect> elements"
if grep -q "<path" "$TMP/waddle-duck-flat.svg"; then
    fail "flat svg contains a <path> -- it should be rects, not a trace"
fi
# Unlike waddle-mark-flat.svg this one must NOT use currentColor: the duck is
# 15 colours and currentColor can only express one.
if grep -q "currentColor" "$TMP/waddle-duck-flat.svg"; then
    fail "flat svg uses currentColor, which cannot express a 15-colour mark"
fi
grep -q 'fill="#' "$TMP/waddle-duck-flat.svg" || fail "flat svg carries no explicit fills"
pass "flat svg is a rect grid carrying its own colours"

echo "all build-duck tests passed"
