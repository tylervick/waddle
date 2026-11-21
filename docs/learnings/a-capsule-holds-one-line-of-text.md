# A capsule holds one line of text, and a coverage test cannot see text over its own background

Measured 2026-11-21 on the iPhone Duo simulator (iOS 27.1) and an iPhone 18
Pro (iOS 27.0), fixing issue #423. The check is
`App/Tests/ImportNoticeBannerTests.swift`; this file is what it does not say.

## The shape

`Capsule()` rounds its ends to half the view's height. Round one line that is
a pill. Round text with no line limit it is a different outline at every line
count: at eight lines (the longest import notice on a closed Duo at the
largest accessibility size) the ends were half-circles 232 pt in radius, and
the first and last lines began outside them, over the tiles. It shows from
three lines up. A banner whose text can wrap takes `Theme.bannerShape`, a
rounded rectangle whose radius does not follow the height, and pads the text
on both axes.

A `RoundedRectangle` clamps its radius to half its shorter side, so a banner
under 32 pt tall (the engine's exit label at the default text size) still
comes out as a pill.

## Three things about testing it by picture

The test draws the banner on nothing with `ImageRenderer`, once as shipped and
once with clear text, and asks that the text mark no pixel the background
does not cover.

- **Coverage alone cannot tell the two drawings apart.** Text over an opaque
  background leaves alpha at 255, so "the two alpha maps differ" fails on a
  correct banner. The guard against comparing a drawing with itself has to
  read a colour channel.
- **A continuous corner is not exactly the same at every height.** A 16 pt
  continuous corner wants more than half of a 44 pt banner, so on one line
  it is drawn a shade tighter: 11 of 255 at one edge pixel. The corner
  comparison allows 32; a capsule misses by 255.
- **`ImageRenderer` with no proposed height never shrinks the text.** The
  banner carries `minimumScaleFactor(0.5)` because on a closed Duo at the
  largest size nine lines do not fit the window, and without it the notice
  ended "Import Fail…". Only a capture of the real window shows that; the
  unit test gives the text all the height it asks for.

## One thing about the Duo's hinge, from taking the captures

`Scripts/duo-pose-device-hub.sh open-turned`, asked of a closed device,
failed 4 of 4 times with `four quarter turns never read 'landscapeRight'
(devicectl says 'portrait')`: Rotate Right pressed straight after Open did
nothing. `open`, three seconds, then `open-turned` worked 4 times of 5, and
the one failure was on a Mac where two other workers were pressing the same
Device Hub window. `half-open` from closed worked as it is.

## The captures

Before and after, the banner in each Duo pose and on the iPhone 18 Pro, are
in `docs/learnings/assets/import-banner-2026-11-21/`.
