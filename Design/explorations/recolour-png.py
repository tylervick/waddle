#!/usr/bin/env python3
"""Remap colour classes in a pixel-art PNG without touching its drawing.

Why this and not a model: any generation -- even image-to-image with a
reference -- redraws the subject. If the artwork is already right and only the
palette is wrong, the correct tool is a per-pixel hue remap. Every pixel keeps
its position and alpha; only its hue changes, so the character, pose and pixel
grid are unchanged by construction rather than by luck.

Selection is by HUE RANGE, not by exact colour, because upscaled pixel art has
hundreds of near-identical shades per visual colour and an exact-match table
would miss the anti-aliased edges and leave a fringe.
"""
import argparse, colorsys, pathlib, sys

from PIL import Image

MAX_PNG_BYTES = 64 * 1024 * 1024

# Hue windows in degrees. Named so the CLI reads like the drawing.
CLASSES = {
    "teal":   (160, 200),
    "green":  (80, 160),
    "blue":   (200, 255),
    "orange": (20, 45),
    "yellow": (45, 70),
    "red":    (335, 20),      # wraps
    "magenta": (255, 335),
}


def in_window(deg, lo, hi):
    return (lo <= deg <= hi) if lo <= hi else (deg >= lo or deg <= hi)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("src", type=pathlib.Path)
    ap.add_argument("-o", "--out", type=pathlib.Path, required=True)
    ap.add_argument("--map", action="append", default=[], metavar="CLASS:HUE[:SAT]",
                    help="remap a colour class to a hue in degrees, e.g. teal:48 "
                         "or teal:48:0.95. Repeatable.")
    ap.add_argument("--min-sat", type=float, default=0.15,
                    help="ignore pixels below this saturation, so the black "
                         "outline and grey metal are never touched")
    ap.add_argument("--lift", type=float, default=0.0,
                    help="0..1 lerp of each remapped pixel's lightness toward "
                         "--target-l; without it, dark shades of the source "
                         "colour become mud rather than shadow")
    ap.add_argument("--target-l", type=float, default=0.55)
    ap.add_argument("--bg", default=None, metavar="R,G,B",
                    help="flatten transparency onto this colour (default: keep alpha)")
    args = ap.parse_args()

    if not args.src.is_file():
        sys.exit(f"error: not a file: {args.src}")
    size = args.src.stat().st_size
    if size > MAX_PNG_BYTES:
        sys.exit(f"error: {args.src} is {size / 1048576:.1f} MB, over the "
                 f"{MAX_PNG_BYTES // 1048576} MB limit.")
    if not args.map:
        sys.exit("error: nothing to do -- pass at least one --map CLASS:HUE")

    rules = []
    for spec in args.map:
        parts = spec.split(":")
        if len(parts) not in (2, 3):
            sys.exit(f"error: bad --map {spec!r}; expected CLASS:HUE[:SAT]")
        name = parts[0].lower()
        if name not in CLASSES:
            sys.exit(f"error: unknown class {name!r}; known: "
                     f"{', '.join(sorted(CLASSES))}")
        try:
            hue = float(parts[1])
            sat = float(parts[2]) if len(parts) == 3 else None
        except ValueError:
            sys.exit(f"error: bad number in --map {spec!r}")
        rules.append((CLASSES[name], hue, sat, name))

    im = Image.open(args.src).convert("RGBA")
    px = list(im.getdata())
    out = []
    hits = {name: 0 for *_, name in rules}
    for r, g, b, a in px:
        if a == 0:
            out.append((r, g, b, a))
            continue
        h, l, s = colorsys.rgb_to_hls(r / 255, g / 255, b / 255)
        if s < args.min_sat:
            out.append((r, g, b, a))
            continue
        deg = h * 360
        for (lo, hi), hue, sat, name in rules:
            if in_window(deg, lo, hi):
                nl = l + (args.target_l - l) * args.lift
                nr, ng, nb = colorsys.hls_to_rgb(hue / 360, nl,
                                                 sat if sat is not None else s)
                out.append((round(nr * 255), round(ng * 255), round(nb * 255), a))
                hits[name] += 1
                break
        else:
            out.append((r, g, b, a))

    res = Image.new("RGBA", im.size)
    res.putdata(out)
    if args.bg:
        try:
            bg = tuple(int(v) for v in args.bg.split(","))
            assert len(bg) == 3
        except (ValueError, AssertionError):
            sys.exit(f"error: bad --bg {args.bg!r}; expected R,G,B")
        flat = Image.new("RGBA", im.size, bg + (255,))
        flat.alpha_composite(res)
        res = flat
    args.out.parent.mkdir(parents=True, exist_ok=True)
    res.save(args.out)
    total = im.size[0] * im.size[1]
    print(f"{args.src.name} -> {args.out.name}")
    for name, n in hits.items():
        print(f"   {name}: {n} px remapped ({100 * n / total:.1f}% of canvas)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
