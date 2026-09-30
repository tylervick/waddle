# iOS 27 made SDL size a landscape window as portrait, and the fix lives in a patch, not the pin

Found 2026-09-30 while proving #158's committed capture test (issue #291).

A session started with the device already in landscape opened an engine
window of exactly the portrait size: `win=402x874` on an 874×402 iPhone 17
Pro screen, with the shelf visible beside it and the overlay laid out over the
whole screen. Rotating *during* a session was fine, which is why
`testSessionSurvivesRotation` never saw it, and the App Store capture's
in-game shots were the first thing to.

**Cause.** SDL's iOS backend decides "is the screen landscape?" from
`-[UIApplication statusBarOrientation]` in three places (`UIKit_IsDisplayLandscape`,
the display-mode swap in `SDL_OnApplicationDidChangeStatusBarOrientation`,
and the fullscreen-frame flip in `UIKit_ComputeViewFrame`). iOS 27 made that
API a no-op; UIKit even logs it, once per call, as
`-[UIApplication statusBarOrientation] API has been deprecated and is a no-op
on 27.0 and later`, and those lines sat in every session log before anyone
read them as a symptom. Upstream fixed it on `main` on 2026-09-20 (commit
`114aca172`, "Fix for iOS 27 no op on statusBarOrientation"), reading the
active window scene's `effectiveGeometry.interfaceOrientation` instead.

**Why a patch and not a pin bump.** No 3.4 release contains that commit and
the 3.4 branch has not backported it, so `Scripts/patches/SDL/0001-ios27-interface-orientation.patch`
carries it, adapted to `release-3.4.12` (upstream's context has `#pragma`
deprecation wrappers the release branch lacks; the change itself is the same
six replacements plus one helper). `Scripts/build-deps.sh` applies every
`Scripts/patches/<dep>/*.patch` after the checkout, skips one already in, and
**stops the build** on one that applies neither way, so the next `SDL_TAG`
bump cannot drop the fix silently: it either re-bases the patch or deletes
it because the release has the fix. `Scripts/test-build-deps.sh` cases 9–11
pin those three behaviours. The patched library is linked into the
xcframework, so `Scripts/engine-fingerprint.sh` hashes `Scripts/patches/**`
too (case 6b of its suite) and CI's deps cache key does the same; a cached
build cannot outlive a patch change.

`TouchControlsTests.testSessionStartedInLandscapeFillsTheScreen` is the
check: it reads the engine's own window size off the debug HUD (`win=WxH`)
and holds it to the screen's landscape size.
