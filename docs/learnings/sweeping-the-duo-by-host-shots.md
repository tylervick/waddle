# Sweeping the iPhone Duo's poses: what the test can do, and what the host has to

Measured 2026-11-20 on the worker Mac (Xcode 27.1, iOS 27.1 runtime, Device
Hub running), while photographing every surface in five poses at three text
sizes for issue #357. `Scripts/duo-layout-sweep.sh` and
`App/UITests/DuoLayoutSweepTests.swift` are the result; this file is what they
had to work round. It adds to `iphone-duo-simulator-traps.md` and
`driving-device-hub-by-desktop-control.md` and repeats neither.

## On an open Duo, XCUITest can press an element and little else

Already recorded: a synthesized drag does nothing there, and (in
`ShelfView`'s `WADDLE_OPEN_PANEL` seam) neither does a long press. Found here:

- **A tap aimed by coordinate opened nothing.**
  `app.coordinate(...).withOffset(...).tap()` at the engine's Save Game item,
  aimed by the debug HUD's `tgt=` field, opened the save list on the closed
  device and not on the open one held wide. XCUITest believes that window is
  tall (`app.frame` reads 669x951 for a 951x669 window), which is the likely
  reason; it was not isolated from the next section's short-press effect. A
  tap on an *element* lands.
- **Element frames are still right.** `element.frame` on the open device is
  in the app's own points, and a touch made by the host at `frame.midX,
  frame.midY` hits the element. That is what makes the next section work.

## The host makes the touches the test cannot

The test writes `touch x,y,ms ...` to its request file, in the app's points,
and the script hands it to `Scripts/duo-pose-device-hub.sh touch`, which maps
the points onto Device Hub's picture of the display and posts the path with
`timed-drag.c`. One command covers all three gestures:

| Gesture | Waypoints | What it takes |
|---|---|---|
| tap | `x,y,250` | On the engine's menu an 80 ms press opened nothing (3 runs, wide, tall and half open); 250 ms opened the item in every run after. |
| long press | `x,y,1200` | Opens a tile's context menu. |
| scroll | `x,y1,60 x,y2,500 x,y2,300` | A slow drag with a pause before the lift, so the list is not flicked past the row. |

The first touch of a run compiles `timed-drag.c`, which once took longer than
the test's wait for an answer. That exposed a hole in the request file's
protocol, which was "the script deletes the file when it has served it": the
test gave up and wrote its next request, the slow handler finished and
deleted *that*, and the test read the deletion as service. A lost shot shows
up as a missing file; a lost touch showed up as nothing. A request now
carries an id and is answered by writing the id to `<request>.done`, so an
answer that arrives late names an id nobody is waiting for. The request file
is deleted only by the side that wrote it.

**The display's place in Device Hub's window is a measurement.** At the
default 1100x800 window and zoom-to-fit: 0.529 window points per app point,
the display's corner at (418, 227) when the app's window is wide and (493,
152) when it is tall. The hook refuses any other window size.

**A device standing half open is drawn in perspective**, shorter than flat:
the tall display covers about 360x468 window points from (490, 170), where
flat it covers 354x503. A straight-line fit to that (0.538 across, 0.492
down) was good enough to hit the engine's menu rows, which are 37 app points
apart, and a tile; nothing finer was tried.

## Device Hub is one window, and every session on the Mac shares it

The hinge buttons and a posted touch act on whichever simulator's row is
SELECTED in the sidebar, and selecting is a separate press from acting. The
hook has always checked that the name it was given is its own simulator's and
nobody else's; what it did not have was anything between "select my row" and
"press Open".

Seen 2026-11-21, with two other sessions driving their own Duo simulators
through the same Device Hub while this one did a hand check: this session's
simulator was turned a quarter turn twice and closed once by presses it never
made, and a game was started on it by a tap that was aimed at another
simulator. Each time the cause was the same from the other side: this session
had selected its row a moment before the other one pressed.

The hook now does two things, and it takes both:

- **A lock**, a directory at a path every session agrees on
  (`/tmp/waddle-device-hub.lock`, not under a per-session `TMPDIR`), held for
  one invocation. A holder that died is cleared by its pid; a live one is
  waited for and then the hook stops, having pressed nothing. This binds only
  sessions that run this version of the hook.
- **The selection is read again immediately before every press of a device
  button and before a touch is posted**, and must still be this simulator's
  row (`outline row (selected) <name> <version> Simulator`). During the same
  hand check this fired for real: `'Duo357 Review' is no longer the simulator
  selected in Device Hub; not going on to post the touch`.

What is left is the time between that read and the press, a fraction of a
second, against a session that does not take the lock (a person at the
window, or an older copy of the hook). The slow part of a touch, compiling
`timed-drag`, is done before the lock is taken and before the row is selected.

A sweep makes hundreds of touches. Do not run one while another session is
using Device Hub with a hook older than this.

`Scripts/duo-layout-sweep.sh` also refuses to run without
`WADDLE_DUO_SIMULATOR`, and refuses the stock name `iPhone Duo`: it reinstalls
the app on that simulator and folds it, and one match for a default name was
being taken as "mine". And it closes the device again on every way out, not
only at the end of a clean run; a run that died in an opened pose used to
leave the device open and turned, because its trap asked `devicectl` for
portrait, which (next section) does nothing here.

## `devicectl device orientation set` turned nothing here, closed or open

`driving-device-hub-by-desktop-control.md` records that `set` reports success
and changes nothing on the *open* device. With Device Hub running it did the
same to the *closed* one: `New Device Orientation: landscapeLeft`, and `get`
still read `portrait`. The first closed-landscape pass was three full runs of
portrait pictures, each launch waiting 45 s for a turn that never came. On a
headless CI runner the same command does turn a closed Duo
(`iphone-duo-simulator-traps.md`), so the script turns through the hook where
there is one and through devicectl where there is not, and reads the result
back either way.

**The turn changes the host shot too.** After Device Hub's Rotate Right, a
`simctl io screenshot --display=LCD` of the closed device comes back upright
at 2034x1398. The traps file says a shot of the outer display is "the panel's
own way up" (1398x2034); that was measured after a devicectl turn. So the
shape of the raw shot, not the pose's name, decides whether it needs turning.

## Things about the run itself

- **`xcodebuild` installs the app again at the start of a test session, and
  the data container moves.** A path taken from `simctl get_app_container`
  before the session is a directory that no longer exists once the test
  runs. Anything the host puts in the container for a test has to be put
  there on request, during the session.
- **A failed test on the Duo costs ten minutes at the end.** `Failure
  collecting diagnostics from simulator: Timed out after 600.0 seconds`.
  `-collect-test-diagnostics never` removes it; a sweep expects failures.
- **Committing a save in one test changes the shelf for every later one.**
  Pressing Return in the engine's save-name entry writes a real save, the
  game's tile becomes the Continue hero, and `playFreedoom1` is gone. The
  sweep leaves the entry through the menu button instead.
- **At the largest accessibility size a lazy list shows about three rows.**
  Settings' fourth row is not in the hierarchy until scrolled to, and on the
  shelf a tile fills the window, so "wait for the row to exist" fails and
  "tap the tile" taps something else. Find a screen by its first row, and
  scroll to everything.
- **Two ways the scrolling itself went wrong there.** A tile taller than the
  landscape window never lies wholly inside it, so "its frame is inside the
  window" is never true; the sweep asks for the element's centre instead. And
  a list found by a query for one of its rows stops being found when that row
  scrolls out of the hierarchy: the drags after the second one fell on the
  shelf beside the panel. Settle where to drag before the first drag.
- **A tall open window (669 pt wide) is regular width.** The game page and
  Settings open in the panel there, as on the wide window; only the closed
  poses push a page and present a sheet.

## The captures

Fifteen contact sheets, one per pose and text size, are in
`docs/learnings/assets/duo-sweep-2026-11-20/` (WebP; `montage` needs its
`-label` before the files, and a `-font`, or the sheet has no names on it).
What they showed is on issue #357.
