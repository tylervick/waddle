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
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

for f in W A D L E; do
    [ -f "$DIR/$f.png" ] || fail "$DIR/$f.png is missing"
done
pass "all five glyph files are present"

# Pillow comes from build-mark.py's own environment: pinned in its inline
# metadata and locked with hashes in Scripts/build-mark.py.lock, so every run
# imports the same Pillow and a release published minutes ago never reaches
# this suite. The lock is checked offline first, then the environment is
# fetched, and only then is anything tested; everything after that runs
# without the network. So each failure says which kind it is: a stale lock, a
# failed download (PyPI, the network, or a Python to run it on), or the
# artwork itself.
LOCKED_SCRIPT=Scripts/build-mark.py
( cd "$ROOT" && uv lock --check --offline --quiet --script "$LOCKED_SCRIPT" ) 2> "$TMP/lock.err" \
    || fail "Scripts/build-mark.py.lock does not match build-mark.py's metadata; run \`uv lock --script $LOCKED_SCRIPT\` and commit it: $(cat "$TMP/lock.err")"
( cd "$ROOT" && uv sync --locked --quiet --script "$LOCKED_SCRIPT" ) 2> "$TMP/fetch.err" \
    || fail "FETCH FAILED, not a test failure: could not install the locked Pillow for $LOCKED_SCRIPT (network, PyPI, or a Python to run it): $(cat "$TMP/fetch.err")"
PY_LOCKED="$(cd "$ROOT" && uv python find --script "$LOCKED_SCRIPT")" \
    || fail "uv python find gave no interpreter for $LOCKED_SCRIPT's environment"
pass "the locked Pillow is installed"

"$PY_LOCKED" - "$DIR" <<'PY' || exit 1
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
    shades = {luma for luma, a in px if a}
    if len(shades) < 4:
        sys.exit(f"FAIL: {ch}.png has {len(shades)} shades — the bevel ramp is gone")
print("ok - geometry, mode, transparency and shading ramp are intact")
PY
pass "glyph artwork is well-formed"
echo "all glyph-source tests passed"
