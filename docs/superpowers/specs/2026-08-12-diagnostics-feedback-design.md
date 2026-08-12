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

- Queries the App Store Connect API beta feedback endpoints
  (`/v1/betaFeedbackScreenshotSubmissions` and
  `/v1/betaFeedbackCrashSubmissions`), filtered to the WADdle app id.
- Tracks already-seen submission IDs in a local state file (git-ignored)
  so each run prints only new submissions.
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
Support, e.g. `Diagnostics/`. Three components plus UI.

### 1. Session log tee

Woof runs in-process (`WoofIOS_Run`), so engine console output goes to
the app's stdout/stderr. At `EngineSession.play` start:

- Redirect stdout and stderr into a pipe (`dup2`); a reader thread
  writes each chunk to both the original file descriptors (Xcode
  console keeps working) and `Diagnostics/session-<generation>.log`.
- Restore the original descriptors when the session ends.
- Retention: keep the last 3 session logs; cap each file at ~1 MB
  (stop writing to the file past the cap, keep passing output through).
- Logs survive app death, so the previous run's log is available after
  a crash or hang.

### 2. MetricKit subscriber

- Registered at app launch in `WADdleApp`.
- On `didReceive` of diagnostic payloads (crash, hang, disk-write
  exception), persist each payload's JSON representation to
  `Diagnostics/metrickit-<date>-<n>.json`.
- Retention: keep the most recent 10 payload files.
- No processing, no symbolication, no upload — raw payloads only.

### 3. Exporter

Builds `WADdle-diagnostics.zip` in a temporary directory using
ZIPFoundation (already a dependency). Contents:

- All retained session logs.
- All retained MetricKit payload files.
- `info.txt`: app version and build, `BuildInfo.commit`/`branch`/
  `builtAt`, iOS version, device model, and a summary of the library
  (playable/loadout names and WAD file names only — never WAD data).

### UI and policy

- `AboutView` gains a **Diagnostics** section: an "Export Diagnostics"
  button that assembles the zip and presents the share sheet
  (`ShareLink`), plus a footnote: "Nothing leaves your device unless
  you share this file."
- `PRIVACY.md` gains one sentence: the app makes no network connections
  on its own; the diagnostics export leaves the device only when the
  user explicitly shares it.

## Error handling

- Tee setup failure (pipe/dup2 errors): the session proceeds without
  capture; never block gameplay on diagnostics.
- Export with nothing to export: still produce a zip with `info.txt`
  so the share flow always works.
- Exporter failures surface as a simple alert in `AboutView`; no
  retry logic.
- Puller: non-2xx API responses print the error and exit non-zero;
  the seen-ID state file is only updated after successful output.

## Testing

- **Puller:** `test-fetch-testflight-feedback.sh` with stubbed
  network/JWT, covering new-vs-seen filtering, markdown shape, and
  state-file update-on-success-only.
- **Tee:** unit test writes through a redirected descriptor pair and
  asserts the log file and pass-through both receive the bytes; tests
  for the 1 MB cap and 3-file rotation.
- **MetricKit:** payload persistence and 10-file retention tested with
  synthesized payload data (real payloads can't be triggered in tests).
- **Exporter:** zip contents and `info.txt` fields asserted via
  ZIPFoundation reads.
- TDD throughout; simulator quirks discovered along the way (fd
  redirection is a likely candidate) become `docs/learnings/` entries
  in the same PR, per house rules.

## Delivery

- PR 1: Slice 1 (scripts only).
- PR 2: Slice 2 (Diagnostics module + UI + `PRIVACY.md` amendment).
- Conventional commits; engine sources untouched, so the
  engine-freshness guard is unaffected.
