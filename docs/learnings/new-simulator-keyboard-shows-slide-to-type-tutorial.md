# A new simulator's first keyboard is the Slide to Type introduction, and a key tap misses

The first time a newly created simulator shows the system keyboard, iOS puts
its one-time "Slide to Type" introduction over the keys (issue #511):

> Speed up your typing by sliding your finger across the letters to compose a word.
> **Continue**

It is its own window, `UIContinuousPathIntroductionView`, above the keyboard.
The keys stay in the accessibility tree underneath it, so a test that waits for
a key finds it, taps it, and the tap lands on the panel instead. Tapping
`Continue` once dismisses it for the device's lifetime. `typeText` is not
affected, because it does not aim at a key.

## The failure signature

`SoftKeyboardTests.testFourFingerTapSummonsAndDismissesInGame` fails on its last
wait (line 75 before the fix):

```
Asynchronous wait failed: Exceeded timeout of 5 seconds, with unfulfilled expectations:
"Expect predicate `exists == 0` for object "softKeyboardActive" Other".
```

Before it, the keyboard summoned and the assertion on that passed, and Return
was found and tapped. The game keeps running behind the panel, with the HUD
and touch overlay intact. Return's tap never reached `TouchKeyboard.onReturn`, so the marker
stayed. A recording shows the panel where the keys should be.

It hits any run in which this is the first test to raise a keyboard on a device
that has never shown the introduction: a narrow `-only-testing` run, a batch in
which only keyboard-free suites run first, and every simulator a worker creates
for itself, which `simulator-test-hazards.md` and the review workflow encourage.
A full run on a fresh CI simulator could pass by luck of order, if an earlier
suite's `typeText` had raised a keyboard first.

## Why it looked like the diff

It surfaced while reviewing #489 (SDL `release-3.4.18` → `release-3.4.20`): the
pull request's first two runs, each on a new simulator, failed, and the SDL bump
touches keyboard focus. A 30-run-per-build soak alternating `main` and the pull
request showed `main` failing the same way, once, on run 1: the device's first
keyboard. Every run after that passed on both builds.

So a red `SoftKeyboardTests` dismiss run is first a question of whether it was
the device's first keyboard. Rerun on the same device before suspecting the
change.

## The check

`dismissSlideToTypeIntroduction(in:)` in `App/UITests/XCTestCase+UIHelpers.swift`
taps the panel's button when it is there and does nothing when it is not.
`SoftKeyboardTests` calls it between finding Return and tapping it. Any new test
that taps a key on the system keyboard should do the same.

Suppressing the panel in the simulator's keyboard preferences was not used: the
helper works however the simulator was made, including by hand.
