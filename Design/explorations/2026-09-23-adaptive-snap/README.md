# Adaptive grid snap — parked

Parked, not shipped. The duck icon was reverted to the WADDLE wordmark for a
release; this branch keeps the duck work and the fix below so it can be picked
up again.

## Why the duck looked soft

`duck-66px.png` was made by `pixelate.py --cells 66 --phase 0`, which assumes
the reference sits on a uniform 19px grid starting at 0. It does not:

- `ref-01-doom-duck.png` is image-model "pixel art" — its blocks run 18–25px.
- The best-fitting horizontal phase drifts from 11 to 16 across the image; the
  global best is roughly x=16, y=17, not 0.

Wherever the fixed grid slides off the real blocks, a cell straddles two of
them. The result is doubled outlines down the right side, black bars through
the beak, a lopsided grille and outlines that alternate 1 and 2 cells wide —
which at 120px reads as "not crisp".

## The fix

`adaptive.py` places each cut on the image's own edge peaks instead: dynamic
programming over the column/row edge-energy profile, gaps constrained to the
nominal period ±5, with a per-cut penalty (90th-percentile edge energy) so it
does not invent extra cuts in flat regions.

```sh
uv run --with pillow --with numpy python adaptive.py \
  ../references/ref-01-doom-duck.png duck-adaptive-raw.png 19
```

`duck-adaptive-13col.png` is that output remapped onto the 13 colours of the
committed `duck-66px.png`, background made transparent and trimmed: 50x57 art
cells. `compare-current-vs-adaptive.png` shows current (left) against adaptive
(right) at 512/180/120/60 on the `#E8E6DE` ground. The owner approved the
adaptive version.

## To resume

1. Fold `adaptive.py`'s cut search into `pixelate.py`, regenerate
   `Design/source/duck/duck-66px.png`, then `mise run icons`. The raw grid is
   63x65, not 66x66 — check whether `check-icons-fresh.sh` or its tests assume 66.
2. Add a `docs/learnings/` entry: image-model pixel art is not on a uniform grid.
3. Before shipping, check the Dark and Tinted appearances: actool derives them
   from the layer, and a dark ground brings back the black-outline-on-dark
   contrast failure (1.09:1) that the light ground fixed.

The gitignored sweeps (48 MB) are archived outside the repo at
`~/waddle-duck-explorations-2026-09-23.tgz`.
