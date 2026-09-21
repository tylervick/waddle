# Icon exploration

How `Design/source/duck/duck-66px.png` — the committed source the app icon
derives from — was actually made. The tools here are **provenance, not build
steps**: nothing in `Scripts/` calls them, and the 66x66 grid is checked in, so
the icon pipeline does not depend on this directory.

## Lineage

```text
references/ref-01-doom-duck-512.png     the owner's chosen artwork
  -> recolour-png.py --map teal:48:0.92 --lift 0.35 --target-l 0.60
  -> pixelate.py --cells 66 --phase 0 --palette 16
  -> Design/source/duck/duck-66px.png
```

`recolour-png.py` remaps colour classes by hue without moving a pixel — every
generation, including image-to-image with a reference, redraws the subject, so
once artwork is right and only its palette is wrong a model is the wrong tool.

`pixelate.py` snaps a pixel-art-*styled* image onto its true integer grid.
Images from image models look like pixel art but carry baked-in anti-aliasing;
this one arrived with 40,123 colours and left with 15. Finding the grid needs
scoring candidate periods **against chance** — a naive sweep favours small
periods, because a period of 10 catches 40% of edges at random. The real period
was 19.0, and 19 x 66 = 1254, the image's own size.

`recolour-svg.py` is the SVG equivalent, kept because it is what proved the
approach before the PNG path existed. Nothing in the current lineage uses it.

## What is not tracked

The concept and style sweeps that led here — nine concepts across twelve styles
and several palettes — came to 46 MB of generated PNGs. They are deliberately
gitignored rather than committed: they are superseded, and git history is the
wrong place for a mood board. See `.gitignore` for the exact paths. Re-running
them costs about a dollar; the prompts and the generator are in
`../icon-prompts.md`.
