# The iPhone Duo simulator: what a script can drive, and which red means nothing

Measured 2026-11-09 with Xcode 27.1 (27A9275) and the iOS 27.1 simulator
runtime (24A94232), while proving the toolchain bump in PR #349.

## The 27.1 runtime runs one device

The iOS 27.1 simulator runtime supports exactly one device type, iPhone Duo.
Every other type is "Incompatible device" there (actions/runner-images#15000),
and the Duo does not exist on 27.0. So one Xcode needs two runtimes: CI builds
against the 27.1 SDK and runs its existing legs on `OS=27.0`; a Duo leg pins
`OS=27.1` on its own. Reading `SIMULATOR_OS` as "should equal `XCODE_VERSION`"
is the mistake this section exists to prevent.

The GitHub image is `runs-on: xcode-27`, named for its Xcode major, not
`macos-27`. It pre-creates the iPhone 18 lineup and no iPhone 17 Pro. The two
have the same screen (a screenshot of each is 1206x2622 px), which is why the
402x874 pt figures in the layout tests survived the move.

## Two displays, not one that resizes

`xcrun devicectl device info displays --device <udid>` reports both:

| Display | Pixels @3x | Points | Active when |
|---|---|---|---|
| `LCD` (outer) | 1398x2034 | 466x678 | closed |
| `LCD-1` (inner) | 2007x2853 | 669x951 | open |

The simulator boots closed. Held in portrait and opened, the app's window is
**951x669**, wider than tall; rotating the open device gives 669x951. Figures
published before the SDK shipped (626x890 inner) were wrong; measure.

Built against the 27.1 SDK, the system keeps a column about 84 pt wide for the
clock, status icons and toolbar buttons: on the trailing edge in portrait, on
the leading edge in landscape-left. The safe area is therefore asymmetric in
every Duo pose.

## Nothing Apple ships folds it from a script

`simctl`, `devicectl` and XCUITest have no hinge command; the hinge lives only
in the Device Hub window. The third-party `hinge` script
(github.com/artemnovichkov/hinge) does it by spawning a small helper inside
the simulator that posts a vendor HID event, and `open`, `close`, `half` and
`orient` all worked here. It rides private interfaces, so expect it to break
on some later Xcode. Read its source before running it: one bash script and a
207-line Objective-C file, no network.

A session can be started with no tap through the profiling seam, which is what
makes a fold experiment scriptable end to end:

```
SIMCTL_CHILD_WADDLE_PROFILE_GAME="Freedoom Phase 1" \
SIMCTL_CHILD_WADDLE_PROFILE_DEMO=demo1 \
SIMCTL_CHILD_WADDLE_FORCE_TOUCH_OVERLAY=1 \
  xcrun simctl launch <udid> com.tylervick.waddle -debugHUD YES
```

The debug HUD's `win=WxH` field then reads the engine's own window size in
each pose.

## Five ways XCUITest misleads on the Duo

1. **Synthesized drags do nothing while the device is open.** Taps land;
   swipes and `press(forDuration:thenDragTo:)` do not. The control was Apple's
   Settings app, not ours: the same drag moved its first list cell from y=82
   to y=-14 on the closed device and left every cell where it was on the open
   one. So on an open Duo every stick, automap, drag-to-turn and
   scroll-to-a-button test fails, and that red says nothing about the app.
   Whether a real finger drag works on the inner display has to be checked by
   hand in Device Hub or on a device.
2. **`XCUIDevice` does not rotate it.** `TouchControlsTests`' two rotation
   tests skip with "this simulator does not perform interface rotation".
   `devicectl device orientation set` does rotate it.
3. **The screen recording is of the inner display.** On a closed device every
   failure video is 2006x2852 px of black.
4. **The back button has no title.** The system lays navigation buttons out
   vertically in the status column, where the back button carries the
   identifier `BackButton` and no label, so a test that taps a button named
   for the previous screen finds nothing.
5. **`XCUIScreen.main.screenshot()` is always the outer display.** On an open
   device it returns 1398x2034 px of a screen that is switched off, and the
   test still passes. A capture of what the player sees has to come from the
   host (`xcrun simctl io <udid> screenshot`, which follows the active
   display), taken while the test holds the screen still.

## What the engine did

A session started on the open device survived close, reopen, rotate and
half-open with no crash, and the window followed each time: `win=951x669`,
`466x678`, `951x669`, `669x951`, and `678x466` closed in landscape. SDL
3.4.18 with the patch in `Scripts/patches/SDL/` needed nothing further for
this, on the simulator.
