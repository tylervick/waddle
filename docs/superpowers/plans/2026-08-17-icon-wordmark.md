# Icon Wordmark Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the rendered webbed-foot app icon with `WAD`/`DLE` set in Freedoom's `DBIGFONT`, tinted nukage green, and move the app's accent colour to match.

**Architecture:** The icon pipeline keeps its shape — tracked source → derived assets → byte-compare guard — but reverses direction. Instead of extracting a subject from an AI render and potracing it, a rarely-run script decodes glyphs out of the pinned Freedoom WAD into tracked PNGs, and an offline script composes, tints, and emits the mark from those. The accent re-point rides along because the same green must serve the icon and the two controls that wear the accent.

**Tech Stack:** Python via `uv` (Pillow), bash guard scripts, Icon Composer `.icon` package, XcodeGen, SwiftUI.

**Spec:** `docs/superpowers/specs/2026-08-17-icon-wordmark-design.md`

## Global Constraints

- Canonical mark: **`WAD` over `DLE`**, all caps, Freedoom `DBIGFONT`, tint `#77FF6F`.
- The mark layer ships **transparent**; `icon.json`'s `fill` owns the ground. actool derives Dark and Tinted *from the layer artwork* — baking a ground in degrades both.
- Accent green is `#77FF6F` = srgb `0.467 / 1.000 / 0.435`.
- The filled "Add Your Games" button gets a **black** label. White on this green is 1.29:1 (FAIL); black is 16.32:1 (AAA).
- Tint ramp must be **HSV, hue-preserving**. Lerping toward white desaturates — red became pink and the bevel flattened when first built.
- Compositing is **integer-scaled nearest-neighbour**. Never smooth-scale the pixel grid.
- `check-icons-fresh.sh --sync-only` must keep working **with no `uv` and no `potrace` on PATH** — CI has neither, and that split is what keeps icon verification runnable on the runner.
- Never edit or delete a test to make it pass.
- Conventional commits; work lands through a PR, never on `main`.
- Branch already exists: `tylervick/icon-wordmark`.

**Deviation from the spec, stated deliberately:** §3 writes the tracked source as a single `Design/source/freedoom-glyphs.png`. This plan uses a **directory of five PNGs** (`Design/source/freedoom-glyphs/{W,A,D,L,E}.png`) instead. The glyphs have different widths (17/15/14/12/12), so one sheet needs sidecar width metadata to be sliceable; five files are self-describing and diff readably. Same architecture, less machinery.

---

## File Structure

**Created:**
- `Scripts/extract-freedoom-glyphs.py` — FON2 RLE decoder. Reads the pinned WAD, writes the five tracked glyph PNGs. The *only* thing that touches Freedoom. Run rarely and deliberately.
- `Scripts/build-mark.py` — offline. Composes the stack, applies the HSV tint, emits `waddle-mark.png` (transparent) and `waddle-mark-flat.svg` (rects).
- `Scripts/test-build-mark.sh` — hermetic tests for the compositor.
- `Scripts/test-glyph-source.sh` — hermetic tests that the *tracked* glyph PNGs are well-formed, without needing the WAD.
- `Design/source/freedoom-glyphs/{W,A,D,L,E}.png` — tracked extraction.
- `docs/learnings/freedoom-fonts-are-uppercase-fon2.md`

**Modified:** `Scripts/render-icons.sh`, `Scripts/check-icons-fresh.sh`, `Scripts/test-check-icons-fresh.sh`, `mise.toml`, `App/AppIcon.icon/icon.json`, `App/Assets.xcassets/AccentColor.colorset/Contents.json`, `App/Sources/UI/ShelfView.swift`, `App/Sources/UI/Theme.swift`, `App/project.yml`, `docs/superpowers/specs/2026-08-13-launcher-ux-design.md`, `docs/superpowers/specs/2026-08-10-app-icon-pipeline-design.md`, `App/Resources/Licenses/NOTICES.md`, `Design/README.md`, `docs/learnings/INDEX.md`

**Deleted:** `Design/source/waddle-logo.png`, `Scripts/extract-mark.py`

---

## Task 1: Extract the glyphs from the WAD

**Files:**
- Create: `Scripts/extract-freedoom-glyphs.py`
- Create: `Design/source/freedoom-glyphs/{W,A,D,L,E}.png`
- Test: `Scripts/test-glyph-source.sh`

**Interfaces:**
- Consumes: `App/Resources/GameData/freedoom1.wad` (gitignored; `mise run fetch-freedoom` provides it).
- Produces: five PNGs, greyscale+alpha (`LA`), transparent background, at native size — `W` 17×15, `A` 15×15, `D` 14×15, `L` 12×15, `E` 12×15. Task 2 reads exactly these.

**Why the extractor has no round-trip test:** re-extraction needs the WAD, which is gitignored, so a test would either need the network or would have to skip — and a skipping guard fails open. Instead the *tracked artifact* is tested hermetically (Step 5), which is what every later step actually depends on.

- [ ] **Step 1: Write the extractor**

Create `Scripts/extract-freedoom-glyphs.py`:

```python
#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow"]
# ///
"""Decode the glyphs the Waddle mark is built from out of Freedoom's DBIGFONT.

Run rarely and deliberately: this is the only script that reads the WAD, and
its output is committed. Everything downstream works from the committed PNGs,
so `mise run check-icons` stays offline and a FREEDOOM_VERSION bump cannot
silently restyle the brand mark.

DBIGFONT is a FON2 lump, not a DOOM patch: height 15, variable width, a
greyscale ramp with highlights and shadows so source ports can tint it at
runtime. Freedoom has no lowercase, which is why the mark is all caps -- see
docs/learnings/freedoom-fonts-are-uppercase-fon2.md.
"""
import argparse, struct, sys
from pathlib import Path
from PIL import Image

GLYPHS = "WADLE"

def lumps(wad: bytes) -> dict[str, tuple[int, int]]:
    sig, n, off = struct.unpack("<4sii", wad[:12])
    if sig not in (b"IWAD", b"PWAD"):
        sys.exit(f"error: not a WAD (magic {sig!r})")
    out = {}
    for i in range(n):
        fp, sz, nm = struct.unpack("<ii8s", wad[off + i * 16 : off + i * 16 + 16])
        out[nm.rstrip(b"\0").decode("ascii", "replace")] = (fp, sz)
    return out

def unrle(src: bytes, i: int, need: int) -> tuple[bytes, int]:
    """FON2 glyph RLE: n>=0 copies n+1 literals; n<0 repeats one byte 1-n times."""
    out = bytearray()
    while len(out) < need:
        c = src[i]; i += 1
        c = c - 256 if c > 127 else c
        if c >= 0:
            out += src[i : i + c + 1]; i += c + 1
        elif c != -128:
            out += bytes([src[i]]) * (1 - c); i += 1
    return bytes(out[:need]), i

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--wad", default="App/Resources/GameData/freedoom1.wad")
    ap.add_argument("--out-dir", default="Design/source/freedoom-glyphs")
    a = ap.parse_args()

    wad_path = Path(a.wad)
    if not wad_path.is_file():
        sys.exit(f"error: {wad_path} is missing — run `mise run fetch-freedoom` first.")
    wad = wad_path.read_bytes()
    idx = lumps(wad)
    if "DBIGFONT" not in idx:
        sys.exit("error: DBIGFONT is absent from this WAD.")

    fp, sz = idx["DBIGFONT"]
    b = wad[fp : fp + sz]
    if b[:4] != b"FON2":
        sys.exit(f"error: DBIGFONT is not FON2 (magic {b[:4]!r}).")
    height, = struct.unpack("<H", b[4:6])
    first, last, const_w, _shading, pal_size, _flags = b[6:12]
    count = last - first + 1
    p = 12
    if const_w:
        w, = struct.unpack("<H", b[p : p + 2]); widths = [w] * count; p += 2
    else:
        widths = list(struct.unpack(f"<{count}H", b[p : p + 2 * count])); p += 2 * count
    pal = b[p : p + (pal_size + 1) * 3]; p += (pal_size + 1) * 3

    decoded, i = {}, p
    for gi in range(count):
        w = widths[gi]
        if w == 0:
            continue
        data, i = unrle(b, i, w * height)
        decoded[chr(first + gi)] = (w, data)

    missing = [c for c in GLYPHS if c not in decoded]
    if missing:
        sys.exit(f"error: glyphs absent from DBIGFONT: {missing}")

    out = Path(a.out_dir); out.mkdir(parents=True, exist_ok=True)
    for ch in GLYPHS:
        w, data = decoded[ch]
        im = Image.new("LA", (w, height), (0, 0))
        px = im.load()
        for y in range(height):
            for x in range(w):
                v = data[y * w + x]
                if v:
                    px[x, y] = (pal[v * 3], 255)   # palette is a greyscale ramp
        im.save(out / f"{ch}.png")
        print(f"  {ch}  {w}x{height}")

if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Run it**

```bash
cd ~/Documents/waddle
chmod +x Scripts/extract-freedoom-glyphs.py
mise run fetch-freedoom          # only if App/Resources/GameData/ is empty
uv run Scripts/extract-freedoom-glyphs.py
```

Expected: five lines — `W 17x15`, `A 15x15`, `D 14x15`, `L 12x15`, `E 12x15`.

- [ ] **Step 3: Confirm the decode is deterministic**

```bash
shasum -a 256 Design/source/freedoom-glyphs/*.png > /tmp/g1
uv run Scripts/extract-freedoom-glyphs.py >/dev/null
shasum -a 256 Design/source/freedoom-glyphs/*.png > /tmp/g2
diff /tmp/g1 /tmp/g2 && echo "deterministic"
```

Expected: `deterministic`. A difference here means the decoder has ordering or state dependence and must be fixed before anything is committed.

- [ ] **Step 4: Eyeball the glyphs**

```bash
open Design/source/freedoom-glyphs/W.png
```

Expected: a recognisable beveled `W` with light top edges and dark bottom edges — not noise. A garbled image means the RLE decode is wrong; do not proceed.

- [ ] **Step 5: Write the hermetic test for the tracked artifact**

Create `Scripts/test-glyph-source.sh`:

```bash
#!/bin/bash
# Tests the COMMITTED Freedoom glyph PNGs, without needing the WAD.
#
# The WAD is gitignored, so a round-trip test of the extractor would need the
# network or would have to skip -- and a skipping guard fails open. What every
# later step actually depends on is the committed artifact, so that is what is
# tested here: it exists, it has the right geometry, and it carries real
# transparency and a real greyscale ramp rather than a flat blob.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/Design/source/freedoom-glyphs"

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

for f in W A D L E; do
    [ -f "$DIR/$f.png" ] || fail "$DIR/$f.png is missing"
done
pass "all five glyph files are present"

uv run --quiet --with pillow python - "$DIR" <<'PY' || exit 1
import sys
from pathlib import Path
from PIL import Image
d = Path(sys.argv[1])
want = {"W": 17, "A": 15, "D": 14, "L": 12, "E": 12}
for ch, w in want.items():
    im = Image.open(d / f"{ch}.png")
    if im.size != (w, 15):
        sys.exit(f"FAIL: {ch}.png is {im.size}, expected {(w, 15)}")
    if im.mode != "LA":
        sys.exit(f"FAIL: {ch}.png mode is {im.mode}, expected LA")
    px = list(im.getdata())
    if not any(a == 0 for _, a in px):
        sys.exit(f"FAIL: {ch}.png has no transparent pixels — a ground was baked in")
    shades = {l for l, a in px if a}
    if len(shades) < 4:
        sys.exit(f"FAIL: {ch}.png has {len(shades)} shades — the bevel ramp is gone")
print("ok - geometry, mode, transparency and shading ramp are intact")
PY
pass "glyph artwork is well-formed"
echo "all glyph-source tests passed"
```

- [ ] **Step 6: Run it**

```bash
chmod +x Scripts/test-glyph-source.sh
Scripts/test-glyph-source.sh
```

Expected: three `ok -` lines, then `all glyph-source tests passed`.

- [ ] **Step 7: Commit**

```bash
git add Scripts/extract-freedoom-glyphs.py Scripts/test-glyph-source.sh Design/source/freedoom-glyphs
git commit -m "feat(design): extract the Freedoom glyphs the mark is built from

DBIGFONT is a FON2 lump -- height 15, variable width, a greyscale ramp
so ports can tint it at runtime. Decoded once and committed, so the icon
pipeline stays offline and a FREEDOOM_VERSION bump cannot silently
restyle the brand mark."
```

---

## Task 2: Compose and tint the mark

**Files:**
- Create: `Scripts/build-mark.py`
- Test: `Scripts/test-build-mark.sh`

**Interfaces:**
- Consumes: `Design/source/freedoom-glyphs/{W,A,D,L,E}.png` from Task 1.
- Produces: `build-mark.py --out-dir DIR` writing `DIR/waddle-mark.png` (1024×1024, RGBA, transparent ground) and `DIR/waddle-mark-flat.svg` (1024 viewBox, `<rect>` elements, `currentColor`). Task 3's `render-icons.sh` and `check-icons-fresh.sh` both call it with `--out-dir`.

- [ ] **Step 1: Write the failing test**

Create `Scripts/test-build-mark.sh`:

```bash
#!/bin/bash
# Tests for Scripts/build-mark.py.
#
# Hermetic: runs the real compositor against the committed glyph PNGs into a
# temp dir. Asserts the properties the .icon package depends on -- above all
# that the layer is TRANSPARENT, because actool derives the Dark and Tinted
# appearances from the layer artwork and a baked-in ground degrades both.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

uv run --quiet "$ROOT/Scripts/build-mark.py" --out-dir "$TMP" >/dev/null \
    || fail "build-mark.py exited non-zero"
pass "build-mark.py runs"

[ -f "$TMP/waddle-mark.png" ]      || fail "waddle-mark.png was not written"
[ -f "$TMP/waddle-mark-flat.svg" ] || fail "waddle-mark-flat.svg was not written"
pass "both outputs exist"

uv run --quiet --with pillow python - "$TMP" <<'PY' || exit 1
import sys
from pathlib import Path
from PIL import Image
d = Path(sys.argv[1])
im = Image.open(d / "waddle-mark.png")
if im.size != (1024, 1024): sys.exit(f"FAIL: mark is {im.size}, expected (1024, 1024)")
if im.mode != "RGBA":       sys.exit(f"FAIL: mark mode is {im.mode}, expected RGBA")
if im.getpixel((0, 0))[3] != 0:
    sys.exit("FAIL: corner pixel is opaque — a ground was baked into the layer")
opaque = [p for p in im.getdata() if p[3] == 255]
if not opaque: sys.exit("FAIL: mark is entirely transparent")
# Hue check: the tint must be green — G dominant on the brightest pixels.
bright = sorted(opaque, key=lambda p: p[0] + p[1] + p[2])[-200:]
if not all(p[1] > p[0] and p[1] > p[2] for p in bright):
    sys.exit("FAIL: brightest pixels are not green-dominant — tint ramp is wrong")
# Bevel check: a hue-preserving ramp keeps many distinct greens.
if len({p[:3] for p in opaque}) < 8:
    sys.exit("FAIL: too few distinct colours — the bevel was flattened")
print("ok - 1024 RGBA, transparent ground, green-dominant, bevel intact")
PY
pass "mark png has the properties the .icon package needs"

grep -q "<rect" "$TMP/waddle-mark-flat.svg" || fail "flat svg has no <rect> elements"
grep -q "currentColor" "$TMP/waddle-mark-flat.svg" || fail "flat svg does not use currentColor"
grep -q "<path" "$TMP/waddle-mark-flat.svg" && fail "flat svg contains a <path> — it should be rects, not a trace"
pass "flat svg is a rect grid using currentColor"

echo "all build-mark tests passed"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
chmod +x Scripts/test-build-mark.sh
Scripts/test-build-mark.sh
```

Expected: FAIL — `build-mark.py` does not exist yet.

- [ ] **Step 3: Write the compositor**

Create `Scripts/build-mark.py`:

```python
#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow"]
# ///
"""Compose the Waddle mark from the committed Freedoom glyphs.

Offline by design: reads only Design/source/freedoom-glyphs/, never the WAD,
so `mise run check-icons` needs no network and no fetched binary.

Three rules this file exists to hold:

  1. The layer is TRANSPARENT. icon.json's `fill` owns the ground, and actool
     derives Dark and Tinted from the layer artwork -- a baked-in ground
     degrades both appearances.
  2. The tint ramps in HSV, preserving hue. Lerping toward white desaturates:
     the first build turned red into pink and flattened the bevel.
  3. Scaling is integer nearest-neighbour. Smooth-scaling a 15px pixel grid
     turns a crisp bevel into mush.
"""
import argparse, colorsys
from pathlib import Path
from PIL import Image

GLYPH_DIR = Path("Design/source/freedoom-glyphs")
TINT = "#77FF6F"      # Freedoom PLAYPAL nukage green
CANVAS = 1024
INSET = 0.72          # fraction of the canvas the mark spans
TRACKING = 1          # px between glyphs, at source scale
LINE_GAP = 2          # px between the two lines, at source scale

def load(ch: str) -> Image.Image:
    return Image.open(GLYPH_DIR / f"{ch}.png").convert("LA")

def row(text: str) -> Image.Image:
    ims = [load(c) for c in text]
    w = sum(i.width for i in ims) + TRACKING * (len(ims) - 1)
    h = max(i.height for i in ims)
    out = Image.new("LA", (w, h), (0, 0))
    x = 0
    for im in ims:
        out.paste(im, (x, 0)); x += im.width + TRACKING
    return out

def stack(top: Image.Image, bottom: Image.Image) -> Image.Image:
    w = max(top.width, bottom.width)
    h = top.height + LINE_GAP + bottom.height
    out = Image.new("LA", (w, h), (0, 0))
    out.paste(top, ((w - top.width) // 2, 0))
    out.paste(bottom, ((w - bottom.width) // 2, top.height + LINE_GAP))
    return out

def tint(src: Image.Image, hexs: str) -> Image.Image:
    r, g, b = (int(hexs[i : i + 2], 16) / 255 for i in (1, 3, 5))
    hue, sat, val = colorsys.rgb_to_hsv(r, g, b)
    out = Image.new("RGBA", src.size, (0, 0, 0, 0))
    sp, op = src.load(), out.load()
    for y in range(src.height):
        for x in range(src.width):
            l, a = sp[x, y]
            if not a:
                continue
            t = l / 255.0
            v = (0.28 + 0.72 * (t ** 0.85)) * (0.85 + 0.35 * val)
            s = min(1.0, sat * (1.12 - 0.32 * t))
            rr, gg, bb = colorsys.hsv_to_rgb(hue, s, min(1.0, v))
            op[x, y] = (int(rr * 255), int(gg * 255), int(bb * 255), 255)
    return out

def to_svg(src: Image.Image, scale: int) -> str:
    """Pixel grid -> rects. No tracing: exact by construction, symmetric by
    construction, and no potrace dependency."""
    px = src.load()
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {CANVAS} {CANVAS}" '
        f'fill="currentColor" role="img" aria-label="Waddle">'
    ]
    ox = (CANVAS - src.width * scale) // 2
    oy = (CANVAS - src.height * scale) // 2
    for y in range(src.height):
        run_start = None
        for x in range(src.width + 1):
            solid = x < src.width and px[x, y][1] != 0
            if solid and run_start is None:
                run_start = x
            elif not solid and run_start is not None:
                parts.append(
                    f'<rect x="{ox + run_start * scale}" y="{oy + y * scale}" '
                    f'width="{(x - run_start) * scale}" height="{scale}"/>'
                )
                run_start = None
    parts.append("</svg>")
    return "".join(parts)

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", required=True)
    a = ap.parse_args()
    out = Path(a.out_dir); out.mkdir(parents=True, exist_ok=True)

    mark = stack(row("WAD"), row("DLE"))
    scale = max(1, int(CANVAS * INSET / mark.width))

    coloured = tint(mark, TINT)
    big = coloured.resize((mark.width * scale, mark.height * scale), Image.NEAREST)
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    canvas.alpha_composite(big, ((CANVAS - big.width) // 2, (CANVAS - big.height) // 2))
    canvas.save(out / "waddle-mark.png")

    (out / "waddle-mark-flat.svg").write_text(to_svg(mark, scale))
    print(f"  waddle-mark.png       {CANVAS}x{CANVAS}")
    print(f"  waddle-mark-flat.svg  {mark.width}x{mark.height} grid at {scale}x")

if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
Scripts/test-build-mark.sh
```

Expected: four `ok -` lines, then `all build-mark tests passed`.

- [ ] **Step 5: Look at it**

```bash
uv run Scripts/build-mark.py --out-dir /tmp/markcheck && open /tmp/markcheck/waddle-mark.png
```

Expected: green beveled `WAD` over `DLE` on a transparent (checkerboard) ground. If the ground is solid, rule 1 has been violated.

- [ ] **Step 6: Commit**

```bash
git add Scripts/build-mark.py Scripts/test-build-mark.sh
git commit -m "feat(design): compose the Waddle mark from the Freedoom glyphs

Transparent layer (icon.json owns the ground), hue-preserving HSV tint
so the bevel survives recolouring, integer nearest-neighbour scaling so
the pixel grid stays exact, and a rect-grid SVG that needs no potrace."
```

---

## Task 3: Rewire the pipeline and retire the foot

**Files:**
- Modify: `Scripts/render-icons.sh`, `Scripts/check-icons-fresh.sh`, `Scripts/test-check-icons-fresh.sh`, `mise.toml`
- Delete: `Scripts/extract-mark.py`, `Design/source/waddle-logo.png`
- Regenerate: `Design/waddle-mark.png`, `Design/waddle-mark-flat.svg`, `App/AppIcon.icon/Assets/mark.png`

**Interfaces:**
- Consumes: `build-mark.py --out-dir DIR` from Task 2.
- Produces: `mise run icons` regenerates all three derived assets; `mise run check-icons` byte-compares them; `check-icons-fresh.sh --sync-only` still runs with neither `uv` nor `potrace` on PATH.

- [ ] **Step 1: Point `render-icons.sh` at the new generator**

In `Scripts/render-icons.sh`, replace the tool loop so it no longer requires `potrace`:

```bash
for tool in uv; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: $tool is not on PATH." >&2
    echo "       install it: https://docs.astral.sh/uv/" >&2
    exit 1
  fi
done
```

and replace the generator call:

```bash
uv run --quiet "$ROOT/Scripts/build-mark.py" --out-dir "$OUT_DIR"
```

Update the header comment: the source is now `Design/source/freedoom-glyphs/`, not `Design/source/waddle-logo.png`.

- [ ] **Step 2: Point `check-icons-fresh.sh` at the new generator**

Change `SOURCE`:

```bash
SOURCE="$ROOT/Design/source/freedoom-glyphs"
```

Change its existence check — it is a directory now, and the five files matter:

```bash
for f in W A D L E; do
  [ -f "$SOURCE/$f.png" ] || fail "Design/source/freedoom-glyphs/$f.png is missing."
done
for f in "$MARK" "$FLAT" "$ICON_ASSET"; do
  [ -f "$f" ] || fail "${f#"$ROOT"/} is missing."
done
```

Drop `potrace` from the full-mode tool loop:

```bash
for tool in uv; do
```

And change the regeneration call and its failure message:

```bash
uv run --quiet "$ROOT/Scripts/build-mark.py" --out-dir "$TMP" >/dev/null \
  || fail "could not rebuild the mark from Design/source/freedoom-glyphs/."
```

- [ ] **Step 3: Update the potrace assertions in the guard's tests**

Both relevant cases strip `PATH` to `/usr/bin:/bin`, which hides `uv` exactly as effectively as it hid `potrace` — so **no test logic changes**. Only the wording that names potrace does. Do not delete either test: the sync-only/full split is what keeps CI able to verify icons.

Case 4's comment and message:

```bash
# 4. --sync-only must not need uv: it runs in CI before the toolchain
#    exists. Strip PATH to the system bins so it cannot be found.
```
```bash
pass "--sync-only runs with no uv on PATH"
```

Case 5's failure message:

```bash
    fail "full mode passed without uv instead of refusing"
```

Leave every `PATH="/usr/bin:/bin"` invocation and every assertion exactly as-is.

- [ ] **Step 4: Update the mise task description**

In `mise.toml`:

```toml
[tasks.icons]
description = "Regenerate icon assets from Design/source/freedoom-glyphs/"
run = "Scripts/render-icons.sh"
```

- [ ] **Step 5: Regenerate, and retire the foot**

```bash
cd ~/Documents/waddle
mise run icons
git rm Scripts/extract-mark.py Design/source/waddle-logo.png
```

- [ ] **Step 6: Verify the guards and their tests**

```bash
Scripts/test-build-mark.sh
Scripts/test-glyph-source.sh
Scripts/test-check-icons-fresh.sh
Scripts/check-icons-fresh.sh && echo "icons fresh"
Scripts/check-icon-json.sh && echo "icon json ok"
```

Expected: all pass. `check-icon-json.sh` needs no edit — it asserts only that root-level `fill-specializations` is absent, not anything about `fill`'s value.

- [ ] **Step 7: Verify `--sync-only` still works toolless**

This is the CI path; if it breaks, icon verification silently stops running on the runner.

```bash
env PATH=/usr/bin:/bin Scripts/check-icons-fresh.sh --sync-only && echo "sync-only ok without uv"
```

Expected: `sync-only ok without uv`.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor(design): rebuild the icon pipeline around the wordmark

Same architecture -- tracked source, derived assets, byte-compare guard --
but the source is now the committed Freedoom glyphs rather than an AI
render, and nothing traces, so potrace leaves. Retires the webbed foot."
```

---

## Task 4: The dark ground and the accent re-point

**Files:**
- Modify: `App/AppIcon.icon/icon.json`, `App/Assets.xcassets/AccentColor.colorset/Contents.json`, `App/Sources/UI/ShelfView.swift:212-223`, `App/Sources/UI/Theme.swift:58-62`, `App/project.yml:58-63`

**Interfaces:**
- Consumes: the transparent mark from Task 3.
- Produces: `Color.appAccent` == `#77FF6F`; the "Add Your Games" button renders a black label on a green fill.

- [ ] **Step 1: Give `icon.json` the dark ground**

Replace the `fill` value. The layer is transparent, so this is what the default appearance sits on:

```json
  "fill" : {
    "automatic-gradient" : "srgb:0.05490,0.05490,0.06275,1.00000"
  },
```

Leave `groups`, `shadow`, and `supported-platforms` untouched.

- [ ] **Step 2: Verify the fill string is actually accepted**

The `.icon` format has no public schema, and a malformed colour is accepted silently and then ignored — see `docs/learnings/icon-composer-package.md`. Build and inspect rather than trusting it:

```bash
mise run generate
xcodebuild -project App/Waddle.xcodeproj -scheme Waddle \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/iconbuild build 2>&1 | tail -5
APP=$(find /tmp/iconbuild -name 'Waddle.app' -type d | head -1)
xcrun assetutil --info "$APP/Assets.car" | grep -A2 UIAppearanceDark
```

Expected: renditions for the default appearance, `UIAppearanceDark`, and `ISAppearanceTintable`. If `srgb:` with four components is rejected, try three (`srgb:R,G,B`); if that also fails, fall back to `extended-gray:0.05490,1.00000` and note the finding for the learning in Task 5.

- [ ] **Step 3: Re-point the accent colour**

`App/Assets.xcassets/AccentColor.colorset/Contents.json`:

```json
        "components" : {
          "alpha" : "1.000",
          "blue" : "0.435",
          "green" : "1.000",
          "red" : "0.467"
        }
```

- [ ] **Step 4: Give the prominent button a black label**

In `App/Sources/UI/ShelfView.swift`, the "Add Your Games" button. White on this green measures 1.29:1 and fails; black measures 16.32:1:

```swift
            Button {
                showImporter = true
            } label: {
                Text("Add Your Games")
                    .frame(maxWidth: .infinity, minHeight: Theme.minimumTapTarget)
            }
            .buttonStyle(.borderedProminent)
            // Adding games is this screen's primary action while it is on
            // screen, and spec §5 names it as one of the two that wear the
            // single accent (the other being Continue, which by §4's rule
            // cannot be showing at the same time).
            //
            // The label is forced black: the accent is a light green, and
            // borderedProminent's default white label measures 1.29:1 against
            // it, which is a contrast failure. Black measures 16.32:1.
            .tint(Color.appAccent)
            .foregroundStyle(.black)
            .accessibilityIdentifier("addYourGamesButton")
```

- [ ] **Step 5: Verify the label override actually takes**

SwiftUI has changed whether `borderedProminent` honours `foregroundStyle` across releases, so this must be seen, not assumed.

```bash
mise run generate
xcodebuild -project App/Waddle.xcodeproj -scheme Waddle \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:WaddleUITests/PlayTabTests test 2>&1 | tail -20
xcrun simctl io booted screenshot /tmp/shelf.png && open /tmp/shelf.png
```

Expected: the "Add Your Games" button is green with **black** text. If the label is still white, `foregroundStyle` is being overridden — replace `.buttonStyle(.borderedProminent)` with a small custom `ButtonStyle` that fills with `Color.appAccent` and sets `.foregroundStyle(.black)`, and record the finding for Task 5's learning.

- [ ] **Step 6: Fix the prose that calls the accent red**

`App/Sources/UI/Theme.swift`:

```swift
    /// The one accent, reserved for primary actions — Freedoom's nukage green,
    /// matching the app icon. Also the asset catalog's global accent
    /// (`ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` in `App/project.yml`),
    /// which is what tints system controls the shell does not draw itself.
    static let appAccent = Color("AccentColor")
```

`App/project.yml`:

```yaml
        # The one accent of spec §5's visual system, named once in the
        # asset catalog (App/Assets.xcassets/AccentColor.colorset). Setting it
        # globally rather than tinting a view tree is what reaches the system
        # controls the shell does not draw itself — sheet confirmation buttons,
        # the document picker, context menus.
```

- [ ] **Step 7: Run the unit suite**

```bash
xcodebuild -project App/Waddle.xcodeproj -scheme Waddle \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' \
  -only-testing:WaddleTests test 2>&1 | tail -5
```

Expected: `TEST SUCCEEDED`, 327 tests.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(ui): move the accent to Freedoom's nukage green

Icon and app now agree on the product's colour. Also an accessibility
fix: the old red measured 3.63:1 as text on the app background (AA-large
only), the green measures 14.98:1. The prominent button's label is forced
black -- white on this green is 1.29:1."
```

---

## Task 5: Documentation, attribution, and the learning

**Files:**
- Rewrite: `Design/README.md`
- Modify: `App/Resources/Licenses/NOTICES.md`, `docs/superpowers/specs/2026-08-13-launcher-ux-design.md:113-119`, `docs/superpowers/specs/2026-08-10-app-icon-pipeline-design.md:1`, `docs/learnings/INDEX.md`
- Create: `docs/learnings/freedoom-fonts-are-uppercase-fon2.md`

**Interfaces:**
- Consumes: findings from Tasks 1–4, including anything learned in Task 4 Steps 2 and 5.
- Produces: a tree that satisfies `check-substrate.sh` (INDEX ↔ learnings bijection).

- [ ] **Step 1: Rewrite `Design/README.md`**

Every word of the current file describes the foot — the extraction, the 98.8% asymmetry, the three rejected vectorizations, the orange colour table. Replace the whole file:

```markdown
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
measures 14.98:1, against the previous red's 3.63:1.

## Three things that look like bugs and are not

**The mark is all caps.** Freedoom has no lowercase — see
`docs/learnings/freedoom-fonts-are-uppercase-fon2.md`. `WADDLE` still contains
`WAD`; the pun is simply not typographically marked.

**The mark layer is transparent, with no ground, squircle or shadow.** iOS 26
supplies all of those, and `icon.json`'s `fill` supplies the ground. actool
derives the Dark and Tinted appearances from the layer artwork, so baking a
ground in would degrade both.

**The flat SVG is a grid of rects, not a traced path.** The source is a pixel
grid, so rects are exact and symmetric by construction. Nothing traces, which
is why `potrace` is not a dependency.
```

- [ ] **Step 2: Widen the Freedoom attribution**

`App/Resources/Licenses/NOTICES.md` — the current entry says "(game data)", which understates the use once the app mark derives from `DBIGFONT`:

```markdown
- Freedoom (game data, and the font artwork the app mark is drawn from) —
  BSD-style license (FREEDOOM-BSD.txt), © 2001-2024 Contributors to the
  Freedoom project.
```

- [ ] **Step 3: Amend spec §5**

In `docs/superpowers/specs/2026-08-13-launcher-ux-design.md` §5, the sentence reading "a single red accent for primary actions (Continue, Add Your Games)" becomes:

```markdown
surface tone for cards and sheets, a single accent for primary actions
(Continue, Add Your Games) — Freedoom's nukage green `#77FF6F`, matching the
app icon — warm gray secondary text.
```

Then append to that paragraph:

```markdown
**Amended 2026-08-17** (`2026-08-17-icon-wordmark-design.md`): the accent was
red `#CC2C20` until the icon became a Freedoom wordmark. The structure of this
commitment is unchanged — still one accent, still worn by exactly these two
controls. The value changed for contrast as much as coherence: the red measured
3.63:1 as text on the near-black background (AA-large only), the green measures
14.98:1. The rule against retro chrome above governs the shell, not the icon.
```

- [ ] **Step 4: Mark the old icon spec superseded**

At the top of `docs/superpowers/specs/2026-08-10-app-icon-pipeline-design.md`, directly under the title:

```markdown
> **Superseded on 2026-08-17** by `2026-08-17-icon-wordmark-design.md`. The
> subject of this document — extracting a rendered subject from an AI image and
> vectorizing it — no longer exists. Kept as a dated record; the reasoning about
> raster-vs-vector at icon sizes is still sound for the mark it describes.
```

- [ ] **Step 5: Write the learning**

Create `docs/learnings/freedoom-fonts-are-uppercase-fon2.md`:

```markdown
# Freedoom's fonts: uppercase-only, and DBIGFONT is FON2

None of this is visible from outside the WAD, and all of it shapes what a
Freedoom-derived mark can be.

**There are two fonts and they are nothing alike.**

- `STCFN033`–`STCFN125` is the status-bar font: one DOOM patch per character,
  **9×7 pixels**, flat. Reading this one first is what produced an early wrong
  conclusion that a Freedoom mark would look like blocky retro pixels.
- `DBIGFONT` is a **FON2** lump: height 15, variable width, stored as a
  greyscale ramp with highlights and shadows so ports can tint it at runtime.
  It is already a beveled metal face.

**Neither has lowercase.** `DBIGFONT` covers `0x20`–`0x60` — space through
backtick. `STCFN` runs 33–96 plus a stray `y` at 121. The letters `d`, `l`, `e`
do not exist in either, so anything set from Freedoom is all caps or is partly
hand-drawn.

**FON2 layout**, after the `FON2` magic: `uint16` height; `uint8` first char,
last char, constant-width flag, shading, palette size, flags; then widths
(`uint16` each, or one if constant-width); then `(palSize+1)*3` palette bytes;
then glyph data. Glyph data is RLE: read a signed byte, `n >= 0` copies `n+1`
literal bytes, `n < 0` (and `!= -128`) repeats the next byte `1-n` times. Each
glyph consumes `width * height` decompressed bytes; zero-width glyphs are
skipped entirely.

`Scripts/extract-freedoom-glyphs.py` is the implementation.

**Licence shape:** `FREEDOOM-BSD.txt` is 3-clause BSD. Reproducing the
copyright notice is satisfied by shipping it and crediting it in `NOTICES.md`.
Clause 3 is the one to watch — the Freedoom name may not be used to endorse or
promote a derived product without written permission, so the attribution stays
factual and in the notices rather than becoming an App Store selling point.
```

- [ ] **Step 6: Index it**

`check-substrate.sh` enforces an exact INDEX ↔ file bijection, so this is required. Append to `docs/learnings/INDEX.md`:

```markdown
- [Freedoom's fonts: uppercase-only, and DBIGFONT is FON2](freedoom-fonts-are-uppercase-fon2.md) — STCFN is the 9×7 status-bar font, DBIGFONT is a beveled FON2 face with RLE glyph data, neither has lowercase, and clause 3 of the BSD keeps the credit out of marketing
```

- [ ] **Step 7: Record anything Task 4 discovered**

If Task 4 Step 2 found that `srgb:` with four components is rejected, or Step 5 found that `borderedProminent` overrides `foregroundStyle`, add a short section to the learning above naming the accepted form and what failed. A finding that cost a build cycle is worth the four lines.

- [ ] **Step 8: Verify the substrate and name guards**

```bash
Scripts/check-substrate.sh && echo "substrate ok"
Scripts/check-name-consistency.sh && echo "name ok"
```

Expected: both pass.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "docs(design): document the wordmark, its licence, and the FON2 decode

Rewrites Design/README.md (every word of it described the retired foot),
widens the Freedoom attribution to cover the font artwork the mark is
drawn from, amends launcher-ux §5's accent commitment with the contrast
measurement that justifies it, and records what the WAD investigation
cost."
```

---

## Task 6: Full verification and the pull request

**Files:** none modified.

**Interfaces:**
- Consumes: everything from Tasks 1–5.

- [ ] **Step 1: Clean tree and full regeneration**

```bash
cd ~/Documents/waddle
git status --porcelain --untracked-files=no    # must be empty
mise run icons
git status --porcelain --untracked-files=no    # must STILL be empty
```

Expected: empty both times. A diff after regeneration means the committed assets do not match what the pipeline produces, and `check-icons-fresh.sh` would fail in CI.

- [ ] **Step 2: Every guard**

```bash
Scripts/check-icons-fresh.sh   && echo "icons fresh"
Scripts/check-icon-json.sh     && echo "icon json ok"
Scripts/check-name-consistency.sh && echo "name ok"
Scripts/check-substrate.sh     && echo "substrate ok"
Scripts/check-engine-fresh.sh  && echo "engine ok"
Scripts/check-masked-gh-status.sh && echo "gh-status ok"
```

- [ ] **Step 3: Every new and touched test suite**

```bash
Scripts/test-glyph-source.sh
Scripts/test-build-mark.sh
Scripts/test-check-icons-fresh.sh
Scripts/test-check-icon-json.sh
```

- [ ] **Step 4: The app suite**

```bash
mise run test 2>/tmp/test.log; echo "TEST_EXIT=$?"; tail -20 /tmp/test.log
```

Capture the status explicitly — do **not** pipe into `tail`, which masks it behind `tail`'s status (see `docs/learnings/pipefail-with-early-exit-consumer.md` and `masked-exit-status-fails-open.md`).

Expected: `WaddleTests` 327 passing. `WaddleUITests` failures limited to the documented set — 4 × `RealWADTests` (fixtures) and `PlayTabTests/testBaseGameDetailControlsOverridePersists` (`ui-tests-are-red-at-head.md`). Anything outside that set is caused by this branch.

- [ ] **Step 5: Confirm the icon actually shipped in the build**

A green build is not evidence the package was consumed (`icon-composer-package.md`). Build fresh here rather than relying on Task 4's derived data still existing:

```bash
xcodebuild -project App/Waddle.xcodeproj -scheme Waddle \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/iconbuild build 2>&1 | tail -3
APP=$(find /tmp/iconbuild -name 'Waddle.app' -type d | head -1)
[ -n "$APP" ] || { echo "no app bundle built"; exit 1; }
xcrun assetutil --info "$APP/Assets.car" | grep -A2 UIAppearanceDark
```

Expected: renditions for the default appearance, `UIAppearanceDark`, and `ISAppearanceTintable`.

- [ ] **Step 6: Look at it on a device-sized screen**

```bash
xcrun simctl install booted "$APP"
xcrun simctl io booted screenshot /tmp/home.png && open /tmp/home.png
```

Expected: green wordmark on a dark ground. The simulator caches icons aggressively — if it shows the old foot, erase the device rather than assuming the build is wrong.

- [ ] **Step 7: Push and open the PR**

```bash
git push -u origin tylervick/icon-wordmark
gh pr create --title "feat: the icon becomes a Freedoom wordmark" --body "$(cat <<'EOF'
The app icon stops being a rendered webbed foot and becomes the name, set in
Freedoom's own `DBIGFONT` and tinted the game's own nukage green. The app
accent moves with it.

Implements `docs/superpowers/specs/2026-08-17-icon-wordmark-design.md`.

## The mark

`WAD` over `DLE`, all caps — Freedoom has no lowercase in either font, and
`WADDLE` still contains `WAD`. `DBIGFONT` is a FON2 lump: height 15, a
greyscale ramp with highlights and shadows, so it is already a beveled metal
face. BSD-licensed, already bundled, already credited.

## The accent

`#CC2C20` → `#77FF6F`, which is an accessibility fix as much as a coherence
one: the red measured 3.63:1 as text on the app background (AA-large only),
the green measures 14.98:1. The prominent button's label is forced black —
white on this green is 1.29:1.

## The pipeline

Same architecture, reversed direction. `potrace` leaves; nothing traces.

- `extract-freedoom-glyphs.py` — rare, deliberate, the only thing that reads
  the WAD; its output is committed so `check-icons` stays offline and a
  `FREEDOOM_VERSION` bump cannot silently restyle the mark
- `build-mark.py` — offline: composes, tints in HSV so the bevel survives, and
  emits a transparent layer plus a rect-grid SVG

## Known limitation

The mark reads as texture rather than letters at 40pt. It holds to about 80pt.
That is inherent to a 15px source with a bevel; `.icon` has no size-variant
mechanism, so a small-size variant would mean a second asset outside the
package. Accepted, not overlooked.
EOF
)"
```

- [ ] **Step 8: Watch CI**

`check-icons-fresh.sh --sync-only` runs on the runner, which has neither `uv` nor `potrace`. If it fails there, the sync-only split was broken in Task 3.
