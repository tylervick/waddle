# The hero zone has to leave the first tile row *tappable*, not just visible

`ShelfHeroLayout.minimumGridPeek` is 120 pt and its comment says the first row
must be "recognizable *and* tappable without scrolling". The first half is what
the constant actually enforces; the second half it does not, and the gap is
invisible until a UI test walks into it.

PR #177 added the first-launch welcome card into the shelf's hero zone. The
Continue hero that already lived there is capped by
`ShelfHeroLayout.artHeight`; the card was given no budget at all. On an
iPhone 17 Pro the numbers work out badly: 440 pt wide less 16 pt of padding
each side is a 408 pt content width, `Theme.gridMinimumTileWidth` is 200, and
408 pt cannot fit two 200 pt columns plus a gap — so the grid resolves to a
*single* full-width column and the first tile is 544 pt tall. With 184 pt of
card and 24 pt of section spacing above it, plus 16 pt of padding below, the
column needs 784 pt inside a 754 pt viewport.

The row still peeked by ~530 pt, far more than `minimumGridPeek`, so nothing
reported a problem. What broke was the tap. `EngineSmokeTests` found
`playFreedoom1`, XCUITest logged `Synthesize event` with no error — and the
button's action never ran. The app's own breadcrumb log is the proof: no
`session begin` line on a failing run, one on a passing run. A screenshot
taken three seconds after the tap shows the springboard, so the synthesized
tap reached the system rather than the button.

Two things follow.

**A tap that synthesizes cleanly is not a tap that landed.** XCUITest reports
success for the gesture, not for the target's reaction. When a UI test fails
waiting for a *consequence* of a tap, check whether the action ran at all
before looking at the consequence — the breadcrumb log answers that in one
`cat`, and it distinguishes "the button never fired" from "the engine never
came back", which look identical from the assertion.

**Whatever occupies the hero zone needs the same budget the hero has.** The
fix is `ShelfHeroLayout.welcomeCardShowsDescription`, which sizes the first
tile row from the viewport via `gridColumnWidth` and drops the card's
description line when the full card would not fit. `ShelfHeroLayoutTests`
pins both directions: the reference phone goes compact, a roomy viewport keeps
the full card. If a third occupant is ever added to that zone, it needs its
own budget too — the zone does not have one, its occupants do.

Bisected with `ui-tests.yml`'s own invocation, one merge at a time:
`ed49418` (#173) green, `9fa7675` (#177) red.

Related: `docs/learnings/lazy-form-hides-rows-from-uitests.md`, the same shape
one screen over.
