# The `.icon` package format, and the actool behaviours that mislead

The app icon is an Icon Composer package (`App/AppIcon.icon`), not an
`.appiconset`. There is no public schema for it, so everything below was
established by inspecting a shipping example and by A/B-ing real builds.

## The format

`.icon` is a **package directory** — UTI `com.apple.iconcomposer.icon`,
conforming to `com.apple.package`, declared by
`Xcode.app/Contents/Applications/Icon Composer.app`. Layout:

```text
AppIcon.icon/
  icon.json
  Assets/mark.png      # SVG works here too
```

Keys confirmed against a real document (Orca ships one at
`Orca.app/Contents/Resources/app.asar.unpacked/resources/icon-source/icon.icon`,
which is the fastest way to re-check any of this):

- `fill` — the background, e.g. `{"automatic-gradient": "extended-gray:1.0,1.0"}`.
  Colours are `<colorspace>:<components>`; `extended-gray`, `srgb`, `display-p3`
  all appear in the framework's strings.
- `groups[]` — each with `layers[]`, `shadow: {kind, opacity}`,
  `translucency: {enabled, value}`.
- `layers[]` — `image-name`, `name`, `position: {scale, translation-in-points}`,
  and `fill-specializations[]` for per-appearance overrides.
- `supported-platforms` — `{"circles": [...], "squares": "shared"}`.

The package basename must match `ASSETCATALOG_COMPILER_APPICON_NAME`. Add it to
the target's sources in `project.yml`; XcodeGen puts it in Resources and actool
picks it up alongside the asset catalog.

To confirm a build actually consumed it, look for the three appearances in the
compiled catalog rather than trusting a green build:

```sh
xcrun assetutil --info "$APP/Assets.car" | grep -A2 UIAppearanceDark
```

A working icon yields `AppIcon` renditions for the default appearance,
`UIAppearanceDark`, and `ISAppearanceTintable`, plus `AppIcon_Assets/<layer>`.

## The dark and tinted appearances are generated — do not author them

`fill` sets the background for the **default appearance only**. The Dark and
Tinted renditions are derived by actool from the layer artwork, with their own
backgrounds, and nothing in `icon.json` needs to ask for them.

Shown by holding everything else fixed and varying `fill` alone. Values are
`SizeOnDisk` from `assetutil --info`, not a byte comparison — actool's output is
not reproducible (see below), so sizes are the only stable signal available:

| `fill` | default `SizeOnDisk` | `UIAppearanceDark` | `ISAppearanceTintable` |
| --- | --- | --- | --- |
| white | 513347 | 610556 | 249283 |
| black | 535180 | 610556 | 249283 |
| red | 589396 | 610556 | 249283 |
| omitted | 393969 | 610556 | 249283 |

Only the default column moves; the Dark and Tinted sizes are unchanged across
all four, consistent with neither consulting `fill`. Confirmed independently by
extracting the renditions and looking at them (see below) — Dark really does
come out on a near-black ground.

## `fill-specializations` at the top level is silently ignored

Putting `fill-specializations` next to the top-level `fill` **compiles without
error or warning and has no effect** — with `appearance` set to `dark`,
`dark-color`, all three dark variants, or alongside `fully-specialize-for`. Every
one produced the same `SizeOnDisk` for all three renditions as the baseline.
actool accepts the key and discards it. It is only honoured on a *layer*, which
is where the shipping example uses it.

This is a correctness trap, not a missing feature: the generated Dark appearance
is already correct, so a hand-written top-level key is both inert **and**
unnecessary. `Scripts/check-icon-json.sh` rejects it, along with the neighbouring
silent failures (a layer pointing at artwork that is not there, orphaned files in
`Assets/`, a package that declares no layers). All of them build green and only
show up as an icon that renders wrong. Run it via `mise run check-icons`; CI runs
it too.

## How to actually look at a rendition

Do not trust a simulator screenshot — see the icon-cache section below. Extract
the renditions from the compiled catalog instead, via CoreUI:

```objc
NSError *e = nil;
CUICatalog *cat = [[NSClassFromString(@"CUICatalog") alloc] initWithURL:carURL error:&e];
for (id o in [cat imagesWithName:@"AppIcon"]) {
    id ap   = [o performSelector:@selector(appearance)];          // UIAppearanceDark, ...
    id rend = [o performSelector:NSSelectorFromString(@"_rendition")];
    CGImageRef img = (__bridge CGImageRef)[rend performSelector:@selector(unslicedImage)];
}
```

Link with `-F/System/Library/PrivateFrameworks -framework CoreUI`. Note the app
icon comes back as `CUINamedMultisizeImageSet`, which has **no** `-image`
selector — go through `-_rendition` on its `CUINamedLookup` superclass.

## actool output is not deterministic

Two builds from a byte-identical `icon.json` produce **different `SHA1Digest`
values** for every rendition:

```text
build 1   (light) CAE95BC2DAB08579   dark C27862EE686D5B94
build 2   (light) 8E9DD7F8FDE24215   dark 07BE08F2E0FACC83
```

Two consequences:

- **Never build a freshness check on compiled catalog bytes** — it would fail on
  every run. `Scripts/check-icons-fresh.sh` compares the *sources* in `Design/`,
  which regenerate deterministically, and never `Assets.car`.
- When A/B-ing an `icon.json` change, compare `SizeOnDisk`, not the digest. That
  is how the `fill-specializations` no-op above was established: equal sizes
  across the change, with only the meaningless digests moving.

## The simulator caches app icons past reinstall

`simctl uninstall` + `simctl install` is **not** enough to see an icon change —
the home screen keeps serving the cached render. Restart SpringBoard
(`simctl spawn <udid> launchctl stop com.apple.SpringBoard`) or install to a
device that has never seen the bundle ID. Expect a freshly created device to drop
the app on a later home-screen page, where a plain screenshot will not find it.
