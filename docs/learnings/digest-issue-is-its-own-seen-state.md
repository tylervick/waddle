# A scheduled job with "new since last time" semantics keeps its state in the thing it delivers

`Scripts/fetch-testflight-feedback.sh` prints only submissions it has not
printed before, tracking ids in a gitignored local file. Correct for a human
at a checkout; meaningless on a CI runner, which starts empty every time and
would re-report the whole backlog on every scheduled run (issue #192).

The options for carrying the state all had a real cost. `actions/cache` is
evictable, and an eviction silently replays everything. A committed state
file needs `contents: write` and makes a commit per run. A gist or a separate
store is one more credential and one more thing to be out of sync with the
output.

The shape that has none of those costs: **the delivery object is the state.**
`Scripts/testflight-feedback-digest.sh` posts one comment per run to the
pinned digest issue #299, with one hidden `<!-- tf-feedback-id: <id> -->`
marker per submission, and rebuilds the fetcher's state file from the
markers already in the issue before fetching. Posting the comment is the
output and the state write in a single step, so there is no window in which
output was delivered and state was not, or state was written and output was
not. A run that fails before the post marks nothing seen, which is the
fetcher's own append-after-output discipline carried across runs. The one
thing it cannot survive is someone deleting a comment, which un-sees those
submissions; the issue body says so.

Two rules the suite (`Scripts/test-testflight-feedback-digest.sh`) pins
because each is a quiet failure otherwise:

- **A failed listing is an error, not an empty list.** Read as "no comments
  yet", a GitHub blip becomes a cold start and replays the backlog into the
  issue. Case 6; the masked-exit-status rule in another form.
- **Bound the output per run and defer the rest.** A broken fetcher or a
  long backlog cannot flood the issue, and the deferred items are posted on
  the next run rather than dropped. Case 4.

Reuse this shape for anything scheduled that must say "new since last time"
from a stateless runner: let the thing you post carry the ids you posted.
