# A test that builds a git fixture inherits the developer's signing config

Any test that stands up a throwaway repo — `Scripts/test-build-deps.sh` builds
two — runs `git` with the developer's global config still in force. On this
machine that config is:

```
commit.gpgsign true
tag.gpgsign    true
gpg.format     ssh
gpg.ssh.program /Applications/1Password.app/Contents/MacOS/op-ssh-sign
```

`commit.gpgsign` is the obvious half. **`tag.gpgSign` is the one that costs a
cycle**, because signing a tag implies *annotating* it, so a plain `git tag v1`
suddenly wants a message and fails with:

```
fatal: no tag message?
```

That error names neither signing nor config, and the fixture code it points at
is a one-liner that is obviously correct. Signing is also environment-dependent:
`op-ssh-sign` only signs with keys held in the 1Password agent, so the same test
can pass for one developer, fail for another, and fail differently in CI.

**Fix — make the fixture hermetic rather than patching each command:**

```bash
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
```

The two `GIT_CONFIG_*` variables cut off *every* inherited setting, not just the
two signing ones, so the fixture behaves the same for every developer and on CI.
They also remove the identity the config was supplying, which is why the four
`GIT_AUTHOR_*`/`GIT_COMMITTER_*` variables have to be supplied alongside them.

Same shape as `Scripts/loop-prompt.md` section 0, one layer further in: a
worktree-local intent silently served by repo-global — here machine-global —
git state.

## It is not only fixtures — any lightweight tag on this machine

The title says "fixture" because that is where it was first paid for, but the
cause is machine-global config and it applies to *any* `git tag` typed by hand
in a real checkout. Creating `build-207` on `main` failed with the same
`fatal: no tag message?` on the first attempt.

Where that matters: **a documented recovery instruction that says `git tag`
does not work as written.** `.github/workflows/testflight.yml`'s tag-push
failure message tells the operator to create and push the tag by hand, and the
obvious command fails on the machine they will run it from — with an error
pointing at a missing annotation rather than at signing. The message now
carries `-c tag.gpgSign=false` for that reason.

The hermetic `GIT_CONFIG_GLOBAL=/dev/null` fix above is right for fixtures and
wrong here: a real checkout needs its identity and its commit signing. For a
one-off command, override only the setting in the way:

```bash
git -c tag.gpgSign=false tag build-207 <sha>
```

**Provenance:** issue #13's first attempt (PR #55, closed unmerged) paid for
this; re-confirmed on the second attempt, where `git tag v1` in a scratch repo
still printed `fatal: no tag message?`. Hit a third time on 2026-08-12 tagging
`build-207` by hand in the real checkout, which is what exposed the broken
remedy in the release workflow.
