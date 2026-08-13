# Tester Feedback & On-Device Diagnostics

**Date:** 2026-08-12
**Status:** Approved design, pending implementation plan

## Purpose

WADdle needs a way to learn from testers about behavior that automated
tests can't reach — rendering/sound oddities with particular WADs, touch
control feel, crashes in the field. The app's privacy stance
(`PRIVACY.md`: no network connections, no analytics, no third-party
SDKs) is a feature and stays intact: everything here is either
Apple-side (TestFlight) or strictly user-initiated sharing.

Testers are a mixed audience; many have no GitHub account. Feedback
therefore centers on TestFlight's built-in feedback plus a share-sheet
diagnostics export anyone can send. No automatic telemetry of any kind.

## Non-goals

- No usage analytics, hosted or otherwise (TelemetryDeck, Sentry, etc.).
- No automatic upload of anything, ever.
- No GitHub-issue deep-link in the app (revisit if tester demographics
  change).
- No log viewer UI — export only.
- WAD file contents are never included in any export (they can be
  copyrighted game data); only names/metadata.

## Slice 1 — TestFlight feedback puller (scripts only, first PR)

`Scripts/fetch-testflight-feedback.sh`, authenticated via the existing
`Scripts/asc-jwt.sh`.

- Queries the App Store Connect API's app-scoped beta feedback routes
  (`/v1/apps/{APP_ID}/betaFeedbackScreenshotSubmissions` and
  `/v1/apps/{APP_ID}/betaFeedbackCrashSubmissions`). Screenshot image
  URLs come from each submission's `attributes.screenshots` array.
- Follows `links.next` pagination on both collections until exhausted —
  a backlog larger than one page must not be silently dropped, because
  unseen submissions beyond page one would otherwise never surface.
- Tracks already-seen submission IDs in a local state file (git-ignored)
  so each run prints only new submissions.
- Every curl call carries explicit `--connect-timeout`/`--max-time`
  values so a stalled connection cannot hang the run.
- Output: markdown to stdout — tester comment, device model, OS
  version, app build, timestamps, and download URLs (screenshots /
  crash logs). A flag (e.g. `--download DIR`) fetches the attachments.
- Paired `Scripts/test-fetch-testflight-feedback.sh` following the
  repo's existing script-test convention (offline; stub `curl`/JWT).
- One-time manual step (not in the repo): update the TestFlight test
  information in App Store Connect to tell testers that screenshotting
  in-app opens the feedback composer.

## Slice 2 — On-device diagnostics (app changes, second PR)

New module `App/Sources/Diagnostics/`. All storage under Application
Support, e.g. `Diagnostics/`, with `isExcludedFromBackup` set on the
directory (reapplied whenever it is ensured before a write): Application
Support is iCloud-backed-up by default, and diagnostics leaving the
device through a backup would undercut the export-only privacy story.
Three components plus UI.

### 1. Session log tee

Woof runs in-process (`WoofIOS_Run`), so engine console output goes to
the app's stdout/stderr. At `EngineSession.play` start:

- Redirect each captured descriptor through **its own pipe** (`dup2`),
  with **one reader thread per descriptor**: each reader writes chunks
  to that descriptor's saved original (Xcode console keeps working,
  stream identity is preserved, nothing is duplicated) and appends to
  the shared session log file under a lock.
- Log names are wall-clock timestamps plus a short random suffix —
  never the in-memory generation counter, which restarts every launch
  and would overwrite the previous launch's logs, exactly the ones a
  crash report needs.
- Descriptor ownership: only `SessionLogCapture` ever calls `dup2`, and
  `EngineSession.play`'s existing reentrancy guard means begin/end pairs
  cannot overlap. The engine has already returned before teardown runs,
  so no writer races the restore; restoring the saved descriptors is
  itself what delivers EOF to the readers, which then drain and exit.
- Teardown waits for the readers with a **bounded** deadline (a couple
  of seconds), then abandons them rather than hang the main thread — a
  blocked pass-through write on a pathological stdout must never block
  quitting a game session.
- Retention: keep the last 3 session logs; cap each file at ~1 MB
  (stop writing to the file past the cap, keep passing output through).
  The log write on the reader thread is synchronous by design: the 1 MB
  cap bounds total write volume, so a bounded-queue/drop-on-full layer
  is complexity this app does not need.
- Logs survive app death, so the previous run's log is available after
  a crash or hang.

### 2. MetricKit subscriber

- Registered at app launch in `WADdleApp`.
- On `didReceive` of diagnostic payloads (crash, hang, disk-write
  exception), persist each payload's JSON representation to
  `Diagnostics/metrickit-<date>-<suffix>.json` — written atomically
  (temp file + rename) with a random suffix so names cannot collide
  across launches or within one delivery batch.
- Retention: keep the most recent 10 payload files. Count-based, not a
  byte budget, deliberately: individual payloads are small and the
  count bound keeps the mechanism trivial.
- No processing, no symbolication, no upload — raw payloads only.

### 3. Exporter

Builds `WADdle-diagnostics.zip` in a temporary directory using
ZIPFoundation (already a dependency). Contents (a strict allowlist —
session logs, MetricKit payloads, `info.txt`, nothing else):

- All retained session logs. Engine console output can name WAD files,
  sandbox paths, and device details; that is the point of a diagnostics
  export, and the UI copy discloses it before the user shares.
- All retained MetricKit payload files.
- `info.txt`: app version and build, `BuildInfo.commit`/`branch`/
  `builtAt`, iOS version, device model, and a summary of the library
  (playable/loadout names and WAD file names only — never WAD data).

Assembly details: a copy failure propagates and fails the export (a
silently incomplete archive is worse than an error the user can see and
retry); export work runs off the main actor; the uncompressed staging
directory is deleted once the zip exists; starting a new export deletes
the previous export's temp output. The zip for an in-flight share stays
on disk — the share sheet has no completion hook, so the OS's periodic
temp cleanup handles the last one.

### UI and policy

- `AboutView` gains a **Diagnostics** section: an "Export Diagnostics"
  button that assembles the zip and presents the share sheet, plus a
  footnote disclosing the contents: recent engine session logs (which
  can include WAD file names) and crash reports, and that nothing
  leaves the device unless the user shares the file.
- `PRIVACY.md` gains one sentence: the app makes no network connections
  on its own; the diagnostics export leaves the device only when the
  user explicitly shares it.

## Error handling

- Tee setup failure (pipe/dup2 errors): the session proceeds with
  whatever capture succeeded — degrading to partial or no capture is
  acceptable, and `end()` restores exactly the descriptors that were
  redirected. Never block gameplay on diagnostics. (No syscall
  failure-injection test harness: these paths are straight-line
  degradation, and a seam for faking `pipe`/`dup2` failures would cost
  more than the coverage is worth for this app.)
- Export with nothing to export: still produce a zip with `info.txt`
  so the share flow always works.
- Exporter failures — including a failed copy of any bundled file —
  surface as a simple alert in `AboutView`; no retry logic.
- Puller: non-2xx API responses print the error and exit non-zero;
  the seen-ID state file is only updated after successful output.

## Testing

- **Puller:** `test-fetch-testflight-feedback.sh` with stubbed
  network/JWT, covering new-vs-seen filtering, markdown shape,
  `links.next` pagination traversal, and state-file
  update-on-success-only.
- **Tee:** unit test writes through a redirected descriptor pair and
  asserts the log file and pass-through both receive the bytes; tests
  for the 1 MB cap and 3-file rotation.
- **MetricKit:** payload persistence and 10-file retention tested with
  synthesized payload data (real payloads can't be triggered in tests).
- **Exporter:** exact zip entry sets and `info.txt` fields asserted via
  ZIPFoundation reads, including the negative case: a stray WAD file in
  the diagnostics directory must not enter the archive.
- TDD throughout; simulator quirks discovered along the way (fd
  redirection is a likely candidate) become `docs/learnings/` entries
  in the same PR, per house rules.

## Delivery

- PR 1: Slice 1 (scripts only).
- PR 2: Slice 2 (Diagnostics module + UI + `PRIVACY.md` amendment).
- Conventional commits; engine sources untouched, so the
  engine-freshness guard is unaffected.
