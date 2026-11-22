# `ImageRenderer` hands back an unfinished drawing while its first pipeline builds

Measured 2026-11-22 from CI's unit-test logs, fixing issue #439. The check is
`finishedDrawing(of:width:describedAs:)` in
`App/Tests/ImportNoticeBannerTests.swift`; this file is the evidence for it.

## The mechanism

The first `ImageRenderer` drawing in a test process builds a Metal pipeline,
`primitive_color`, the one that fills a shape with a flat colour. The test
process has never drawn in-process before (the app on screen is drawn by the
render server), so `ImportNoticeBannerTests` always pays for it, in its first
drawing. On this Mac it is too quick to be logged. On CI's runners it took
from half a second to 25 s.

While it builds, a drawing does not wait for it. It waits 2 s, logs
`image provider … timed out while waiting for phase 6 (1)`, and returns what
it has, without the background; or it blocks until the build ends (5.5 s in
one log, with no timeout line) and returns a drawing just as incomplete. The
tests then compare those. "Clearing the text changed nothing" and "the corner
differs at 27,0: 0 on one line, 54 …" are both that.

Every pull request leg from 2026-11-21 to 22 that ran the suite, 149 jobs
(the pipeline build time is the one the renderer logs, or under 0.5 s where
it logs none):

| First `primitive_color` build | Jobs | Logged a timeout | Failed the suite |
|---|---|---|---|
| under 2 s | 131 | 3 | 0 |
| 2 to 5 s | 9 | 9 | 0 |
| 5 s and over | 9 | 9 | 8 |

Every failure of the suite in those logs is in the last row, and every one
compared drawings made before the build had ended. The Duo leg failed
4 times in 47, each after a build of 15 to 17.4 s; the slowest builds before
the leg split were on the single iPhone job. The one slow build that passed
(6.8 s, three timeouts) did so because the drawings that timed out were ones
no assertion read closely enough to notice.

Why some runs build the pipeline in 15 s and most in 1 s was not found.
Branches that put a custom `Layout` or the fold reader on screen saw it more
often (`a-scroll-view-measured-to-lay-out-its-own-content-can-spin.md`,
`parting-the-launcher-at-the-fold.md`), and branches with neither saw it
too. The runners draw in software on three cores.

## Why the fix is a redraw and not a longer wait

The 2 s is the renderer's own and cannot be lengthened, and a drawing that
blocked longer was no more complete. The only sign of an unfinished drawing
the renderer gives the caller is the time it took: a whole drawing of the
banner takes about 0.1 s on CI's slowest leg, an unfinished one 2 s or
more. So a drawing that took 1.5 s or longer is thrown away and drawn again,
for up to 90 s; a drawing that never finishes inside that throws rather than
being compared. Each redraw prints `ImportNoticeBannerTests: …` to the test
log, which is how to tell a run that met a cold pipeline from one that did
not.

It does not excuse a wrong shape: with the banner put back to a capsule the
suite still fails, 20 failures across the corner and glyph tests, with no
drawing thrown away.

A new picture test that uses `ImageRenderer` should draw through the same
helper, or warm the renderer the same way, rather than trusting its first
drawing.
