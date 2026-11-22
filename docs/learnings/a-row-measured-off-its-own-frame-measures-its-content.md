# A row measured off its own frame measures its content

Found 2026-11-21 for issue #450, which asked whether `GamePageView` could
feed its own measurements the way `ShelfView` did
(`a-scroll-view-measured-to-lay-out-its-own-content-can-spin.md`). One of
its three could. No hang was seen; the page changed arrangement on every
layout pass.

## What each container does with content that reports wider than offered

Measured in a unit-test host (iPhone 18 Pro simulator, iOS 27.0) in a
669 pt window, with content told to report a sixth of a point more than the
last width measured, for forty steps:

| Measured | Result |
|---|---|
| a `ScrollView` | walks: 669.0 to 675.5 |
| a `Form` or a `List` | 669.0, once. It is not widened by a row |
| a row's `frame(maxWidth: .infinity)`, inside a form | walks: 629.0 to 635.5 |
| a clear zero-height sibling of that frame, in a `VStack` | walks the same |
| a `Layout` round that frame that reports its offer | 629.0, once |

So `onGeometryChange` on a form is safe, and on a flexible frame it reads
whatever the content reported. A `VStack` is no way round it: a stack that
one child has widened offers the others the wider width.

## What it did to the page

`GamePageView` read `heroRowWidth` off the hero row's frame, and
`PlayableDetailLayout.arrangement` chooses stacked or side by side from it.
The row holds wrapping `Text`, which reports a fraction over at many widths:
in a sweep of windows 420 to 1100 pt wide at `accessibility5` and
`xxxLarge`, about one in six came back a sixth, a quarter or a third of a
point over.

Stacked and side by side do not over-report alike. Where the rule's
threshold fell inside the difference, each arrangement measured the width
that chooses the other. A game named "Sigil II Extraordinarily Thunderstruck
Wads" with a Continue save, at `accessibility3`, in a 423x284 window:

```
heroRowWidth  383.25  383.0   383.25  383.0   ...
arrangement   side    stacked side    stacked ...
```

Also at 431x289, and at 412x284 at `accessibility1`. Seven changes in five
seconds of forced layout passes in the test host, then quiet when left
alone; never a spin. Those are not a shipping device's window. They need a
page wider than its viewport is tall at about 390 pt wide, which is a
narrow iPad window, or a phone with the keyboard up. It was not reproduced
in the launched app.

## Finding it

A blind sweep of 2,500 window widths showed the over-report and no cycle.
What found the cycle was working out where it had to be: host the page once
to learn the caption's width and what the form and the row take off a
window, then ask the pure rule which windows give a different arrangement
for a row a third of a point wider, and host only those. 31 windows, 3
cycled. `GamePageMeasurementTests` does the same search each run, because
the windows move with the fonts.

A sweep that hosts thousands of windows in one test process must drop each
one (`rootViewController = nil`, inside an `autoreleasepool`). The first
sweep here did not, and died after about 2,500 in
`AG::data::table::grow_region`, which read for a moment like the hang being
looked for.

A hosted page's measurements also change for a reason that is not the
page's: the test window's own bars settle a pass after the form is first
measured. On CI's iPad the viewport read 113 and then 165, and on its
iPhone Duo the form read 434 and then 346 (88 pt of safe area at the
sides). The first version of the test required each measurement to be taken
once, passed on an iPhone 18 Pro and failed on both of those. What tells a
loop from settling is that a loop comes back: the test requires that no set
of measurements is seen twice, and that one width of form has one width of
row. `ShelfContainerWidthTests` met the same 88 pt: a scroll view's content
is its width less its safe area, not its width.

## The fix

`onOfferedWidthChange` (`App/Sources/UI/ContainerWidth.swift`) puts the row
in a `Layout` that is as wide as its offer and as tall as the row, and
measures that. The other two measurements needed nothing: the form is not
widened, and the caption probe is a `fixedSize()` copy that no offer
reaches.

A custom `Layout` round the shelf's whole content slowed CI's picture tests
once, for a reason never found. This one is round a single row of a page
that is not on screen while those tests run.

## The checks

- `ScrollContentWidthTests`: the table above, as tests.
- `GamePageMeasurementTests`: the real page, on its thresholds; fails if the
  row is measured off its frame again.
- `ShelfContainerWidthTests`: the real shelf's guard.

A launch scan on an open iPhone Duo (the page opened in the panel with
`WADDLE_OPEN_PANEL`, both ways up, twelve text sizes, two names) found no
hang with the fix. In the panel the page is narrower than it is tall, so it
is stacked whatever the row measures; the scan shows the page still draws
there, not that the threshold was crossed on a device.
