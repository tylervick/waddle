# Waddle brand assets

**Two sources, two marks, because they do different jobs.** The duck is what
the app icon shows; the wordmark is the name set in type, for places that want
the name rather than a symbol. Both are derived — nothing in this directory
except the two sources is hand-edited.

```text
Design/source/duck/duck-66px.png                tracked: 66x66, 15 colours
Design/waddle-duck.png                          derived: transparent, 1024
Design/waddle-duck-flat.svg                     derived: rect grid, 1024 viewBox
App/AppIcon.icon/Assets/duck.png                derived: copy of waddle-duck.png

Design/source/freedoom-glyphs/{W,A,D,L,E}.png   tracked: decoded from DBIGFONT
Design/waddle-mark.png                          derived: transparent, 1024
Design/waddle-mark-flat.svg                     derived: rect grid, currentColor
```

```sh
mise run icons         regenerate the derived assets
mise run check-icons   verify the committed assets match both sources
```

The glyphs are committed rather than read from the WAD at build time. The WAD
is gitignored and fetched, so reading it here would put a network round trip
inside `mise run check-icons` and let a `FREEDOOM_VERSION` bump silently
restyle the mark. To re-derive them deliberately, run
`Scripts/extract-freedoom-glyphs.py`.

## Which asset to use

| Use | Asset |
| --- | --- |
| App icon | `App/AppIcon.icon` — do not hand-edit; regenerate |
| The duck at ≤1024 | `waddle-duck.png` |
| The duck at any size, favicon, print | `waddle-duck-flat.svg` |
| The name in type | `waddle-mark.png`, or `waddle-mark-flat.svg` at small sizes |

`waddle-mark-flat.svg` fills with `currentColor`, so it inherits colour from
its context. `waddle-duck-flat.svg` does **not** and cannot: the duck is 15
colours and `currentColor` expresses one. It is built to read on a dark ground
but carries enough contrast to survive a light one.

## Colour

| Role | Hex |
| --- | --- |
| Duck palette | 13 colours, fixed by `duck-66px.png` — greens, teal, orange, near-black |
| Wordmark tint | `#77FF6F` — Freedoom PLAYPAL nukage green |
| Icon ground | `#E8E6DE` — set by `icon.json`'s `fill`, not baked into the layer |

**Why the ground is light.** The duck is fully enclosed by a `#000000`
outline — 93% of its outer boundary. Against the original near-black `#0E0E10`
ground that measured **1.09:1**, so the silhouette dissolved and the icon read
as a dim blob at 40pt; the feet disappeared entirely. `#E8E6DE` takes the same
boundary to **13.46:1**, measured on actool's own 120px rendition. Nudging the
ground darker trades that back: `#33383A`, the best dark option tried, only
reached 1.77:1.

Interior colours were never the problem and are untouched — because the duck is
enclosed, no interior colour ever meets the ground.

**Known loose end:** the app's `AccentColor` is still `#77FF6F`, which matched
the wordmark when the wordmark was the icon. Neither the duck's greens nor the
light ground are that colour, so the icon and the in-app accent no longer
agree. Deciding what the accent should be is a UX change, deliberately out of
scope for the icon work.

## Geometry

The duck source is 66x66 cells; its art occupies 50x56 of them. `build-duck.py`
trims to the art and scales by the largest **integer** factor that fits inside
`INSET = 0.85` — x15 today, giving a 750x840 mark with 92px of clearance on the
1024 canvas. Integer is the constraint, 0.85 is the ceiling: the factor is
whatever fits under it, never a fractional scale chosen to hit it exactly.

The wordmark is 48x32 source pixels at 17x (`INSET = 0.82` in `build-mark.py`).

## Five things that look like bugs and are not

**The duck layer is transparent, with no ground, squircle or shadow.** iOS 26
supplies the container, the shadow and the specular; `icon.json`'s `fill`
supplies the ground. actool derives the Dark and Tinted appearances *from the
layer artwork*, so baking a ground in would degrade both. Same rule as the
wordmark, same reason.

**The duck SVG carries explicit fills while the wordmark SVG uses
`currentColor`.** Not an inconsistency — a 15-colour mark cannot be expressed
as one inherited colour.

**Both flat SVGs are grids of rects, not traced paths.** Both sources are pixel
grids, so rects are exact and symmetric by construction. Nothing traces, which
is why `potrace` is not a dependency.

**The wordmark is all caps.** Freedoom has no lowercase in either of its fonts
— see `docs/learnings/freedoom-fonts-are-uppercase-fon2.md`. `WADDLE` still
contains `WAD`; the pun is simply not typographically marked.

**The wordmark's two rows are ragged.** `WAD` is 48 source px, `DLE` is 40, and
they are centred rather than justified. Letterspacing `DLE` to square the block
was tried and reads as artificially stretched on a pixel face.
