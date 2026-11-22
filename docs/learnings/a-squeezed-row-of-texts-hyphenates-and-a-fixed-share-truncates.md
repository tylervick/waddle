# A squeezed row of texts hyphenates, and a fixed share of a row truncates

Measured 2026-11-21 on the iPhone Duo simulator (iOS 27.1) and an iPhone 17
(iOS 27.0) at `accessibility-extra-extra-extra-large`, fixing issue #424 on
the shelf's Continue hero. Two different failures of one word, with two
different causes. Sheets are in `assets/continue-hero-2026-11-21/`: `pair-*`
is `main` beside the fix, `all-sizes-*` is the fix at all twelve text sizes.

## An `HStack` of `Text`s that does not fit shares the shortfall

The hero's caption line was `HStack { ▶ Continue · 4 minutes ago }`. When the
row is narrower than the line, SwiftUI does not wrap the row: it gives each
`Text` a column and wraps inside it, and a single word in a column narrower
than itself is hyphenated. So the hero's own action read `Con-` / `tinue`
beside `48` / `seconds` / `ago`. It was not only the closed Duo (344 pt of
row): an iPhone 17 in portrait did the same.

`ViewThatFits(in: .horizontal)` with the one-line row first and a stack
second is the fix, and the word that must never give way also gets
`.lineLimit(1).fixedSize()`.

## A caption given a fixed share of the row cuts its buttons

Beside its art, the caption had half the row whatever was in it. A button
label is text at the reader's size; at the largest size the wider of
Continue and New Game, with the style's padding, needs more than the 312 pt
that is half the row of an open Duo turned tall. Both were cut (`Contin…`,
`New Ga…`), and so was the closed Duo on its side, which the sweep's report
did not list because the button starts under the fold there.

The art now gives way: `ShelfHeroLayout.sideBySideArtHeight` takes a
`captionMinimumWidth` and `ShelfHeroLayoutTests` pins it.

**Measure the label from the views, not from `UIFont`.** A `Label`'s icon
and the gap after it are SwiftUI's to size and both grow with the text, so a
sum of `NSString` widths is a guess that truncates when it is a few points
short. `ShelfView.heroButtonLabelGauge` is the two labels in a hidden,
`fixedSize()` stack in a `.background`, read with `onGeometryChange`. It is
labels only, with `.accessibilityHidden(true)`: a hidden copy of the
*buttons* would carry their accessibility identifiers a second time.

## A row of two stretching buttons is split evenly, so judge it that way

`ViewThatFits` chose between the buttons in a row and in a column. It asks
whether the row's ideal width fits, which is the sum of the two labels. But
both buttons stretch (`frame(maxWidth: .infinity)`), so the row is drawn as
two equal halves, and wherever the sum fitted and twice the wider label did
not, the wider label was cut: `New Ga…` on an open Duo at
`accessibility-medium` and on a landscape iPhone at `accessibility-large`,
sizes the first pass of this fix did not capture. The review of pull request
434 found it.

`ShelfHeroLayout.buttonArrangement` now makes the choice from the caption's
width and the measured label, and is tested. The general point: `ViewThatFits`
measures ideal sizes, and a stack of flexible children is not drawn at them.

The game page kept its own `ViewThatFits` for the same two buttons, and wrapped
them to `Contin-` / `ue` and `New` / `Game` on a closed iPhone Duo held
sideways at the *default* text size (issue #468), and on a regular iPhone at
the largest accessibility size. It now uses the same rule
(`GamePageMeasurements.buttonArrangement`). Two `ViewThatFits` over the same
buttons were one fix apart; look for the other copy when fixing one.

## The UI test that reported a busy main thread was reporting a real hang

While taking the captures, the sweep's hero test failed on the unfixed build
with `process main thread busy for 30.0s` in the two poses where the buttons
were cut, and an earlier version of this file guessed truncation was the
cause. It was not: see
`a-scroll-view-measured-to-lay-out-its-own-content-can-spin.md` (issue #437).
The app launched by hand looked idle only because minutes had passed and the
date string was a different one.

## Taking the hero on a simulator by hand

`WADDLE_SEED_CONTINUE_SAVE=1` on a fresh install shows the welcome card, not
the hero: the seed gives a save to the most recently *played* game, and
nothing has been played. Run a session first (the sweep's `testA_Session`
does), or use the sweep itself: `Scripts/duo-layout-sweep.sh run closed
closed-landscape` works against a regular iPhone named in
`WADDLE_DUO_SIMULATOR`, without a pose hook, and only its size check
complains.
