# A `Label` in a form row's background is drawn as its icon alone

Measured 2026-11-22 on an iPhone 18 Pro simulator (iOS 27.0, Xcode 27.1),
fixing issue #468 on the game page.

The game page measures its hero's labels with hidden, `fixedSize()` copies
in the hero row's `.background` (`captionProbe`, and since #468
`actionLabelGauge`). Hosted in a `Form` row, the same two labels read:

| Copy in the row's background | Width |
|---|---|
| `Label("Continue")` and `Label("New Game")`, any mix of `.font` and `.lineLimit` | 40 pt |
| the same with `.labelStyle(.titleAndIcon)` | 117.7 pt |
| `Text("Continue")` and `Text("New Game")` | 86 pt |
| one `Label` alone, outside any form | 110 pt |

40 pt is the icon. In a form row's background a `Label` resolves its style to
icon only, while the buttons in the row itself draw title and icon, so a
gauge that does not say `.titleAndIcon` measures something the screen never
shows and reports it without complaint. `captionProbe`'s action words had
measured 72 pt (40 of icon, 32 of padding) for every word since #425; its
title pieces were wider, so nothing showed.

So: a `Label` used as a measuring copy says `.labelStyle(.titleAndIcon)`, and
the views it measures say the same, so the two cannot resolve differently.
Saying it changes the drawn button too: in the form row the buttons' icons
had been drawn larger (the clock 24x22 pt) and further from the title than
the shelf hero's; under `.titleAndIcon` they are 19x17 pt and match it. That
is visible at every text size, on every device
(`assets/game-page-actions-2026-11-22/iphone-portrait-default-buttons.webp`).
`GamePageActionRowTests` holds the page's gauge to a label measured on its
own; delete the style from the gauge and it fails.

A label drawn in the page still measured a few points wider than one on its
own (151 against 146 pt at `xxxLarge`), so a test that judges the page's
choice of row or column should use the page's own reading, not its own.
