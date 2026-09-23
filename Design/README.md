# Waddle brand assets

The mark is the app's name, set in Freedoom's own `DBIGFONT` and tinted the
game's own nukage green. Everything here derives from five committed glyph
PNGs — to change the mark, change those or the compositor, then re-run the
pipeline. Do not edit the derived assets.

```text
Design/source/freedoom-glyphs/{W,A,D,L,E}.png   tracked: decoded from DBIGFONT
Design/waddle-mark.png                          derived: transparent, 1024
Design/waddle-mark-flat.svg                     derived: rect grid, 1024 viewBox
App/AppIcon.icon/Assets/mark.png                derived: copy of waddle-mark.png
```

```sh
mise run icons         regenerate the derived assets
mise run check-icons   verify the committed assets match the source
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
| Anything at ≤1024 | `waddle-mark.png` |
| Small sizes, favicon, README, print | `waddle-mark-flat.svg` |

`waddle-mark-flat.svg` fills with `currentColor`, so it inherits colour from
its context rather than carrying its own.

## Colour

| Role | Hex |
| --- | --- |
| Mark tint | `#77FF6F` — Freedoom PLAYPAL nukage green |
| Icon ground | `#0E0E10` — set by `icon.json`'s `fill`, not baked into the mark |

The same green is the app's accent (`AccentColor`), so the icon and the app
agree. It was chosen partly on contrast: as text on the app background it
measures 14.98:1, against the previous red's 3.63:1. It is a *light* colour —
anything that fills with it needs a dark label, or the contrast inverts.

## Geometry

The mark is 48×32 source pixels, scaled 17× to 816×544 on the 1024 canvas
(`INSET = 0.82` in `Scripts/build-mark.py`). Measured against an iOS
continuous-corner squircle, that leaves ~99px of clearance; nothing clips until
an inset of 0.95. The size is therefore a design decision, not a safe-area
limit — it is deliberately larger than it needs to be, because the mark's one
weakness is legibility at 40pt and bigger letterforms are what survive the
downsample.

## Four things that look like bugs and are not

**The mark is all caps.** Freedoom has no lowercase in either of its fonts —
see `docs/learnings/freedoom-fonts-are-uppercase-fon2.md`. `WADDLE` still
contains `WAD`; the pun is simply not typographically marked.

**The two rows are ragged.** `WAD` is 48 source px, `DLE` is 40, and they are
centred rather than justified. Letterspacing `DLE` to square the block was
tried and reads as artificially stretched on a pixel face.

**The mark layer is transparent, with no ground, squircle or shadow.** iOS 26
supplies the container, the shadow and the specular; `icon.json`'s `fill`
supplies the ground. actool derives the Dark and Tinted appearances *from the
layer artwork*, so baking a ground in would degrade both.

**The flat SVG is a grid of rects, not a traced path.** The source is a pixel
grid, so rects are exact and symmetric by construction. Nothing traces, which
is why `potrace` is not a dependency.
