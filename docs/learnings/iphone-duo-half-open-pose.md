# An iPhone Duo's half-open pose: what the system reports, and what moving the picture costs

Measured 2026-11-13 on the iPhone Duo simulator (iOS 27.1, Xcode 27.1), with
a probe in the touch overlay that logged the hinge and the fold's region
through each pose, for issue #373: the game above the fold and the controls
below it while the device stands half open.

## The window says nothing

The window is 669x951 pt flat and 669x951 pt half open (951x669 the other
way up). No size, trait or safe-area inset changes when the device is bent.
Anything that infers the pose from the window is guessing.

## Two public signals, and you need both

iOS 27.1 has no SwiftUI API for the fold. UIKit has two, and neither is
enough alone.

**`UIHingeInteraction`**, added to any view, hands its handler a `UIHinge`
with a `status` and an `angle`:

| Pose | `status` | `angle` |
|---|---|---|
| open flat (180°) | `.fullyOpen` | π |
| bent, 60° to 120° tried | `.partiallyOpen` | the angle |
| closed | `.closed` | 0 |

It says the device is bent. It does not say which way the fold runs across
the window, and a Duo held like a book reads exactly the same as one standing
on a table.

**`UIView.reservedRegions(kind: .division)`** returns the band where the
system says content should part in two, in the view's own coordinates:

| Window | `frame` | `margins` |
|---|---|---|
| 669x951 (fold across) | (0, 455.5, 669, 40) | top 20, bottom 20 |
| 951x669 (fold down the middle) | (455.5, 0, 40, 669) | left 20, right 20 |
| closed | none | |

The frame already includes the margins. Asked for with `.includeInactive`,
the band is reported in every open pose, and its `isActive` is true only
while the hinge is partly open. (What the call returns without that option
was not tried.) So the frame's shape
gives the direction and its position gives the two halves.

`HalfOpenSplit` requires a partly open hinge and an active band that crosses
the window from side to side. The book pose has an active band too, from top
to bottom, and is left alone.

## The two signals do not change together

- Bending: the hinge handler fires with `.partiallyOpen` while the band is
  still inactive. The band turned active 340 ms and 356 ms later in two
  tries. The handler happened to fire again then, but that was an angle
  update, not a notification about the band, and nothing else announces it.
- Opening flat or closing: the hinge handler fires first and the band is
  still active inside it; 60 to 140 ms later it is not.

So a handler that reads the band once at the moment the hinge changes gets
the wrong answer in both directions. The overlay recomputes from the hinge
handler, from `layoutSubviews`, and from the 0.25 s poll it already runs.

## SDL cannot put a letterboxed picture anywhere but the middle

The engine presents with `SDL_SetRenderLogicalPresentation(...,
SDL_LOGICAL_PRESENTATION_LETTERBOX)`, which centres the picture in the whole
output and has no offset. To stand the picture on the upper half, the engine
turns logical presentation off while an area is set and places the texture
itself (`I_SetPictureArea`, `PictureRect` in `i_video.c`). Everything that
maps between the window and the picture has to go through the same rect, or
a menu tap lands on the wrong item: `I_MenuPointFromWindow`,
`I_WindowPointFromMenu`, `I_PictureRectInWindow` and upstream's
`UpdateMouseMenu`.

## A picture that moves needs the window cleared every frame

Upstream clears the window once per change (`clearneeded`). On iOS the
window is presented from a small pool of drawables whose contents persist,
and nothing but that clear touches the window outside the picture, so one
clear reaches one drawable. After unfolding, the upper-half picture was still
visible above the centred one in 7 of 8 screenshots taken one after another. The
engine now clears every frame under `WOOF_IOS`; the same 8 screenshots then
had no pixel of it.

That also removed something older: a strip of an earlier frame under the
status bar in a letterboxed window, there for the same reason and visible in
captures from before this work.

## The engine build and `DEVELOPER_DIR`

`mise run build-engine` rebuilds the dependencies first. Run with
`DEVELOPER_DIR` pointing at Xcode 27.1 on a machine whose selected Xcode is
27.0, CMake keeps the cached 27.0 SDK and compiles it with the 27.1 clang,
and OpenAL Soft stops on

```
CFBase.h:361:5: error: '__SWIFT_ATTR_SUPPORTS_SENDABLE_DECLS' is not defined, evaluates to 0 [-Werror,-Wundef]
```

Build the engine with the selected Xcode, and use `DEVELOPER_DIR` only for
the app and the simulator.

## Testing it without a hinge

No CI simulator has a hinge, and nothing Apple ships bends the Duo simulator
from a script (`iphone-duo-simulator-traps.md`). `WADDLE_TEST_HALF_OPEN`
(Debug builds) stands in for the two readings above, with a 40 pt band across
the middle of whatever window the test has, and the Darwin notification
`com.tylervick.waddle.test.half-open-toggle` flips it mid-session.
`HalfOpenLayoutTests` uses both. What that cannot show is that the system
reports what the table says; that was checked by hand with the third-party
`hinge` script and has to be checked again by hand if either API changes.
