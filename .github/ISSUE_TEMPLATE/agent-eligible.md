---
name: Agent-eligible task
about: A self-contained task an unattended run may claim
labels: ["agent:eligible"]
---

<!--
All three sections below are required and must be non-empty --
Scripts/check-substrate.sh fails CI otherwise. Add a kind label (bug,
enhancement, documentation, test, chore, deps) and a size label
(size:xs, size:s, size:m).

Size is an estimate. If the work turns out larger or smaller, correct the
label when the PR lands rather than leaving it wrong -- the labels are what
make separate pieces of work comparable to each other.
-->

## Definition of done

<!-- One sentence naming the condition that must become true. Name the observable
     change, not the activity: "ZipExtractor rejects any entry whose uncompressed
     size exceeds the cap, and a test proves it" -- not "fix the size cap". -->

## Verification

<!-- The exact command that demonstrates it. -->

```
mise run test
```

## Provenance

<!-- Where this came from: the plan, review, or PR that deferred it. -->
