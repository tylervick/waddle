# Masking a query's exit status makes a guard fail open

`cmd || true` and `2>/dev/null` are how you stop `set -euo pipefail` aborting a
script on an expected non-zero exit. They also destroy the only evidence that
the command failed. When the command's *output* is then used to decide
something, a failure stops looking like a failure and starts looking like an
answer — usually the permissive one.

This has bitten this repo four times, in two different scripts:

1. **`loop-precheck.sh`, abandoned-worktree sweep.** `grep` with no match exits
   1; under `pipefail` inside `set -e` that aborted the entire precheck, with
   empty stdout *and* empty stderr. The run looked like a clean refusal. Fixed
   with `done || true` on the loop.
2. **`loop-precheck.sh`, claim-liveness check.** The timeline query was
   unpaginated, so a labeling event older than the newest 30 events was simply
   absent. Absent read as "no claim found" — age ~56 years — and the guard
   swept live claims. It failed open on exactly the issues the loop retries
   most.
3. **`loop-report.sh`, reconciliation (PR #66).** `commit_emails="$(gh api
   --paginate ... || true)"`. `gh` streams each page as it arrives, so a
   failure on page 2 still leaves page 1 in the variable. If page 1 was all
   agent-authored, the authorship gate passed on partial data and reconciled a
   PR that a later page might have shown carries a human commit. The sibling
   comments query was worse: a failed call produced `0`, recording a fabricated
   measurement of zero findings — indistinguishable in the report from a PR
   that was genuinely reviewed and found clean.
4. **`loop-report.sh`, the legacy live query (issue #68).** PR #66 fixed the
   shape above in the reconciliation path and deliberately left the same
   `gh api ... | grep -c ... || true` in the legacy branch — the one taken when
   a record predates `coderabbit_findings_first` entirely — rather than widen
   an unrelated PR. A failed call there still counted 0 and folded it into the
   findings total as an ordinary *scored* legacy record. Fixed by testing the
   status directly and giving a failed query its own counter and its own
   reported line, so "never successfully queried" stops reading as "queried,
   found clean". The lesson is about the leftover as much as the bug: a known
   instance of a fixed pattern, left in place and recorded as tracked
   separately, is one nobody is looking at.

## The rule

Decide what a *failure* means before you decide what the output means, and keep
the two separable. Test the status directly rather than masking it:

```bash
if out="$(gh api ... 2>/dev/null)"; then
    # succeeded — now interpret $out, including the empty case
else
    # failed — do not interpret $out at all
fi
```

The status of an assignment is the status of its command substitution, and
`set -e` is suspended inside an `if` condition, so this is safe and needs no
`|| true`.

Keep `|| true` only where the non-zero status is itself the expected, meaningful
answer and carries no failure information — `grep -c` returning 1 for "no
matches" is the canonical case. `loop-report.sh` keeps exactly that one and no
others, in both its reconciliation and its legacy paths.

## Empty output is not one thing

Once failure is separated out, a successful-but-empty result still needs its own
ruling, and it differs per query. In `loop-report.sh`:

- an empty **commits** list is impossible for a real PR, so it is treated as
  suspect and refuses reconciliation;
- an empty **comments** list is a fully-measured zero — CodeRabbit reviewed and
  found nothing Major/Critical — so it reconciles at 0.

Collapsing those two into one rule breaks the feature in one direction or the
other. A reviewer asked for the strict version of both; the comments half would
have discarded the only two working measurements the report has.

## Not yet an executable check

A lint could flag `gh api` inside a command substitution whose status is masked.
It is not written yet because the obvious `grep` also fires on the legitimate
`grep -c ... || true`, which both remaining call sites use correctly and which
must not be flagged. The legacy path used to be the second reason this check
could not be written; occurrence 4 above removed it, so telling the two apart is
now the only thing standing in the way. Write the check when it can; until then,
this file is the check.
