# `github.run_number` inside a called workflow is the caller's, so a build number derived from it changes meaning the day the workflow is reused

`testflight.yml` used to compute the TestFlight build number as
`BUILD_NUMBER_OFFSET + github.run_number`. That was sound while the file had
one trigger surface: its own runs numbered 1, 2, 3, and the offset lifted them
above the builds consumed by hand. It stopped being sound the moment the
workflow gained `on: workflow_call` so that `ci.yml` could ship each merge.

Inside a called workflow, `github.run_number` (and `github.run_id`) belong to
the **caller's** run. `ci.yml` was in the high hundreds; `testflight.yml` was
at 75. The merge path would have produced build 684-and-up while the
hand-dispatched path kept producing 276-and-up, two unrelated sequences on
one App Store Connect app, and the first dispatch after a merge would have
been rejected at upload for not exceeding the newest number, after the full
archive.

## What to do instead

Derive the number from the record of what actually shipped: the newest
`build-*` tag plus one, with the run-number formula kept only as the bootstrap
for a repository with no tag at all. The tags are pushed by the release itself
and fetched by `fetch-depth: 0`, the runs serialize on one concurrency group
so the previous run's tag is present before the next one reads it, and the
sort is `--sort=-v:refname` because the question is "the highest number ever
used", not "the nearest tag by ancestry" (`Scripts/release-due.sh` wants the
latter and says why).

The resolution step then validates that the result, override included, is
strictly above the newest tag, so a bad override fails in seconds rather than
after the archive.

## The general shape

Any value a reusable workflow reads from the `github` context that describes
*a run* (run number, run id, run attempt, workflow name, event name) describes
the caller's run once the workflow is called. A value that must be stable
across the dispatched and the called path has to come from something both
paths share: the repository, its tags, or an explicit input.
