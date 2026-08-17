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
hand-drawn. That is why the app mark reads `WADDLE` rather than the mixed-case
wordmark form.

**FON2 layout**, after the `FON2` magic: `uint16` height; `uint8` first char,
last char, constant-width flag, shading, palette size, flags; then widths
(`uint16` each, or one if constant-width); then `(palSize+1)*3` palette bytes;
then glyph data. Glyph data is RLE: read a signed byte, `n >= 0` copies `n+1`
literal bytes, `n < 0` (and `!= -128`) repeats the next byte `1-n` times. Each
glyph consumes `width * height` decompressed bytes; zero-width glyphs are
skipped entirely.

`Scripts/extract-freedoom-glyphs.py` is the implementation, and
`Scripts/build-mark.py` is what tints and composes the result.

**Tinting a greyscale ramp: use HSV, not a lerp toward white.** The obvious
`lerp(colour, white, luminance)` desaturates as it brightens, so a red ramp
comes out pink and the bevel flattens into a smear. Preserve the hue and drive
value and saturation instead.

**Licence shape:** `FREEDOOM-BSD.txt` is 3-clause BSD. Reproducing the
copyright notice is satisfied by shipping it and crediting it in `NOTICES.md`.
Clause 3 is the one to watch — the Freedoom name may not be used to endorse or
promote a derived product without written permission, so the attribution stays
factual and in the notices rather than becoming an App Store selling point.

## Two things that turned out fine, recorded so nobody re-checks them

- **`icon.json` accepts a four-component `srgb:` fill.**
  `"automatic-gradient" : "srgb:0.05490,0.05490,0.06275,1.00000"` is honoured —
  confirmed by `Gradient-1`/`Gradient-2` renditions appearing in the compiled
  `Assets.car` alongside `UIAppearanceDark` and `ISAppearanceTintable`. The
  format has no public schema and ignores malformed values silently, so this
  was verified with `assetutil` rather than a green build.
- **`.buttonStyle(.borderedProminent)` honours `.foregroundStyle(.black)`.**
  Needed because the accent is a light green: the default white label measures
  1.29:1 against it. No custom `ButtonStyle` was required on iOS 26.
