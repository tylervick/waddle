#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow"]
# ///
"""Report signals about a generated mark candidate.

Companion to icon-prompts.md. This measures; it does not judge. Whether a
candidate is GOOD depends on the style it is going for, and no threshold here
knows that -- a painterly icon and a flat pictogram fail each other's checks.
Exits 0 always.

  1. SILHOUETTE  -- the shape with all colour removed. Diagnostic for flat and
     monochrome styles; close to meaningless for painterly or dimensional
     ones, which legitimately carry their form in colour and light.
  2. TINY        -- 16px and 40px blowups. The one check that applies to every
     style equally, and usually the one that decides things.
  3. MARGIN      -- how much clear edge the artwork leaves.
  4. COLOURS     -- distinct RGB over opaque pixels. Reported, not scored: 2 is
     right for a monochrome mark and wrong for an illustrated one.
  5. ALPHA       -- share of partially transparent pixels. High values are
     expected for soft illustration and suspicious for pixel art, where they
     usually mean the model matted against a background instead of cutting
     real transparency.

Writes the derived images next to the candidate for eyeballing.
"""

import argparse
import sys
from pathlib import Path

from PIL import Image

INSET = 0.85  # icon-prompts.md preamble; judgement, not a safe-area limit


def load(path: Path) -> Image.Image:
    im = Image.open(path)
    return im.convert("RGBA")


def silhouette(im: Image.Image) -> Image.Image:
    return im.getchannel("A").point(lambda v: 255 if v >= 128 else 0, mode="1")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("candidate", type=Path)
    ap.add_argument("--out-dir", type=Path, default=None)
    args = ap.parse_args()

    im = load(args.candidate)
    out = args.out_dir or args.candidate.parent
    out.mkdir(parents=True, exist_ok=True)
    stem = args.candidate.stem
    w, h = im.size

    print(f"{args.candidate}  {w}x{h}")
    if w != h:
        print(f"  ! not square ({w}x{h}) -- an icon layer must be square")

    # 1. Silhouette
    sil = silhouette(im)
    sil.convert("L").save(out / f"{stem}-silhouette.png")
    print(f"  silhouette -> {stem}-silhouette.png"
          f"   (meaningful for flat styles; ignore for painterly ones)")

    # 2. Tiny
    for px in (16, 40):
        small = im.resize((px, px), Image.LANCZOS)
        small.resize((400, 400), Image.NEAREST).save(out / f"{stem}-{px}px.png")
        print(f"  {px}px       -> {stem}-{px}px.png")

    # 3. Margin
    bbox = im.getchannel("A").point(lambda v: 255 if v >= 8 else 0).getbbox()
    if bbox is None:
        print("  ! margin     FAIL -- image is fully transparent")
    else:
        left, top, right, bottom = bbox
        margin = min(left, top, w - right, h - bottom)
        need = round(w * (1 - INSET) / 2)
        span = max(right - left, bottom - top)
        verdict = "ok" if margin >= need else "tight"
        print(f"  margin       {verdict} -- {margin}px clear, {need}px suggested "
              f"(art spans {span}px of {w})")

    # 4. Colours, counted over visible pixels only
    visible = [px[:3] for px in im.getdata() if px[3] >= 128]
    distinct = len(set(visible))
    print(f"  colours      {distinct} distinct RGB over opaque pixels")

    # 5. Hard alpha
    alpha = list(im.getchannel("A").getdata())
    soft = sum(1 for v in alpha if 8 < v < 248)
    pct = 100.0 * soft / len(alpha)
    edge = "hard" if pct < 2.0 else "soft"
    print(f"  alpha edges  {edge} -- {pct:.2f}% partially transparent "
          f"(hard suits pixel/flat art, soft suits illustration)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
