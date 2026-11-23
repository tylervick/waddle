# A scroll view whose content is held to its container keeps its old width

Found 2026-11-22 working issue #469, on `main` at 962f9ee. On an open iPhone
Duo held wide (951x669), with Settings or a game's page open in the panel's
column, the shelf was drawn wider than its column and cut at its left edge,
differently from launch to launch.

## What it was

`ShelfView` guarded its scroll content for issue #437 with
`containerRelativeFrame(.horizontal)`, so the content reported its
container's width and not its own. For content in a `ScrollView`, the
container is the scroll view. And a vertical `ScrollView` is as wide as
content that reports wider than it was offered
(`a-scroll-view-measured-to-lay-out-its-own-content-can-spin.md`). So the
content follows the scroll view and the scroll view follows the content.
That cuts #437's loop, because a fraction of a point the content adds cannot
reach the measurement. But it also holds a width once one is reached: when
the offer shrinks, the content still reports the old width, so the scroll
view stays at it, centred in the narrower space it was offered.

The panel's column narrows the shelf's offer in several layout passes as it
arrives. The scroll view's frame in the app, logged per pass (x, width):
951 → 763 → 669 on one launch, 587 → 539 → 515 on another, ending at
(−89, 669), (−12, 515), (−24, 539) or (−48, 587) in a 491 pt column. Which
one depends on the order of passes, which is why it changed from launch to
launch. A unit test reproduces it deterministically: lay out a scroll view
at 951 pt, narrow the window to 491, and it stays 951 wide at x −230.

## What `main` did, counted

20 launches on my own Duo, open and upright, `WADDLE_RESET_STORE=1`, the gear
tapped through `Scripts/duo-pose-device-hub.sh touch` on a settled shelf,
captured 3 s later. Three pictures, and none of them was right:

| Picture | Launches | Shelf |
|---|---|---|
| `main-settings-cut-b.webp` | 16 | the sentence begins "ur own WADs", the first tile "om Phase 1" |
| `main-settings-cut-a.webp` | 3 | nothing visibly cut, but 515 pt of content in the 491 pt column: the card's 16 pt margin shows as about 4 |
| `main-settings-cut-c.webp` | 1 | the sentence begins "ing your own WADs", Add Games under the column |

The second one is the one the issue called right ("layout B" there). It is
too wide too, by 24 pt.

It reached beyond the panel. When the previous launch ended with the panel
open, the next launch's shelf had a column's worth of offer at first, so
with **no panel open** the shelf was cut in 15 of 16 launches
(`main-no-panel-after-panel-launch-cut.webp`). The first launch, after none
had opened the panel, was right.

## The fix: measure the offer, which nothing inside can change

`OfferedWidthScrollView` (`App/Sources/UI/ContainerWidth.swift`) is a
`ScrollView` inside a `GeometryReader`, with the content framed to the
reader's width. A `GeometryReader` is as big as it is offered and its
children cannot change that, so the content's width follows the offer down
as well as up, and #437's loop stays cut. It is a built-in view, not a
custom `Layout`; why that matters is in the #437 learning.

With it, the same 20 launches gave one picture (`fix-settings.webp`), and so
did a game's page (`fix-game-page.webp`, 4 launches) and both at
`accessibility-extra-extra-extra-large` (`fix-settings-ax5.webp`, 4;
`fix-game-page-ax5.webp`, 3). The shelf with no panel open was
pixel-identical to `main`'s right one: 10 launches of 10 sampled at 3, 6, 12
and 20 s, and every launch after one that had the panel open except the
stray-column launches below. #437's reproduction (open and turned tall,
largest size, "Last played" at 34 s, 23 and 40 minutes) drew the hero and
sat at 0.0% CPU in 6 launches of 6.

Two captures of one build differ anyway, in about 1,545 px of the home
indicator's bar, and in a few pixels of a glass button. Read a difference
against that before calling it one.

`ShelfContainerWidthTests.testTheShelfNarrowsWithItsWindow` hosts the real
shelf at 951 pt and narrows the window to 491; with the old hold it fails at
x −230 and 951 wide. `ScrollContentWidthTests` pins the trap itself
(content held to its container keeps a scroll view wide) beside the fix.

## Any change of offer, either way, not only a panel

The hold is not specific to the panel: anything that changes the shelf's
offer after it has been laid out can show it. Checked 2026-11-22 against
the same three builds: `main`, this fix, and `main` with the shelf's scroll
view unguarded. The last is the form the shelf had in 1.5 (`build-295`) and
before #434.

| Change | `main` | fix | unguarded |
|---|---|---|---|
| iPhone 18 Pro, launched portrait, turned landscape | wrong 3/3: a portrait-width column centred, black at the sides (`main-iphone-rotated-to-landscape.webp`) | 3/3 = fresh landscape launch | 3/3 right |
| iPhone 18 Pro, launched landscape, turned portrait | wrong 3/3: cut at the left, tiles in two columns | 3/3 = fresh portrait launch | 3/3 right |
| iPad Pro 11, launched portrait, turned landscape | wrong 3/3 (`main-ipad-rotated-to-landscape.webp`) | right 3/3 | right 3/3 |
| iPad Pro 13, launched landscape, turned portrait | wrong 3/3, cut at the left | right 3/3 | right 3/3 |
| iPad, Settings beside the shelf (`WADDLE_OPEN_PANEL`), either orientation | cut, 3/3 each (`main-ipad-settings-portrait.webp`) | right 3/3 each | not checked |
| Duo open → closed | cut 3/3 (`main-duo-folded-closed.webp`) | = fresh closed launch 3/3 | 2/2 right |
| Duo closed → open | in bounds, but tiles larger than a fresh launch's, 3/3 | = fresh open launch 3/3 | 2/2 right |

Every rotation is wrong on `main`, growing as plainly as shrinking: the
scroll view, which carries the shelf's background, stays at the width it
was first laid out at.

**Start from a fresh launch in the pose you turn from.** An earlier version
of this table said `main` turned landscape → portrait correctly, with an
explanation that the landscape shelf is already about portrait width. Both
were wrong. That run launched in portrait, turned to landscape, and then
back, so the landscape shelf it started from was the held portrait width
itself, and turning back needed no change. An independent review launched
in landscape and saw it cut; launched that way, it is cut 3 times in 3 on
both phone and iPad.

Fresh launches are pixel-identical across the three builds. So the
regression came in with #434 (merged 2026-11-22) and is not in 1.5. That is
inferred from the unguarded build, not from running the 1.5 binary.

The navigation bar's scroll-edge effect is unchanged by the `GeometryReader`
round the scroll view: at the largest text size, scrolled by a UI test
under the bar on an iPhone 18 Pro, `main` and the fix are pixel-identical,
at the top and scrolled.

Not checked: iPad Split View and Slide Over, which need gestures there is no
hook for. They are a window narrowing, like the Mac windows of #488, and the
unit test's narrowed window stands in for them.

## Still open: a stray column, on `main` too

In 4 launches of 32 with the fix, and 1 of 16 on `main`, a launch after
one that ended with the panel open came up with the whole navigation stack
laid out as if the column were beside it, though no panel showed: the
wordmark centred over the left 587 pt, the shelf fitted to that
(`stray-column-main-and-fix.webp`; `main`'s picture is pixel-identical). That
is the inspector's own state, not the shelf's width, and this fix does not
change it.

Captures are in `assets/shelf-beside-panel-2026-11-22/`.
