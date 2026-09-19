# Signing commits on a machine that has no signing key

`main` is governed by a repository **ruleset** requiring verified signatures.
[history-rewrites-drop-signatures.md](history-rewrites-drop-signatures.md)
covers the case where commits *were* signed and a rewrite unsigned them, and
its remedy — `git rebase --force-rebase --gpg-sign <base>` — assumes a key is
configured. On a machine where one is not, that remedy has nothing to sign
with, and there is no local fix at all:

```bash
gpg --list-secret-keys   # command not found
ls ~/.ssh/*.pub          # no matches
ssh-add -l               # The agent has no identities.
git config --get-regexp 'commit.gpgsign|gpg.format|user.signingkey'   # nothing, any scope
```

**`--admin` does not rescue this.** Branch-protection rules can be bypassed by
an administrator; a *ruleset* violation cannot. `gh pr merge --merge --admin`
fails with a message that names the rule and nothing else:

```
GraphQL: Repository rule violations found

Commits must have verified signatures.
```

Before that, the same merge without `--admin` reports only "the base branch
policy prohibits the merge", which sounds like a required review and is not.
The signature requirement surfaces only under `--admin`, so reaching for the
bypass is what diagnoses the problem.

**Remedy — have GitHub create the commits, and it signs them.** This is the
same mechanism that makes a web-UI edit show "Verified": the commit is built
server-side and signed with GitHub's `web-flow` key. The GraphQL mutation
`createCommitOnBranch` is the API form.

```bash
gh api graphql --input - <<'JSON'
{"query":"mutation($input: CreateCommitOnBranchInput!){createCommitOnBranch(input:$input){commit{oid signature{isValid state}}}}",
 "variables":{"input":{
   "branch":{"repositoryNameWithOwner":"tylervick/waddle","branchName":"<branch>"},
   "expectedHeadOid":"<current branch head>",
   "message":{"headline":"<subject>","body":"<body>"},
   "fileChanges":{"additions":[{"path":"<path>","contents":"<base64>"}]}}}}
JSON
```

It commits on top of `expectedHeadOid`, so replacing existing unsigned commits
means first forcing the branch ref back to its base
(`gh api -X PATCH repos/<owner>/<repo>/git/refs/heads/<branch> -f sha=<base>
-F force=true`) and then replaying each commit in order, passing the previous
result as the next `expectedHeadOid`. Authorship stays with the token's user;
`git log --pretty=%G?` will still print `N` afterwards if the machine has no
`gpg` to *verify* with, so confirm through the API instead:

```bash
gh api repos/<owner>/<repo>/commits/<sha> --jq '.commit.verification'
```

**Verify the content survived, against the right base.** If `main` moved while
you worked, the replayed commits sit on a new base and a head-to-head
`git diff <old-head> <new-head>` shows every commit that landed in between —
alarming and meaningless. Compare each side to *its own* base:

```bash
diff <(git diff <new-base> <new-head>) <(git diff <old-base> <old-head>)
```

Empty output means the change is byte-identical and only the base moved.

**No guard script here, for the same reason as the related learning.** The
ruleset already fails closed at the only moment it matters. A local check
would duplicate an enforcement that exists server-side and cannot be skipped.

## Superseded on the build host: give the machine a key instead

The server-side replay above is the remedy when there is genuinely no key. On
this build host there now is one, so reach for the ordinary
`git rebase --force-rebase --gpg-sign` remedy first and treat
`createCommitOnBranch` as the fallback for a machine that still has nothing.

What was missing was never the *ability* to sign — `ssh-keygen` ships with
macOS — only a key and the config pointing at it:

```bash
ssh-keygen -t ed25519 -C "<github-noreply-email>" -f ~/.ssh/id_ed25519_signing -N ""
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/id_ed25519_signing.pub
git config --global commit.gpgsign true
```

Three things that are easy to get wrong:

- **Register the public half as a *Signing Key*, not an Authentication Key**
  (<https://github.com/settings/ssh/new>). They are separate lists on the same
  page, and a key in the wrong one verifies nothing. Signing-only is also what
  makes a passphrase-less key defensible here: it proves authorship and grants
  no repository access.
- **`gh` cannot do that registration under a fine-grained PAT.** `user/ssh_signing_keys`
  answers `403 Resource not accessible by personal access token`, and
  `gh auth refresh` does not apply to PAT logins. Paste it in the browser rather
  than re-authenticating `gh` and disturbing the token the loop runs on.
- **Do not set `tag.gpgSign`** while you are in there — see
  [git-fixtures-inherit-signing-config.md](git-fixtures-inherit-signing-config.md)
  for the `fatal: no tag message?` cycle it costs. Commit signing alone is what
  the ruleset requires.

Global identity has to be set too, not just signing: it was unset machine-wide,
and every repository here that works does so because it sets `user.email`
*locally*. A repository that does not — `~/repos/graphghan` — could not commit
at all. `git -C <repo> var GIT_AUTHOR_IDENT` answers that question without
making a commit.

Verification still cannot come from `%G?` alone. It reports `G` as soon as the
signature checks out against `gpg.ssh.allowedSignersFile`, which is a local
file and says nothing about what GitHub will accept. Confirm through the API:

```bash
gh api repos/<owner>/<repo>/commits/<sha> --jq '.commit.verification'
```

**Paid for on 2026-09-18**, merging #225 from a build host with no keychain.
