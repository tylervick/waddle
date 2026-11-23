# A digest whose seen-state is hidden markers must escape the text it quotes

The digests that keep their state in the issue they post to
(`digest-issue-is-its-own-seen-state.md`) read back every
`<!-- <kind>-id: … -->` in the issue's comments. They also quote text that
strangers wrote: a customer review, a tester's comment. A review whose body
contains `<!-- review-id: X -->` is posted verbatim, GitHub renders it
invisibly, and the next run reads X as seen: review X is never delivered,
and nothing anywhere says so. The same text can `@`-mention any GitHub user
from the repository's bot.

Escaping entities is not enough, and it was the first fix in both digests.
`&lt;` closes the HTML hole but leaves Markdown live: a line `# X` or a line
under `---` becomes a heading (a fake `## Crash feedback …` reads as another
submission), a `- ` line a fake field, `#1` or `owner/repo#2` a
cross-reference the bot creates. And inside the stranger's own backticks
entities are not decoded, so their `<b>` shows as `&lt;b&gt;`. The rendering
that closes all of it: every line of quoted text in its own code span whose
backtick delimiter is longer than any backtick run in the line (so the text
cannot close it), lines joined by a trailing-backslash hard break, a blank
line starting a new paragraph. GitHub renders no heading, tag, mention or
reference inside a code span, and shows the text exactly as written. Split
with `splitlines()`, never `split("\n")`: CommonMark also ends a line at a
lone `\r`, and the text after one starts at column 0, outside the list
item -- live. A fenced block is inert too, but GitHub shows it
`white-space: pre`, so a long paragraph is one line scrolling sideways; code
spans wrap. Code is still the raw body that the next run greps for markers,
so break `<!--` with a zero-width space as well.

Both `Scripts/apple-insights-digest.sh` (review title and body) and
`Scripts/testflight-feedback-digest.sh` (the tester's comment) render this
way; cases 10 to 10d of `Scripts/test-apple-insights-digest.sh` and 18 to
21 of `Scripts/test-testflight-feedback-digest.sh` check it, by what a
CommonMark renderer would leave live rather than a grep for the raw string.

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

`Scripts/testflight-feedback-digest.sh` had both weaknesses until issue
#509: it read markers from every author's comments on the public #299, and
quoted tester comments unescaped. It now takes the same shape -- the same
`DIGEST_TRUSTED_AUTHORS` default and checks, and the code-span rendering
above -- pinned by cases 13 to 21 of
`Scripts/test-testflight-feedback-digest.sh`. A new digest that keeps its
state in markers needs both from the start.
