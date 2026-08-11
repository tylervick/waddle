# An unattended `git push` hangs instead of failing

Two separate credential mechanisms sit in front of `origin`, and in an
unattended run (no one at the keyboard to answer a prompt) each one fails in a
way that does not look like an auth failure.

**SSH first.** `origin` is `git@github.com:tylervick/waddle.git`, and
`~/.ssh/config` points `IdentityAgent` at 1Password's `agent.sock`. If
1Password is locked, the socket still exists, so ssh does not fall back to
anything — it fails with `sign_and_send_pubkey: signing failed for ED25519 ...
communication with agent failed`, then `Permission denied (publickey)`.
`ssh-add -l` reports `The agent has no identities`. Retrying does not recover
it; an unattended run has no way to unlock 1Password.

**HTTPS second, and this is the one that hangs.** Rewriting the URL and
handing git `gh`'s token looks like it should work, but `credential.helper` is
**cumulative, not overridable** — a `-c credential.helper=...` on the command
line *appends* to the globally configured `osxkeychain` helper rather than
replacing it. osxkeychain runs first, blocks on a Keychain prompt no one can
answer, and the push produces no output and never returns. It reads as a
network stall, not as an auth problem. `GIT_TRACE=1` names it outright: the
last line is `run_command: 'git credential-osxkeychain get'`.

Clear the list with an empty value first, then add `gh`'s helper. As with the
signing identity in `Scripts/loop-prompt.md` section 0, spell this out on every
network command rather than hoisting it into `git config` — shell and config
state do not survive between an unattended run's separate tool invocations, and
a `git config` write here would land in the shared `.git/config` and retag the
owner's own checkout:

```bash
git -c credential.helper= \
    -c credential.helper='!gh auth git-credential' \
    -c url."https://github.com/".insteadOf="git@github.com:" \
    push origin HEAD:<branch>
```

Two things this does *not* affect. Commit signing is untouched — the loop's
`gpg.ssh.program=ssh-keygen` signs straight from the
`~/.ssh/waddle-agent-signing` key file and never consults an agent, so commits
succeed while pushes hang. And `git fetch` of this repo succeeds with no
credentials at all, because it is public — so a run can fetch, branch, commit,
and only discover the problem at its first push, well after it has already
claimed an issue.

**Provenance:** agent-loop trial `2026-08-11T160141Z` (issue #49), which lost
about four minutes to a two-minute push timeout before tracing it.
