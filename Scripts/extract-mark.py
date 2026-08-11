#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "pillow", "scipy", "svgpathtools"]
# ///
"""Extract the WADdle mark from the source render.

Reads Design/source/waddle-logo.png (an AI-generated 1254x1254 render of the
orange webbed foot sitting on a white rounded card) and writes the two files
every other icon asset derives from:

  Design/waddle-mark.png       subject on transparency, 1024 canvas
  Design/waddle-mark-flat.svg  flat silhouette, 1024 viewBox, ~30 segments

The card, its rounded corners, and the cast shadow are all DISCARDED. iOS 26
supplies the container, the shadow, and the glass specular; shipping our own
would double up on the system's. That is also why the mark is extracted rather
than the render being used as-is.

The shaded mark stays raster on purpose. Three vectorizations of it were built
and compared (machine trace, gradient decomposition, authored illustration) and
all three read visibly worse than the render. An iOS icon tops out at 1024 and
the subject lands ~657px inside that frame, so the raster is lossless at every
size iOS asks for. Only the FLAT mark is vector, because it has jobs the raster
cannot do: the Tinted/Mono appearance, 29px, favicons, and print.

Requires potrace on PATH (brew install potrace).
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage
from svgpathtools import CubicBezier, Line, parse_path
from svgpathtools import Path as SvgPath

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Design/source/waddle-logo.png"
DEFAULT_OUT = ROOT / "Design"
MARK_NAME = "waddle-mark.png"
FLAT_NAME = "waddle-mark-flat.svg"

CANVAS = 1024  # icon canvas; the source is scaled into this, preserving framing

# Saturation threshold separating the mark from the card and its cast shadow.
# The mark's least-saturated parts are the rim highlight (~169) and the bottom
# lip (~177); the card is ~2 and the shadow is a desaturated grey. 60 sits in
# open space between them.
#
# This is a threshold, NOT a soft ramp. Saturation is linear in pixel coverage,
# so a half-covered edge pixel and a genuinely lighter part of the mark are
# indistinguishable by saturation -- ramping on it makes the rim highlight
# semi-transparent while leaving real edge pixels opaque. Coverage is taken
# geometrically instead (see coverage()).
SAT_THRESHOLD = 60.0

# potrace: tuned by sweeping alphamax x opttolerance against the mask and taking
# the knee -- 0.18px mean boundary deviation at 1254 (IoU 0.9985). Tightening
# opttolerance to 0.2 roughly doubles the node count to buy 0.05px, which is not
# worth the unreadable path data.
POTRACE_ALPHAMAX = "1.0"
POTRACE_OPTTOLERANCE = "1.0"
POTRACE_UNIT = "100"
POTRACE_TURDSIZE = "2"


def die(msg: str) -> None:
    sys.exit(f"error: {msg}")


def subject_mask(rgb: np.ndarray) -> np.ndarray:
    """Boolean mask of the mark, with the card and cast shadow removed."""
    saturated = (rgb.max(2) - rgb.min(2)) > SAT_THRESHOLD
    labels, count = ndimage.label(saturated)
    if count == 0:
        die("no saturated region found in the source render")
    sizes = ndimage.sum(saturated, labels, range(1, count + 1))
    return ndimage.binary_fill_holes(labels == (int(np.argmax(sizes)) + 1))


def coverage(mask: np.ndarray) -> np.ndarray:
    """Anti-aliased alpha from the mask's signed distance field.

    One pixel of feather centred on the boundary, which is what the render's own
    edge looks like. Geometric rather than colour-derived, so the rim highlight
    and bottom lip stay fully opaque despite being less saturated than the core.
    """
    signed = ndimage.distance_transform_edt(mask) - ndimage.distance_transform_edt(~mask)
    return np.clip(signed + 0.5, 0.0, 1.0)


def decontaminate(rgb: np.ndarray, mask: np.ndarray) -> np.ndarray:
    """Replace edge colours with the nearest well-interior colour.

    Edge pixels in the source are the mark already composited over the white
    card, so carrying their RGB into a straight-alpha image paints a white
    fringe the moment iOS 26's dark appearance composites it on black. Eroding
    two pixels clears the blend zone, then every pixel takes the colour of its
    nearest surviving interior pixel.
    """
    interior = ndimage.binary_erosion(mask, np.ones((3, 3)), iterations=2)
    if not interior.any():
        die("mark is too thin to decontaminate")
    _, (iy, ix) = ndimage.distance_transform_edt(~interior, return_indices=True)
    return rgb[iy, ix]


def mirror_axis(alpha: np.ndarray) -> float:
    """Sub-pixel vertical axis maximising self-mirror IoU."""
    width = alpha.shape[1]
    columns = np.arange(width)
    _, xs = np.nonzero(alpha > 0.5)
    centre = (xs.min() + xs.max()) // 2

    def mirrored(cx: float) -> np.ndarray:
        src = 2.0 * cx - columns
        lo = np.floor(src).astype(int)
        frac = src - lo
        left = np.clip(lo, 0, width - 1)
        right = np.clip(lo + 1, 0, width - 1)
        return alpha[:, left] * (1.0 - frac) + alpha[:, right] * frac

    best_cx, best_iou = float(centre), -1.0
    for step in range(-60, 61):
        cx = centre + step / 2.0
        other = mirrored(cx)
        union = np.maximum(alpha, other).sum()
        iou = float(np.minimum(alpha, other).sum() / union) if union else 0.0
        if iou > best_iou:
            best_cx, best_iou = cx, iou
    print(f"  mirror axis x={best_cx} (IoU {best_iou:.5f})")
    return best_cx


def symmetric_alpha(alpha: np.ndarray) -> np.ndarray:
    """Average the two halves, so the traced silhouette is exactly symmetric.

    Applied to the FLAT vector only. The raster keeps the render's real,
    slightly asymmetric lighting -- that is the artwork, not an error.
    """
    width = alpha.shape[1]
    columns = np.arange(width)
    src = 2.0 * mirror_axis(alpha) - columns
    lo = np.floor(src).astype(int)
    frac = src - lo
    left = np.clip(lo, 0, width - 1)
    right = np.clip(lo + 1, 0, width - 1)
    return (alpha + alpha[:, left] * (1.0 - frac) + alpha[:, right] * frac) / 2.0


def trace_flat(alpha: np.ndarray, size: int) -> str:
    """potrace the symmetric mask, baked into a CANVAS-sized viewBox."""
    with tempfile.TemporaryDirectory() as tmp:
        pbm, svg = Path(tmp) / "mask.pbm", Path(tmp) / "mask.svg"
        # potrace traces black; invert so the subject is the ink.
        Image.fromarray((~(alpha > 0.5)).astype(np.uint8) * 255).convert("1").save(pbm)
        try:
            subprocess.run(
                ["potrace", str(pbm), "-s", "-o", str(svg),
                 "-a", POTRACE_ALPHAMAX, "-O", POTRACE_OPTTOLERANCE,
                 "-u", POTRACE_UNIT, "-t", POTRACE_TURDSIZE],
                check=True, capture_output=True,
            )
        except FileNotFoundError:
            die("potrace not found on PATH — brew install potrace")
        except subprocess.CalledProcessError as exc:
            die(f"potrace failed: {exc.stderr.decode(errors='replace').strip()}")
        raw = svg.read_text()

    joined = " ".join(re.findall(r'\bd="([^"]+)"', raw))
    if not joined.strip():
        die("potrace produced no path data")

    # potrace emits transform="translate(0,H) scale(0.01,-0.01)"; bake that out,
    # then scale the source canvas into CANVAS so the vector registers exactly
    # with the raster (which is the same canvas, same scale).
    scale = CANVAS / size

    def bake(z: complex) -> complex:
        return complex((0.01 * z.real) * scale, (size - 0.01 * z.imag) * scale)

    segments = []
    for seg in parse_path(joined):
        if isinstance(seg, CubicBezier):
            segments.append(CubicBezier(bake(seg.start), bake(seg.control1),
                                        bake(seg.control2), bake(seg.end)))
        elif isinstance(seg, Line):
            segments.append(Line(bake(seg.start), bake(seg.end)))
        else:
            die(f"unexpected segment type from potrace: {type(seg).__name__}")

    d = re.sub(r"(\d+\.\d{2})\d+", r"\1", SvgPath(*segments).d())
    print(f"  flat silhouette: {len(segments)} segments")
    return d


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out-dir", type=Path, default=DEFAULT_OUT,
        help="where to write the two artifacts (default: Design/). "
             "check-icons-fresh.sh points this at a temp dir so it can "
             "regenerate and compare without touching the tree.",
    )
    out_dir = parser.parse_args().out_dir
    mark_png, flat_svg = out_dir / MARK_NAME, out_dir / FLAT_NAME

    if not SOURCE.exists():
        die(f"{SOURCE.relative_to(ROOT)} is missing")

    image = Image.open(SOURCE).convert("RGB")
    if image.width != image.height:
        die(f"expected a square source render, got {image.width}x{image.height}")
    size = image.width
    rgb = np.asarray(image).astype(np.float64)
    print(f"source {size}x{size}")

    mask = subject_mask(rgb)
    ys, xs = np.nonzero(mask)
    print(f"  subject bbox {xs.max()-xs.min()+1}x{ys.max()-ys.min()+1}"
          f" at ({xs.min()},{ys.min()})")

    alpha = coverage(mask)
    rgba = np.dstack([decontaminate(rgb, mask), alpha * 255.0])
    mark = Image.fromarray(rgba.astype(np.uint8), "RGBA")
    if size != CANVAS:
        mark = mark.resize((CANVAS, CANVAS), Image.LANCZOS)
    mark_png.parent.mkdir(parents=True, exist_ok=True)
    mark.save(mark_png)
    print(f"  wrote {mark_png} ({CANVAS}x{CANVAS} RGBA)")

    d = trace_flat(symmetric_alpha(alpha), size)
    flat_svg.write_text(
        '<svg xmlns="http://www.w3.org/2000/svg" '
        f'viewBox="0 0 {CANVAS} {CANVAS}" width="{CANVAS}" height="{CANVAS}">'
        f'<path fill="currentColor" d="{d}"/>'
        "</svg>\n"
    )
    print(f"  wrote {flat_svg} ({flat_svg.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
