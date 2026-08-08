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

**Provenance:** issue #13's first attempt (PR #55, closed unmerged) paid for
this; re-confirmed on the second attempt, where `git tag v1` in a scratch repo
still printed `fatal: no tag message?`.
