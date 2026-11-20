---
name: Task
about: A self-contained piece of work, written so it can be done from the issue alone
---

<!--
An issue is open to any agent unless it carries the needs:owner label. Write
all three sections below; whoever works this may have nothing else to go on.
Add a kind label (bug, enhancement, documentation, test, chore, deps). A size
label (size:xs, size:s, size:m) is optional.

If a step needs the owner (a device, a decision, a credential, an approval),
add the needs:owner label and a "## Needs the owner" section naming that step
and what would unblock it. Scripts/check-issue-format.sh fails the Issue
Format workflow on a needs:owner issue without one.
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
