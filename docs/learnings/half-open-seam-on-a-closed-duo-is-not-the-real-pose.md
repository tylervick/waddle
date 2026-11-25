# The half-open seam on a closed iPhone Duo is not the real pose

`WADDLE_TEST_HALF_OPEN=1` parts the launcher at a 40 pt band across the
middle of whatever window the app has. UI tests run it on a simulator that
boots **closed**, so that window is the outer display's 466 x 678 pt, and the
shelf's half is 302 pt tall. No physical pose gives that: a Duo standing half
open shows the inner display, 669 x 951 pt, and the shelf's half is far
taller. Measured 2026-11-25 for issue #541, iOS 27.1, Xcode 27.1.

Two things follow in that short half that the real pose does not do:

- **The bar overflows.** The system moves the shelf's leading and trailing
  toolbar items (Settings, `touchSchemeMenu`, and Add, `importButton`) under
  a `BottomOverflowBarButtonItem` labelled "More". Bent for real through
  Device Hub (`Scripts/duo-pose-device-hub.sh half-open`), both stay in the
  bar. A test that waits for, taps or hit-tests either one reports a missing
  or covered shelf over a shelf that is fully drawn.
- **Settings' lazy list stops early.** The lower half is short enough that
  the `Form` has not built its Files row
  ([lazy-form-hides-rows-from-uitests.md](lazy-form-hides-rows-from-uitests.md)),
  including when Settings is reached again by Back after a fold, which builds
  the list afresh at its top.

So in `HalfOpenLauncherTests`, "the shelf is here" is a tile
(`waitForShelf(in:)`), Settings is opened through `openShelfSettings(in:)`,
which goes through More when the gear is not in the bar, and rows below
Settings' first are scrolled to. Before reading a seam failure as an app
defect, look at the real pose: on a closed Duo the seam is a geometry
stand-in, not what a player sees.
