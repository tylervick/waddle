#!/usr/bin/env python3
"""Recolour a Recraft pixel-art SVG deterministically.

Why this exists: Recraft's `controls.colors` is a palette *hint*, not an
assignment -- there is no way to say "this colour goes on the face". Once a
composition is right, editing its dozen flat fills gives exact colours in one
pass instead of resampling the model and hoping.

Green is used for BOTH the helmet and the face in these outputs, so colour
alone cannot separate them. Paths are therefore classified by geometry: a
green path whose bounding-box centre falls inside the visor opening is face,
everything else stays helmet.
"""
import argparse, colorsys, pathlib, re, sys

# These SVGs run ~120 KB. The cap is generous enough never to bite on real
# Recraft output and small enough that pointing this at the wrong file fails
# with a sentence instead of swapping.
MAX_SVG_BYTES = 32 * 1024 * 1024

PATH_RE = re.compile(r'(<path[^>]*?fill="rgb\((\d+),(\d+),(\d+)\)"[^>]*?d="([^"]*)"[^>]*?/?>)')
NUM = re.compile(r'-?\d+\.?\d*')


def read_svg(path):
    """Read an SVG, refusing anything implausibly large. Size is checked with
    stat() first so an oversized file is never pulled into memory at all."""
    if not path.is_file():
        raise SystemExit(f"error: not a file: {path}")
    size = path.stat().st_size
    if size > MAX_SVG_BYTES:
        raise SystemExit(
            f"error: {path} is {size / 1048576:.1f} MB, over the "
            f"{MAX_SVG_BYTES // 1048576} MB limit. Is this really an SVG?")
    return path.read_text(errors="replace")


def canvas_size(svg, path):
    """Width of the drawing area, for spotting the full-canvas background path.

    Handles `viewBox` with any origin and float values, falls back to a bare
    `width`, and says what is wrong rather than raising AttributeError on a
    None match -- an SVG whose viewBox is `0 0 512.0 512.0` is perfectly legal
    and would have crashed the naive version.
    """
    m = re.search(r'viewBox="\s*(-?[\d.]+)\s+(-?[\d.]+)\s+([\d.]+)\s+([\d.]+)', svg)
    if m:
        return float(m.group(3)) - float(m.group(1))
    m = re.search(r'\bwidth="([\d.]+)', svg)
    if m:
        return float(m.group(1))
    raise SystemExit(
        f"error: {path} has no usable viewBox or width; cannot tell how big "
        f"the canvas is, so the background path cannot be identified.")


def bbox(d):
    n = [float(x) for x in NUM.findall(d)]
    xs, ys = n[0::2], n[1::2]
    return (min(xs), min(ys), max(xs), max(ys)) if xs else None


def is_green(c):
    r, g, b = c
    return g > r + 25 and g > b + 25


def retint(c, hue_deg, sat, lift=0.0, target_l=0.59):
    """Recolour keeping the original lightness RELATIONSHIPS, so the pixel-art
    shading survives, while optionally lifting the whole ramp toward the
    requested colour's lightness -- a dark green retinted at its own lightness
    reads as mud, not as shadow on yellow."""
    r, g, b = (v / 255 for v in c)
    _, l, _ = colorsys.rgb_to_hls(r, g, b)
    l = l + (target_l - l) * lift
    r2, g2, b2 = colorsys.hls_to_rgb(hue_deg / 360, l, sat)
    return tuple(round(v * 255) for v in (r2, g2, b2))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src", type=pathlib.Path)
    ap.add_argument("-o", "--out", type=pathlib.Path, required=True)
    ap.add_argument("--face-box", default="640,700,1540,1200",
                    help="x0,y0,x1,y1 of the visor opening in viewBox units")
    ap.add_argument("--face-hue", type=float, default=48.0)
    ap.add_argument("--face-sat", type=float, default=0.95)
    ap.add_argument("--lift", type=float, default=0.0,
                    help="0..1 lerp of each face shade's lightness toward "
                         "--target-l, to stop dark greens becoming mud-brown")
    ap.add_argument("--target-l", type=float, default=0.59,
                    help="lightness of the requested face colour (250,210,50)")
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--bg", default="45,50,55", help="r,g,b or 'none' to keep")
    args = ap.parse_args()

    fx0, fy0, fx1, fy1 = (float(v) for v in args.face_box.split(","))
    t = read_svg(args.src)
    canvas = canvas_size(t, args.src)

    recoloured = bg_done = 0

    def sub(m):
        nonlocal recoloured, bg_done
        whole, r, g, b, d = m.groups()
        c = (int(r), int(g), int(b))
        bb = bbox(d)
        if bb is None:
            return whole
        # The full-canvas path is the background.
        if (bb[2] - bb[0]) > canvas * 0.98 and (bb[3] - bb[1]) > canvas * 0.98:
            if args.bg != "none":
                bg_done += 1
                return whole.replace(f"rgb({r},{g},{b})", "rgb(%s)" % args.bg.replace(",", ","))
            return whole
        if not is_green(c):
            return whole
        cx, cy = (bb[0] + bb[2]) / 2, (bb[1] + bb[3]) / 2
        if fx0 <= cx <= fx1 and fy0 <= cy <= fy1:
            recoloured += 1
            nr, ng, nb = retint(c, args.face_hue, args.face_sat,
                                args.lift, args.target_l)
            if args.verbose:
                print(f"   face  rgb{c} -> rgb({nr},{ng},{nb})  "
                      f"centre=({cx:.0f},{cy:.0f})", file=sys.stderr)
            return whole.replace(f"rgb({r},{g},{b})", f"rgb({nr},{ng},{nb})")
        return whole

    out = PATH_RE.sub(sub, t)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(out)
    print(f"{args.src.name} -> {args.out.name}: {recoloured} green paths retinted, "
          f"{bg_done} background path(s) set")
    return 0


if __name__ == "__main__":
    sys.exit(main())
