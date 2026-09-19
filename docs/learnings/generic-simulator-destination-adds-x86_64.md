# A generic iOS Simulator destination also builds x86_64

`WoofEngine.xcframework` carries exactly one simulator slice, arm64
(`Scripts/build-engine.sh` builds `iphoneos` and `iphonesimulator`, both
arm64). A build that asks for any other simulator architecture therefore has
no engine to link against.

`-destination 'generic/platform=iOS Simulator'` asks for all of them. On an
Apple Silicon machine that still includes x86_64, and the link fails:

```
ld: warning: ignoring file .../libWoofEngine.a(SDL_video.c.o):
    found architecture 'arm64', required architecture 'x86_64'
... one such warning per object file ...
clang: error: linker command failed with exit code 1
** BUILD FAILED **
```

The diagnosis is buried. Those are *warnings*, hundreds of them, and the only
error says "linker command failed" without naming a cause. Nothing mentions
the destination that requested x86_64, and the obvious reading — that the
engine is built wrong, or that the xcframework is missing a slice — is the
wrong one. The framework is fine; the request is wrong.

**Fix: pin the architecture on the command.**

```bash
xcodebuild -project App/Waddle.xcodeproj -scheme Waddle \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build ARCHS=arm64
```

This does not affect `mise run test` or `ci.yml`, which pass a *concrete*
destination (`platform=iOS Simulator,name=iPhone 17 Pro`). A named simulator
resolves to one device and therefore one architecture, so the generic form is
the only one that reaches for x86_64. That asymmetry is why this can sit
undiscovered until the first tool that builds without a named device —
here, the `.revyl/config.yaml` build recipe.

**Paid for on 2026-09-18**, on the first end-to-end run of the Revyl build
recipe. Worth noting that Revyl's own documented examples all carry
`ARCHS=arm64`; it reads as boilerplate and is not.
