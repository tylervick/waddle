#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow"]
# ///
"""Decode Freedoom Phase 1's TITLEPIC into the Get Freedoom tile's art (#552).

Run rarely and deliberately: its output is committed, as
`extract-freedoom-glyphs.py`'s is. Once the app stops bundling Freedoom (#505)
there is no WAD on a new player's device to read the art from at runtime, so
the tile that offers Freedoom draws this image instead.

TITLEPIC is a DOOM patch (column posts) in PLAYPAL's first palette. The PNG
keeps the lump's own 320x200 pixels, as `WADArtwork` decodes them for a real
tile, so the tile crops it the same way and the two look alike.

Freedoom is BSD-licensed; About keeps its credit.

    Scripts/extract-freedoom-titlepic.py
"""
import argparse, struct, sys
from pathlib import Path
from PIL import Image


def lumps(wad: bytes) -> dict[str, tuple[int, int]]:
    sig, n, off = struct.unpack("<4sii", wad[:12])
    if sig not in (b"IWAD", b"PWAD"):
        sys.exit(f"error: not a WAD (magic {sig!r})")
    out = {}
    for i in range(n):
        fp, sz, nm = struct.unpack("<ii8s", wad[off + i * 16 : off + i * 16 + 16])
        out.setdefault(nm.rstrip(b"\0").decode("ascii", "replace"), (fp, sz))
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--wad", default="App/Resources/GameData/freedoom1.wad")
    ap.add_argument("--out", default="App/Assets.xcassets/FreedoomTitle.imageset/freedoom-title.png")
    a = ap.parse_args()

    wad_path = Path(a.wad)
    if not wad_path.is_file():
        sys.exit(f"error: {wad_path} is missing — run `mise run fetch-freedoom` first.")
    wad = wad_path.read_bytes()
    idx = lumps(wad)
    for name in ("PLAYPAL", "TITLEPIC"):
        if name not in idx:
            sys.exit(f"error: {name} is absent from this WAD.")

    fp, _ = idx["PLAYPAL"]
    palette = wad[fp : fp + 768]

    fp, sz = idx["TITLEPIC"]
    pic = wad[fp : fp + sz]
    if pic[:8] == b"\x89PNG\r\n\x1a\n":
        sys.exit("error: TITLEPIC is a PNG here; this script decodes DOOM patches only.")
    width, height, _left, _top = struct.unpack("<hhhh", pic[:8])
    offsets = struct.unpack(f"<{width}I", pic[8 : 8 + 4 * width])

    im = Image.new("RGB", (width, height), (0, 0, 0))
    px = im.load()
    for x, p in enumerate(offsets):
        while pic[p] != 0xFF:
            top, length = pic[p], pic[p + 1]
            data = pic[p + 3 : p + 3 + length]
            for i, c in enumerate(data):
                y = top + i
                if 0 <= y < height:
                    px[x, y] = tuple(palette[c * 3 : c * 3 + 3])
            p += length + 4

    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    im.save(out, optimize=True)
    print(f"  TITLEPIC {width}x{height} -> {out}")


if __name__ == "__main__":
    main()
