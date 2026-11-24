# A UI test's geometry has to come from the device it runs on

Three `WaddleUITests` failed on every iPad run for as long as they had existed
(issue #519), and nothing noticed, because no job ran the UI suite on an iPad.
Each had baked an iPhone's shape into a number:

- **`app.swipeUp()` swipes the window's centre.** On an iPad the game page is
  a 376 pt panel at the window's right, the centre is on the shelf, and the
  shelf scrolled while the row stayed under the panel's fold. Pass the scroll
  view that holds the element: `scrollTo(_:in:swiping:)`.
- **`app.frame` is not the container.** "The row spans its card" was written
  as `> app.frame.width * 0.6`, which a 376 pt panel in a 1032 pt window can
  never meet. Compare with the container's frame.
- **A fixed offset from a button's centre is not a miss.** Overlay buttons
  scale with the screen (`TouchOverlayLayout.scale`): weaponPrev is 48 pt on
  a phone and 74.5 pt on a 13" iPad, so centre + 34 pt landed *on* the
  button. Offset from the button's frame edge instead, and assert the side
  effect a hit would have (a menu opening) did not happen.
- **"Fills the width" is a phone's half, not a rule.** A 4:3 picture fills
  whichever side of its area runs out first; an iPad's upper half is wider
  than 4:3, so the picture fills the height.

The same issue found a fourth trap that is not about devices: a near-miss test
that cannot fail. Under the default `classic` scheme a press right of the
stick column starts nothing whatever the cushion, so the test passed with
`TouchTrackRouter.buttonNearMissMargin` at 0. Before trusting a negative
assertion, break the thing it guards and watch it go red.

The check is `ui-tests.yml`'s iPad leg, which runs the whole suite on the
`iPad Pro 13-inch (M4)` on every push to `main` and nightly. A test that
passes on the phone and fails there is reading the phone's shape.
