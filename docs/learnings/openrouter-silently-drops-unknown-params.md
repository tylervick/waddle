# OpenRouter silently drops unknown image parameters

`POST /api/v1/images` accepts parameters it does not recognise, returns
**HTTP 200**, bills the request normally, and ignores them. Nothing in the
response says a parameter was discarded. A bogus `zzz_not_a_real_parameter`
round-trips exactly as cleanly as a real one.

This was paid for twice in one session while generating app-icon candidates.

## Reference images

`image`, `image_urls` and `reference_images` are all accepted and all ignored.
The correct field is **`input_references`**, a list of
`{"type": "image_url", "image_url": {"url": "<data: or https: URL>"}}`.

The only reliable tell is `usage.prompt_tokens`:

| Request | prompt_tokens |
| --- | --- |
| Prompt only | 71 |
| Prompt + two 512px images under `image` | 71 |
| Prompt + the same two under `input_references` | 2130 |

The first attempt produced a *good-looking* result, which is what made it
dangerous — the model had simply followed the text description. A control run
with the field removed entirely, producing the identical token count, is what
proved the images were never read.

## Provider-specific parameters

Recraft's colour controls reach the provider only when nested under
`provider.options.<slug>`. Top level is dropped — **even though the endpoint
metadata lists the key as allowed**:

```json
{"provider": {"options": {"recraft": {"controls": {"colors": [{"rgb": [255,0,200]}]}}}}}
```

Measured on `recraft/recraft-v4.1` with an identical prompt: top-level
`controls` gave 0% magenta, the nested form gave 81%.

`allowed_passthrough_parameters` says a key is *permitted*, not where to put
it. That distinction is the whole trap.

## Ask the endpoint what it accepts

`GET /api/v1/images/models/{id}/endpoints` is authoritative, and disagrees with
both the model listing and the published docs:

- `/api/v1/models` omits image-generation models entirely. Use
  `?output_modality=image` — 54 models rather than 0.
- `supported_parameters` on the model record is useless for this endpoint: it
  lists chat parameters (`frequency_penalty`, `logit_bias`) and omits
  `input_references`, which demonstrably works.
- Recraft accepts `style`, `controls`, `text_layout` and **not** `strength`, on
  every one of `v4.1`, `v4.1-pro`, `v4.1-vector`, `v4.1-pro-vector` — contrary
  to documentation describing a `strength` parameter. Sending it changes
  nothing: mean difference from the reference image was 0.5709 without it and
  0.5778 with `strength: 0.05`, which is noise.

The endpoint record also revealed `background: "transparent"` as a real
parameter on `gpt-image-2.5-*`, which had been requested in prose for an entire
session.

## Rule

Before trusting any image parameter, read
`/api/v1/images/models/{id}/endpoints`, then confirm the effect is visible in
either `usage.prompt_tokens` or the pixels. A 200 means nothing.
