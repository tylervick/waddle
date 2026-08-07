# Loop trial records

One file per agent-loop run: `<YYYY-MM-DD>-issue-<N>.md`, with a `---`
frontmatter block that `Scripts/loop-report.sh` parses, followed by free prose.

This is an orphan branch. It carries records only, never code, so merging it
into `main` contributes nothing but data. Records are pushed here directly
rather than through a pull request: they are measurements, not changes, and they
must accumulate even while work PRs wait on review.

A record whose `outcome` is still `started` is a run that died mid-flight. Those
are kept, not cleaned up — a lost trial is data.
