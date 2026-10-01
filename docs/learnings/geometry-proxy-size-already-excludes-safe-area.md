# `GeometryProxy.size` already excludes the safe area

Both screens that budget layout against the viewport — the shelf's hero zone
(`ShelfHeroLayout`) and the game page's header art (`PlayableDetailLayout`) —
measured it with the same `onGeometryChange` transform:

```swift
proxy.size.height - proxy.safeAreaInsets.top - proxy.safeAreaInsets.bottom
```

That subtracts the bars twice. For a view laid out inside its safe area,
`proxy.size` is **already** the region between the navigation bar and the home
indicator, and `safeAreaInsets` reports what lies *outside* that region. The
numbers, read off a live iPhone 17 Pro on 2026-09-30 through a temporary
readout in the view:

| | `proxy.size.height` | `safeAreaInsets.top` | `safeAreaInsets.bottom` | `frame(in: .global).minY` |
|---|---|---|---|---|
| Shelf `ScrollView` | 724 | 116 | 34 | 116 |
| Game page `Form` | 724 | 116 | 34 | 116 |

The frame starts at y = 116, exactly where the top inset ends: the view is not
under the bar, yet the inset is still reported. 724 − 116 − 34 = 574 was the
viewport both screens had been using, on a screen with 724 pt to spend.

Two things it cost, both invisible to the layout suites because they take the
viewport as an input:

- The game page's art was capped at 167 pt in **portrait** — where there is
  room for its natural 231 pt — and the capped path letterboxes, so every
  game page opened on a blurred band around a smaller picture. It went
  unnoticed because the header was a grouped `Form` row and nothing ever
  photographed it in portrait (the store screenshots are landscape).
- The shelf's welcome card gave up its description on viewports that could
  afford it, and the hero capped 150 pt early. Neither assertion in
  `ShelfHeroLayoutTests` could see it: they are correct about the arithmetic
  and silent about the input.

The fix is to use `proxy.size` alone; both screens do now.

**How it was found, and why it kept hiding.** The design-system hero row
(2026-09-30) drew the same art with its own chrome, and the stale cap put a
letterbox and a 64 pt gap in the middle of the first screenshot. The gap came
from a second effect worth knowing: a `List`/`Form` cell that was self-sized
while the art had one height did not shrink when the measurement arrived and
the art became shorter — the content floated centred in the taller cell. With
the measurement fixed the height no longer changes after the first layout in
portrait, so the cell never goes stale; but a layout whose row height depends
on a value that settles late should expect this.

**Not turned into an executable check** because it needs a rendered screen:
the repo's layout tests are pure functions over supplied bounds, and the
learning in `geometry-tests-cannot-see-the-screen.md` already covers why that
is the gap. The cheap probe is the one that found it: a `Text(verbatim:)` of
the measured numbers in the view, read back from the XCUITest hierarchy dump.

**Provenance:** the design-system pass, `2026-09-30-design-system-design.md`.
