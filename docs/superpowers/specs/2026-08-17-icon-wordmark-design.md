# App icon: from pictorial mark to Freedoom wordmark

**Status: approved at the brainstorming gate (2026-08-17).**

The app icon stops being a rendered orange webbed foot and becomes the name,
set in Freedoom's own beveled font and tinted the game's own nukage green. The
app's accent colour moves with it. This supersedes
`docs/superpowers/specs/2026-08-10-app-icon-pipeline-design.md`, whose subject
— extracting a rendered subject from an AI image — no longer exists.

## 1. What the mark is

**`WAD` over `DLE`, all caps, set in Freedoom's `DBIGFONT`, tinted `#77FF6F`,
on a dark ground.**

`DBIGFONT` is not the 9×7 status-bar font. It is a FON2 lump: height 15,
variable width, stored as a greyscale ramp with highlights and shadows so
source ports can tint it at runtime. It is already a beveled metal face —
which is the aesthetic this redesign was reaching for, sitting in a file the
app already ships.

**All caps is forced, and it is fine.** Both Freedoom fonts are uppercase-only
— `DBIGFONT` covers `0x20`–`0x60`, `STCFN` runs 33–96 plus a stray `y`. The
letters `d`, `l`, `e` do not exist in either. The mixed-case wordmark is
therefore impossible without drawing half the letters by hand. `WADDLE` still
contains `WAD`; the pun stops being typographically marked, and `WADDLE_*` is
already the project's own all-caps form.

**Stacking is load-bearing.** `WAD`/`DLE` is 48×32 source pixels — near-square,
filling an icon. Set on one line, `WADDLE` is 89×15: a 5.9:1 ribbon that leaves
most of a square empty.

**Accepted limitation.** The mark reads as texture rather than letters at 40pt
(Settings, Spotlight). It holds to roughly 80pt. This is inherent to a 15px
source with a bevel and no pipeline work fixes it. A simplified small-size
variant is out of scope: `.icon` has no size-variant mechanism, so it would
mean a second asset outside the package.

## 2. Colour

**Icon and app accent both become `#77FF6F`** — Freedoom's own PLAYPAL nukage
green, which makes the palette as license-clean and as native as the
letterforms.

The retired orange `#F4490A` was chosen for the webbed foot. With the foot
retired it is orphaned, not inherited.

### 2.1 The accent re-point is an accessibility fix

Measured against the app's `#0E0E10` background and label colours:

| Case | Ratio | WCAG |
| --- | --- | --- |
| Green `#77FF6F` text on `#0E0E10` | **14.98** | AAA |
| Red `#CC2C20` text on `#0E0E10` | 3.63 | AA-large only |
| White label on green fill | **1.29** | **FAIL** |
| White label on red fill | 5.32 | AA |
| Black label on green fill | **16.32** | AAA |
| Black label on red fill | 3.95 | AA-large |

Two consequences:

- The **existing red is the weak one.** "Continue" text at 3.63 clears only
  AA-large today. The re-point fixes that, and this — not aesthetics — is the
  durable justification to record in the spec it amends.
- **The filled button is the whole problem.** Green behind a white label is
  catastrophic and behind a black one is excellent, so the fix is to flip the
  label, not to compromise the green.

No single green serves both roles: `#1F7A2B` reaches AA for white-on-fill
(5.42) but drops to 3.56 as text on dark; `#3AA347` does the reverse. The
tension is structural, which is why the black label is the answer rather than
a hue compromise.

### 2.2 Where it lands

- `App/Assets.xcassets/AccentColor.colorset` → srgb `0.467 / 1.000 / 0.435`
- `App/Sources/UI/ShelfView.swift:222` — the `.borderedProminent` "Add Your
  Games" button gets an explicit black label
- `App/Sources/UI/Theme.swift:58` and `App/project.yml:58` — both describe it
  in prose as "the one **red** accent"; both must follow
- `docs/superpowers/specs/2026-08-13-launcher-ux-design.md` §5 "Visual system"
  — **amended, not contradicted.** The structure of the commitment survives:
  still one accent, still worn by exactly two controls (Add Your Games, and
  Continue, which §4 guarantees cannot be showing at the same time). Only the
  value changes, and the contrast measurement above is the reason.

**Unverified assumption:** that `.borderedProminent` honours a
`.foregroundStyle(.black)` on its label rather than forcing its own. SwiftUI
has changed this across releases. The plan verifies it in a real build before
relying on it, and falls back to a custom `ButtonStyle` if it does not hold.

## 3. Pipeline

The existing pipeline runs one direction: a hand-supplied AI render →
`extract-mark.py` isolates the subject and potraces a silhouette → derived
assets. That machinery exists to pull a rendered object off a card, and a
wordmark composed from bitmap glyphs needs none of it.

The architecture — tracked source → derived assets → byte-compare guard — is
kept. Only the source and the generator change.

```text
Design/source/freedoom-glyphs.png   tracked: W A D L E, decoded from DBIGFONT
        ↓  Scripts/build-mark.py    compose → tint → emit
Design/waddle-mark.png              derived: transparent lockup, 1024
Design/waddle-mark-flat.svg         derived: pixel grid → rects
App/AppIcon.icon/Assets/mark.png    derived: copy
```

### 3.1 The source of truth is a committed extraction, not the WAD

`Scripts/fetch-freedoom.sh` pins `FREEDOOM_VERSION="0.13.0"` and verifies a
SHA-256 checksum, so deriving from the WAD would be reproducible. It is still
the wrong input for the regen step:

- `App/Resources/GameData/` is **gitignored**. Reading the WAD would make icon
  verification depend on a fetched binary and a network round-trip, in a guard
  (`check-icons-fresh.sh`) that is otherwise offline and hermetic.
- Bumping `FREEDOOM_VERSION` would silently restyle the brand mark. With a
  committed extraction the mark changes only when someone deliberately
  re-extracts, and the byte-compare guard makes that change visible in review.

This matches how the repo already treats the engine — vendor and pin, rather
than fetch at verify time.

### 3.2 Two scripts, split by how often they run

- **`Scripts/extract-freedoom-glyphs.py`** — rare and deliberate. Reads the
  pinned WAD, decodes the FON2 RLE, writes `Design/source/freedoom-glyphs.png`.
  The only thing that touches Freedoom.
- **`Scripts/build-mark.py`** — every regen, offline. Composes the stack,
  applies a hue-preserving HSV tint ramp, emits the transparent mark PNG and
  the flat SVG.

The tint must be HSV-based, not a lerp toward white: lerping desaturates: red
became pink and the bevel flattened when this was first built. Preserving hue
and driving value/saturation keeps the bevel intact and makes a future palette
change a one-line edit rather than a redraw.

Compositing is integer-scaled nearest-neighbour so the pixel grid stays exact
at every size.

### 3.3 The layer is transparent; `icon.json` owns the ground

`icon.json`'s `fill` changes from `extended-gray:1.00000,1.00000` (white) to
the dark ground. The mark layer ships as **transparent green glyphs**.

This is not cosmetic. `docs/learnings/icon-composer-package.md` records that
Dark and Tinted are derived by actool *from the layer artwork*. Baking the
ground into the PNG would fight the format and degrade both derived
appearances.

### 3.4 `potrace` leaves; `uv` stays

Nothing traces any more. A pixel grid converts to SVG rects directly — no
faceting, exactly symmetric by construction.

`potrace` was never a bootstrap dependency; it is required only by
`render-icons.sh` and by `check-icons-fresh.sh` in full mode. Both drop it.
`uv` stays, because both new scripts are Python.

This touches two existing tests directly: `test-check-icons-fresh.sh` asserts
that `--sync-only` runs *with no uv and no potrace on PATH*, and that full mode
*refuses* without them. The second assertion changes shape when potrace is no
longer required. `--sync-only` exists because CI has neither tool, so that
split must survive the rewrite intact — it is what keeps icon verification
runnable on the runner.

## 4. Attribution

`FREEDOOM-BSD.txt` is 3-clause BSD. Two clauses matter:

- **Reproduce the copyright notice** in documentation or accompanying
  materials. Already satisfied: the app ships `FREEDOOM-BSD.txt` and credits
  Freedoom in `NOTICES.md`.
- **Clause 3, non-endorsement.** The Freedoom name may not be used to endorse
  or promote products derived from it without written permission. Using the
  glyph artwork is plainly fine. Leaning on "Freedoom" as an App Store selling
  point would not be. Keep the attribution factual and in the notices; it is
  not a feature bullet.

`NOTICES.md` currently reads "Freedoom (game data) — BSD-style license". Once
the icon derives from `DBIGFONT` that understates the use, and the entry must
say the app mark derives from Freedoom's font artwork.

## 5. Documentation

- **`Design/README.md` is rewritten, not edited.** Every word describes the
  foot: the extraction, the 98.8% asymmetry, the three rejected vectorizations,
  the orange colour table. All of it becomes wrong at once.
- **A new learning** records what this investigation cost: Freedoom's fonts are
  uppercase-only; `STCFN` is the 9×7 status-bar font while `DBIGFONT` is a
  FON2 beveled face; the glyph data is RLE-compressed. None of it is knowable
  from outside the WAD.
- `docs/superpowers/specs/2026-08-10-app-icon-pipeline-design.md` is marked
  superseded rather than deleted — it is a dated record, and
  `docs/learnings/the-name-is-waddle.md` establishes that those stay.

## 6. Deleted

- `Design/source/waddle-logo.png` — the AI render of the foot
- `Design/waddle-mark.png`, `Design/waddle-mark-flat.svg`
- `Scripts/extract-mark.py` — subject extraction and potrace, entirely obsolete
- `potrace` from the bootstrap path

## 7. Verification

- `mise run icons` regenerates; `mise run check-icons` byte-compares. Guards
  keep their shape — only `check-icons-fresh.sh`'s input path and generator
  change, with `test-check-icons-fresh.sh` following.
- `check-icon-json.sh` needs **no change**. It asserts only that root-level
  `fill-specializations` is absent — actool silently ignores it — and does not
  assert on `fill`'s value. Its own comment corroborates §3.3: actool derives
  the appearances from the layer artwork, and `fill` sets the default
  appearance only.
- **All three appearances must be confirmed in a built app**, not inferred from
  a green build:
  `xcrun assetutil --info "$APP/Assets.car" | grep -A2 UIAppearanceDark`
  should yield renditions for the default appearance, `UIAppearanceDark`, and
  `ISAppearanceTintable`.
- The simulator caches icons aggressively (`icon-composer-package.md`); a stale
  icon after install is expected, not a regression.

## 8. Out of scope

- **A small-size icon variant.** `.icon` has no mechanism for it.
- **Re-pointing anything beyond the accent.** `AppBackground`, `AppSurface` and
  `AppSecondaryText` are unchanged.
- **The App Store listing.** Its name is blocked on `WAITING_FOR_REVIEW`
  (see `docs/app-store/metadata.md` §1); a new icon can ship with the next
  version alongside it.
