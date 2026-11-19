# An accessibility element on the screen's centre line breaks `app.tap(withNumberOfTaps:numberOfTouches:)`

The weapon-select branch added an invisible hotspot to the touch overlay: a
clear `UIView` at the bottom centre of the game picture, an accessibility
element (`weaponSelectHotspot`, `.button`) with `isUserInteractionEnabled`
off. Both `SoftKeyboardTests` cases then failed on the four-finger tap with
"Failed to unable to compute coordinates for gesture after 5 attempts,
final visible/unoccluded frame was {{0, 0}, {402, 874}}", while they passed
on `main`.

How XCUITest places an app-level multi-touch tap
(`-[XCUIElementBaseEventTarget _tapWithNumberOfTaps:numberOfTouches:...]`,
read from the `XCUIAutomation` binary):

1. Points are spread down the vertical centre line of the visible frame.
   On a 402 x 874 portrait screen with four touches they are
   `{201, 5}`, `{201, 293}`, `{201, 581}`, `{201, 869}`.
2. For each point it runs the app's **accessibility** hit test
   (`hitTestElement:withPoint:`). Anything other than the target itself
   (the application) is an occlusion.
3. The occluder becomes the hit element's highest ancestor below a window
   (`_highestNonWindowAncestorOfElement:notSharedWithElement:`), and that
   frame is cut out of the visible frame before trying again.

The hotspot was `{{167.5, 512.3}, {67.0, 75.3}}`, so `{201, 581}` was in it.
The accessibility hit test does **not** honour `isUserInteractionEnabled`
(it found the hotspot anyway), the ancestor was the full-screen
`touchOverlay`, cutting out the whole screen left nothing new to try, and
all five attempts computed the same points. The session log in the result
bundle (`xcresulttool export diagnostics`, `Session-WaddleUITests-*.log`)
says so outright: `Found occlusion at transformed point {201, 581}: Button
... identifier: 'weaponSelectHotspot'`, followed by `Occluding element
Other ... 'touchOverlay' has been encountered N times`. The test log shows
only the second half, which points at the wrong view.

Views that are not accessibility elements are passed over by the hit test
even though they appear in the UI-test tree (the overlay itself and SDL's
views do), which is why `main` passed: no element sat on the centre line.

**The fix:** the hotspot is an accessibility element only while VoiceOver or
Switch Control is running (`updateWeaponHotspotExposure` in
`TouchOverlayView`). Otherwise it is a plain view that keeps its identifier,
so `app.descendants(matching: .any)["weaponSelectHotspot"]` still finds it.

**Before adding an element to the overlay**, check whether its frame
crosses the centre line at those heights on the test device. The
`SoftKeyboardTests` four-finger taps are the check. The test's own comment
about the second tap failing with the keyboard up is the same mechanism:
keys under those points.
