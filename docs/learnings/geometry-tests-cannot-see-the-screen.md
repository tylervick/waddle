# A green layout suite says nothing about the composed screen

Between 2026-08-16 and 2026-08-21 the shelf accumulated five visual defects
while every layout test passed: the app name rendered twice in a stack (nav
title over the welcome card's title row), the Continue hero's game repeated
as the first tile directly beneath itself, a uniform 16 pt interval everywhere
read as no spacing at all, the tile scrim was too thin to bed its title, and
the capped landscape hero cropped TITLEPIC to an unreadable band.

None of these is a bug in anything `ShelfHeroLayoutTests` or
`PlayableTileLayoutTests` measures. The suites pin fold budgets, tap
clearances, column counts and scrim ceilings — *arithmetic about* the screen —
and all of that arithmetic was correct. What nothing in the process ever did
was look at the rendered result: screenshots were captured landscape-only for
App Store slots, UI tests assert identifiers, and the loop optimizes exactly
what the issue's Verification section states. Every defect was therefore
found by a TestFlight tester or by a person, days later.

**The check is `App/Sources/UI/ShelfPreviews.swift`**: canvas previews of the
shelf's three hero-zone states with real TITLEPIC art, added 2026-08-21 —
the day they first rendered is the day all five defects above became obvious
at a glance. When changing layout constants, tile chrome, or hero-zone
composition, open the previews and look before trusting a green suite; when
reviewing such a change, ask for the before/after render, not just the
numbers. A defect you can only state as "it looks wrong" is still a defect,
and this file is the reminder that the repo has no automated eye — the
previews are where a human one plugs in cheapest.

**Provenance:** the 2026-08-21 design pass (spec §§2, 4, 5 amendments of the
same date), which corrected all five in one change.
