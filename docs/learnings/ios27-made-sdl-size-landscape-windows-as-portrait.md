# iOS 27 made SDL size a landscape window as portrait; a patch carried the fix until `release-3.4.20`

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

**Why a patch and not a pin bump (2026-09-30 to #489).** No 3.4 release
contained that commit then and the 3.4 branch had not backported it, so
`Scripts/patches/SDL/0001-ios27-interface-orientation.patch` carried it,
adapted to `release-3.4.12` (upstream's context has `#pragma`
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

**Bumped to `release-3.4.16` on 2026-10-01** (the SDL half of issue #79). The
patch applied unchanged (`git apply --check` against a pristine
`release-3.4.16` clone, then `build-deps.sh`'s own apply), so upstream's fix
is still main-only and the patch stays. Nothing in 3.4.13 to 3.4.16 touches
`SDL_uikitwindow.m`'s orientation path.

**Bumped to `release-3.4.18` on 2026-10-03** (with SONiVOX `v4.0.2`, after
the Woof 16 re-vendor in #328). None of the 73 commits in 3.4.17 and 3.4.18 is
the upstream orientation fix or touches the uikit window path, so the patch
stays; `build-deps.sh` applied it unchanged. The one iOS-relevant change in
the range is `295ca921` "implement joystick hotplugging", which is the path the
overlay's virtual gamepad attaches through, so `TouchControlsTests` is the
suite to watch on this bump, not only the orientation test.

**Bumped to `release-3.4.20` in #489, and the patch is deleted.** The patch
no longer applied either way, which is what stopped CI. `114aca172` itself
is not an ancestor of `release-3.4.20` (`git merge-base --is-ancestor` says
no), but the release has its cherry-pick `ca97578d7` ("cherry picked from
commit 114aca17…"), whose `+`/`-` lines are identical to upstream's apart
from the `#pragma` wrappers the release branch lacks. It also has a
follow-up, `2ee7eb621` "Fixed window orientation on iOS 27" (cherry-pick of
`22a4d8b25`, SDL issue 16436), which is why the patch stopped fitting:

- it fixes upstream's SDK guard to `>= 270000`, the same correction this
  patch made. The pre-27 `statusBarOrientation` fallback was already in
  upstream's original commit (`ca97578d7` has it; `2ee7eb621` does not touch
  it), so with the guard fixed `UIKit_GetInterfaceOrientation()` in 3.4.20 is
  byte for byte the patch's helper;
- `UIKit_IsDisplayLandscape` and `SDL_OnApplicationDidChangeStatusBarOrientation`
  now treat `UIInterfaceOrientationUnknown` (no active scene yet) as "not
  known", falling back to the screen bounds or waiting for the next
  notification instead of reading it as portrait;
- `UIKit_ComputeViewFrame` no longer flips the fullscreen frame by
  orientation at all on iOS 13 and later; it uses the window bounds as-is.

So the mechanism the patch relied on for the landscape-start case (flip the
frame by the scene's orientation) is gone, replaced by trusting the window
bounds. `TouchControlsTests.testSessionStartedInLandscapeFillsTheScreen` is
still the check that it comes out the same.

**3.4.20 also changes keyboard focus on iOS**, which is not orientation but
ships in the same bump, so suspect it first if anything about text input or
focus after backgrounding changes:

- `00efbb347` "Fixed keyboard focus on iOS" (cherry-pick of `77f5b5bc8`):
  SDL now follows `UIWindowDidBecomeKeyNotification` and
  `UIWindowDidResignKeyNotification` and sets or clears keyboard focus with
  the key window. Windows on scenes whose role is not the application role,
  such as a non-interactive external display, never get focus.
- `628c35c9a` "Save and restore the keyboard focus when going into the
  background on iOS and Android" (cherry-pick of `85b4e21bf`): on returning to
  the foreground SDL now restores focus to the one window that had it, instead
  of calling `SDL_SetKeyboardFocus` on every window in turn.

Neither is in `release-3.4.18`. Both touch the path the in-game soft keyboard
depends on, so `SoftKeyboardTests` is the suite to watch on this bump.

