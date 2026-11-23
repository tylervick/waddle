# A digest whose seen-state is hidden markers must escape the text it quotes

The digests that keep their state in the issue they post to
(`digest-issue-is-its-own-seen-state.md`) read back every
`<!-- <kind>-id: … -->` in the issue's comments. They also quote text that
strangers wrote: a customer review, a tester's comment. A review whose body
contains `<!-- review-id: X -->` is posted verbatim, GitHub renders it
invisibly, and the next run reads X as seen: review X is never delivered,
and nothing anywhere says so. The same text can `@`-mention any GitHub user
from the repository's bot.

`Scripts/apple-insights-digest.sh` (issue #486) escapes `&`, `<`, `>` and
breaks `@` in everything it quotes from Apple, so quoted text cannot close
into a comment or a tag, or notify anyone. Case 10 of
`Scripts/test-apple-insights-digest.sh` is the check.

The same forgery needs no quoting at all on a public, unlocked issue: anyone
can comment there, and a comment carrying a marker counts unless the digest
reads markers only from its own comments. `Scripts/apple-insights-digest.sh`
reads only comments by a trusted SET of logins, `DIGEST_TRUSTED_AUTHORS`:
by default `github-actions[bot]` (what the workflow's `GITHUB_TOKEN` posts
as; it cannot ask `/user` who it is) and the repository's owner. A set, not
"whoever is posting now": a first cut trusted only the current poster, so a
person's manual run ignored every marker the bot had posted and re-posted all
of it, and the bot then did the same to the person's. A post that lands under
a login outside the set fails the run, since its markers would be invisible.
Each login is validated before it reaches the jq filter, and the list is
split with globbing off -- `[bot]` is a bracket pattern. Cases 3b to 3d.

`Scripts/testflight-feedback-digest.sh` has both weaknesses as of
2026-11-23: it reads markers from every author's comments on the public #299,
and it quotes tester comments unescaped. It was left for its own issue rather
than changed in the pull request that found it (#498).
