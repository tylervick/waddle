# The unattended loop (archived)

**Retired 2026-11-20. Nothing here is run, wired into CI, or a rule for anyone.**

From 7 to 21 August 2026 a scheduled Orca automation (`waddle-loop`) picked one
issue at a time, worked it in a fresh worktree and opened a pull request.
`loop-prompt.md` was its protocol, `loop-precheck.sh` chose the issue, and
`loop-report.sh` summarised the trial records it pushed to the `loop-trials`
branch. That branch holds 45 records: 38 `pr-opened`, 5 `stuck`, 1 `no-repro`
and 1 left at `started`.

It was retired because it had not run since 21 August while the README, the
issue-filing skill and the label scheme still described it as the main worker.
The backlog is now worked by a steward bot or an attended session that starts
a worker on an issue; see "How work flows" in `CLAUDE.md`.

The `waddle-loop` automation (disabled) and the `loop-trials` branch were left
as they were.

## What is here

| File | Was |
|---|---|
| `loop-prompt.md` | The run protocol, 1,089 lines |
| `loop-precheck.sh`, `test-loop-precheck.sh` | Issue selection and claim handling, with its hermetic suite |
| `loop-report.sh`, `test-loop-report.sh` | The trial report, with its hermetic suite |

The files are as they were on `main` at 563f6fe, moved from `Scripts/`. The only
edit is in the two suites, which now find their script beside them, so both
still pass when run from here by hand. The scripts themselves still compute
the repository root as `..` and would need that changed before real use.

Paths, section numbers and rules inside these files describe August 2026.
Known to be stale already: the prompt forbids editing `Scripts/release-args.sh`
(no such file), caps the wait for CI at 15 minutes (pull-request CI now takes
about 32), and its "Operating this loop" section describes an unmerged branch.

## Worth reusing

Two things in `loop-precheck.sh` were paid for and apply to anything that
selects issues or tracks claims:

- **The unfiltered issue query** (section 3). `gh issue list --label X` goes
  through GitHub's search index, which can omit an issue whose label is
  attached, and an omitted issue looks exactly like an empty queue. The script
  lists every open issue and applies the label locally. See
  `docs/learnings/label-filtered-issue-queries-omit-issues.md`; cases 19 to 21
  of the suite pin it.
- **The stale-claim sweep** (section 4). A claim label outlives a run that
  died. The script reads the time the label was applied from the issue
  timeline and clears claims older than the work budget. A failed timeline
  query, or a claim with no labelling event found, is read as live and never
  as stale: an earlier version scored one as 56 years old and handed a claimed
  issue to a second run. It also decodes
  `--paginate` output one JSON document at a time, since that is several
  arrays back to back, not one. See
  `docs/learnings/masked-exit-status-fails-open.md`.

Smaller, same file: an issue counts as taken when an open pull request body
names it with any of GitHub's nine closing keywords, in `#N` or `GH-N` form.
