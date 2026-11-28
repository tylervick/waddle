# Driving Device Hub by desktop control: it works, in the background, on an unlocked Mac, with three traps

Measured 2026-11-20 on the worker Mac with Xcode 27.1 (27A9275), the iOS 27.1
simulator runtime and Orca's computer-use (`orca computer ...`), while doing
the hand-work of issues 356 and 358. Xcode 26.2 stayed selected throughout;
every call ran with
`DEVELOPER_DIR=/Applications/Xcode-27.1.0.app/Contents/Developer`.

## What worked

An agent can do what `docs/learnings/iphone-duo-simulator-traps.md` said
needed a person, without bringing a window forward or moving the pointer.

- **Start it.** `orca computer launch-app /Applications/Xcode-27.1.0.app/Contents/Applications/DeviceHub.app`
  (bundle id `com.apple.dt.Devices`). Select your own device by pressing its
  sidebar row. Accessibility and Screen Recording were already granted to Orca.
- **The Mac must be unlocked.** With the screen locked or asleep every
  `orca computer` call fails with `screen_locked` (seen by the reviewer of
  PR 414 on 2026-11-20, twice, 15 minutes apart). Nothing an agent can do
  lifts that; a person has to unlock it.
- **Hinge.** Device Hub has three accessibility buttons under the device:
  `Closed`, `Partially Open`, `Open`. Pressing one by element index folds the
  simulator. No third-party tool is needed.
- **Rotate.** The `Rotate Right` button rotates the open device a quarter
  turn. `devicectl device orientation set` reported success and changed
  nothing on this device; `devicectl device orientation get` is still the way
  to read the result. The same held for the closed device while Device Hub
  was running, and a touch (tap, long press, slow drag) can be aimed in the
  app's own points: `sweeping-the-duo-by-host-shots.md`.
- **Taps and drags reach the open inner display.** `orca computer click --x --y`
  and `orca computer drag` on the device picture land as touches. Apple's
  Settings list, which a test-synthesized drag could not move on the open
  device, scrolled.
- **The simulator's own elements are in Device Hub's accessibility tree**, so
  a button can be pressed by name (`Details`, `Done`, `Files`) instead of by
  coordinate.
- **Captures** still come from `xcrun simctl io <udid> screenshot --display=LCD-1`.
- **It can be scripted.** `Scripts/duo-pose-device-hub.sh` presses the hinge
  and rotate buttons by name and reads the turn back from `devicectl device
  orientation get`, which stays truthful on the open device even though
  `set` does nothing there. A sidebar row reads `<name> <iOS version>
  Simulator` and the tree carries no UDID, so a name is the only handle and
  a prefix of it is someone else's simulator: the script matches the whole
  row, checks the name against `simctl`, and refuses unless exactly one row
  matches. It is the pose hook of
  `Scripts/capture-screenshots.sh capture duo-inner` (issue 409), which took
  the store's inner-display screenshots with Device Hub in the background.

Mapping device points to window coordinates, with the Device Hub window at
its default 1100x800 and zoom-to-fit: 0.529 window points per device point,
origin (418, 227) when the open display is wide (951x669) and (493, 152) when
it is tall (669x951). Re-measure from a window screenshot if the window is
resized.

## Trap 1: Orca's drag is one fast stroke

`orca computer drag` has no duration, hold or waypoints. A fast stroke is a
flick: from the bottom edge it is the home gesture, on a home-screen icon it
is a tap. Split View, a context menu, the movement stick and the layout
editor all need a press that is held or a path that pauses.

`docs/learnings/assets/duo-device-hub-2026-11-20/timed-drag.c` posts a timed path the same way Orca's
helper posts its own events (`SLPSPostEventRecordTo` to mark the window key,
then `CGEventPostToPid` with event field 51 set to the window number and a
window-local location). Those are private interfaces; expect them to break on
a later macOS. Build and use:

```
clang -O2 docs/learnings/assets/duo-device-hub-2026-11-20/timed-drag.c -o timed-drag \
  -framework ApplicationServices -F/System/Library/PrivateFrameworks -framework SkyLight
# pid, window id and window origin from `orca computer list-windows --app com.apple.dt.Devices --json`
./timed-drag <pid> <window-id> <origin-x> <origin-y> [--option]  x,y,ms  x,y,ms ...
```

Coordinates are global screen points; the first waypoint is the press and its
`ms` is how long it is held, a repeated point is a pause. `--option` sets the
Option flag on the whole path (see below for what that did not achieve). A plain
`CGEventPostToPid` without field 51 is ignored by Device Hub.

**Two fingers were not reachable, in the background or the foreground.** An
Option-drag posted this way arrives as a one-finger drag, with or without an
Option key event first. With the owner's leave, a real one was tried too:
Device Hub brought to the front, left Option held and the pointer dragged
through the HID event tap, in both orientations. It also panned the automap
(`k172:2`, no `k61`) and no second touch point appeared. So Option-drag, the
old Simulator's pinch, is not how Device Hub makes a second finger; what is
has not been found. DeviceKit carries `magnifyWithEvent:`, which suggests a
trackpad pinch, unconfirmed.

Device Hub's app menu has both "Quit Device Hub" and "Quit and Keep Simulators
Running": a plain quit shuts down the simulators it started, other workers'
included, so leave it running.

## Trap 2: Device Hub's accessibility tree keeps stale nodes

The tree lists the simulator's elements twice and keeps text from screens
that are gone, including the previous process's debug HUD. Pressing an element
by name works; waiting on tree text does not. Wait on pixels from
`simctl io screenshot` instead (strip the alpha channel first: the capture
carries the display's corner mask).

## Trap 3: `WADDLE_AUTOQUIT_SECONDS` runs through the level load

The budget starts when the session starts (`EngineSession.play()` arms it once
per session), not when the level is on screen. Under load, the tap, the level
load and the screenshot polling that confirmed the level took about 20 s here,
so a 25 s budget ended each session as the first gesture began, and the next
gesture then started a new session from the shelf. An earlier version of this
file said the budget counts from app launch; that was a wrong inference from
the same symptom. Budget 60 s when desktop-control steps sit between the tap
and the gesture.

## Split View on the Duo, as found

- Entered by a slow swipe up from the bottom edge, a pause in the middle
  (drop zones appear on both sides), a drag onto a side zone, release, then a
  tap on a second app. Only when the open display is wide (951x669, either way
  up). When it is tall (669x951) no drop zones appear and the gesture ends in
  the app switcher; rotating a split to tall returns the app to full screen.
- Waddle is laid out natively there, not scaled: the debug HUD reads
  `win=469x669` in the pane and `win=951x669` full screen. Two drags on the
  divider left the pane at 469; whether the split is fixed or the drags missed
  the handle is not established.
- A device held upside-down and opened still shows Waddle upright at 951x669
  although the iPhone orientation list omits upside-down, and adding
  upside-down to the list changed neither figure.

Captures are in `docs/learnings/assets/duo-device-hub-2026-11-20/`.

**A cross-app drag works this way** (2026-11-26, #550). This is the drag a
test cannot make. Open Safari with `simctl openurl` and swipe it into Split
View as above; it takes the right half. Then swipe to the home-screen page
that has Waddle, and tap Waddle to put it in the left half. Every step goes
through `Scripts/duo-pose-device-hub.sh touch <udid> <name> wide`. Then make
one touch path: a press on a link held for 1300 ms, then about 2 s of moves
over Waddle's half, with a 900 ms pause at the end. Safari lifts the link and
Waddle gets the drop. The hook sometimes fails to read Device Hub's window
("could not read Device Hub's window"). A retry a few seconds later usually
gets through.

## Building on this Mac

`mise run bootstrap` under `DEVELOPER_DIR` took 225 s and needed nothing else.
The copy of `Vendor/` a fresh Orca worktree arrives with was stale against
`Scripts/check-engine-fresh.sh`, so bootstrap is not optional. Nothing in
`Scripts/` or `mise.toml` names an Xcode: every `xcodebuild`, `xcrun` and
CMake call resolves through the environment, so without `DEVELOPER_DIR` they
silently use the selected Xcode 26.2.
