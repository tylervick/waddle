#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow"]
# ///
"""Derive the duck mark from the committed 66x66 pixel grid.

Design/source/duck/duck-66px.png is the only hand-supplied duck input. It is a
real pixel-art sprite -- 66x66 cells, 15 colours, hard alpha -- so everything
below is exact integer arithmetic rather than resampling.

Three rules this file exists to hold:

  1. The layer is TRANSPARENT. icon.json's `fill` owns the ground, and actool
     derives Dark and Tinted from the layer artwork -- a baked-in ground
     degrades both. Same rule build-mark.py holds, for the same reason.
  2. Scaling is INTEGER nearest-neighbour. The source was recovered from an
     anti-aliased render by snapping it to its true grid
     (docs/learnings/ai-pixel-art-sits-on-a-real-grid.md); a fractional resize
     would put that anti-aliasing straight back.
  3. The SVG is a grid of rects, not a traced path -- exact and symmetric by
     construction, and no potrace dependency. Unlike waddle-mark-flat.svg it
     carries its own colours: the duck is 15 colours, so currentColor cannot
     express it.

Verify with Scripts/check-icons-fresh.sh.
"""
import argparse
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Design/source/duck/duck-66px.png"
CANVAS = 1024
# Fraction of the canvas the art may span. The scale below is the largest
# INTEGER factor that fits inside it, so the real coverage lands at or under
# this -- 0.85 yields x15, an 840px tall duck with 92px of clearance.
# Deliberately a ceiling, not a target: a non-integer scale chosen to hit the
# number exactly would defeat rule 2.
INSET = 0.85


def scaled(src: Image.Image) -> tuple[Image.Image, int]:
    """Trim to the art, then blow it up by the largest integer factor that
    still fits INSET. Trimming first is what makes the factor depend on the
    duck rather than on however much empty grid it was drawn in."""
    box = src.getchannel("A").getbbox()
    if box is None:
        raise SystemExit(f"error: {SOURCE} is fully transparent")
    art = src.crop(box)
    scale = int((CANVAS * INSET) // max(art.size))
    if scale < 1:
        raise SystemExit(
            f"error: art is {art.size[0]}x{art.size[1]} cells, too large to "
            f"scale by an integer factor inside {INSET:.0%} of {CANVAS}px")
    return art.resize((art.width * scale, art.height * scale), Image.NEAREST), scale


def centred(art: Image.Image) -> Image.Image:
    out = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    out.paste(art, ((CANVAS - art.width) // 2, (CANVAS - art.height) // 2), art)
    return out


def to_svg(src: Image.Image, scale: int) -> str:
    """Pixel grid -> rects, one run per horizontal span of identical colour.

    Runs break on COLOUR, not just on opacity -- build-mark.py can merge on
    opacity alone because its output is monochrome. Merging a colour change
    here would silently flatten the duck's shading.
    """
    px = src.load()
    ox = (CANVAS - src.width * scale) // 2
    oy = (CANVAS - src.height * scale) // 2
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {CANVAS} {CANVAS}" '
        f'role="img" aria-label="Waddle">'
    ]
    for y in range(src.height):
        run_start = None
        run_col = None
        for x in range(src.width + 1):
            here = px[x, y] if x < src.width else None
            col = here[:3] if here and here[3] != 0 else None
            if col == run_col:
                continue
            if run_col is not None:
                r, g, b = run_col
                parts.append(
                    f'<rect x="{ox + run_start * scale}" y="{oy + y * scale}" '
                    f'width="{(x - run_start) * scale}" height="{scale}" '
                    f'fill="#{r:02X}{g:02X}{b:02X}"/>'
                )
            run_start, run_col = (x, col) if col is not None else (None, None)
    parts.append("</svg>")
    return "".join(parts)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", required=True)
    a = ap.parse_args()
    out = Path(a.out_dir)
    out.mkdir(parents=True, exist_ok=True)

    src = Image.open(SOURCE).convert("RGBA")
    box = src.getchannel("A").getbbox()
    art, scale = scaled(src)
    centred(art).save(out / "waddle-duck.png")
    (out / "waddle-duck-flat.svg").write_text(to_svg(src.crop(box), scale))
    print(f"  wrote waddle-duck.png and waddle-duck-flat.svg "
          f"(x{scale}, {art.width}x{art.height} on {CANVAS})")


if __name__ == "__main__":
    main()
