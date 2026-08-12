# Tester Feedback & Diagnostics Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pull TestFlight beta feedback from App Store Connect via a script, and give the app a fully-offline diagnostics capture (engine session logs + MetricKit payloads) with a user-initiated share-sheet export.

**Architecture:** Slice 1 is a standalone shell script following the repo's existing ASC-script pattern (`whats-to-test.sh`): JWT via `asc-jwt.sh`, curl + python3 stdlib, hermetic test script. Slice 2 is a new `App/Sources/Diagnostics/` module: a file-descriptor tee capturing engine console output per session, a MetricKit payload store, and a ZIPFoundation exporter surfaced from `AboutView`.

**Tech Stack:** bash + curl + python3 (stdlib only), Swift/SwiftUI, XCTest, MetricKit, ZIPFoundation (existing dependency), XcodeGen.

**Spec:** `docs/superpowers/specs/2026-08-12-diagnostics-feedback-design.md`

## Global Constraints

- The app makes **no network connections on its own** — nothing in Slice 2 may touch the network. Export leaves the device only via the user's share action.
- WAD file **contents** never appear in any export; names/metadata only.
- Bundle id is `com.tylervick.waddle`; ASC API base is `https://api.appstoreconnect.apple.com`.
- Scripts add **no dependencies** beyond bash/curl/python3-stdlib/openssl (repo rule, see `whats-to-test.sh` header).
- Script exit statuses are never masked; a failed call must not read as an empty result (`docs/learnings/masked-exit-status-fails-open.md`).
- Session log retention: keep the last **3** logs, cap each at **1 MB**. MetricKit retention: last **10** payload files.
- Tee failure must never block gameplay; export with nothing captured still produces a zip with `info.txt`.
- Conventional commits (`feat(...)`, `fix(ui):`, `docs(...)`). No AI attribution lines in commits or PRs.
- Work lands via PRs, never directly on `main`. Never edit or delete a test to make it pass.
- After adding Swift files, run `mise run generate` (XcodeGen snapshots the file list; new files are invisible to the project until regeneration).
- Never run two `xcodebuild` test sessions against one simulator at once. Test destination: `platform=iOS Simulator,name=iPhone 17 Pro`. `RealWADTests` failures without fixtures are expected (see `docs/learnings/simulator-test-hazards.md`).
- iOS deployment target is 26.0 — no availability guards needed for any API used here.

---

## Slice 1 — branch `tylervick/testflight-feedback-puller`

### Task 1: TestFlight feedback puller script

**Files:**
- Create: `Scripts/fetch-testflight-feedback.sh`
- Create: `Scripts/test-fetch-testflight-feedback.sh`
- Modify: `.gitignore` (add the state file)

**Interfaces:**
- Consumes: `Scripts/asc-jwt.sh` (prints one JWT; overridable via `ASC_JWT` env var — same seam `whats-to-test.sh` uses).
- Produces: `Scripts/fetch-testflight-feedback.sh [--download DIR]` — prints new feedback submissions as markdown to stdout; exit 0 with "No new feedback." when there is nothing new; non-zero on any API/parse failure. Seen-submission ids accumulate in `$FEEDBACK_STATE` (default: `<repo>/.testflight-feedback-seen`), one id per line, appended **only after** all output for this run has been printed.

- [ ] **Step 1: Write the failing test script**

Create `Scripts/test-fetch-testflight-feedback.sh` (mode 755). It is hermetic: curl is stubbed via a fake binary on `PATH`, the JWT via a fake `ASC_JWT`. The stub routes by URL substring and logs each URL it serves so assertions can check what was requested.

```bash
#!/bin/bash
# Tests for Scripts/fetch-testflight-feedback.sh.
#
# HERMETIC: curl is a stub on PATH routing canned fixtures by URL; the JWT
# comes from a fake ASC_JWT. Nothing here contacts App Store Connect.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# --- fixtures ---------------------------------------------------------------
mkdir -p "$TMP/bin" "$TMP/fixtures"

cat > "$TMP/fixtures/apps.json" <<'JSON'
{"data":[{"type":"apps","id":"APP123","attributes":{"bundleId":"com.tylervick.waddle"}}]}
JSON

cat > "$TMP/fixtures/screenshots.json" <<'JSON'
{"data":[
  {"type":"betaFeedbackScreenshotSubmissions","id":"shot-1",
   "attributes":{"createdDate":"2026-08-12T01:02:03Z","comment":"Fire button drifts",
     "deviceModel":"iPhone17,1","osVersion":"26.0",
     "screenshotImages":[{"url":"https://example.invalid/shot-1.png"}]}},
  {"type":"betaFeedbackScreenshotSubmissions","id":"shot-2",
   "attributes":{"createdDate":"2026-08-11T09:00:00Z","comment":"Love it",
     "deviceModel":"iPad16,3","osVersion":"26.0","screenshotImages":[]}}
]}
JSON

cat > "$TMP/fixtures/crashes.json" <<'JSON'
{"data":[
  {"type":"betaFeedbackCrashSubmissions","id":"crash-1",
   "attributes":{"createdDate":"2026-08-12T05:06:07Z","comment":"Died loading my WAD",
     "deviceModel":"iPhone17,1","osVersion":"26.0.1"}}
]}
JSON

# curl stub: routes by URL substring, appends each URL to curl.log. `-o FILE`
# (used by --download for screenshot images) writes a marker file instead of
# printing to stdout.
cat > "$TMP/bin/curl" <<STUB
#!/bin/bash
url=""; out=""
prev=""
for a in "\$@"; do
    case "\$prev" in -o) out="\$a" ;; esac
    case "\$a" in https://*|http://*) url="\$a" ;; esac
    prev="\$a"
done
echo "\$url" >> "$TMP/curl.log"
if [ -f "$TMP/fail-marker" ]; then exit 22; fi
body=""
case "\$url" in
    *"/v1/apps"*)                                 body="\$(cat "$TMP/fixtures/apps.json")" ;;
    *betaFeedbackScreenshotSubmissions*)          body="\$(cat "$TMP/fixtures/screenshots.json")" ;;
    *betaFeedbackCrashSubmissions*)               body="\$(cat "$TMP/fixtures/crashes.json")" ;;
    *example.invalid*)                            body="PNGBYTES" ;;
    *) exit 22 ;;
esac
if [ -n "\$out" ]; then printf '%s' "\$body" > "\$out"; else printf '%s' "\$body"; fi
STUB
chmod +x "$TMP/bin/curl"

cat > "$TMP/bin/fake-jwt" <<'STUB'
#!/bin/bash
echo "fake.jwt.token"
STUB
chmod +x "$TMP/bin/fake-jwt"

run_fetch() { # extra args...
    env PATH="$TMP/bin:$PATH" ASC_JWT="$TMP/bin/fake-jwt" \
        FEEDBACK_STATE="$TMP/state" \
        "$ROOT/Scripts/fetch-testflight-feedback.sh" "$@"
}

# 1. First run prints every submission as markdown, newest info intact.
out="$(run_fetch)" || fail "first run exited non-zero: $out"
echo "$out" | grep -q "shot-1" || fail "missing shot-1; got: $out"
echo "$out" | grep -q "Fire button drifts" || fail "missing shot-1 comment; got: $out"
echo "$out" | grep -q "iPhone17,1" || fail "missing device model; got: $out"
echo "$out" | grep -q "shot-2" || fail "missing shot-2; got: $out"
echo "$out" | grep -q "crash-1" || fail "missing crash-1; got: $out"
echo "$out" | grep -q "Died loading my WAD" || fail "missing crash comment; got: $out"
pass "prints screenshot and crash submissions as markdown"

# 2. All three ids are now in the state file.
for id in shot-1 shot-2 crash-1; do
    grep -qx "$id" "$TMP/state" || fail "state file missing $id"
done
pass "records seen ids in the state file"

# 3. Second run prints nothing new.
out="$(run_fetch)" || fail "second run exited non-zero: $out"
echo "$out" | grep -qi "no new feedback" || fail "second run should say no new feedback; got: $out"
echo "$out" | grep -q "shot-1" && fail "second run re-printed shot-1"
pass "a second run reports nothing new"

# 4. A failed API call exits non-zero and does NOT update the state file.
rm -f "$TMP/state"
touch "$TMP/fail-marker"
if out="$(run_fetch 2>&1)"; then
    fail "succeeded despite curl failing: $out"
fi
[ ! -s "$TMP/state" ] || fail "state file was written on a failed run"
rm -f "$TMP/fail-marker"
pass "a failed API call exits non-zero and leaves the state file alone"

# 5. Malformed JSON exits non-zero.
printf 'not json' > "$TMP/fixtures/screenshots.json"
rm -f "$TMP/state"
if out="$(run_fetch 2>&1)"; then
    fail "succeeded despite malformed JSON: $out"
fi
pass "malformed JSON is a failure, not an empty result"
# restore fixture for the next case
cat > "$TMP/fixtures/screenshots.json" <<'JSON'
{"data":[{"type":"betaFeedbackScreenshotSubmissions","id":"shot-1",
 "attributes":{"createdDate":"2026-08-12T01:02:03Z","comment":"Fire button drifts",
   "deviceModel":"iPhone17,1","osVersion":"26.0",
   "screenshotImages":[{"url":"https://example.invalid/shot-1.png"}]}}]}
JSON

# 6. --download DIR saves each new submission's JSON and fetches image URLs.
rm -f "$TMP/state"
mkdir -p "$TMP/dl"
out="$(run_fetch --download "$TMP/dl")" || fail "--download run failed: $out"
[ -f "$TMP/dl/shot-1.json" ] || fail "shot-1.json not saved"
[ -f "$TMP/dl/crash-1.json" ] || fail "crash-1.json not saved"
ls "$TMP/dl"/shot-1*.png >/dev/null 2>&1 || fail "screenshot image not downloaded"
pass "--download saves submission JSON and screenshot images"

echo "All fetch-testflight-feedback tests passed."
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `Scripts/test-fetch-testflight-feedback.sh`
Expected: FAIL — `fetch-testflight-feedback.sh` does not exist yet.

- [ ] **Step 3: Implement the script**

Create `Scripts/fetch-testflight-feedback.sh` (mode 755). Mirrors `whats-to-test.sh` conventions: `api_get` tests curl's status directly, python3 stdlib for JSON, no new dependencies. Field extraction is tolerant — Apple's beta-feedback resources are new and their exact attribute set may drift, so absent fields print as `-` rather than failing.

```bash
#!/bin/bash
# Prints NEW TestFlight beta feedback (screenshot + crash submissions) as
# markdown, tracking already-seen submission ids in a state file so each run
# shows only what arrived since the last one.
#
# Usage:
#   Scripts/fetch-testflight-feedback.sh                 print new feedback
#   Scripts/fetch-testflight-feedback.sh --download DIR  also save each new
#       submission's raw JSON to DIR/<id>.json and download any screenshot
#       images to DIR/<id>-<n>.png
#
# Env:
#   ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH   for Scripts/asc-jwt.sh
#   ASC_JWT          override the JWT minter (tests use this)
#   FEEDBACK_STATE   override the state file (default: <repo>/.testflight-feedback-seen)
#
# The state file is APPENDED ONLY AFTER all output for the run has been
# printed: a failed run must leave it untouched so the next run re-surfaces
# the same submissions instead of silently swallowing them. Same discipline
# as docs/learnings/masked-exit-status-fails-open.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

API="https://api.appstoreconnect.apple.com"
BUNDLE_ID="com.tylervick.waddle"
ASC_JWT="${ASC_JWT:-$ROOT/Scripts/asc-jwt.sh}"
STATE_FILE="${FEEDBACK_STATE:-$ROOT/.testflight-feedback-seen}"

DOWNLOAD_DIR=""
if [ "${1:-}" = "--download" ]; then
    DOWNLOAD_DIR="${2:?usage: $0 [--download DIR]}"
    mkdir -p "$DOWNLOAD_DIR"
elif [ -n "${1:-}" ]; then
    echo "usage: $0 [--download DIR]" >&2; exit 2
fi

TOKEN="$("$ASC_JWT")" \
  || { echo "error: could not mint an App Store Connect API token" >&2; exit 1; }
if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::add-mask::$TOKEN"; fi

api_get() { # path -- status tested directly, never masked
    curl -sS -f -H "Authorization: Bearer $TOKEN" "$API$1"
}

# Resolve the app id from the bundle id (same two-step as whats-to-test.sh:
# curl status first, parse second, so a failed call never reads as empty).
APPS_RESP="$(api_get "/v1/apps?filter%5BbundleId%5D=$BUNDLE_ID")" \
  || { echo "error: could not resolve the app id for $BUNDLE_ID" >&2; exit 1; }
APP_ID="$(printf '%s' "$APPS_RESP" | python3 -c '
import json, sys
items = json.load(sys.stdin).get("data") or []
if not items: sys.exit(3)
print(items[0]["id"])
')" || { echo "error: no app matching $BUNDLE_ID (or unparseable response)" >&2; exit 1; }

SHOTS_RESP="$(api_get "/v1/betaFeedbackScreenshotSubmissions?filter%5Bapp%5D=$APP_ID&sort=-createdDate&limit=50")" \
  || { echo "error: could not fetch screenshot feedback" >&2; exit 1; }
CRASH_RESP="$(api_get "/v1/betaFeedbackCrashSubmissions?filter%5Bapp%5D=$APP_ID&sort=-createdDate&limit=50")" \
  || { echo "error: could not fetch crash feedback" >&2; exit 1; }

[ -f "$STATE_FILE" ] || : > "$STATE_FILE"

# One python pass renders the markdown for every UNSEEN submission, writes
# per-submission JSON into DOWNLOAD_DIR when set, emits the list of image
# URLs to fetch on fd 3, and the list of newly-seen ids on fd 4. Ids only
# reach the state file after this whole pipeline has succeeded.
RENDER_OUT="$(mktemp)"; URLS_OUT="$(mktemp)"; IDS_OUT="$(mktemp)"
trap 'rm -f "$RENDER_OUT" "$URLS_OUT" "$IDS_OUT"' EXIT

SHOTS_JSON="$SHOTS_RESP" CRASH_JSON="$CRASH_RESP" \
STATE_PATH="$STATE_FILE" DL_DIR="$DOWNLOAD_DIR" \
python3 - 3>"$URLS_OUT" 4>"$IDS_OUT" >"$RENDER_OUT" <<'PY'
import json, os, sys

seen = set()
with open(os.environ["STATE_PATH"]) as f:
    seen = {line.strip() for line in f if line.strip()}

dl_dir = os.environ.get("DL_DIR") or None
urls = os.fdopen(3, "w")
ids = os.fdopen(4, "w")

def field(attrs, name):
    v = attrs.get(name)
    return str(v) if v not in (None, "") else "-"

def render(kind, doc):
    try:
        items = json.loads(doc).get("data") or []
    except json.JSONDecodeError:
        sys.exit(f"error: unparseable {kind} response")
    for item in items:
        sid = item.get("id", "")
        if not sid or sid in seen:
            continue
        attrs = item.get("attributes") or {}
        print(f"## {kind} {sid}")
        print(f"- created: {field(attrs, 'createdDate')}")
        print(f"- device: {field(attrs, 'deviceModel')} ({field(attrs, 'osVersion')})")
        print(f"- comment: {field(attrs, 'comment')}")
        print()
        if dl_dir:
            with open(os.path.join(dl_dir, f"{sid}.json"), "w") as f:
                json.dump(item, f, indent=2)
            images = attrs.get("screenshotImages") or []
            for n, img in enumerate(images, 1):
                url = (img or {}).get("url")
                if url:
                    urls.write(f"{dl_dir}/{sid}-{n}.png\t{url}\n")
        ids.write(sid + "\n")

render("Screenshot feedback", os.environ["SHOTS_JSON"])
render("Crash feedback", os.environ["CRASH_JSON"])
PY

if [ -s "$RENDER_OUT" ]; then
    cat "$RENDER_OUT"
else
    echo "No new feedback."
fi

# Screenshot downloads: the image URLs are pre-signed and need no auth header.
while IFS=$'\t' read -r dest url; do
    [ -n "$dest" ] || continue
    curl -sS -f -o "$dest" "$url" \
      || { echo "error: could not download $url" >&2; exit 1; }
done < "$URLS_OUT"

# Everything succeeded -- only now do the new ids become "seen".
cat "$IDS_OUT" >> "$STATE_FILE"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `Scripts/test-fetch-testflight-feedback.sh`
Expected: all `ok - ...` lines, ending `All fetch-testflight-feedback tests passed.`

- [ ] **Step 5: Ignore the state file and commit**

Append to `.gitignore`:

```
.testflight-feedback-seen
```

```bash
git add Scripts/fetch-testflight-feedback.sh Scripts/test-fetch-testflight-feedback.sh .gitignore
git commit -m "feat(scripts): pull new TestFlight beta feedback from App Store Connect"
```

- [ ] **Step 6: Live smoke test (manual, optional but recommended)**

With the real `ASC_KEY_ID`/`ASC_ISSUER_ID`/`ASC_KEY_PATH` exported (see the TestFlight upload procedure), run `Scripts/fetch-testflight-feedback.sh` once. If Apple's real attribute names differ from the fixtures (the beta-feedback resources are new), adjust the fixture JSON **and** the `render` field names together in a follow-up commit — the tolerant `field()` accessor means a mismatch shows up as `-` values, not a crash.

- [ ] **Step 7: Push and open the Slice 1 PR**

```bash
git push -u origin tylervick/testflight-feedback-puller
gh pr create --title "feat(scripts): TestFlight feedback puller" --body "..."
```

PR body: what the script does, the state-file semantics, and the manual ASC step (test information text telling testers to screenshot in-app) which is done in App Store Connect, not in the repo.

---

## Slice 2 — branch `tylervick/diagnostics-export`

### Task 2: DiagnosticsPaths + SessionLogCapture (the fd tee)

**Files:**
- Create: `App/Sources/Diagnostics/DiagnosticsPaths.swift`
- Create: `App/Sources/Diagnostics/SessionLogCapture.swift`
- Test: `App/Tests/SessionLogCaptureTests.swift`

**Interfaces:**
- Produces:
  - `enum DiagnosticsPaths { static var directory: URL }` — `Application Support/Diagnostics`, created on demand by callers.
  - `final class SessionLogCapture` with:
    - `init(directory: URL, maxFileBytes: Int = 1_000_000, maxFiles: Int = 3, targetFDs: [Int32] = [STDOUT_FILENO, STDERR_FILENO])`
    - `func begin(name: String) throws` — rotates old logs, creates `session-<name>.log`, redirects each target fd through a pipe whose reader thread writes to both the original destination and the log file.
    - `func end()` — restores the fds, drains and joins the reader threads. Safe to call when not begun.
    - `static func sessionLogs(in directory: URL) -> [URL]` — `session-*.log` sorted oldest-first by modification date.
  - Later tasks rely on: log files named `session-*.log` inside `DiagnosticsPaths.directory`.

- [ ] **Step 1: Write the failing tests**

Create `App/Tests/SessionLogCaptureTests.swift`. Tests never touch real stdout/stderr — they pass their own file-backed fds as `targetFDs`, so XCTest output is never redirected.

```swift
import XCTest
@testable import WADdle

final class SessionLogCaptureTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Opens a file-backed fd the capture can dup2 over, standing in for
    /// stdout. Returns the fd and the file backing the "original" stream.
    private func makeTargetFD() throws -> (fd: Int32, original: URL) {
        let url = tmp.appendingPathComponent("original-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let fd = open(url.path, O_WRONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        return (fd, url)
    }

    private func writeAll(_ string: String, to fd: Int32) {
        let bytes = Array(string.utf8)
        bytes.withUnsafeBufferPointer { buf in
            var offset = 0
            while offset < buf.count {
                let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                XCTAssertGreaterThan(n, 0)
                offset += n
            }
        }
    }

    func testTeesWritesToBothLogFileAndOriginalDestination() throws {
        let (fd, original) = try makeTargetFD()
        defer { close(fd) }
        let capture = SessionLogCapture(directory: tmp, targetFDs: [fd])

        try capture.begin(name: "t1")
        writeAll("P_SetupLevel: E1M1\n", to: fd)
        capture.end()

        let log = tmp.appendingPathComponent("session-t1.log")
        let logText = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(logText.contains("P_SetupLevel: E1M1"))
        let originalText = try String(contentsOf: original, encoding: .utf8)
        XCTAssertTrue(originalText.contains("P_SetupLevel: E1M1"),
                      "pass-through to the original destination must keep working")
    }

    func testEndRestoresTheOriginalDescriptor() throws {
        let (fd, original) = try makeTargetFD()
        defer { close(fd) }
        let capture = SessionLogCapture(directory: tmp, targetFDs: [fd])

        try capture.begin(name: "t2")
        capture.end()
        writeAll("after-end\n", to: fd)

        let logText = try String(contentsOf: tmp.appendingPathComponent("session-t2.log"),
                                 encoding: .utf8)
        XCTAssertFalse(logText.contains("after-end"),
                       "writes after end() must not reach the log")
        let originalText = try String(contentsOf: original, encoding: .utf8)
        XCTAssertTrue(originalText.contains("after-end"))
    }

    func testLogFileStopsAtByteCapButPassThroughContinues() throws {
        let (fd, original) = try makeTargetFD()
        defer { close(fd) }
        let capture = SessionLogCapture(directory: tmp, maxFileBytes: 100, targetFDs: [fd])

        try capture.begin(name: "t3")
        writeAll(String(repeating: "a", count: 300), to: fd)
        capture.end()

        let logSize = try FileManager.default
            .attributesOfItem(atPath: tmp.appendingPathComponent("session-t3.log").path)[.size] as! Int
        XCTAssertLessThanOrEqual(logSize, 100 + 64,
            "log may overshoot by at most one read chunk boundary, never unbounded")
        let originalSize = try FileManager.default
            .attributesOfItem(atPath: original.path)[.size] as! Int
        XCTAssertEqual(originalSize, 300, "pass-through must not be capped")
    }

    func testRotationKeepsAtMostMaxFilesLogs() throws {
        let (fd, _) = try makeTargetFD()
        defer { close(fd) }
        let capture = SessionLogCapture(directory: tmp, maxFiles: 3, targetFDs: [fd])

        for name in ["r1", "r2", "r3", "r4"] {
            try capture.begin(name: name)
            writeAll("session \(name)\n", to: fd)
            capture.end()
        }

        let logs = SessionLogCapture.sessionLogs(in: tmp).map { $0.lastPathComponent }
        XCTAssertEqual(logs.count, 3)
        XCTAssertFalse(logs.contains("session-r1.log"), "oldest log must be rotated out")
        XCTAssertTrue(logs.contains("session-r4.log"))
    }

    func testEndWithoutBeginIsANoOp() {
        let capture = SessionLogCapture(directory: tmp)
        capture.end() // must not crash or hang
    }
}
```

- [ ] **Step 2: Regenerate the project and run the tests to verify they fail**

```bash
mise run generate
xcodebuild -project App/WADdle.xcodeproj -scheme WADdle \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  test -only-testing:WADdleTests/SessionLogCaptureTests
```

Expected: build FAILS — `SessionLogCapture` unresolved. (Test files are globbed from `App/Tests` by XcodeGen; regeneration is what makes the new file visible.)

- [ ] **Step 3: Implement DiagnosticsPaths and SessionLogCapture**

Create `App/Sources/Diagnostics/DiagnosticsPaths.swift`:

```swift
import Foundation

/// Where all diagnostics artifacts live. Application Support (not Documents):
/// Documents is user-visible via the Files app and doubles as the WAD adoption
/// inbox, so internal logs there would surface in the user's file browser and
/// risk being swept by the adoption pass.
enum DiagnosticsPaths {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }
}
```

Create `App/Sources/Diagnostics/SessionLogCapture.swift`:

```swift
import Foundation

/// Tees writes made to a set of file descriptors (stdout/stderr in
/// production -- the in-process Woof engine prints its console there) into a
/// per-session log file, while passing every byte through to the original
/// destination so Xcode's console keeps working. begin/end brackets one
/// engine session.
final class SessionLogCapture {
    let directory: URL
    let maxFileBytes: Int
    let maxFiles: Int
    private let targetFDs: [Int32]

    private var savedFDs: [Int32: Int32] = [:]   // target fd -> dup of original
    private var pipeWriteFDs: [Int32] = []
    private var readerThreads: [Thread] = []
    private let logLock = NSLock()
    private var logFD: Int32 = -1
    private var logBytesWritten = 0
    private var active = false

    init(directory: URL, maxFileBytes: Int = 1_000_000, maxFiles: Int = 3,
         targetFDs: [Int32] = [STDOUT_FILENO, STDERR_FILENO]) {
        self.directory = directory
        self.maxFileBytes = maxFileBytes
        self.maxFiles = maxFiles
        self.targetFDs = targetFDs
    }

    /// `session-*.log` in `directory`, sorted oldest-first by modification
    /// date. Used by rotation here and by the exporter to bundle logs.
    static func sessionLogs(in directory: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("session-")
                   && $0.pathExtension == "log" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return da < db
            }
    }

    func begin(name: String) throws {
        guard !active else { return }
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)

        // Rotate BEFORE creating the new log: keep the newest maxFiles - 1 so
        // the new file makes exactly maxFiles.
        let existing = Self.sessionLogs(in: directory)
        if existing.count > maxFiles - 1 {
            for old in existing.prefix(existing.count - (maxFiles - 1)) {
                try? FileManager.default.removeItem(at: old)
            }
        }

        let logURL = directory.appendingPathComponent("session-\(name).log")
        logFD = open(logURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard logFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        logBytesWritten = 0

        for target in targetFDs {
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else { continue }
            let (readEnd, writeEnd) = (fds[0], fds[1])
            let saved = dup(target)
            guard saved >= 0, dup2(writeEnd, target) >= 0 else {
                close(readEnd); close(writeEnd)
                if saved >= 0 { close(saved) }
                continue
            }
            close(writeEnd) // target now IS the write end; drop our extra ref
            savedFDs[target] = saved

            let thread = Thread { [weak self] in
                self?.pump(from: readEnd, passThroughTo: saved)
            }
            thread.name = "SessionLogCapture fd \(target)"
            thread.start()
            readerThreads.append(thread)
        }
        active = true
    }

    func end() {
        guard active else { return }
        // Restoring the original fd over the pipe's write end closes the
        // process's last reference to it, so each pump loop sees EOF and
        // exits after draining whatever is still buffered.
        for (target, saved) in savedFDs {
            dup2(saved, target)
            close(saved)
        }
        savedFDs.removeAll()
        // Wait for the pumps to drain (bounded: EOF is already in flight).
        while readerThreads.contains(where: { !$0.isFinished }) {
            usleep(1_000)
        }
        readerThreads.removeAll()
        logLock.lock()
        if logFD >= 0 { close(logFD); logFD = -1 }
        logLock.unlock()
        active = false
    }

    private func pump(from readEnd: Int32, passThroughTo original: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(readEnd, &buffer, buffer.count)
            guard n > 0 else { break }
            buffer.withUnsafeBytes { raw in
                // Pass through first -- the console must never lose bytes
                // even if the log write fails or the cap has been hit.
                var offset = 0
                while offset < n {
                    let written = write(original, raw.baseAddress! + offset,
                                        n - offset)
                    if written <= 0 { break }
                    offset += written
                }
                logLock.lock()
                if logFD >= 0 && logBytesWritten < maxFileBytes {
                    let allowed = min(n, maxFileBytes - logBytesWritten)
                    let writtenToLog = write(logFD, raw.baseAddress!, allowed)
                    if writtenToLog > 0 { logBytesWritten += writtenToLog }
                }
                logLock.unlock()
            }
        }
        close(readEnd)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Same `xcodebuild ... -only-testing:WADdleTests/SessionLogCaptureTests` command as Step 2.
Expected: all 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Diagnostics App/Tests/SessionLogCaptureTests.swift
git commit -m "feat(diagnostics): capture engine session console output to rotating logs"
```

### Task 3: Wire the tee into EngineSession

**Files:**
- Modify: `App/Sources/EngineSession.swift` (inside `play(arguments:scheme:)`, around the existing `isRunning = true` block at lines 91–96)
- Test: `App/Tests/EngineSessionGenerationTests.swift` (extend)

**Interfaces:**
- Consumes: `SessionLogCapture(directory:)`, `begin(name:)`, `end()`, `DiagnosticsPaths.directory` from Task 2.
- Produces: `EngineSession.sessionLogCapture` — a `static let` shared capture instance over `DiagnosticsPaths.directory`, so tests and the exporter agree on the location.

- [ ] **Step 1: Write the failing test**

Add to `App/Tests/EngineSessionGenerationTests.swift` (it is `@MainActor` and already imports XCTest + `@testable import WADdle`; match its style):

```swift
func testSessionLogCaptureUsesTheDiagnosticsDirectory() {
    XCTAssertEqual(EngineSession.sessionLogCapture.directory,
                   DiagnosticsPaths.directory)
}
```

(The begin/end pairing around `WoofIOS_Run` cannot be exercised without booting a real engine — the reentrancy/argument guards return before any capture. This test pins the wiring's one testable fact; the tee mechanics are covered by Task 2's tests.)

- [ ] **Step 2: Run to verify it fails**

```bash
xcodebuild -project App/WADdle.xcodeproj -scheme WADdle \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  test -only-testing:WADdleTests/EngineSessionGenerationTests
```

Expected: build FAILS — `sessionLogCapture` not defined.

- [ ] **Step 3: Implement the wiring**

In `App/Sources/EngineSession.swift`, add inside `enum EngineSession`:

```swift
/// Shared capture over the app's diagnostics directory. One session log per
/// engine run; the exporter bundles whatever this leaves behind.
static let sessionLogCapture = SessionLogCapture(directory: DiagnosticsPaths.directory)
```

Then in `play(arguments:scheme:)`, extend the existing `isRunning = true` / `defer` block (keep ordering: capture ends before the overlay teardown is irrelevant, but it must end after the engine returns):

```swift
isRunning = true
// Session log names are wall-clock timestamps, not the generation counter:
// the counter restarts at 1 every launch, so generation-named files would
// overwrite the previous launch's logs -- exactly the ones a crash report
// needs. Failure to start capture never blocks gameplay (spec).
let logStamp = ISO8601DateFormatter().string(from: .now)
    .replacingOccurrences(of: ":", with: "-")
try? sessionLogCapture.begin(name: logStamp)
OverlayPresenter.shared.begin(scheme: scheme)
defer {
    OverlayPresenter.shared.end()
    sessionLogCapture.end()
    isRunning = false
}
```

- [ ] **Step 4: Run to verify it passes**

Same command as Step 2. Expected: PASS (including the pre-existing generation tests).

- [ ] **Step 5: Commit**

```bash
git add App/Sources/EngineSession.swift App/Tests/EngineSessionGenerationTests.swift
git commit -m "feat(diagnostics): tee engine console output during play sessions"
```

### Task 4: MetricKit payload store + subscriber

**Files:**
- Create: `App/Sources/Diagnostics/DiagnosticsStore.swift`
- Modify: `App/Sources/WADdleApp.swift` (register the subscriber in `init()`)
- Test: `App/Tests/DiagnosticsStoreTests.swift`

**Interfaces:**
- Consumes: `DiagnosticsPaths.directory`.
- Produces:
  - `final class DiagnosticsStore` with `init(directory: URL, maxPayloads: Int = 10)`, `@discardableResult func savePayloadData(_ data: Data, receivedAt date: Date) throws -> URL`, and `static func payloadFiles(in directory: URL) -> [URL]` (`metrickit-*.json`, oldest-first by name).
  - `final class DiagnosticsMetricSubscriber: NSObject, MXMetricManagerSubscriber` with `static let shared`, registered via `MXMetricManager.shared.add(...)`.
  - Later tasks rely on: payload files named `metrickit-*.json` inside `DiagnosticsPaths.directory`.

- [ ] **Step 1: Write the failing tests**

Create `App/Tests/DiagnosticsStoreTests.swift`:

```swift
import XCTest
@testable import WADdle

final class DiagnosticsStoreTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testSavesPayloadDataAsTimestampedJSONFile() throws {
        let store = DiagnosticsStore(directory: tmp)
        let date = Date(timeIntervalSince1970: 1_770_000_000)
        let url = try store.savePayloadData(Data("{\"crash\":true}".utf8), receivedAt: date)

        XCTAssertTrue(url.lastPathComponent.hasPrefix("metrickit-"))
        XCTAssertEqual(url.pathExtension, "json")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{\"crash\":true}")
    }

    func testTwoPayloadsAtTheSameInstantGetDistinctFiles() throws {
        let store = DiagnosticsStore(directory: tmp)
        let date = Date(timeIntervalSince1970: 1_770_000_000)
        let a = try store.savePayloadData(Data("a".utf8), receivedAt: date)
        let b = try store.savePayloadData(Data("b".utf8), receivedAt: date)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(DiagnosticsStore.payloadFiles(in: tmp).count, 2)
    }

    func testRetentionKeepsAtMostMaxPayloads() throws {
        let store = DiagnosticsStore(directory: tmp, maxPayloads: 3)
        for i in 0..<5 {
            try store.savePayloadData(Data("p\(i)".utf8),
                receivedAt: Date(timeIntervalSince1970: Double(1_770_000_000 + i)))
        }
        let files = DiagnosticsStore.payloadFiles(in: tmp)
        XCTAssertEqual(files.count, 3)
        let contents = try files.map { try String(contentsOf: $0, encoding: .utf8) }
        XCTAssertFalse(contents.contains("p0"), "oldest payloads must be pruned")
        XCTAssertTrue(contents.contains("p4"))
    }
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
mise run generate
xcodebuild -project App/WADdle.xcodeproj -scheme WADdle \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  test -only-testing:WADdleTests/DiagnosticsStoreTests
```

Expected: build FAILS — `DiagnosticsStore` unresolved.

- [ ] **Step 3: Implement the store and subscriber**

Create `App/Sources/Diagnostics/DiagnosticsStore.swift`:

```swift
import Foundation
import MetricKit

/// Persists MetricKit diagnostic payloads (crashes, hangs, disk-write
/// exceptions) as raw JSON files. No processing, no symbolication, and --
/// per the privacy policy -- absolutely no upload: files sit here until the
/// user exports them or retention prunes them.
final class DiagnosticsStore {
    let directory: URL
    let maxPayloads: Int

    init(directory: URL, maxPayloads: Int = 10) {
        self.directory = directory
        self.maxPayloads = maxPayloads
    }

    /// `metrickit-*.json` sorted oldest-first. The timestamp is embedded in
    /// the name, so lexical order IS chronological order.
    static func payloadFiles(in directory: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("metrickit-")
                   && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @discardableResult
    func savePayloadData(_ data: Data, receivedAt date: Date) throws -> URL {
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: date)
            .replacingOccurrences(of: ":", with: "-")
        // UUID suffix: several payloads can arrive in one delivery batch with
        // the same receipt date, and each must land in its own file.
        let name = "metrickit-\(stamp)-\(UUID().uuidString.prefix(8)).json"
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)

        let files = Self.payloadFiles(in: directory)
        if files.count > maxPayloads {
            for old in files.prefix(files.count - maxPayloads) {
                try? FileManager.default.removeItem(at: old)
            }
        }
        return url
    }
}

/// The app's one MetricKit subscriber. MXMetricManager holds subscribers
/// weakly, so the static `shared` reference is what keeps it alive.
final class DiagnosticsMetricSubscriber: NSObject, MXMetricManagerSubscriber {
    static let shared = DiagnosticsMetricSubscriber(
        store: DiagnosticsStore(directory: DiagnosticsPaths.directory))

    private let store: DiagnosticsStore

    init(store: DiagnosticsStore) {
        self.store = store
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            // Best-effort: a full disk must not turn a crash report into a
            // second crash.
            try? store.savePayloadData(payload.jsonRepresentation(),
                                       receivedAt: Date())
        }
    }
}
```

In `App/Sources/WADdleApp.swift`, add `import MetricKit` at the top and register at the end of `init()` (after the `do/catch` block, last line of `init`):

```swift
MXMetricManager.shared.add(DiagnosticsMetricSubscriber.shared)
```

- [ ] **Step 4: Run to verify they pass**

Same command as Step 2. Expected: all 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Diagnostics/DiagnosticsStore.swift App/Sources/WADdleApp.swift \
        App/Tests/DiagnosticsStoreTests.swift
git commit -m "feat(diagnostics): persist MetricKit crash and hang payloads locally"
```

### Task 5: DiagnosticsExporter

**Files:**
- Create: `App/Sources/Diagnostics/DiagnosticsExporter.swift`
- Test: `App/Tests/DiagnosticsExporterTests.swift`

**Interfaces:**
- Consumes: `SessionLogCapture.sessionLogs(in:)` (Task 2), `DiagnosticsStore.payloadFiles(in:)` (Task 4), `BuildInfo`, ZIPFoundation's `FileManager.zipItem(at:to:)`.
- Produces:
  - `enum DiagnosticsExporter` with:
    - `static func export(diagnosticsDirectory: URL, libraryLines: [String]) throws -> URL` — returns a `WADdle-diagnostics.zip` in a fresh temp directory containing `info.txt`, all session logs, and all MetricKit payloads.
    - `static func infoText(libraryLines: [String]) -> String` — the `info.txt` body (separately testable).

- [ ] **Step 1: Write the failing tests**

Create `App/Tests/DiagnosticsExporterTests.swift`:

```swift
import XCTest
import ZIPFoundation
@testable import WADdle

final class DiagnosticsExporterTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagexport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func zipEntryNames(_ zipURL: URL) throws -> Set<String> {
        let archive = try Archive(url: zipURL, accessMode: .read)
        return Set(archive.map { ($0.path as NSString).lastPathComponent })
    }

    func testInfoTextCarriesBuildAndLibraryFacts() {
        let text = DiagnosticsExporter.infoText(libraryLines: ["wad: freedoom1.wad",
                                                               "loadout: Nuts"])
        XCTAssertTrue(text.contains(BuildInfo.commit))
        XCTAssertTrue(text.contains("wad: freedoom1.wad"))
        XCTAssertTrue(text.contains("loadout: Nuts"))
        XCTAssertTrue(text.contains("iOS"), "must name the OS version")
    }

    func testExportBundlesLogsPayloadsAndInfo() throws {
        try Data("engine says hi".utf8)
            .write(to: tmp.appendingPathComponent("session-a.log"))
        try Data("{}".utf8)
            .write(to: tmp.appendingPathComponent("metrickit-2026-b.json"))

        let zip = try DiagnosticsExporter.export(diagnosticsDirectory: tmp,
                                                 libraryLines: [])
        let names = try zipEntryNames(zip)
        XCTAssertTrue(names.contains("info.txt"))
        XCTAssertTrue(names.contains("session-a.log"))
        XCTAssertTrue(names.contains("metrickit-2026-b.json"))
    }

    func testExportWithEmptyDiagnosticsStillProducesInfoOnlyZip() throws {
        let empty = tmp.appendingPathComponent("empty", isDirectory: true)
        // Deliberately never created: the directory may not exist on a fresh
        // install that has never run a session. Export must still succeed.
        let zip = try DiagnosticsExporter.export(diagnosticsDirectory: empty,
                                                 libraryLines: [])
        XCTAssertEqual(try zipEntryNames(zip), ["info.txt"])
    }

    func testExportNeverIncludesWADFiles() throws {
        try Data("IWAD....".utf8).write(to: tmp.appendingPathComponent("stray.wad"))
        let zip = try DiagnosticsExporter.export(diagnosticsDirectory: tmp,
                                                 libraryLines: [])
        XCTAssertFalse(try zipEntryNames(zip).contains("stray.wad"),
            "only session logs, payloads, and info.txt may be bundled")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
mise run generate
xcodebuild -project App/WADdle.xcodeproj -scheme WADdle \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  test -only-testing:WADdleTests/DiagnosticsExporterTests
```

Expected: build FAILS — `DiagnosticsExporter` unresolved.

- [ ] **Step 3: Implement the exporter**

Create `App/Sources/Diagnostics/DiagnosticsExporter.swift`:

```swift
import Foundation
import ZIPFoundation

/// Assembles the user-facing diagnostics zip. Pure local file assembly --
/// the result goes nowhere until the user hands it to the share sheet.
enum DiagnosticsExporter {
    /// Builds WADdle-diagnostics.zip in a fresh temp directory and returns
    /// its URL. Always succeeds down to at least an info.txt-only zip, so
    /// the share flow works even on a fresh install with nothing captured.
    static func export(diagnosticsDirectory: URL, libraryLines: [String]) throws -> URL {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-export-\(UUID().uuidString)",
                                    isDirectory: true)
        let payload = staging.appendingPathComponent("WADdle-diagnostics",
                                                     isDirectory: true)
        try FileManager.default.createDirectory(at: payload,
                                                withIntermediateDirectories: true)

        try infoText(libraryLines: libraryLines)
            .write(to: payload.appendingPathComponent("info.txt"),
                   atomically: true, encoding: .utf8)

        // Allowlist copy, not a directory copy: anything else that ever ends
        // up in the diagnostics directory (or a stray WAD) must not ship.
        let bundled = SessionLogCapture.sessionLogs(in: diagnosticsDirectory)
            + DiagnosticsStore.payloadFiles(in: diagnosticsDirectory)
        for file in bundled {
            try? FileManager.default.copyItem(
                at: file,
                to: payload.appendingPathComponent(file.lastPathComponent))
        }

        let zipURL = staging.appendingPathComponent("WADdle-diagnostics.zip")
        try FileManager.default.zipItem(at: payload, to: zipURL,
                                        shouldKeepParent: false)
        return zipURL
    }

    static func infoText(libraryLines: [String]) -> String {
        var model = utsname()
        uname(&model)
        let device = withUnsafeBytes(of: &model.machine) { buf in
            String(decoding: buf.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let bundle = Bundle.main
        let version = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let buildNumber = bundle.object(
            forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

        var lines = [
            "WADdle diagnostics",
            "generated: \(ISO8601DateFormatter().string(from: .now))",
            "",
            "app version: \(version) (\(buildNumber))",
            "commit: \(BuildInfo.commit) (\(BuildInfo.branch))",
            "built at: \(BuildInfo.builtAt)",
            "iOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "device: \(device)",
            "",
            "library (names only; WAD contents are never exported):",
        ]
        lines += libraryLines.isEmpty ? ["(empty)"] : libraryLines
        return lines.joined(separator: "\n") + "\n"
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Same command as Step 2. Expected: all 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Diagnostics/DiagnosticsExporter.swift \
        App/Tests/DiagnosticsExporterTests.swift
git commit -m "feat(diagnostics): assemble shareable diagnostics zip with info.txt"
```

### Task 6: AboutView UI, PRIVACY.md, full suite, PR

**Files:**
- Modify: `App/Sources/UI/AboutView.swift` (new Diagnostics section; takes `library`)
- Modify: `App/Sources/UI/PlayView.swift:70` (`AboutView()` → `AboutView(library: library)`)
- Modify: `PRIVACY.md`
- Test: `App/Tests/DiagnosticsExporterTests.swift` (extend with the library-lines builder test)

**Interfaces:**
- Consumes: `DiagnosticsExporter.export(diagnosticsDirectory:libraryLines:)`, `DiagnosticsPaths.directory`, `LibraryService.allWADs()` / `allLoadouts()` (existing; `WADFile.filename`, `Loadout.name`).
- Produces: `DiagnosticsExporter.libraryLines(from: LibraryService?) -> [String]` — the bridge between SwiftData and the exporter, kept on the exporter so it is unit-testable without view scaffolding.

- [ ] **Step 1: Write the failing test for the library-lines builder**

Append to `App/Tests/DiagnosticsExporterTests.swift` (this test needs SwiftData scaffolding; copy the in-memory `ModelContainer` + `LibraryService` setup used at the top of `App/Tests/LibraryServiceTests.swift` verbatim, including its `@MainActor`/async-setUp pattern, into a new `@MainActor final class DiagnosticsLibraryLinesTests: XCTestCase`):

```swift
func testLibraryLinesNameWADsAndLoadoutsOnly() throws {
    try service.registerImported(filename: "gothic.wad", sha1: "abc123",
                                 kind: "pwad")
    let lines = DiagnosticsExporter.libraryLines(from: service)
    XCTAssertTrue(lines.contains { $0.contains("gothic.wad") })
    XCTAssertFalse(lines.joined().contains("abc123"),
        "hashes and paths stay out; names only")
}

func testLibraryLinesWithNilServiceIsEmpty() {
    XCTAssertEqual(DiagnosticsExporter.libraryLines(from: nil), [])
}
```

(Check `registerImported`'s full signature in `LibraryService.swift:223` when writing this — it takes more parameters; fill them the way `LibraryServiceTests` does.)

- [ ] **Step 2: Run to verify it fails**

```bash
xcodebuild -project App/WADdle.xcodeproj -scheme WADdle \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  test -only-testing:WADdleTests/DiagnosticsLibraryLinesTests
```

Expected: build FAILS — `libraryLines(from:)` not defined.

- [ ] **Step 3: Implement the builder and the UI**

Add to `DiagnosticsExporter`:

```swift
/// Names-only library summary for info.txt. Best-effort: a SwiftData read
/// failure yields fewer lines, never a failed export.
@MainActor
static func libraryLines(from library: LibraryService?) -> [String] {
    guard let library else { return [] }
    let wads = ((try? library.allWADs()) ?? []).map { "wad: \($0.filename)" }
    let loadouts = ((try? library.allLoadouts()) ?? []).map { "loadout: \($0.name)" }
    return wads + loadouts
}
```

(If `WADFile`'s property is not `filename`, read `App/Sources/Models/WADFile.swift` and use its actual stored-name property.)

In `App/Sources/UI/AboutView.swift`, add the dependency and the section:

```swift
struct AboutView: View {
    let library: LibraryService?
    private let sourceURL = URL(string: "https://github.com/tylervick/waddle")!

    /// URL is not Identifiable; the sheet needs an item that is.
    private struct ExportedZip: Identifiable {
        let url: URL
        var id: URL { url }
    }
    @State private var exportedZip: ExportedZip?
    @State private var exportError: String?
```

New section after "Open source" (before "Licenses"):

```swift
Section("Diagnostics") {
    Button("Export Diagnostics") { exportDiagnostics() }
        .accessibilityIdentifier("exportDiagnosticsButton")
    Text("Bundles recent engine session logs and crash reports. Nothing leaves your device unless you share this file.")
        .font(.footnote)
}
```

Modifiers on the `List` (alongside the existing `.navigationTitle`):

```swift
.sheet(item: $exportedZip) { zip in
    ShareSheet(items: [zip.url])
}
.alert("Export failed", isPresented: .init(
    get: { exportError != nil },
    set: { if !$0 { exportError = nil } }
)) {
    Button("OK", role: .cancel) {}
} message: {
    Text(exportError ?? "")
}
```

Private method and the representable (bottom of the file):

```swift
private func exportDiagnostics() {
    do {
        let url = try DiagnosticsExporter.export(
            diagnosticsDirectory: DiagnosticsPaths.directory,
            libraryLines: DiagnosticsExporter.libraryLines(from: library))
        exportedZip = ExportedZip(url: url)
    } catch {
        exportError = error.localizedDescription
    }
}
```

```swift
/// UIActivityViewController wrapper: ShareLink wants its item up front, but
/// the zip is assembled on tap, so the sheet is presented item-driven.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController,
                                context: Context) {}
}
```

In `App/Sources/UI/PlayView.swift:70`:

```swift
.sheet(isPresented: $showAbout) {
    NavigationStack { AboutView(library: library) }
}
```

- [ ] **Step 4: Run the new tests, then verify the UI builds**

```bash
xcodebuild -project App/WADdle.xcodeproj -scheme WADdle \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  test -only-testing:WADdleTests/DiagnosticsLibraryLinesTests
```

Expected: PASS.

- [ ] **Step 5: Amend PRIVACY.md**

Change the network bullet to state the one user-initiated exception:

```markdown
- The app makes no network connections on its own. The only data that can
  leave your device is the diagnostics file you explicitly export and share
  from the About screen — and it goes only where you send it.
```

Keep the rest of the file as is (the "no analytics, no tracking, no
third-party SDKs that phone home" bullet remains true).

- [ ] **Step 6: Run the full suite**

```bash
mise run test
```

Expected: green, except `RealWADTests` failures if the fixtures from `docs/learnings/simulator-test-hazards.md` are absent (expected, not a regression). Do not run any other xcodebuild session concurrently.

- [ ] **Step 7: Commit, push, open the Slice 2 PR**

```bash
git add App/Sources/UI/AboutView.swift App/Sources/UI/PlayView.swift \
        App/Sources/Diagnostics/DiagnosticsExporter.swift \
        App/Tests/DiagnosticsExporterTests.swift PRIVACY.md
git commit -m "feat(ui): export diagnostics from the About screen"
git push -u origin tylervick/diagnostics-export
gh pr create --title "feat(diagnostics): on-device session logs, crash payloads, and export" --body "..."
```

PR body: the three components, retention numbers, the privacy-policy amendment, and a note that MetricKit payload delivery cannot be demonstrated on the simulator (Apple delivers diagnostics on device, typically at most once per day — the store is unit-tested with synthesized data instead).

- [ ] **Step 8: Learnings check**

If the fd tee hit any simulator- or device-specific trap (fds behaving differently under the simulator, SDL touching stdout, XCTest interference), add `docs/learnings/<topic>.md` plus an `INDEX.md` line **in the same PR**, per house rules.
