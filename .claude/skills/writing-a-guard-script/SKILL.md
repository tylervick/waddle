---
name: writing-a-guard-script
description: Use when adding or changing a Scripts/check-*.sh guard or its Scripts/test-*.sh suite in the WADdle repo, when turning a docs/learnings/ trap into an executable check, or when debugging bash in Scripts/ that fails open, aborts silently under set -e, or behaves differently on another machine or in CI.
---

# Writing a guard script in WADdle

## Overview

`CLAUDE.md`: *"A learning that can be an executable check should become one —
`Scripts/check-engine-fresh.sh` is the pattern — and the learning file then
points at the check instead of restating it."* That promotion is why `Scripts/`
holds 40 shell files — every single one `#!/bin/bash` with `set -euo pipefail` —
and why all 8 of its `check-*.sh` guards have a `test-check-*.sh` suite beside
them.

Read the two models before writing: `Scripts/check-simulator-available.sh` +
`Scripts/test-check-simulator-available.sh` (stubs a binary on PATH), and
`Scripts/check-red-green.sh` + `Scripts/test-check-red-green.sh` (builds
throwaway git repos).

## The shape

Every guard in this repo follows it. Deviating is a review finding.

```bash
#!/bin/bash
# What this refuses, and the incident that bought it -- name the CI run, PR,
# or issue. Then: what a skip means, and what a failure means.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
```

And its suite:

```bash
#!/bin/bash
# Tests for Scripts/check-<name>.sh.
#
# Fully HERMETIC: <how>. Nothing here touches <the real thing>.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }
# ... numbered cases, each a comment saying what shape it pins and why ...
echo "All check-<name> tests passed."
```

All 16 suites use that exact `fail`/`pass` pair. Cases are numbered in comments
(`# 1.`, `# 3b.`) and the comment says what failure shape the case exists to
catch, not what the code does.

## Hermetic means: stub the world on a controlled PATH

Three techniques, all live in the repo:

| Technique | Model |
|---|---|
| Write a stub binary into `$TMP/bin` and run with `env PATH="$TMP/bin:/usr/bin:/bin"` | `test-check-simulator-available.sh` stubs `xcrun`, one fixture per `simctl list` output shape |
| Strip PATH to `/usr/bin:/bin` so a tool is *invisible*, and clear its credentials too | `test-check-issue-format.sh` runs `env PATH=/usr/bin:/bin GH_TOKEN= GITHUB_TOKEN= GH_CONFIG_DIR=/nonexistent` — the step-level `GH_TOKEN` would otherwise leak in and run real `gh` |
| Build a throwaway git repo per case | `test-check-red-green.sh`'s `make_repo`, `test-build-deps.sh` |

Make stubs *strict*: end them with `echo "stub xcrun: unhandled args: $*" >&2;
exit 64` so an unexpected call is a loud failure, not a silent pass.

Make the suite *fast*: expose the slow knob as an env var and set it to zero in
the test. `check-simulator-available.sh` reads `SIMULATOR_CHECK_ATTEMPTS` /
`SIMULATOR_CHECK_DELAY` purely so its suite need not really sleep 60s per case.

**A git fixture inherits the developer's global config.** Export these at the
top of any suite that runs `git` — see
`docs/learnings/git-fixtures-inherit-signing-config.md`:

```bash
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
```

Without them `commit.gpgsign` routes through 1Password's `op-ssh-sign` and the
suite passes for one developer and fails for another; and `tag.gpgSign` makes a
plain `git tag v1` fail with `fatal: no tag message?`, an error that names
neither signing nor config. For a one-off command in a *real* checkout, override
only the setting in the way: `git -c tag.gpgSign=false tag build-207 <sha>`.

**One deliberate exception to hermeticity:**
`Scripts/test-check-masked-gh-status.sh` also asserts against the real
`Scripts/` directory, so that a newly-added masked call fails CI. Fixtures prove
the rule; the live assertion is what makes it bite.

## Skip cleanly, or fail closed — decide, and test both

A guard that needs something it may not have has two honest outcomes and they
must not be confused. `Scripts/check-issue-format.sh` is the reference:

- `gh` missing, or `gh auth status` fails → print `skip - <reason>`, **exit 0**.
- The query itself fails (bad scope, network, rate limit, wrong cwd) → **fail
  closed** with an `error:` line. Not a skip.

Both halves are pinned by cases 1 and 2 of its suite. Then, because a skip in a
context that *always* has credentials can only mean something broke,
`.github/workflows/issue-format.yml` re-fails the job on one:

```bash
Scripts/check-issue-format.sh | tee "$out"
! grep -q '^skip - ' "$out"
```

Distinguish failure *shapes* when they call for different responses.
`check-simulator-available.sh` prints the `WADDLE_SIMULATOR_UNAVAILABLE` marker
for "CoreSimulator enumerated nothing" (infrastructure — re-run) and omits it
for "no device matched" (a real pin problem — a re-run will not help).
`Scripts/loop-prompt.md` §4.3 greps for exactly that marker.

## Register it, or nobody runs it

Add the suite to `.github/workflows/ci.yml` → **"Verify the build-script
helpers"**. Its comment states the rule: *"This list must name EVERY
Scripts/test-*.sh suite, not just the ones that guard the build."* The reason is
concrete — `test-loop-report.sh` and `test-loop-precheck.sh` once ran nowhere on
a pull request, so a change breaking one was green in CI and then scored
`proved` by `check-red-green.sh` for breaking its own tests.

**The unattended loop may not do this.** `Scripts/loop-prompt.md` → "Rules that
are absolute" forbids creating or modifying anything under `.github/workflows/`.
An `agent:eligible` issue that adds a guard must say the CI wiring is the
owner's follow-up, or be `agent:blocked`. See the `filing-an-issue` skill.

If the guard replaces a prose learning, update the `docs/learnings/` file to
point at the check rather than restate it, and keep its `INDEX.md` line — the
bijection is enforced by `Scripts/check-substrate.sh`.

## Prove the guard is not vacuous

A guard whose suite passes proves the suite ran, not that the guard
discriminates. `docs/learnings/masked-exit-status-fails-open.md` shows the
standard: pointed at the tree before PR #66 the check reports three violations;
before issue #68's fix, the one at `loop-report.sh:232`; at `Scripts/` today,
none. Do the same — break the condition, confirm the case fails, restore,
confirm it passes — and say so in the PR body. Claims of exactly that shape have
been false here before (PR #57; see
`docs/superpowers/specs/2026-08-10-test-proof-signal-design.md`).

## The four bash traps this repo keeps re-paying

macOS ships **bash 3.2.57**. No associative arrays, no `${var^^}`, no clean
multi-value return — `check-simulator-available.sh` uses globals set by
`query_once` and says why in a comment. Measure the shape you are about to
write; it is four lines and an `echo "reached end"`.

**1. A masked exit status makes a guard fail open.** Four occurrences in two
scripts — `docs/learnings/masked-exit-status-fails-open.md`. `cmd || true` and
`2>/dev/null` destroy the evidence that the command failed, and the output is
then read as an answer, usually the permissive one. Decide what *failure* means
before you decide what the *output* means:

```bash
if out="$(gh api ... 2>/dev/null)"; then
    # succeeded -- now interpret $out, including the empty case
else
    # failed -- do not interpret $out at all
fi
```

`set -e` is suspended inside an `if` condition, so this needs no `|| true`. Keep
`|| true` only where the non-zero status *is* the meaningful answer (`grep -c`
returning 1 for no matches). `Scripts/check-masked-gh-status.sh` enforces this
for `gh api` in CI and will reject `|| true` / `|| echo` on such a line, while
accepting `|| skip` / `|| err`. And note: successful-but-empty still needs its
own ruling, per query — an empty commit list is impossible and suspect; an empty
comment list is a fully-measured zero.

**2. `$(...)` around a function call discards everything but stdout.**
`docs/learnings/command-substitution-discards-callee-state.md`. The subshell
throws away the callee's variable writes *and* swallows its `exit`:
`check-red-green.sh`'s `classify_domain` set the global `REVERTED` that the EXIT
trap needed, and left the tree reverted and dirty; a test hook's `exit 70` killed
only the subshell. Fix: run the callee directly and capture via redirection.

```bash
classify_domain swift "$(swift_src)" "$(swift_test)" > "$verdict_tmp"
sw="$(cat "$verdict_tmp")"
```

**3. A loop body's trailing `&&` list trips `errexit` — only when the loop is a
pipeline stage.** `docs/learnings/loop-body-last-status-triggers-errexit.md` has
the measured table. `printf … | while … done` and `echo … | for …` abort; a plain
`for`, `while … < file`, and `while … < <(…)` do not. The mechanism is the
subshell boundary, not the loop: the `&&`-list exemption does not survive being
re-delivered across one. Same for an explicit `( … )` and for a function
returning to its call site. Fix is `if`/`fi`, not blanket `|| true` — which would
hide a real failure inside the action too:

```bash
if [ -f "$t" ]; then echo "$t"; fi
```

`pipefail` produces the same shape with no `&&` in sight, and is worse: there is
no exemption to inherit, so it aborts in *every* loop shape. Do not run the
inference backwards — verifying the safe `for` form and then stripping an
`if`/`fi` back to `&&` inside a piped loop reintroduces a silent, message-free
abort.

**4. `tag.gpgSign` surfaces as `fatal: no tag message?`** — see the git-fixture
exports above.

## Common mistakes

| Mistake | Fix |
|---|---|
| Guard added, suite not added to `ci.yml`'s helper list | Nobody runs it before merge; add it (owner-only if the loop authored it). |
| Header comment describes the code | Describe what it refuses, and name the incident that bought it. |
| Permissive stub that falls through on unexpected args | End the stub with a loud `exit 64`. |
| Suite that really sleeps or really queries | Expose the knob (`*_DELAY`, `*_ATTEMPTS`); stub the binary. |
| Query failure treated as a skip | Skip only for "the tool isn't here". A failed query fails closed. |
| `cmd || true` on a query whose output decides something | Test the status in an `if`, then interpret the output separately. |
| Suite runs `git` without the `GIT_CONFIG_*` exports | It will pass for you and fail for someone else, or in CI. |
| Learning file left restating a manual fix after the check lands | Point it at the check; keep the `INDEX.md` line (`check-substrate.sh`). |
