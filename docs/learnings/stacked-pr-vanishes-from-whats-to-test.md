# A pull request merged through a stacked child gets no What to Test bullet of its own

Measured 2026-09-20, previewing the notes for the build after #255 and #256.

#256 was stacked on #255's branch. Merging #256 brought #255's commits to
`main` in the same merge commit, and GitHub marked both merged with that one
commit. `Scripts/whats-to-test.sh` writes one bullet per merged pull request
it can attribute a merge commit to, with the first sentence of that pull
request's first prose paragraph as the text. So the notes had no bullet for
#255 at all -- the change a tester would actually notice, the in-game menus
losing entries after a relaunch -- and #256's bullet read, verbatim:

```text
In the app:
- Stacked on #255 (the base branch is tylervick/menu-state-repro; retarget to main once that merges).
```

Two things follow.

**The child's opening sentence has to be written for the tester and cover the
parent.** The script fetches pull-request bodies live when it attaches the
notes at the end of the TestFlight run, so editing a merged pull request's
description before that step lands is enough -- that is how the build above was
corrected, with `Scripts/whats-to-test.sh --print` as the check. A stacking
note, a "## Why" heading, or a sentence about the pull request itself is not a
change description; put the tester-facing sentence first and the plumbing
after it.

**Preview the notes before dispatching.** `Scripts/whats-to-test.sh --print`
needs no credentials and shows exactly what testers will read. Run it before
`gh workflow run testflight.yml --ref main`, not after.
