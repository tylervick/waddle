# Gesture recognizers do not fire inside SDL's own UIWindow

A `UITapGestureRecognizer` attached to the touch overlay reaches `.recognized`
but its target-action **never runs**. KVO-diagnosed: no UIViewController-hosted
scene backs SDL's directly-owned `UIWindow`, and the action dispatch depends on
one.

Plain responder-chain delivery — `touchesBegan` / `touchesMoved` /
`touchesEnded` — works normally.

**What to do instead:** implement gestures by counting touches in the responder
callbacks. The four-finger soft-keyboard tap is done this way, not with a
recognizer. This applies to any future gesture work on that overlay.

**Provenance:** soft-keyboard branch, 2026-07-21.
