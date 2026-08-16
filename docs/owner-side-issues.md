# Working an `agent:blocked` issue

`Scripts/loop-prompt.md` is the protocol for unattended runs. This is its
counterpart for the work the loop is *not* allowed to do — the `agent:blocked`
pile, which only the owner (or an assistant working with them) can clear.

Read this before starting one. It exists because the same three mistakes kept
recurring across sessions, and all three are cheap to avoid if you know them.

## The pile is not a backlog

Most of it is a correct work queue, not a failure. Classify before picking —
the blocked-reason paragraph in each issue is authoritative, and the classes
have very different drainability:

| Class | Drains by | Example blocked-reason |
|---|---|---|
| **Forbidden file** | one sitting of owner edits | "the deliverable edits `.github/workflows/`" |
| **Decision** | a conversation, then it becomes implementable | "every resolution adds a dependency" |
| **Policy** | only by doing the thing | "screenshot capture and App Store metadata judgement are owner-gated" |
| **Physical** | a device in someone's hands | "needs on-device tuning" |

Forbidden-file items batch: several usually share one edit surface, and each is
individually too small to sit down for. That is why they accumulate.

**Read the issue's own blocked-reason. Do not infer the class from the title,
the labels, or which issues it references.** Two sibling issues can name
different unblock conditions — one saying "when #124 *merges*", another "when
#124 is unstuck" — and those are different days.

## The process

### 1. Confirm the blocked-reason is still true

Blocked-reasons go stale. A guard that was owner-only because it needed CI
wiring may only need the script now.

### 2. Verify preconditions in the code, not the tracker

**This is the step that gets skipped, and the one that costs most.**

"Is the prerequisite merged?" is answered by looking for the thing it added:

```bash
grep -rn -- '-loadgame' App/Sources/    # not: gh issue view 112 --json state
```

An issue can be closed by a commit that did something else; a PR can be merged
whose branch you are not on; a person can tell you something merged and be
remembering a different number. Check the artifact, not the record of it.

### 3. Set up

Branch from a freshly fetched `main`. If anything will build, check the engine
first — `Scripts/check-engine-fresh.sh` prints the exact rebuild command, and
`Scripts/loop-precheck.sh` refuses while it is stale.

Prefer a worktree per issue if running more than one. Never two `xcodebuild`
test sessions against one simulator (`CLAUDE.md`).

### 4. Do the work

The judgement is why it is blocked — that part is the owner's. Where the issue
offers options and asks the pull request to justify one, that choice is theirs
to make, not yours to assume.

### 5. Land it as a pull request

Body carries `Closes #<N>`. Never merge locally; never push to `main`. The owner
merges.

### 6. Close out

- Confirm the issue actually closed.
- Unblock siblings **whose stated condition is now met** — re-read their text
  rather than assuming a merge satisfied them.
- Drop labels that no longer describe reality.
- Delete the branch; remove the worktree.
- If a trap was paid for, add a `docs/learnings/` file and its `INDEX.md` line
  in the same pull request (`CLAUDE.md`; `Scripts/check-substrate.sh` enforces
  the bijection).

## Traps specific to this work

**Label queries can silently omit an issue.** `gh issue list --label X` resolves
through GitHub's search index, which can miss an issue whose label is genuinely
attached. Issue #79 was invisible to every search-backed path while present in
both GraphQL label-edge paths. When a count looks wrong, cross-check:

```bash
gh api graphql -f query='{repository(owner:"tylervick",name:"waddle"){
  label(name:"agent:blocked"){issues(first:50,states:OPEN){nodes{number}}}}}'
```

Tracked as an issue against `loop-precheck.sh`, which selects work the same way.

**Stale prose is replaced, not appended to.** A file header that contradicts its
own contents is how several defects here survived. If a change falsifies a
comment, rewrite the comment in the same commit.

**Backticks in `git commit -m "..."` are command substitution.** A message
containing `` `inputs` `` silently loses the word. Use `-F <file>` for anything
with backticks.

**A check that has never failed is a check you have not tested.** When landing a
guard for a defect that still exists, land the guard *first* so its initial run
goes red and proves it executes. Fixing the defect first lets the guard go green
without ever demonstrating itself.

## Where the live state is

Do not trust a list of issue numbers written down anywhere, including here.

```bash
gh issue list --state open --label agent:blocked        # the pile
gh issue list --state open --label agent:eligible       # what the loop may take
Scripts/loop-precheck.sh                                # what it would take next
```

Deciding what is worth doing first is not hard and does not need a procedure —
three separate agents given only the pile and the repository produced good,
independently-arrived-at triage. What they could not know is the state
verification above. That is what this file is for.
