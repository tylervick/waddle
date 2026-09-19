# Blink diffs against the *local* `main`, which in this repo is always stale

`blink review` reviews "every local change since the branch left the default
branch", and it resolves that default branch from the **local** `main` ref —
not `origin/main`, and not the GitHub API. In a repository worked through
worktrees, local `main` is never checked out by anything and therefore never
advances: `git fetch origin main` updates `origin/main` and leaves `main`
exactly where it was the day the clone was made.

Measured here, the first time the Stop hook fired:

| ref | commit |
| --- | --- |
| `main` (local) | `bf37f5b` — 22 commits behind |
| `origin/main` | `7f3a1de` |
| `HEAD` | the branch's own 2 commits |

So the review's range was 24 commits, not 2. It reported five findings, all
five in files the branch had never touched — someone else's merged pull
requests, re-reviewed as though they were this branch's work. The branch's
actual diff had one finding, and it was invisible underneath the noise.

The failure is quiet in the worst way: the findings are *real* findings about
*real* code, so nothing about them looks wrong. Only checking which files they
name reveals that they are not yours.

**Fix** — fast-forward the local ref, not just the remote-tracking one:

```sh
git fetch origin main:main     # updates BOTH main and origin/main
```

`git fetch origin main` (no colon) is the one that does not. The refspec form
works from any worktree as long as no worktree currently has `main` checked
out, which in this repository is the normal state.

A quick way to tell the two cases apart before trusting a review:

```sh
git diff --name-only main...HEAD    # should list only your own files
```

## Not an executable check

There is nothing durable to assert. This is a property of one clone's refs at
one moment, it goes stale again with the next merge to `main`, and CI cannot
see it at all — a runner clones fresh, so its `main` is current by
construction and a guard there would pass on every run while local checkouts
drifted. Checking it at `mise run blink-setup` time would be worth just as
little, since setup runs once and the staleness recurs forever after. The
habit is the check: when a review's findings name files you did not touch,
compare `main` against `origin/main` before reading any further.
