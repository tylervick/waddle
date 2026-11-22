# A scroll view measured to lay out its own content can spin for ever

Found 2026-11-21 by the review of pull request 434 and fixed there (issue
#437). On an open iPhone Duo turned tall (669x951) or standing half open, at
`accessibility-extra-extra-extra-large`, `main` launched to a white screen
at 95 to 98% CPU and never drew a frame, whenever the Continue hero's "Last
played" line had two wide digits ("34 seconds", "23 minutes", "40 minutes";
not "12 seconds", not "6 minutes"). `assets/continue-hero-2026-11-21/hang-*.webp`
is `main` beside the fix.

## The loop

`ShelfView` measures its `ScrollView` with `onGeometryChange` into
`heroContentWidth`, and sizes the hero's art from it. Three facts close the
circle:

- **A vertical `ScrollView` is as wide as its content when the content
  reports wider than it was offered.** It is not simply as wide as its
  proposal. `ScrollContentWidthTests` shows this on its own, with no shelf.
- **A `Text` can report wider than it was offered, by a fraction of a
  point.** The caption beside the art was offered 312.5 pt (half of a 637 pt
  row less the gap). Measured in a unit-test host at the largest size, the
  "Last played …" line alone, by what it was offered and what it reported:

  | Offered | "34 seconds", "23 minutes", "40 minutes" | "6 minutes" | "12 seconds" |
  |---|---|---|---|
  | 312.5 | 312.667 | 286.333 | 309.333 |
  | 312.583 | 312.667 | 286.333 | 309.333 |
  | 312.667 | 313.0 | 286.333 | 309.333 |
  | 312.0, 312.333, 313.0 | as offered | 286.333 | 309.333 |

  The three strings that hung `main` are the three that report over; the two
  that did not hang report under. The title and both buttons reported what
  they were offered or less. So it is a wrapping `Text` whose text fills the
  width, offered a width off the pixel grid, and it is 1/6 pt: half a pixel
  at 3x.
- **The art's width is a function of the measurement**, so a wider scroll
  view makes wider art, a different caption width, a different line break,
  and a different reported width.

lldb on the spinning process showed the measurement going 669 → 669.167 →
669.583 → 669.458 → … and back to 669, a 45-step cycle inside one render
pass. A healthy launch measures 669 once.

## The fix is to cut the path, not to avoid the trigger

The first version of pull request 434 narrowed the art so the buttons fitted,
and stopped hanging in about 330 launches. A trace showed it still took the
first step (669 → 669.167 → 669) and got out one state change later. Nothing
had been fixed; a different string or width could have spun it again.

`reportingContainerWidth()` on the scroll view's content
(`containerRelativeFrame(.horizontal)`) makes the content report the scroll
view's width whatever it measures. The content's width is then the scroll
view's own by construction, and the traced measurement is 669.0 from the
first frame.

Anything that measures a container and feeds the result to that container's
content has this shape. `GamePageView` measures itself the same way and was
examined for issue #450: its form cannot be widened, its hero row could, and
did. See `a-row-measured-off-its-own-frame-measures-its-content.md`.

`ShelfContainerWidthTests` hosts the real `ShelfView` in a window too narrow
for its content and fails when the modifier is deleted or moved off the
scroll content, so the guard no longer rests on a hand launch.

## A custom `Layout` cut the path too, and CI's picture tests failed with it

The first cut was a custom `Layout` round the content that reported its
proposal. It worked: no hang in 400 launches, identical pictures. Then CI's
unit tests failed on it five runs in five, always in
`ImportNoticeBannerTests`, which draws with `ImageRenderer` and has nothing
to do with the shelf. The unit tests run inside the app, with the shelf on
screen. What the logs show, on the iPhone leg of each run:

| Shelf's content | Runs | First Metal pipeline build | `image provider … timed out` | Result |
|---|---|---|---|---|
| `main`, and three runs of two other branches | 4 | 0.56 to 1.1 s, or too short to be logged | none | pass |
| inside the custom `Layout` | 5 | 4.3, 13.1, 13.9, 22.1, 23.9 s | 2 to 5 | fail |
| same branch, the `Layout` taken out | 1 | 3.7 s | 1 | pass |
| `containerRelativeFrame` instead | 1 | 0.69 s | none | pass |
| an underlay measured instead | 1 | 0.75 s | none | pass |

`ImageRenderer` gives up after two seconds and hands back an empty drawing,
which is what the tests then compare. (The suite now throws such a drawing
away and draws it again: `imagerenderer-hands-back-an-unfinished-drawing.md`.)
Why a custom `Layout` in the on-screen shelf slows the test process's first pipeline build on the runner was not
found: locally, on the same simulator model and runtime, the app is idle
with it (0.00 CPU s in 10 s, no wakeups, the same 65 views), a lazy grid
inside it stays lazy, and all 792 tests pass, on an erased simulator too.
The runner draws in software on three cores; this Mac does not.

Two things to take from it. A CI-only failure in a test you did not touch
can still be yours: the same picture test failing twice on one branch while
it passes on its neighbours is the signal, and three throwaway draft pull
requests (the same code again, the suspect taken out, the new tests taken
out) settled in forty minutes what an afternoon of local measurement could
not. And prefer the built-in modifier to a custom `Layout` round a screen's
whole content when both do the job.

## Telling a hang from a slow launch

`ps -o %cpu` is an average over the process's life, so five seconds after a
launch on a busy Mac a healthy app also reads above 50%. A first scan here
called three healthy launches hangs that way, and one hang's absence a fix.
A hang is still above 50% ten seconds later, and again three seconds after
that; a slow launch is not. Read it twice before believing either answer.

## How it was seen first, and misread

As a UI test failing with `Failed to get matching snapshots: Unable to
perform work on main run loop, process main thread busy for 30.0s`, on a
screen that a hand launch minutes later showed idle. The hand launch had a
different "Last played" string. A UI test's busy main thread on a shelf with
a Continue hero is worth one launch with the same date before it is put down
to the runner.

## Checking the real screen

A unit test cannot open a Duo. With the device opened and turned through
`Scripts/duo-pose-device-hub.sh open-turned`, and the app not running:

```
xcrun simctl ui <udid> content_size accessibility-extra-extra-extra-large
C="$(xcrun simctl get_app_container <udid> com.tylervick.waddle data)"
sqlite3 "$C/Library/Application Support/default.store" \
  "update ZGAME set ZLASTPLAYED = (strftime('%s','now') - 978307200 - 1400) where ZNAME='Freedoom Phase 1'; PRAGMA wal_checkpoint(FULL);"
SIMCTL_CHILD_WADDLE_SEED_CONTINUE_SAVE=1 xcrun simctl launch <udid> com.tylervick.waddle
```

Setting `lastPlayed` this way also gives a fresh install its Continue hero
without a session. 1400 is "23 minutes ago"; 34 and 2400 hang `main` too.
