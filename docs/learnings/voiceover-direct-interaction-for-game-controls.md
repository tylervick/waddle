# A real-time game control tells VoiceOver `.allowsDirectInteraction`, not `.button`

`OverlayButton` (the FIRE/USE/weapon/MAP/menu circles of the touch overlay)
exposed `accessibilityTraits = .button` from the day it was written. Under
VoiceOver a `.button` is activated by focusing it and double-tapping, one
element at a time, and the double-tap is a *tap*: press and release. Doom
needs the opposite on every axis: FIRE is held, USE is pressed while the
stick is held, weapons are cycled mid-strafe. A focus-then-double-tap model
cannot express "hold" or "two at once", so with VoiceOver on the overlay
was, at best, a way to fire single shots while standing still (issue #215).

`UIAccessibilityTraits.allowsDirectInteraction` is Apple's trait for exactly
this class of control: one that must receive the user's touches as touches
(the documentation's example is a piano keyboard, where a double-tap per key
is unplayable). With it, VoiceOver delivers a touch that lands on the
element straight to the view's `touchesBegan`/`touchesEnded`, so the
press-and-hold machinery (`OverlayPressTiming`, the trigger axis for FIRE)
runs exactly as it does with VoiceOver off. The element keeps its label, so
a VoiceOver user still finds each control by exploring the screen, and the
screen reader still announces it; what changes is only what happens when the
finger stays.

**Keep `.button` beside it.** The trait set is a mask, and the first cut
replaced `.button` outright. Measured 2026-09-30 on the iPhone 17 Pro
simulator: with `.button` gone, `app.buttons["fireButton"]` matched nothing,
and both in-game `TouchControlsTests` cases run failed on
`waitForExistence` within 30 s. XCUITest (and Revyl, which drives the same
accessibility tree) classify an element as a button from that trait, so
removing it would have turned every overlay UI test red for a reason that
reads as "the overlay never installed". `.button` also makes VoiceOver
announce the control as a button. Direct interaction decides what a held
finger does; `.button` only says what the thing is. The two coexist, as they
do on a direct-touch keyboard key.

**The Direct Touch rotor.** Since iOS 13 VoiceOver does not honour
`.allowsDirectInteraction` unconditionally: the user enables Direct Touch
for an app through the rotor (or Settings → Accessibility → VoiceOver →
Rotor → Direct Touch Apps). If a held finger on FIRE still behaves like a
focus-then-double-tap button on the device, that setting is the first thing
to check, and the device note below should say which state it was in.

Decided 2026-09-30 from Apple's documented semantics of the two traits,
with the maintainer's agreement that the device run confirms rather than
decides (the trait's meaning is not in question, only whether anything else
in the overlay gets in the way). The in-game UI-test path, which the
original issue recorded as red, has been green since the forced-overlay seam
(`WADDLE_FORCE_TOUCH_OVERLAY`), so the trait is pinned by
`OverlayButtonAccessibilityTraitTests` in the unit bundle and the overlay's
whole behaviour by `TouchControlsTests`.

**What the device run must record** (append below when done: device, iOS
build, date):

- With VoiceOver on, explore to FIRE: it is announced by its label; a finger
  held on it fires continuously and release stops the fire (watch `trigger`
  on the debug HUD drop to 0.00).
- Two fingers: one held on FIRE, another on the stick area, move and fire at
  once.
- The four-finger keyboard summon: VoiceOver reserves multi-finger taps
  (four-finger taps jump to the first/last element), so expect it to be
  claimed. The documented alternative path to typing is a hardware keyboard,
  which the engine reads directly (`docs/manual-testing.md`, "Keyboard &
  mouse"), or VoiceOver off for the moment of typing.

The stick and turn areas are not accessibility elements; a touch that misses
every button lands on the overlay view itself and starts a stick or turn
track as it always did. Whether the SDL window underneath presents as an
element at all is still unmeasured and stays on the issue.
