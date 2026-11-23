# Type at a smaller size is wider than its width scaled

Measured 2026-11-22 on an iPhone 18 Pro simulator (iOS 27.0, Xcode 27.1),
fixing issue #458; seen on an iPhone 17e simulator in landscape.

`minimumScaleFactor(0.85)` shrinks a `Text` to 0.85 of its *point size*, not
of its width. Type is not drawn in proportion to its size (smaller sizes get
looser tracking), so the shrunk text is wider than 0.85 of the full width.
The tile's one-line rule (`PlayableTileLayout.oneLineTitleMinimumWidth`)
assumed the opposite, and offered the one line to titles it could not hold.

"Freedoom Phase 1", `.headline`:

| Size | Full width | 0.85 × full | Set at 0.85 of the size | Narrowest line SwiftUI drew it whole in |
|---|---|---|---|---|
| `xLarge` | 161.5 | 137.3 | 139.4 | 140.25 |
| `xxxLarge` | 190.9 | 162.2 | 165.1 | 164.75 |
| `accessibility3` | 329.3 | 279.9 | 280.9 | 281.0 |
| `accessibility4` | 385.4 | 327.6 | 328.9 | 329.5 |
| `accessibility5` | 433.4 | 368.4 | 369.8 | 369.5 |

(Widths from `UIFont`; the last column by drawing the one-line `Text` in
lines a quarter point apart.) The old rule said 0.85 × full, rounded up, plus
a point: 329 at `accessibility4`. An iPhone 17e's landscape tile gives its
title exactly 329, so the one line was chosen and `Text` truncated it to
"Freedoom Phase…". The issue's "a third of a point" was this gap: the title
at its smallest size against the line, not at its full size.

Where SwiftUI's needed width and `UIFont`'s at the smaller size differ, it is
by under a point either way, so the rule now measures the name in the font at
0.85 of its size and keeps its one point over.

**When a rule predicts what a `minimumScaleFactor` will do, measure the text
at the smaller size, never scale the full width.** `TileTitleFitTests` draws
the real title (`PlayableTileTitle`) across the rule's threshold at every
size above the default and fails on the scaled arithmetic; it is the check.

A second thing seen while measuring: a view that measures text with the bare
`UIFont.preferredFont(forTextStyle:)` follows the *host's* content size, not
the environment's `dynamicTypeSize`. In the app the two agree; in a unit test
that sets `.environment(\.dynamicTypeSize, …)` they do not, and the rule
silently runs at the simulator's size. The tile title now takes its font
from the environment's size, so the test exercises the rule it claims to.

Captures (`assets/shelf-title-and-hero-fit-2026-11-22/`): the 17e at
`accessibility4` before and after, and the sizes either side after. The same
folder has issue #457's pair from the same pull request (a closed Duo on its
side at the largest size: the hero's "Last played" line now gives way so
Continue stays above the home indicator) and the #437 hang reproduction run
against it, idle.
