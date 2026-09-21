# Mark generation prompts

Prompts for exploring a replacement Waddle mark. Built as **concept × style**,
so the two choices stay independent — pick a subject, pick a rendering, paste
the assembled prompt. Nothing here presumes the current mark's pixel-art
lineage or its monochrome pipeline.

Assemble as: `PREAMBLE + CONCEPT + STYLE`.

## Preamble — paste this at the top of every prompt

Only two of these are actually imposed on us; the rest are craft.

```text
Output a single 1024x1024 square image with a fully transparent background
(real alpha channel).

Do NOT draw a background, ground plane, rounded square frame, squircle,
circular badge, border, drop shadow, or specular highlight. The operating
system supplies the container, the shadow and the ground.

Keep all artwork within the central 85% of the canvas, with clear margin on all
four sides. Nothing touches or bleeds off the edge.

The design must stay legible when scaled to 40x40 pixels. No fine interior
detail, no hairline strokes, no small text.

No watermark, no signature, no border.
```

The hard ones are the transparency and the no-container rule: iOS 26 draws the
squircle and the shadow itself, so a baked-in one gets drawn twice. The margin
and the 40px bar are judgement, and worth relaxing if a candidate is good
enough to argue for.

## Concepts

Pick one. Drop it in under the preamble as `SUBJECT:`. Deliberately spread
across four families — the app is a WAD player that happens to be called
Waddle, and only one of those halves is a bird.

### Things that waddle

**A — Duck, full figure.** *A duck standing mid-waddle, seen in profile, one
webbed foot lifted and forward, body tilted slightly off-balance. Confident and
characterful rather than cute.*

**B — Penguin, full figure.** *A penguin mid-stride, seen head-on, flippers out
for balance and body tilted off-vertical. Upright, top-heavy, slightly
absurd.* — worth trying before the duck: penguins are the canonical waddler,
and the upright top-heavy shape survives a downscale better than a duck's
horizontal one. Keep it clearly not-Tux — different proportions, no white belly
oval.

**C — Webbed foot.** *A single bold webbed footprint seen from directly above,
three forward toes joined by webbing and one short rear toe. Or: a diagonal
trail of three prints of decreasing size, staggered left-right-left to suggest
a waddling gait.*

### Doom heritage

**D — Helmeted bird.** *A duck's head in three-quarter view wearing a battered
military helmet with a cracked visor, in the spirit of an early-1990s
first-person-shooter status-bar portrait. Grim and deadpan. Head and helmet
only: no body, no weapon, no blood.*

**E — The doorway.** *A heavy recessed doorway seen straight on, lit from
within, with the thick stepped frame and hard shadow of an early-1990s
first-person-shooter door. Nothing visible through it but light.* — the one
shape every player of this lineage recognises instantly, and it says "go in"
rather than "here is a bird."

### The WAD itself

**F — The WAD pun.** *A typographic lockup of the word WADDLE in all capitals,
on two stacked lines: "WAD" on top, "DLE" below, with "WAD" noticeably larger
and heavier so the shorter word reads as hidden inside the longer one. The two
lines are centred on one another rather than stretched to equal width. Spell it
exactly: W A D on top, D L E below. No tagline or secondary text.*

**G — The WAD as an object.** *A chunky data cartridge or disk seen at a slight
three-quarter angle, thick-edged and industrial, with a glowing green slot or
label panel. The physical object a game lives inside.* — literal to what the
app does: it holds and plays WAD files.

### Abstract

**H — The gait.** *Three or four thick offset chevrons or blocks, staggered
left-right-left and tilted alternately, reading as side-to-side motion. No
creature, no letters — the rhythm of waddling as pure geometry.*

**I — Play, built from something.** *A play triangle constructed out of another
form — a beak, a doorway, a stack of cartridges — so the mark reads as "player"
first and the pun second.*

## Styles

Pick one. Drop it in as `STYLE:`. These are deliberately far apart — run the
same concept through several before deciding anything.

**1 — DOS pixel sprite.** *Coarse pixel grid, roughly 32x32 source pixels
scaled up with hard square edges and no anti-aliasing. Limited palette in the
manner of an early-1990s VGA game sprite, with dithered shading and a dark
outline. Toxic green (#77FF6F) dominant.*

**2 — Full-colour illustrated.** *Rich painterly illustration with real
lighting, dimensional form, soft interior gradients and a warm rim light.
Modern premium app-icon treatment in the manner of a well-crafted indie game
icon. Free to use the full colour range; toxic green (#77FF6F) as the
signature hue but not the only one.*

**3 — Flat geometric vector.** *Clean flat vector construction from simple
geometric primitives, crisp edges, generous negative space, three to five flat
colours with no gradients or texture. The disciplined restraint of a modern
pictogram or transit symbol.*

**4 — Heavy-outline sticker.** *Bold uniform black outline around every form,
flat saturated fills inside, slight cartoon exaggeration. The confident
graphic weight of a vinyl sticker or an enamel pin.*

**5 — Monochrome minimal.** *A single flat colour (#77FF6F) on transparency,
with every detail carried by outline and negative space — interior features are
transparent cuts through the shape, never a second colour. Reads as a pure
silhouette.*

**6 — Chrome / dimensional.** *Glossy dimensional rendering with beveled edges,
a metallic or glassy surface, and reflected highlights, in the manner of a
late-1990s software logo. Green anodised finish.*

## Four assembled examples

Four of the fifty-four combinations, spread across the style range so you can
see the shape of an assembled prompt. Everything else is a two-line swap from
the menus above — the examples are a sample, not the menu.

<details>
<summary><strong>A × 1 — duck, pixel sprite</strong></summary>

```text
Output a single 1024x1024 square image with a fully transparent background
(real alpha channel).

Do NOT draw a background, ground plane, rounded square frame, squircle,
circular badge, border, drop shadow, or specular highlight. The operating
system supplies the container, the shadow and the ground.

Keep all artwork within the central 85% of the canvas, with clear margin on all
four sides. Nothing touches or bleeds off the edge.

The design must stay legible when scaled to 40x40 pixels. No fine interior
detail, no hairline strokes, no small text.

No watermark, no signature, no border.

SUBJECT: a duck standing mid-waddle, seen in profile, one webbed foot lifted
and forward, body tilted slightly off-balance. Confident and characterful
rather than cute.

STYLE: coarse pixel grid, roughly 32x32 source pixels scaled up with hard
square edges and no anti-aliasing. Limited palette in the manner of an
early-1990s VGA game sprite, with dithered shading and a dark outline. Toxic
green (#77FF6F) dominant.
```
</details>

<details>
<summary><strong>D × 2 — helmeted bird, fully illustrated</strong></summary>

```text
Output a single 1024x1024 square image with a fully transparent background
(real alpha channel).

Do NOT draw a background, ground plane, rounded square frame, squircle,
circular badge, border, drop shadow, or specular highlight. The operating
system supplies the container, the shadow and the ground.

Keep all artwork within the central 85% of the canvas, with clear margin on all
four sides. Nothing touches or bleeds off the edge.

The design must stay legible when scaled to 40x40 pixels. No fine interior
detail, no hairline strokes, no small text.

No watermark, no signature, no border.

SUBJECT: a duck's head in three-quarter view wearing a battered military helmet
with a cracked visor, in the spirit of an early-1990s first-person-shooter
status-bar portrait. Grim and deadpan. Head and helmet only: no body, no
weapon, no blood.

STYLE: rich painterly illustration with real lighting, dimensional form, soft
interior gradients and a warm rim light. Modern premium app-icon treatment in
the manner of a well-crafted indie game icon. Free to use the full colour
range; toxic green (#77FF6F) as the signature hue but not the only one.
```
</details>

<details>
<summary><strong>F × 3 — WAD wordmark, flat vector</strong></summary>

```text
Output a single 1024x1024 square image with a fully transparent background
(real alpha channel).

Do NOT draw a background, ground plane, rounded square frame, squircle,
circular badge, border, drop shadow, or specular highlight. The operating
system supplies the container, the shadow and the ground.

Keep all artwork within the central 85% of the canvas, with clear margin on all
four sides. Nothing touches or bleeds off the edge.

The design must stay legible when scaled to 40x40 pixels. No fine interior
detail, no hairline strokes, no small text.

No watermark, no signature, no border.

SUBJECT: a typographic lockup of the word WADDLE in all capitals, on two
stacked lines: "WAD" on top, "DLE" below, with "WAD" noticeably larger and
heavier so the shorter word reads as hidden inside the longer one. The two
lines are centred on one another rather than stretched to equal width. Spell it
exactly: W A D on top, D L E below. No tagline or secondary text.

STYLE: clean flat vector construction from simple geometric primitives, crisp
edges, generous negative space, three to five flat colours with no gradients or
texture. The disciplined restraint of a modern pictogram or transit symbol.
```
</details>

<details>
<summary><strong>C × 4 — webbed foot, sticker</strong></summary>

```text
Output a single 1024x1024 square image with a fully transparent background
(real alpha channel).

Do NOT draw a background, ground plane, rounded square frame, squircle,
circular badge, border, drop shadow, or specular highlight. The operating
system supplies the container, the shadow and the ground.

Keep all artwork within the central 85% of the canvas, with clear margin on all
four sides. Nothing touches or bleeds off the edge.

The design must stay legible when scaled to 40x40 pixels. No fine interior
detail, no hairline strokes, no small text.

No watermark, no signature, no border.

SUBJECT: a single bold webbed duck footprint seen from directly above, three
forward toes joined by webbing and one short rear toe.

STYLE: bold uniform black outline around every form, flat saturated fills
inside, slight cartoon exaggeration. The confident graphic weight of a vinyl
sticker or an enamel pin.
```
</details>

## Concept F as an Ideogram 4.0 JSON prompt

Ideogram 4.0 takes structured JSON, so placement and palette become parameters
rather than prose the model may ignore. Worth it on the wordmark, where exact
spelling and exact placement both matter. Swap the `prompt` string to change
style; the layout block is what you are buying.

```json
{
  "prompt": "Clean flat vector wordmark built from simple geometric primitives, crisp edges, generous negative space, flat colour fills with no gradients or texture, modern pictogram restraint",
  "background": "transparent",
  "resolution": "1024x1024",
  "palette": { "members": ["#77FF6F", "#3FA83A", "#1C5A1A", "#0E0E10"] },
  "text_layout": [
    {
      "text": "WAD",
      "bounding_box": { "x": 0.09, "y": 0.18, "width": 0.82, "height": 0.30 },
      "weight": "heaviest"
    },
    {
      "text": "DLE",
      "bounding_box": { "x": 0.16, "y": 0.52, "width": 0.68, "height": 0.30 },
      "weight": "heavy"
    }
  ],
  "negative_prompt": "background, ground plane, rounded square frame, squircle, circular badge, border, drop shadow, specular highlight, tagline, secondary text, watermark, signature"
}
```

Check the key names against Ideogram's current schema — the concept survives a
rename, the exact spelling of `text_layout` may not.

## Judging the outputs

`Design/judge-mark.py` reports signals, not verdicts. It always exits 0.

```sh
./Design/judge-mark.py candidate.png --out-dir /tmp/judge
```

It writes a silhouette plus 16px and 40px blowups, and reports margin, colour
count and alpha hardness.

**Read the silhouette as a signal, not a gate.** A strong silhouette correlates
with reading well at small sizes, but plenty of excellent full-colour icons
would "fail" it outright — it is diagnostic for styles 3 and 5, and close to
meaningless for styles 2 and 6. The 40px blowup is the check that applies to
every style equally.

Baseline from the current Freedoom-glyph mark:

```text
Design/waddle-mark.png  1024x1024
  margin       ok -- 104px clear, 77px suggested (art spans 816px of 1024)
  colours      170 distinct RGB over opaque pixels
  alpha edges  hard -- 0.00% partially transparent
```

Its 40px blowup shows `WAD` holding while `DLE` turns to mush — the weakness
`README.md` owns up to under "Geometry", and the bar a replacement should
clear.

## Model notes

Checked 2026-09-20. Image models move fast — re-verify before a big batch.

### GPT Image 2.5 — Flare and Sunburst

Both shipped in the API on 2026-09-08 with **first-class transparent
backgrounds**: `background="transparent"` with `output_format` of PNG or WebP.
Check the alpha on the first output — soft matted edges are the giveaway that a
model faked transparency, and they matter most for styles 1 and 5.

Same token rates, so the choice is turnaround versus precision:

| | Use it for |
| --- | --- |
| **Flare** | Fast, speed-optimised. The exploration pass — run the whole concept × style grid here |
| **Sunburst** | Quality-optimised, slower, stronger on precision and consistency. The finishing pass |

Flare → judge → Sunburst only on survivors.

### Recraft V4.1 Vector

Not V3. The current family is **V4.1** — V4.1, **V4.1 Vector**, V4.1 Utility,
with Pro tiers above. V4.1 Vector emits genuine editable SVG path data rather
than auto-tracing a raster, and is aimed at logos. Best paired with styles 3,
4 and 5; a painterly style 2 has nothing to gain from vector output.

#### Getting actual SVG out of it

**You do not need this to explore.** A PNG tells you everything you need to
judge a concept and a style; the vector format only matters once you have
picked a winner and want the asset that scales to a favicon and to print.

When you do get there, two routes, and **neither requires a new account if you
already have OpenRouter**:

| Route | SVG | Needs |
| --- | --- | --- |
| OpenRouter chat UI | no | what you are already using |
| OpenRouter `/api/v1/images` | yes | same key, one command — below |
| recraft.ai web app | yes | a Recraft signup, only if you want a GUI |

The chat UI is not an OpenRouter limitation so much as a chat one:
`output_format: "svg"` is dropped at the adapter boundary because chat media
pipelines only persist raster formats. The images endpoint has no such
constraint and returns `b64_json` with `"media_type": "image/svg+xml"`.

<details>
<summary>Script for the images endpoint, if you want to batch</summary>

Confirm the field names against OpenRouter's current reference before wiring
anything up — the endpoint and `output_format` are documented, but response
shapes drift. `recraft/recraft-v4.1-pro-vector` is the higher-resolution slug.

```sh
#!/bin/bash
# Save as fetch-svg.sh and run it. Capturing the status separately matters:
# `curl -s` exits 0 on an HTTP error, and decoding an error object straight
# into candidate.svg leaves a zero-byte file and a confusing traceback.
set -euo pipefail

response=$(mktemp)
trap 'rm -f "$response"' EXIT

# --max-time is not optional here -- image generation is exactly the kind of
# call that hangs, and 000 below is curl's code for "never answered".
status=$(curl -s --max-time 300 -o "$response" -w '%{http_code}' \
  https://openrouter.ai/api/v1/images \
  -H "Authorization: Bearer $OPENROUTER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "recraft/recraft-v4.1-vector",
    "prompt": "<paste the assembled prompt here>",
    "output_format": "svg"
  }') || status=000
# The `|| status=000` is load-bearing under `set -e`: curl exits non-zero on a
# connection failure or timeout, which would otherwise kill the script at the
# assignment and never reach the message below.

case "$status" in
  2??) ;;
  000) echo "request timed out or could not connect" >&2; exit 1 ;;
  *)   echo "request failed: HTTP $status" >&2; cat "$response" >&2; exit 1 ;;
esac

python3 -c '
import base64, json, sys
payload = json.load(sys.stdin)
item = (payload.get("data") or [{}])[0]
blob = item.get("b64_json")
if not blob:
    sys.exit(f"no image in response: {json.dumps(payload)[:400]}")
print(item.get("media_type", "unknown"), file=sys.stderr)
sys.stdout.write(base64.b64decode(blob).decode())
' < "$response" > candidate.svg
```

Check what you actually got:

```sh
head -c 200 candidate.svg    # want '<svg', not PNG magic bytes
grep -c '<path' candidate.svg
```
</details>

### Ideogram 4.0

Open-weight (9.3B, released 2026-06-03), native transparency, 2K, best-in-class
text rendering. Use it for concept F, where a model that garbles `WADDLE` burns
the batch. Its structured JSON turns placement and palette into parameters.

Licensing is split and worth knowing before reaching for it: the **inference
code** is Apache 2.0, but the **weights** are under Ideogram's Non-Commercial
Model Agreement, with self-hosted commercial use requiring a paid licence. That
is irrelevant while generating through a hosted API, which is all this document
does — it would matter the moment anyone self-hosted the weights to make art
for a shipping app.

### Not recommended

Midjourney, DALL-E and Imagen have no reliable alpha. All three above do.
