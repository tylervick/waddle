#!/bin/bash
# Tests for the inner-display export of Scripts/capture-screenshots.sh
# (`export duo-inner`) and for Scripts/opaque-png.swift, which it runs.
#
# No simulator and no Device Hub: the "host shots" are PNGs made here, at the
# two sizes the open iPhone Duo gives, and the set is written to a temporary
# directory through WADDLE_SCREENSHOT_OUT. It does need macOS: the export
# calls `xcrun swift` and `sips`, as the capture does.
#
# What it guards: the files this export writes are committed and uploaded to
# the store as they are, and nothing downstream looks at the pixels. So a shot
# the export cannot vouch for must stop it, and a stopped export must leave
# the committed set as it found it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

WIDE="01-play-tab 02-library 03-preset-editor 04-control-feel 05-ingame 06-automap"
TALL="07-ingame-half-open"

# A real, decodable RGBA PNG. kind: picture (opaque, not flat), black (opaque,
# one colour), translucent (the picture, with alpha below 255 in one corner).
make_png() { # path width height kind
    python3 - "$@" <<'PY'
import struct, sys, zlib
path, w, h, kind = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
def chunk(tag, body):
    return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body))
rows = bytearray()
for y in range(h):
    if kind == "black":
        row = bytes((0, 0, 0, 255)) * w
    else:
        shade = y * 255 // (h - 1)
        row = bytes((shade, 255 - shade, (y * 7) % 256, 255)) * w
        if kind == "translucent" and y < 4:
            row = bytes((shade, 255 - shade, 9, 128)) * 4 + row[16:]
    rows += b"\x00" + row
open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
                       + chunk(b"IDAT", zlib.compress(bytes(rows), 1)) + chunk(b"IEND", b""))
PY
}

# "WxH colour-type chunk,chunk,..." for a PNG.
describe() { # path
    python3 - "$1" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
kinds, i = [], 8
while i < len(d):
    n = int.from_bytes(d[i:i + 4], "big"); kinds.append(d[i + 4:i + 8].decode()); i += 12 + n
print("%dx%d" % (int.from_bytes(d[16:20], "big"), int.from_bytes(d[20:24], "big")), d[25], ",".join(sorted(set(kinds))))
PY
}

# Decoded RGB of a PNG, as a hash: the colour bytes only, whatever the file's
# colour type and filters, so an RGBA source and its RGB rewrite compare.
rgb_hash() { # path
    python3 - "$1" <<'PY'
import hashlib, sys, zlib
d = open(sys.argv[1], "rb").read()
w, h, ctype = int.from_bytes(d[16:20], "big"), int.from_bytes(d[20:24], "big"), d[25]
bpp = {2: 3, 6: 4}[ctype]
idat, i = b"", 8
while i < len(d):
    n = int.from_bytes(d[i:i + 4], "big")
    if d[i + 4:i + 8] == b"IDAT": idat += d[i + 8:i + 8 + n]
    i += 12 + n
raw, stride = zlib.decompress(idat), w * bpp
out, prev = hashlib.sha256(), bytearray(stride)
for y in range(h):
    f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
    if f == 1:
        for x in range(bpp, stride): line[x] = (line[x] + line[x - bpp]) & 255
    elif f == 2:
        line = bytearray((a + b) & 255 for a, b in zip(line, prev))
    elif f == 3:
        for x in range(stride): line[x] = (line[x] + ((line[x - bpp] if x >= bpp else 0) + prev[x]) // 2) & 255
    elif f == 4:
        for x in range(stride):
            a, b, c = (line[x - bpp] if x >= bpp else 0), prev[x], (prev[x - bpp] if x >= bpp else 0)
            p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
            line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
    prev = line
    out.update(bytes(line) if bpp == 3 else bytes(v for k, v in enumerate(line) if k % 4 != 3))
print(out.hexdigest())
PY
}

# Fresh world per case: seven good host shots, and a set already "committed"
# in the destination, which a refused export must not disturb.
setup() {
    rm -rf "$TMP/w"; mkdir -p "$TMP/w/results/iphone-duo-inner-host-shots" "$TMP/w/out/iphone-duo-inner"
    SHOTS="$TMP/w/results/iphone-duo-inner-host-shots"; DEST="$TMP/w/out/iphone-duo-inner"
    [ -f "$TMP/wide.png" ] || { make_png "$TMP/wide.png" 2853 2007 picture; make_png "$TMP/tall.png" 2007 2853 picture; }
    for s in $WIDE; do cp "$TMP/wide.png" "$SHOTS/$s.png"; echo "committed $s" > "$DEST/$s.png"; done
    cp "$TMP/tall.png" "$SHOTS/$TALL.png"; echo "committed $TALL" > "$DEST/$TALL.png"
}
run() {
    set +e
    OUT="$(WADDLE_SCREENSHOT_RESULTS="$TMP/w/results" WADDLE_SCREENSHOT_OUT="$TMP/w/out" \
        "$ROOT/Scripts/capture-screenshots.sh" export duo-inner 2>&1)"
    RC=$?
    set -e
}
# The destination exactly as setup left it: the seven stand-in files, their
# contents, and nothing else.
assert_untouched() { # what
    for s in $WIDE $TALL; do
        [ "$(cat "$DEST/$s.png" 2>/dev/null)" = "committed $s" ] || fail "$1: $s.png in the set was replaced or removed"
    done
    [ "$(ls -A "$DEST" | wc -l | tr -d ' ')" = 7 ] || fail "$1: the set gained or lost a file: $(ls -A "$DEST" | paste -sd' ' -)"
    [ -z "$(find "$TMP/w/results" -name 'export-stage*')" ] || fail "$1: a staging directory was left behind"
}

# 1. Seven good shots: seven files, each its exact size, RGB without alpha,
#    no chunk beyond the picture, and the same pixels as the shot.
setup; run
[ "$RC" = 0 ] || fail "a good set was refused: $OUT"
for s in $WIDE; do
    [ "$(describe "$DEST/$s.png")" = "2853x2007 2 IDAT,IEND,IHDR,sRGB" ] || fail "$s exported as: $(describe "$DEST/$s.png")"
done
[ "$(describe "$DEST/$TALL.png")" = "2007x2853 2 IDAT,IEND,IHDR,sRGB" ] || fail "$TALL exported as: $(describe "$DEST/$TALL.png")"
[ "$(rgb_hash "$DEST/05-ingame.png")" = "$(rgb_hash "$SHOTS/05-ingame.png")" ] || fail "05-ingame's pixels changed in the rewrite"
[ "$(rgb_hash "$DEST/$TALL.png")" = "$(rgb_hash "$SHOTS/$TALL.png")" ] || fail "$TALL's pixels changed in the rewrite"
[ -z "$(find "$TMP/w/results" -name 'export-stage*')" ] || fail "a staging directory was left behind"
pass "a good set exports at exact sizes, opaque, bare of metadata, pixel for pixel"

# 2. A translucent shot is refused, not blended onto black, and says so.
setup; make_png "$SHOTS/03-preset-editor.png" 2853 2007 translucent; run
[ "$RC" != 0 ] || fail "exported a translucent shot"
echo "$OUT" | grep -q "03-preset-editor.png has 16 pixel(s) that are not fully opaque" || fail "wrong refusal for a translucent shot: $OUT"
assert_untouched "translucent shot"
pass "a translucent shot is refused and the set is left alone"

# 3. So is a shot of a display that was switched off ...
setup; make_png "$SHOTS/06-automap.png" 2853 2007 black; run
[ "$RC" != 0 ] || fail "exported a flat black shot"
echo "$OUT" | grep -q "06-automap is one flat colour" || fail "wrong refusal for a black shot: $OUT"
assert_untouched "black shot"
pass "a flat black shot is refused and the set is left alone"

# 4. ... a shot taken in the wrong pose (the size is the pose) ...
setup; cp "$TMP/wide.png" "$SHOTS/$TALL.png"; run
[ "$RC" != 0 ] || fail "exported a wide shot under the half-open name"
echo "$OUT" | grep -q "$TALL is not 2007x2853" || fail "wrong refusal for a wrong-pose shot: $OUT"
assert_untouched "wrong-pose shot"
pass "a shot of the wrong shape is refused and the set is left alone"

# 5. ... and a shot the test never asked for. The LAST shot is the missing
#    one, so the six before it had all passed when the export stopped: this
#    is the case that used to leave six new files beside one old one.
setup; rm "$SHOTS/$TALL.png"; run
[ "$RC" != 0 ] || fail "exported a set with a shot missing"
echo "$OUT" | grep -q "$TALL: the test never asked for it" || fail "wrong refusal for a missing shot: $OUT"
echo "$OUT" | grep -q "is unchanged" || fail "the refusal does not say the set is unchanged: $OUT"
assert_untouched "missing shot"
pass "a missing shot is refused and no file of the set is rewritten"

echo "All capture-export tests passed."
