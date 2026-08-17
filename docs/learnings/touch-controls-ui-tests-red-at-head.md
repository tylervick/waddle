# The touch-controls UI tests are red at HEAD too, and they fail *before* touching anything

`ui-tests-are-red-at-head.md` names two detail-page tests. It is not the whole
list, and the omission matters most to exactly the work that would want these:
anything touching `App/Sources/Touch/`.

`WaddleUITests/TouchControlsTests/testModernSchemeDragTurnReachesEngine` and
`WaddleUITests/TouchControlsTests/testNearMissBesideWeaponPrevDoesNotStartStick`
both fail on an unmodified tree, verified at `174a52f` on 2026-08-17 by
stashing a diff and re-running:

```
XCTAssertTrue failed - overlay never installed
XCTAssertGreaterThan failed: ("0") is not greater than ("0")
    -- modern-scheme drag-turn never reached the SDL shim
```

**The failure mode is the trap.** These read as damning if you have just
changed touch routing — "the drag-turn gesture never reached the shim" is
precisely what a broken router would produce. But `fireButton` /
`weaponPrevButton` never appear at all, which means the engine session never
installed the overlay, so no gesture was ever routed, correctly or otherwise.
The tests die a full step upstream of the code under change. A near-miss
assertion that never got an overlay is not evidence about near-misses.

The same attribution rule as the sibling file applies, and the same procedure
proves it — stash, `mise run generate`, re-run, compare. Budget a couple of
minutes for it rather than reading the failure text at face value.

Two consequences worth stating:

- **Routing changes cannot be validated through this suite right now.** Cover
  the decision in `WaddleTests` instead, which is what
  `TouchTrackRouterTests` (issue #132) does — CI runs it on every pull
  request, and it needs no engine session at all.
- **Nothing will tell you when this changes.** `ci.yml` runs
  `-only-testing:WaddleTests`; `ui-tests.yml` runs on `push: main` and manual
  dispatch, so no pull request runs either test.

Deliberately not an executable check: a guard asserting "these two are red"
would enshrine a broken state and would have to be deleted the moment someone
fixes it. Like its sibling, this file is a statement about HEAD — if these go
green, delete it rather than working around it.

**Provenance:** issue #132 (extracting the touch routing decision), 2026-08-17.
The extraction changed `touchesBegan`, these two failed in the same run, and
the stash-and-rerun above showed them failing identically without the change.
