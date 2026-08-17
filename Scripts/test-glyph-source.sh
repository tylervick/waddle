#!/bin/bash
# Tests the COMMITTED Freedoom glyph PNGs, without needing the WAD.
#
# The WAD is gitignored, so a round-trip test of the extractor would need the
# network or would have to skip -- and a skipping guard fails open. What every
# later step actually depends on is the committed artifact, so that is what is
# tested here: it exists, it has the right geometry, and it carries real
# transparency and a real greyscale ramp rather than a flat blob.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/Design/source/freedoom-glyphs"

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

for f in W A D L E; do
    [ -f "$DIR/$f.png" ] || fail "$DIR/$f.png is missing"
done
pass "all five glyph files are present"

uv run --quiet --with pillow python - "$DIR" <<'PY' || exit 1
import sys
from pathlib import Path
from PIL import Image
d = Path(sys.argv[1])
want = {"W": 17, "A": 15, "D": 14, "L": 12, "E": 12}
for ch, w in want.items():
    im = Image.open(d / f"{ch}.png")
    if im.size != (w, 15):
        sys.exit(f"FAIL: {ch}.png is {im.size}, expected {(w, 15)}")
    if im.mode != "LA":
        sys.exit(f"FAIL: {ch}.png mode is {im.mode}, expected LA")
    # im.load() rather than getdata(): getdata is deprecated and removed in
    # Pillow 14, and a warning in a guard's output erodes its signal.
    p = im.load()
    px = [p[x, y] for y in range(im.height) for x in range(im.width)]
    if not any(a == 0 for _, a in px):
        sys.exit(f"FAIL: {ch}.png has no transparent pixels — a ground was baked in")
    shades = {l for l, a in px if a}
    if len(shades) < 4:
        sys.exit(f"FAIL: {ch}.png has {len(shades)} shades — the bevel ramp is gone")
print("ok - geometry, mode, transparency and shading ramp are intact")
PY
pass "glyph artwork is well-formed"
echo "all glyph-source tests passed"
