# WADdle brand assets

Everything here derives from one hand-supplied file. To change the logo, replace
that file and re-run the pipeline — do not edit the derived assets.

```
Design/source/waddle-logo.png   the only hand-supplied input (1254x1254 render)
Design/waddle-mark.png          derived: subject on transparency, 1024 canvas
Design/waddle-mark-flat.svg     derived: flat silhouette, 1024 viewBox
App/AppIcon.icon/Assets/mark.png  derived: copy of waddle-mark.png
```

```
mise run icons         regenerate everything from the source render
mise run check-icons   verify the committed assets match the source
```

## Which asset to use

| Use | Asset |
| --- | --- |
| App icon | `App/AppIcon.icon` — do not hand-edit; regenerate |
| Anything dimensional at ≤1024 | `waddle-mark.png` |
| Tinted/Mono, small sizes, favicon, README, print | `waddle-mark-flat.svg` |

`waddle-mark-flat.svg` fills with `currentColor`, so it inherits colour from its
context rather than carrying its own.

## Colour

| Role | Hex |
| --- | --- |
| Mark, core | `#F4490A` |
| Mark, interior face | `#F95109` (top) → `#F74104` (bottom) |
| Mark, rim highlight | `#F56E31` |
| Mark, bottom lip | `#B51F04` |
| Icon background | white |

The interior face is almost flat; the dimensionality is carried by the rim and
the bottom lip, not by a body gradient. Worth knowing before anyone "fixes" the
mark by adding a strong gradient to it.

## Two things that look like bugs and are not

**The mark is not perfectly symmetric.** It is 98.8% mirror-symmetric about
x=625.0 in the source. The raster keeps that real asymmetry, because the render
is lit slightly off-axis and that is the artwork. Only the flat vector is
symmetrised — its halves are averaged before tracing, so the traced path is
exactly symmetric.

**The mark carries no squircle, no background, and no drop shadow.** iOS 26
supplies all three. They are stripped during extraction so the icon does not
ship a second shadow underneath the system's.

## Why the dimensional mark is raster

Three vectorizations were built and compared against the render: a machine trace
(visibly faceted), a residual-driven gradient decomposition (lost the rim
highlight), and an authored 8-path illustration (correct in character, grooves
too shallow). All three read worse than the render. An iOS icon tops out at 1024
and the subject lands ~657px inside that frame, so the raster is lossless at
every size iOS asks for.

Full reasoning: `docs/superpowers/specs/2026-08-10-app-icon-pipeline-design.md`.
