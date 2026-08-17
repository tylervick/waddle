#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow"]
# ///
"""Decode the glyphs the Waddle mark is built from out of Freedoom's DBIGFONT.

Run rarely and deliberately: this is the only script that reads the WAD, and
its output is committed. Everything downstream works from the committed PNGs,
so `mise run check-icons` stays offline and a FREEDOOM_VERSION bump cannot
silently restyle the brand mark.

DBIGFONT is a FON2 lump, not a DOOM patch: height 15, variable width, a
greyscale ramp with highlights and shadows so source ports can tint it at
runtime. Freedoom has no lowercase, which is why the mark is all caps -- see
docs/learnings/freedoom-fonts-are-uppercase-fon2.md.
"""
import argparse, struct, sys
from pathlib import Path
from PIL import Image

GLYPHS = "WADLE"


def lumps(wad: bytes) -> dict[str, tuple[int, int]]:
    sig, n, off = struct.unpack("<4sii", wad[:12])
    if sig not in (b"IWAD", b"PWAD"):
        sys.exit(f"error: not a WAD (magic {sig!r})")
    out = {}
    for i in range(n):
        fp, sz, nm = struct.unpack("<ii8s", wad[off + i * 16 : off + i * 16 + 16])
        out[nm.rstrip(b"\0").decode("ascii", "replace")] = (fp, sz)
    return out


def unrle(src: bytes, i: int, need: int) -> tuple[bytes, int]:
    """FON2 glyph RLE: n>=0 copies n+1 literals; n<0 repeats one byte 1-n times."""
    out = bytearray()
    while len(out) < need:
        c = src[i]
        i += 1
        c = c - 256 if c > 127 else c
        if c >= 0:
            out += src[i : i + c + 1]
            i += c + 1
        elif c != -128:
            out += bytes([src[i]]) * (1 - c)
            i += 1
    return bytes(out[:need]), i


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--wad", default="App/Resources/GameData/freedoom1.wad")
    ap.add_argument("--out-dir", default="Design/source/freedoom-glyphs")
    a = ap.parse_args()

    wad_path = Path(a.wad)
    if not wad_path.is_file():
        sys.exit(f"error: {wad_path} is missing — run `mise run fetch-freedoom` first.")
    wad = wad_path.read_bytes()
    idx = lumps(wad)
    if "DBIGFONT" not in idx:
        sys.exit("error: DBIGFONT is absent from this WAD.")

    fp, sz = idx["DBIGFONT"]
    b = wad[fp : fp + sz]
    if b[:4] != b"FON2":
        sys.exit(f"error: DBIGFONT is not FON2 (magic {b[:4]!r}).")
    (height,) = struct.unpack("<H", b[4:6])
    first, last, const_w, _shading, pal_size, _flags = b[6:12]
    count = last - first + 1
    p = 12
    if const_w:
        (w,) = struct.unpack("<H", b[p : p + 2])
        widths = [w] * count
        p += 2
    else:
        widths = list(struct.unpack(f"<{count}H", b[p : p + 2 * count]))
        p += 2 * count
    pal = b[p : p + (pal_size + 1) * 3]
    p += (pal_size + 1) * 3

    decoded, i = {}, p
    for gi in range(count):
        w = widths[gi]
        if w == 0:
            continue
        data, i = unrle(b, i, w * height)
        decoded[chr(first + gi)] = (w, data)

    missing = [c for c in GLYPHS if c not in decoded]
    if missing:
        sys.exit(f"error: glyphs absent from DBIGFONT: {missing}")

    out = Path(a.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    for ch in GLYPHS:
        w, data = decoded[ch]
        im = Image.new("LA", (w, height), (0, 0))
        px = im.load()
        for y in range(height):
            for x in range(w):
                v = data[y * w + x]
                if v:
                    px[x, y] = (pal[v * 3], 255)  # palette is a greyscale ramp
        im.save(out / f"{ch}.png")
        print(f"  {ch}  {w}x{height}")


if __name__ == "__main__":
    main()
