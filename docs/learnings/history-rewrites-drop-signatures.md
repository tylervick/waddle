# Rewriting history unsigns every commit it touches

This repo requires signed commits, and GitHub blocks the merge button on any
pull request containing an unsigned one — reported as "unverified commits",
which names neither signing nor the rewrite that caused it.

Every history rewrite drops the signature of every commit it recreates:
`git filter-branch`, `git rebase` without `--gpg-sign`, `git commit --amend`
under a config that is not signing, `git cherry-pick`. The rewritten commits
keep their author, date, message and tree, so nothing looks wrong locally —
`git log` is identical. Only `%G?` shows it:

```bash
git log --pretty='%h %G? %s' main..HEAD   # G = good, N = none
```

**Paid for on 2026-08-16.** A `git add -A` swept an unrelated 810KB image into
a commit. Removing it with

```bash
git filter-branch --force --index-filter \
  'git rm --cached --ignore-unmatch "<file>"' -- <base>..HEAD
```

did remove the file, and silently unsigned all three rewritten commits. The PR
looked fine and CI was green; only the merge button objected.

**Remedy — re-sign in place, non-interactively:**

```bash
git rebase --force-rebase --gpg-sign <base>   # <base> = last good commit
git log --pretty='%h %G? %s' main..HEAD       # confirm zero N
git push --force-with-lease
```

`--force-rebase` is what makes it recreate commits that are already on top of
`<base>`; without it the rebase is a no-op and nothing gets signed. Content is
untouched — verify with `git diff <old-head> HEAD --stat`, which must be empty.

**No guard script here on purpose.** GitHub's required-signature check already
fails closed on exactly this, before a merge can happen. A local script would
duplicate an enforcement that already exists at the only moment it matters.

Related: `docs/learnings/git-fixtures-inherit-signing-config.md` covers the
opposite direction — inherited signing config breaking throwaway fixtures.
