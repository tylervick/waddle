# BoomBox (working name)

A free, open-source Doom source-port app for iPhone and iPad, built on
[Woof!](https://github.com/fabiangreffrath/woof) (Boom/MBF21 compatibility).
Bundles [Freedoom](https://freedoom.github.io/); users import their own WADs.

Licensed under the GNU GPL v2 (see COPYING). Freedoom content is
BSD-licensed (see its accompanying COPYING file).

## Building

Requirements: Xcode 26.2+, Homebrew (`brew install cmake ninja xcodegen`).

```sh
Scripts/vendor-woof.sh      # one-time: vendor pinned Woof! source
Scripts/build-deps.sh       # SDL3 + OpenAL Soft static libs (device + simulator)
Scripts/build-engine.sh     # Woof! static lib + WoofEngine.xcframework + woof.pk3
Scripts/fetch-freedoom.sh   # Freedoom WADs into App/Resources/GameData
cd App && xcodegen generate # generate BoomBox.xcodeproj
```

Then build/run the `BoomBox` scheme in Xcode or with `xcodebuild`.
