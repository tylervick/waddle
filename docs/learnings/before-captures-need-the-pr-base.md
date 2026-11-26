# A "before" capture built from local `main` can be from the wrong code

Seen 2026-11-26 on issue #547. The pull request's base was `origin/main` at
6dc3a54 (pull request #546 merged), but the Orca workspace's local `main`
ref still pointed at the commit before it. The "before" app was built with
`git checkout main -- <files>`, so it lacked #546's title cap: the closed
Duo shot showed a five-line title pushing Continue off screen, a defect
`main` no longer had, and it looked like a dramatic before/after that was
not real.

What gave it away was the screenshot disagreeing with a unit test that
draws `main`'s layout (`HeroCaptionFitTests` capped that title at two lines;
the capture showed it uncapped). The fix is to build "before" from the
merge base the pull request is measured against, never a local branch name:

```bash
git fetch origin main
git checkout "$(git merge-base HEAD origin/main)" -- <the files you changed>
# build, copy the .app aside, then
git checkout HEAD -- <the files you changed>
```

When a before capture shows a defect the base's tests say is gone, suspect
the build before the code.
