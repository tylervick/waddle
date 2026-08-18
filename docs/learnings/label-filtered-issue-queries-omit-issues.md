# A label-filtered issue query silently omits issues

`gh issue list --label <name>` resolves through GitHub's **search index**, which
can omit an issue whose label is genuinely attached. The same is true of REST
`issues?labels=` and of `search/issues`. The label edge —
`repository.label(name:).issues` in GraphQL — and an **unfiltered**
`gh issue list` both return the complete set.

Measured on this repository 2026-08-18, and still true days after #171 first
recorded it on 2026-08-16:

```console
$ gh issue list --label agent:blocked --limit 200 --json number --jq length
8
$ gh issue list --state open --limit 1000 --json number,labels \
    --jq '[.[] | select(any(.labels[]; .name=="agent:blocked"))] | length'
9
```

The missing one was #79, every time.

This is not a slow query or a stale cache you can wait out. An omitted issue is
invisible for as long as the index disagrees — never selected by
`Scripts/loop-precheck.sh`, never format-checked by
`Scripts/check-issue-format.sh`, and indistinguishable in the record from a
queue that is genuinely empty. It is a failure shaped exactly like success.

**So neither script filters by label server-side.** Both fetch the open issues
unfiltered and apply the label locally. `Scripts/test-loop-precheck.sh` cases
19-21 and `Scripts/test-check-issue-format.sh` case 3 pin that: they assert the
query carries no `--label`, that a non-eligible issue is never selected, and
that an empty-but-readable queue does not report as an unreadable one.

The residual risk is that the unfiltered listing is complete only because `gh`
routes it through `repository.issues` rather than search. If that ever changes,
the omission returns silently. The cases above pin the query shape, not the
routing, so a `gh` upgrade is the thing to re-measure — the two commands above
are the measurement.
