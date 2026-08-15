# Setting TestFlight "What to Test" notes on upload

## The problem

Nothing in the release path sets a build's "What to Test" text. `Scripts/upload.sh`
uploads the IPA and stops; `.github/workflows/testflight.yml` never mentions
release notes. Every TestFlight build therefore arrives with the field empty,
to be filled in by hand in App Store Connect — which in practice means it is
not filled in. Build 207 shipped on 2026-08-11 and still has no notes. A tester
opening TestFlight sees a build number and nothing else.

This is issue 65, and it is **owner-only**: it touches the release path, which
is never `agent:eligible`. The unattended loop must not build or run it.

## Where the text comes from

Two parts, concatenated:

```
<optional preamble — docs/app-store/whats-to-test.md, verbatim>

Changes since build <N-1>:
- fix(ui): choose the IWAD hint case-insensitively (#76)
- chore(touch): drop the unwired TouchButton.east case (#74)
```

The changelog half is computed fresh at release time from
`git log build-<N-1>..HEAD`. The preamble is an ordinary tracked file, reviewed
in a pull request like anything else, for "focus on X this time" framing the
commit log cannot supply.

**The derived half exists to make staleness impossible.** Issue 65 originally
proposed a tracked file alone, failing the release if it were empty. That
guards the wrong state: an empty file is obvious, while a file still holding
the *previous* release's notes is not empty, passes the check, and ships
confidently wrong text. Given the agent loop lands two or three pull requests a
day, a hand-maintained file would be stale most releases. A computed changelog
cannot be — and it needs no discipline to stay true.

Consequently an **empty preamble is a normal state, not an error**. The derived
half always carries content, so there is nothing to fail on. A release with no
merges since the last build is the one case that produces an empty changelog;
see Error handling.

## Finding the range: tag each upload

The repository currently records nothing about which commit a build shipped
from, so there is no anchor for "since the last build". The job pushes a
lightweight tag `build-<N>` after a confirmed upload, and the next release
computes its range from it.

This also buys release provenance the project does not have today: you can
check out exactly what any tester is running.

**Ordering is load-bearing: tag on upload success, before attempting notes.**
The tag records what shipped. A notes failure does not unship a build, and if
the tag were gated on notes succeeding, the *next* release would compute its
range from the wrong anchor and silently re-list changes already delivered.

**That ordering dictates the anchor rule: the range starts at the newest
`build-*` tag STRICTLY BELOW the build being annotated, not at the newest tag
there is.** By the time the notes step runs, `build-<N>` already exists and
points at HEAD, so "newest tag" means the current build and every range is
`build-N..HEAD` — empty, on every release. With no preamble the run goes red
after a successful upload; with a preamble it goes *green* and ships the
preamble alone, the changelog silently gone. Anchoring below the current build
is what makes the tag-before-notes ordering and a derived changelog coexist.
`--print` takes no build number and keeps anchoring on the newest tag, since
there is no current build to exclude.

The job needs `contents: write` for the tag push, narrowly; it is `contents:
read` today. Nothing else in the workflow gains write access.

Alternatives considered and rejected: deriving the previous commit from the
TestFlight workflow's own run history (a `workflow_dispatch` input is not
reliably retrievable after the fact, so a real upload cannot be told from a
`validate_only` run, and a `build_number` override breaks the
run-number-to-build mapping); and recording the shipped SHA on an orphan branch
as `loop-trials` does (still needs push access, and invents state a tag models
natively).

## Reaching App Store Connect

`Scripts/whats-to-test.sh <build-number>` does the work, so it is runnable
outside the workflow — but only while `HEAD` is still the commit the build
shipped from. The changelog range ends at `HEAD` (`$TAG..HEAD`), not at the
build's own commit. On the workflow path that endpoint is correct by
construction: the script runs at the commit being shipped, so `HEAD` *is* the
build. Off that path the claim holds only for as long as that stays true —
once anything has landed on `main` since the release, the notes describe work
the build does not contain.

Two consequences worth stating outright. Re-attaching notes by hand after a
notes failure inherits this condition: the remedy is sound when it is run
promptly, and silently wrong once `main` has moved, so it is not
unconditionally safe. And a past build cannot be annotated this way at all —
`prev_tag` selects only the *start* of the range, so no argument moves the
endpoint off `HEAD`. Historical builds are deliberately out of scope; this
design only moves forward.

The App Store Connect REST API authenticates with an **ES256 JWT**. The
existing `ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_PRIVATE_KEY` secrets are
sufficient — the same credentials `xcrun altool` already uses for the upload.

**There is no PyJWT on the runner, and adding a dependency to the release path
is not worth it.** `openssl dgst -sha256 -sign` produces a DER-encoded
signature; JOSE requires the raw `R‖S` pair. A short pure-stdlib `python3` step
unpacks the DER and base64url-encodes it. This is the one genuinely fiddly part
of the implementation and the obvious wrong turn is reaching for a pip install.

Then:

1. Resolve the app id: `GET /v1/apps?filter[bundleId]=<bundle id>`. It is
   derived rather than hardcoded so the script carries no second copy of an
   identifier the project already owns; the bundle id comes from
   `App/project.yml`.
2. `GET /v1/builds?filter[app]=<app id>&filter[version]=<N>` to find the build.
   `<N>` is the build number, passed as the script's argument — in the workflow
   that is the existing `buildnum` step's output, so the notes and the upload
   can never disagree about which build they mean.
3. Poll until the build is addressable, for at most **15 minutes at 30-second
   intervals**. **This is required, not defensive**, and it is *two* states to
   wait out, not one. First the build resource does not exist at all —
   `data: []` — because App Store Connect creates it when ingestion begins,
   not when the upload returns; that is the normal answer for the first minute
   or more, so an absent build is polled for rather than failed on. Then it
   sits in `PROCESSING` for minutes more (several, for build 205). The cap
   exists so a build stuck in either state fails the job rather than holding
   the 90-minute workflow timeout, and the failure says which of the two it
   was.
4. `GET /v1/builds/<id>/betaBuildLocalizations` to find an existing `en-US`
   entry.
5. `PATCH` it if present, `POST` a new one if not. Both shapes occur: a
   re-attach after a failure hits the `PATCH` path.

## Error handling

**A tag-push failure fails the job loudly, for the same reason a notes
failure does below.** If the tag never lands, the *next* release computes
its changelog range from the previous or bootstrap tag and silently re-lists
changes already shipped — the exact failure the tag-before-notes ordering
above exists to prevent, so a quiet failure here is at least as damaging as
a quiet notes failure. The realistic causes are a tag-protection ruleset on
`build-*` or a transient push rejection, not a duplicate tag name: a retry
recomputes the same build number from `run_number`, so it would fail earlier,
at upload, on App Store Connect's duplicate-build rejection, before ever
reaching this step again.

The failure message states the same two facts a notes failure does — the
build IS uploaded, the release did NOT fail — plus that the tag specifically
was NOT recorded. The recovery differs from a notes failure, though:
**re-running does not fix this and should not be attempted.** It recomputes
the same build number and would tag the wrong build if it got this far again,
and as above it will not even get that far. The fix is to create and push
the tag by hand:
`git -c tag.gpgSign=false tag build-<N> && git push origin build-<N>`.

The `-c` is not optional on a machine with `tag.gpgSign = true`. A bare `git
tag` fails there with `fatal: no tag message?`, which reads as a missing
annotation and sends the operator looking for the wrong thing entirely — see
`docs/learnings/git-fixtures-inherit-signing-config.md`. The workflow's own
failure message already prints this corrected form; this document is stating
the same command, not a second one.

**A notes failure fails the job loudly.** The run goes red so it cannot be
missed.

**The recovery is to re-run the whole workflow, and that costs a build
number.** The owner chose this over a separately-runnable recovery path,
knowing the trade: after a successful upload the build is already in App Store
Connect, so re-dispatching rebuilds and uploads again under a new build number
for what is only a metadata problem. The existing `build_number` input cannot
avoid it — App Store Connect rejects a duplicate.

Because that cost is real and easy to incur reflexively, **the failure message
must state it**: name the build number, say the build IS uploaded and the
release did not fail, and say that re-running will consume another build
number. A red status whose obvious remedy is destructive has to explain itself
at the point of failure, not in a document.

**An empty changelog with an empty preamble fails.** That means no merges since
the last build and no hand-written framing — a build with genuinely nothing to
say about it. Shipping it with an empty field is the status quo this exists to
end, so it stops the release instead.

**A missing `build-<N-1>` tag is not an error on first use.** No tags exist
yet — or the only one is the tag this very release just pushed. When no tag
below the current build is found, the changelog falls back to the last 20
first-parent commits and says so in the notes, rather than failing a release
for a bootstrap condition that occurs exactly once.

**Over-long notes are trimmed, not sent.** `whatsNew` caps at about 4000
characters and App Store Connect rejects an over-long value — after the upload
has consumed a build number and the tag has been pushed. At two or three
merged pull requests a day, a few weeks between releases overruns it. The
notes are therefore trimmed to whole bullets below the cap with a trailing
"… and N more changes", and `--print` shows the trimmed text, since a preview
that differs from the payload is the same class of lie as stale notes.

## Testing

`Scripts/test-whats-to-test.sh`, hermetic in the idiom of the existing guards
(`Scripts/test-check-simulator-available.sh` is the closest model): stub `git`
and `curl` on a controlled PATH; build fixture repositories for the log range.
Cases:

- preamble present → included verbatim above the changelog
- preamble absent or empty → changelog alone, exit 0
- no commits since the tag **and** no preamble → fails
- `build-<N-1>` tag missing → falls back to recent history and says so
- the JWT's three segments are well-formed and the signature is 64 raw bytes
  (the DER→JOSE conversion is where this will break, so assert its shape)
- build stuck in `PROCESSING` past the cap → fails, and the message names the
  build number
- existing `en-US` localization → `PATCH`; none → `POST`
- **two build tags, the higher one at HEAD** → the changelog anchors on the
  lower. A single-tag fixture cannot see the anchor rule at all, because
  "newest tag" and "newest tag below N" then name the same commit — so this
  fixture is what makes the release-path behaviour provable rather than
  assumed
- absent build, then absent, then `VALID` → attaches (an early poll is not a
  failure); `PROCESSING`, `PROCESSING`, then `VALID` → attaches, having
  queried the build more than once
- the `POST`/`PATCH` itself rejected → non-zero exit, and Apple's error body
  reaches stderr. The lookup `GET` and the write share a URL, so a
  failure injected by URL alone only ever hits the lookup: the write has to
  be failed by method or it is never covered
- notes longer than the cap → trimmed, under the cap, and saying how many
  changes were dropped

**What cannot be tested hermetically:** the real API contract. Stubs assert
what this script sends, not what App Store Connect accepts. The first live run
is the first genuine test of the request shapes, and it will run against
production because there is no sandbox. Expect to iterate once.

## What this does not do

- No cadence. TestFlight stays `workflow_dispatch`-only; shipping remains a
  deliberate act, per that workflow's existing comment. A schedule is a
  separate decision, and a build with notes is a precondition for it being
  worth having.
- No localization beyond `en-US`.
- No editing of notes for builds already delivered to testers, beyond
  re-running the attach against an existing build.
