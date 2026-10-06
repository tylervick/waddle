# The job token cannot create a tag on a commit whose workflow files differ from main's head, which an on-merge release does routinely

Build 277 (CI run 37097820909, the first on-merge release to get past
signing) uploaded to App Store Connect and then failed at "Tag the shipped
build":

```
! [remote rejected] build-277 -> build-277 (refusing to allow a GitHub App to create or update workflow `.github/workflows/app-store-listing.yml` without `workflows` permission)
```

The job token had `contents: write`, which had always been enough. What
changed was the cadence. A nightly release tagged main's head, so the tagged
commit's workflow files were main's. An on-merge release tags the commit it
built, twenty-five minutes after that commit was main's head, and in that
window three merges touching `.github/workflows/` had landed. GitHub treats a
ref creation that "changes" a workflow file relative to the default branch
as needing the `workflows` permission, and `permissions:` has no such key:
the job token cannot be given it.

The fix is a credential that can: `RELEASE_TAG_TOKEN`, a fine-grained
personal access token scoped to this repository with Contents and Workflows
read/write, stored in the `app-store` environment, and used by the tag step
alone through `GIT_ASKPASS`. The release job's token is `contents: read`
again, its checkout no longer persists credentials, and the job proves the
token present and unexpired before the archive starts, so the expiry fails
in seconds rather than after an upload.

`Scripts/check-release-tag-token.sh` is the check: no `contents: write` in
the release workflow, every checkout drops the job token, every `git push`
carries `RELEASE_TAG_TOKEN`. Its suite restores the regression on a copy of
the real file to prove the live case bites.

Hand remedy when the step fails anyway: push the tag yourself at the
shipped commit, as the step's error says, before the next merge derives the
same number.
