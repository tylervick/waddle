#!/usr/bin/env python3
"""Snap a pixel-art-STYLED image onto its true integer grid.

Images from image models look like pixel art but are not: the blocks carry
baked-in anti-aliasing, so a 66x66 design arrives as tens of thousands of
colours. This recovers the real grid.

Each output cell takes the MODAL colour of its centre, not a point sample or
an average. Point-sampling lands on an anti-aliased pixel roughly as often as
not; averaging invents colours that are in no cell. The mode is what the block
actually is.
"""
import argparse, collections, pathlib, sys

from PIL import Image

MAX_BYTES = 64 * 1024 * 1024


def modal_cell(px, x0, y0, x1, y1, inset):
    """Most common colour in a cell, ignoring an inset border so the
    anti-aliased seam between cells never wins the vote."""
    ix = max(0, int((x1 - x0) * inset))
    iy = max(0, int((y1 - y0) * inset))
    votes = collections.Counter()
    for y in range(y0 + iy, max(y0 + iy + 1, y1 - iy)):
        for x in range(x0 + ix, max(x0 + ix + 1, x1 - ix)):
            votes[px[x, y]] += 1
    return votes.most_common(1)[0][0] if votes else (0, 0, 0, 0)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("src", type=pathlib.Path)
    ap.add_argument("-o", "--out", type=pathlib.Path, required=True)
    ap.add_argument("--cells", type=int, required=True,
                    help="grid width in cells (e.g. 66)")
    ap.add_argument("--phase", type=float, default=0.0,
                    help="grid offset in source pixels")
    ap.add_argument("--inset", type=float, default=0.25,
                    help="fraction of each cell ignored at its border (0..0.45)")
    ap.add_argument("--scale", type=int, default=0,
                    help="upscale factor for the output; 0 = emit the raw grid")
    ap.add_argument("--alpha-cut", type=int, default=128)
    ap.add_argument("--palette", type=int, default=0,
                    help="reduce to N colours after snapping; 0 = leave alone. "
                         "Snapping alone does not give a pixel-art palette -- "
                         "each block carries internal shading, so the modal "
                         "colours still number in the hundreds.")
    args = ap.parse_args()

    if not args.src.is_file():
        sys.exit(f"error: not a file: {args.src}")
    if args.src.stat().st_size > MAX_BYTES:
        sys.exit(f"error: {args.src} exceeds {MAX_BYTES // 1048576} MB")
    if not 0 <= args.inset < 0.45:
        sys.exit("error: --inset must be in [0, 0.45)")
    if args.cells < 2:
        sys.exit("error: --cells must be at least 2")

    im = Image.open(args.src).convert("RGBA")
    w, h = im.size
    px = im.load()
    period = w / args.cells
    rows = int(round(h / period))

    grid = Image.new("RGBA", (args.cells, rows))
    gp = grid.load()
    for cy in range(rows):
        for cx in range(args.cells):
            x0 = int(round(cx * period + args.phase))
            x1 = int(round((cx + 1) * period + args.phase))
            y0 = int(round(cy * period + args.phase))
            y1 = int(round((cy + 1) * period + args.phase))
            x0, y0 = max(0, x0), max(0, y0)
            x1, y1 = min(w, x1), min(h, y1)
            if x1 <= x0 or y1 <= y0:
                gp[cx, cy] = (0, 0, 0, 0)
                continue
            r, g, b, a = modal_cell(px, x0, y0, x1, y1, args.inset)
            gp[cx, cy] = (r, g, b, 255 if a >= args.alpha_cut else 0)

    if args.palette:
        # Quantise RGB only. Alpha is carried around the median-cut, which is
        # RGB-only, and reapplied -- otherwise transparent cells get voted a
        # colour and the silhouette grows a halo.
        alpha = grid.getchannel("A")
        flat = Image.new("RGB", grid.size, (0, 0, 0))
        flat.paste(grid.convert("RGB"), mask=alpha)
        q = flat.quantize(colors=args.palette, method=Image.MEDIANCUT).convert("RGB")
        grid = q.convert("RGBA")
        grid.putalpha(alpha)

    out = grid
    if args.scale:
        out = grid.resize((args.cells * args.scale, rows * args.scale), Image.NEAREST)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    out.save(args.out)

    opaque = [p[:3] for p in grid.getdata() if p[3] > 0]
    print(f"{args.src.name} -> {args.out.name}")
    print(f"   grid: {args.cells}x{rows} cells at {period:.2f} px")
    print(f"   palette: {len(set(opaque))} colours over {len(opaque)} opaque cells")
    return 0


if __name__ == "__main__":
    sys.exit(main())
