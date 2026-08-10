# The `.icon` package format, and two actool behaviours that mislead

The app icon is an Icon Composer package (`App/AppIcon.icon`), not an
`.appiconset`. There is no public schema for it, so everything below was
established by inspecting a shipping example and by A/B-ing real builds.

## The format

`.icon` is a **package directory** — UTI `com.apple.iconcomposer.icon`,
conforming to `com.apple.package`, declared by
`Xcode.app/Contents/Applications/Icon Composer.app`. Layout:

```
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

```
xcrun assetutil --info "$APP/Assets.car" | grep -A2 UIAppearanceDark
```

A working icon yields `AppIcon` renditions for the default appearance,
`UIAppearanceDark`, and `ISAppearanceTintable`, plus `AppIcon_Assets/<layer>`.

## `fill-specializations` at the top level is silently ignored

Putting `fill-specializations` next to the top-level `fill` — the obvious way to
give the icon a dark background — **compiles without error or warning and has no
effect**. actool accepts the key and discards it. It is only honoured on a
*layer*, which is where the shipping example uses it.

This is worth knowing because the failure mode is invisible: the build is green,
the dark rendition still exists in the catalog, and only a pixel comparison shows
that nothing changed. If a dark background is wanted, author it in Icon
Composer.app rather than assuming the hand-written key took.

## actool output is not deterministic

Two builds from a byte-identical `icon.json` produce **different `SHA1Digest`
values** for every rendition:

```
build 1   (light) CAE95BC2DAB08579   dark C27862EE686D5B94
build 2   (light) 8E9DD7F8FDE24215   dark 07BE08F2E0FACC83
```

Two consequences:

- **Never build a freshness check on compiled catalog bytes** — it would fail on
  every run. `Scripts/check-icons-fresh.sh` compares the *sources* in `Design/`,
  which regenerate deterministically, and never `Assets.car`.
- When A/B-ing an `icon.json` change, compare `SizeOnDisk`, not the digest. That
  is how the `fill-specializations` no-op above was proven: byte-identical sizes
  across the change, with only the meaningless digests moving.

## The simulator caches app icons past reinstall

`simctl uninstall` + `simctl install` is **not** enough to see an icon change —
the home screen keeps serving the cached render. Restart SpringBoard
(`simctl spawn <udid> launchctl stop com.apple.SpringBoard`) or install to a
device that has never seen the bundle ID. Expect a freshly created device to drop
the app on a later home-screen page, where a plain screenshot will not find it.
