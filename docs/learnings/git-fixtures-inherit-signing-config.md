# A hermetic test that builds a git repo must opt out of signing — twice

Test scripts here build throwaway repos in `mktemp -d` fixtures
(`Scripts/test-build-deps.sh`). A fixture repo is new, but `git` still reads
the owner's `~/.gitconfig`, and this machine signs by default. Two settings
bite, and only one of them is obvious:

- **`commit.gpgsign`** hands each fixture commit to the configured signer.
  Here that is 1Password's `op-ssh-sign`, which only signs with keys held in
  the 1Password agent, so the commit dies outright.
- **`tag.gpgSign`** turns a plain `git tag v1` into an *annotated* tag, which
  then requires a message it was never given. The failure is
  `fatal: no tag message?` — which reads like a bad `git tag` invocation and
  says nothing about signing, so it sends you looking in the wrong place.

Pass both per command; never `git config` them, which would write into the
shared config and retag the owner's own checkout:

```bash
git_c() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c tag.gpgSign=false "$@"; }
```

This is the same lesson as `Scripts/loop-prompt.md` section 0 — signing
identity travels per command, not per environment — reaching one place that
section does not: fixtures inside tests, where the failure surfaces as a
confusing git error rather than a signing one.

**Provenance:** writing `Scripts/test-build-deps.sh` for issue #13, 2026-08-07.
