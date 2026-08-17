#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow"]
# ///
"""Compose the Waddle mark from the committed Freedoom glyphs.

Offline by design: reads only Design/source/freedoom-glyphs/, never the WAD,
so `mise run check-icons` needs no network and no fetched binary.

Three rules this file exists to hold:

  1. The layer is TRANSPARENT. icon.json's `fill` owns the ground, and actool
     derives Dark and Tinted from the layer artwork -- a baked-in ground
     degrades both appearances.
  2. The tint ramps in HSV, preserving hue. Lerping toward white desaturates:
     an early build turned red into pink and flattened the bevel.
  3. Scaling is integer nearest-neighbour. Smooth-scaling a 15px pixel grid
     turns a crisp bevel into mush.
"""
import argparse, colorsys
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
GLYPH_DIR = ROOT / "Design/source/freedoom-glyphs"
TINT = "#77FF6F"  # Freedoom PLAYPAL nukage green
CANVAS = 1024
# Fraction of the canvas the mark spans. 0.82 -> 17x -> an 816x544 mark with
# ~99px of clearance to the iOS squircle. Measured against a superellipse
# (n=5) mask: nothing clips until 0.95, so this is a design choice rather
# than a safe-area limit. Larger than it looks like it needs to be on purpose
# -- the mark's weakness is legibility at 40pt, and bigger letterforms are
# what survives the downsample.
INSET = 0.82
# Tracking stays at 1: the two rows come out ragged (WAD is 48px, DLE 40px)
# and that is deliberate. Letterspacing DLE to square the block was tried and
# reads as artificially stretched on a pixel face.
TRACKING = 1  # px between glyphs, at source scale
LINE_GAP = 2  # px between the two lines, at source scale


def load(ch: str) -> Image.Image:
    return Image.open(GLYPH_DIR / f"{ch}.png").convert("LA")


def row(text: str) -> Image.Image:
    ims = [load(c) for c in text]
    w = sum(i.width for i in ims) + TRACKING * (len(ims) - 1)
    h = max(i.height for i in ims)
    out = Image.new("LA", (w, h), (0, 0))
    x = 0
    for im in ims:
        out.paste(im, (x, 0))
        x += im.width + TRACKING
    return out


def stack(top: Image.Image, bottom: Image.Image) -> Image.Image:
    w = max(top.width, bottom.width)
    h = top.height + LINE_GAP + bottom.height
    out = Image.new("LA", (w, h), (0, 0))
    out.paste(top, ((w - top.width) // 2, 0))
    out.paste(bottom, ((w - bottom.width) // 2, top.height + LINE_GAP))
    return out


def tint(src: Image.Image, hexs: str) -> Image.Image:
    r, g, b = (int(hexs[i : i + 2], 16) / 255 for i in (1, 3, 5))
    hue, sat, val = colorsys.rgb_to_hsv(r, g, b)
    out = Image.new("RGBA", src.size, (0, 0, 0, 0))
    sp, op = src.load(), out.load()
    for y in range(src.height):
        for x in range(src.width):
            l, a = sp[x, y]
            if not a:
                continue
            t = l / 255.0
            v = (0.28 + 0.72 * (t**0.85)) * (0.85 + 0.35 * val)
            s = min(1.0, sat * (1.12 - 0.32 * t))
            rr, gg, bb = colorsys.hsv_to_rgb(hue, s, min(1.0, v))
            op[x, y] = (int(rr * 255), int(gg * 255), int(bb * 255), 255)
    return out


def to_svg(src: Image.Image, scale: int) -> str:
    """Pixel grid -> rects. No tracing: exact by construction, symmetric by
    construction, and no potrace dependency. Horizontal runs are merged so the
    file stays small."""
    px = src.load()
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {CANVAS} {CANVAS}" '
        f'fill="currentColor" role="img" aria-label="Waddle">'
    ]
    ox = (CANVAS - src.width * scale) // 2
    oy = (CANVAS - src.height * scale) // 2
    for y in range(src.height):
        run_start = None
        for x in range(src.width + 1):
            solid = x < src.width and px[x, y][1] != 0
            if solid and run_start is None:
                run_start = x
            elif not solid and run_start is not None:
                parts.append(
                    f'<rect x="{ox + run_start * scale}" y="{oy + y * scale}" '
                    f'width="{(x - run_start) * scale}" height="{scale}"/>'
                )
                run_start = None
    parts.append("</svg>")
    return "".join(parts)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", required=True)
    a = ap.parse_args()
    out = Path(a.out_dir)
    out.mkdir(parents=True, exist_ok=True)

    mark = stack(row("WAD"), row("DLE"))
    scale = max(1, int(CANVAS * INSET / mark.width))

    coloured = tint(mark, TINT)
    big = coloured.resize((mark.width * scale, mark.height * scale), Image.NEAREST)
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    canvas.alpha_composite(big, ((CANVAS - big.width) // 2, (CANVAS - big.height) // 2))
    canvas.save(out / "waddle-mark.png")

    (out / "waddle-mark-flat.svg").write_text(to_svg(mark, scale))
    print(f"  waddle-mark.png       {CANVAS}x{CANVAS}")
    print(f"  waddle-mark-flat.svg  {mark.width}x{mark.height} grid at {scale}x")


if __name__ == "__main__":
    main()
