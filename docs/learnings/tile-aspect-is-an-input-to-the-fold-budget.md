# `Theme.tileAspectRatio` is an input to the shelf's fold budget

`ShelfHeroLayout.heroZoneBudget` computes the first tile row's height as
`gridColumnWidth(...) / Theme.tileAspectRatio`. So the tile's *shape* is an
input to how much room the hero zone has above the fold, and to
`welcomeCardShowsDescription`, which spends that budget.

Changing the tile aspect therefore moves assertions in `ShelfHeroLayoutTests`
that never mention tiles. Making tiles shorter (3:4 → 4:3) makes the first row
shorter, which makes the budget *larger*, which flips any assertion of the form
"this card does not fit" to true.

Observed 2026-08-21 on issue #199, whose definition of done required
`Theme.tileAspectRatio = 4.0 / 3.0`. That change is sound and the safety
property is strictly better afterwards — a shorter row leaves *more* above the
fold — but it turned `testWelcomeCardDropsItsDescriptionOnTheCIPhone` red. That
test pins a historical one-column geometry (`tileMinimumWidth: 200`, the floor
before #205 lowered it to 150) where a 370 pt-wide tile was 493 pt tall and the
welcome card genuinely did not fit. At 4:3 the same tile is 277 pt tall, the
budget goes from 195 pt to 411 pt, and the full card fits with room to spare.

Proved by toggling the one constant and changing nothing else: at `3.0 / 4.0`
that test passes and the new tile-geometry tests fail; at `4.0 / 3.0` the
reverse. Its sibling `testEverySupportedPhoneClearsTheFoldWithTheFullCard`,
which uses the floor the product actually ships, passes either way.

**Two things to carry forward.**

First, an issue that says a constant is safe to change may be wrong about what
reads it. #199 stated that `ShelfHeroLayoutTests` "covers the hero, which passes
its own `ShelfHeroLayout.artHeight` and is unaffected by `tileAspectRatio`."
Half of that file is the welcome card's budget, which reads it through
`heroZoneBudget`. Grep for the constant before believing a claim about its blast
radius — `grep -rn tileAspectRatio App/` finds all four call sites in a second.

Second, this is why the unattended loop cannot finish #199. The remaining work
is a judgement about an existing test — re-anchor it to a geometry that still
discriminates, or retire it as superseded — and
`Scripts/loop-prompt.md` forbids an unattended run from editing a test to make
something pass, without exception. That prohibition binds the run, not the
owner: it is a one-line decision in an interactive session, and the same shape
as the forbidden-edit refusals on issues #68 and #14.

**Not turned into an executable check on purpose.** The mechanical form of this
— "no test may read a constant another test's subject also reads" — would fire
on most of `ShelfHeroLayoutTests` and forbid the shared-constant style the whole
layout suite is built on. What went wrong was a claim in an issue body, and
`Scripts/check-issue-format.sh` (which might otherwise host such a check) is
itself on the never-modify list.

**Provenance:** agent loop run 58, issue #199, 2026-08-21.
