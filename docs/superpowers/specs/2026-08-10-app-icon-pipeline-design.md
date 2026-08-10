# App icon pipeline — design

Replaces the current orange-flame `AppIcon.appiconset` with the webbed-foot mark,
delivered through an Icon Composer `.icon` package, and makes every derived image
regenerable from a committed source render.

## Why this shape

`deploymentTarget` is iOS 26.0, so the icon ships as an Icon Composer package and
nothing needs to fall back to the retired size matrix. Two consequences drive the
whole design:

- **The container is the system's, not ours.** iOS 26 supplies the squircle, the
  drop shadow, and the liquid-glass specular. The white card, rounded corners, and
  cast shadow in the source render are therefore *discarded during extraction* —
  baking our own would double up on the system's.
- **There is no icon-set to generate.** An iOS appiconset has been a single 1024
  PNG since Xcode 14; a `.icon` is one package. Tools that generate the
  20/29/40/60/76/83.5 matrix solve a problem that no longer exists, and none are
  adopted here.

## The dimensional mark stays raster — deliberately

Three vectorizations of the shaded render were built and compared by eye:

| Approach | Result |
| --- | --- |
| vtracer, 384 stacked colour regions | Visibly faceted; posterization banding in every smooth region |
| Residual-driven gradient decomposition | Plateaued early; feathering destroyed the rim highlight |
| Authored 8-path/8-gradient illustration | Smooth and correct in character, but grooves shallower than the source |

All three are worse than the source render. An iOS icon tops out at 1024 and the
extracted subject lands at ~657px inside that frame — a downscale, so the raster is
lossless at every size iOS asks for. **Vectorizing the shaded render buys nothing
and costs fidelity, so it is not done.**

CIEDE2000 was used as the decision metric early and was wrong twice: it scored the
faceted trace at ΔE 1.18 (mean error is blind to hard edges inserted into smooth
gradients, which is exactly what the eye catches), then inflated to 3.19 once the
geometry was reframed, because misregistration dominated. **The metric is not part
of this pipeline.** Candidates are judged visually; the automated check verifies
reproducibility, not beauty.

The flat silhouette *is* vector, because it has jobs the raster cannot do: the
Tinted/Mono appearance, 29px, favicons, README, and print.

## Components

### Source of truth

`Design/source/waddle-logo.png` — the original 1254² render, committed. Every other
image derives from it. If the logo changes, a new render replaces this file and
everything downstream regenerates.

### `Scripts/extract-mark.py`

Single-purpose, PEP 723 inline dependencies so `uv run` needs no venv. Reads the
source render, writes two artifacts:

- `Design/waddle-mark.png` — subject on transparency in a 1024 canvas. Mask is
  saturation-thresholded (the drop shadow is desaturated grey and falls out
  cleanly), reduced to the largest connected component with holes filled. Alpha is
  soft-edged, not binarised, so the extraction keeps the render's anti-aliasing.
  Geometry is *not* symmetrised — this is the original art.
- `Design/waddle-mark-flat.svg` — potrace on a symmetrised mask, normalised into a
  1024 viewBox. 22 segments, ~900 bytes.

Symmetry is applied only to the flat vector: the mark is 98.8% mirror-symmetric
about x=625.0, so averaging the halves before tracing yields an exactly symmetric
path, while the raster keeps the render's real (slightly asymmetric) lighting.

### `App/AppIcon.icon`

Package directory, hand-authored so it diffs. Verified format:

```
AppIcon.icon/
  icon.json
  Assets/mark.png
```

`icon.json` carries a top-level `fill` for the background, one group holding the
mark layer, and `supported-platforms`. `specular` is disabled — the render already
contains its own highlights. Shadow stays system-driven.

Basename must match `ASSETCATALOG_COMPILER_APPICON_NAME` (`AppIcon`).

### Build wiring

`App/project.yml` gains `AppIcon.icon` as a target resource;
`App/Assets.xcassets/AppIcon.appiconset/` is deleted. `ASSETCATALOG_COMPILER_APPICON_NAME`
is already `AppIcon` and does not change.

### `Scripts/render-icons.sh` (`mise run icons`)

Runs the extraction and copies the mark into the `.icon` package. That is the
whole job.

Two things this spec originally proposed were dropped once it came time to build
them:

- **Flat-mark PNG rasters.** Nothing consumes them yet. The SVG is the deliverable;
  rasters can be added when something actually needs one.
- **A composited 1024 "marketing" icon.** It would require approximating Apple's
  squircle, and an approximation of a proprietary shape is worse than no file at
  all. App Store Connect takes the icon from the build, and a press kit is better
  served by an export from Icon Composer.

### `Scripts/check-icons-fresh.sh`

Mirrors `check-engine-fresh.sh`: compares **content**, never mtimes, so a fresh
checkout or restored CI cache does not trip it.

Two modes, because they need different things installed:

- `--sync-only` — verifies the `.icon` package's copy is byte-identical to
  `Design/waddle-mark.png`. Pure file comparison, no tooling. This is what CI runs,
  in the cheap step that executes before toolchain setup, where neither `uv` nor
  `potrace` exists.
- default — re-runs the extraction into a temp dir and compares both derived files,
  proving the committed assets are what the source produces. Needs `uv` and `potrace`.

The narrow CI mode is a *scoped* check, not a fail-open one: within its scope it
fails closed, and it never silently downgrades — you get the mode you asked for or
an error.

No renderer-version assertion is needed after all: the pipeline lost its `resvg`
and `oxipng` steps along with the dropped rasters, and the surviving `potrace`
output proved byte-reproducible across runs.

## Testing

The pipeline produces images, so the meaningful verification is that the app builds
with the new icon and that regeneration is reproducible:

1. `xcodegen generate` succeeds with the `.icon` wired in.
2. `xcodebuild` compiles the asset catalog without actool errors.
3. `Scripts/check-icons-fresh.sh` passes on a clean tree and fails after touching a
   `Design/` source without regenerating.

## What building it turned up

Recorded in `docs/learnings/icon-composer-package.md`:

- The `.icon` format itself, confirmed against a shipping example rather than
  guessed from framework strings.
- **Top-level `fill-specializations` is silently ignored by actool** — it compiles
  clean and does nothing. The obvious way to give the icon a dark background is a
  no-op, and only a size comparison reveals it.
- **actool output is nondeterministic** — identical input, different digests every
  build. This is why the freshness check compares `Design/` sources and never
  `Assets.car`.
- **The simulator caches icons past reinstall**, so a screenshot is not evidence
  until SpringBoard is restarted.

## Known limitations

- **No dark-appearance background.** The icon keeps its white ground in dark mode,
  which is ordinary iOS behaviour for an app that ships no dark variant. Adding one
  needs Icon Composer.app, since the hand-written key does not take.
- **The dark rendition was never visually confirmed.** It exists in the catalog with
  distinct content, but the simulator's icon cache and home-screen paging defeated
  every attempt to photograph it, and it was not worth more time.
- **This is a rebrand**, not a refresh — it replaces the flame icon outright.
