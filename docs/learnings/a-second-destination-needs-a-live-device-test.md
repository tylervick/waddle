# A second test destination buys nothing until one test reads the live device

Issue #131 asked for the suite to run on an iPad as well as a phone, and
offered a way to prove the new leg was worth its runtime: break a
`TouchOverlayLayout` iPad expectation, watch the iPad leg go red while the
iPhone leg stays green.

That proof cannot work, and the reason generalises. `TouchOverlayLayoutTests`
is pure geometry: it hands the layout a `CGRect` from a literal table and
asserts what comes back. Its iPad cases are iPad-shaped *numbers*, not an iPad.
Break one and **both** legs go red, because both legs run the same arithmetic
over the same literals. Every one of the 309 tests in `WADdleTests` was like
that, which is why adding the destination alone would have doubled the CI
simulator time and duplicated 309 identical verdicts.

A second destination is only a second destination if at least one test can
observe which device it is on. `App/Tests/LiveDeviceOverlayLayoutTests.swift`
is that test: it reads `windowScene.screen.bounds`, the live window, and the
safe-area insets the system actually reports, and checks them against a table
of the destinations this repo pins. Breaking its iPad row now does exactly what
the issue described — iPad red, iPhone green, measured.

Two things that look like coverage and are not:

- **`XCTSkip` by idiom.** A test that skips on the destination that matters is
  indistinguishable, in a green run, from one that never existed. Where the
  live device is not one this repo pins, assert the weaker invariant that still
  holds (an iPad's overlay scale cannot land in phone territory) rather than
  skipping.
- **Trusting the idiom alone.** If `TARGETED_DEVICE_FAMILY` ever lost its `2`,
  the app would run on an iPad in iPhone compatibility mode — phone idiom,
  phone-sized screen — and the iPad leg would match the *iPhone* row and pass,
  testing a phone twice. `testHostAppIsBuiltForIPadAndIPhone` reads
  `UIDeviceFamily` out of the host bundle to stop that being silent.

Adding a third destination means adding a row to `pinnedDestinations`, not just
another `xcodebuild` invocation.
