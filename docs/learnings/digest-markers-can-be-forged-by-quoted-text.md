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

`Scripts/testflight-feedback-digest.sh` still quotes tester comments
unescaped. Its authors are invited TestFlight testers rather than the
public, which is why it was left alone when this was found (2026-11-23).
