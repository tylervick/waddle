#!/bin/bash
# Tests for Scripts/ui-test-launch-report.sh.
#
# Fully HERMETIC: stubs `xcrun` and `log` on a controlled PATH and feeds them
# log lines in the shape the simulator and xcodebuild write. Never touches a
# real simulator, log archive or result bundle.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# A fixture directory steers the stubs:
#   poster.txt, launches.txt   what `log show` prints for each predicate
#   session.log                the session log `xcresulttool export` produces
#   collect.status             exit status of every `log collect` (default 0)
#   collect.fails.once         the first `log collect` fails as on a shut-down device
make_fixture() { # dest
    mkdir -p "$1/bin" "$1/bundle.xcresult"
    cat > "$1/bin/xcrun" <<'STUB'
#!/bin/bash
F="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$1 $2 $4 $5 $6" = "simctl spawn log collect --output" ]; then
    if [ -f "$F/collect.status" ]; then echo "log: collect failed"; exit "$(cat "$F/collect.status")"; fi
    if [ -f "$F/collect.fails.once" ]; then rm "$F/collect.fails.once"; echo "Process spawn via launchd failed because device is not booted."; exit 149; fi
    mkdir -p "$7"
    exit 0
fi
if [ "$1 $2 $4" = "simctl bootstatus -b" ]; then echo "booted $3" >> "$F/boots"; exit 0; fi
if [ "$1 $2 $3 $4" = "xcresulttool export diagnostics --path" ] && [ "$6" = "--output-path" ]; then
    if [ ! -f "$F/session.log" ]; then echo "no diagnostics"; exit 1; fi
    mkdir -p "$7/0_Test/WaddleUITests"
    cp "$F/session.log" "$7/0_Test/WaddleUITests/Session-WaddleUITests-2026-11-19_000334-6ttLo5.log"
    exit 0
fi
echo "stub xcrun: unhandled args: $*" >&2
exit 64
STUB
    cat > "$1/bin/log" <<'STUB'
#!/bin/bash
F="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$1 $2 $4 $5 $6" = "show --archive --style compact --predicate" ]; then
    echo "Timestamp               Ty Process[PID:TID]"
    case "$7" in
        *PosterBoard*)  if [ -f "$F/poster.txt" ]; then cat "$F/poster.txt"; fi ;;
        *testmanagerd*) if [ -f "$F/launches.txt" ]; then cat "$F/launches.txt"; fi ;;
        *) echo "stub log: unknown predicate: $7" >&2; exit 64 ;;
    esac
    exit 0
fi
echo "stub log: unhandled args: $*" >&2
exit 64
STUB
    chmod +x "$1/bin/xcrun" "$1/bin/log"
}

report() { # dir
    env PATH="$1/bin:/usr/bin:/bin" \
        "$ROOT/Scripts/ui-test-launch-report.sh" UDID-1 "$1/bundle.xcresult" "$1/out"
}

tracked() { # date time pid
    echo "$1 $2 Df runningboardd[17675:d1f3] [com.apple.runningboard:process] Now tracking process: [app<com.tylervick.waddle((null))>:$3]"
}
update() { # date time pid
    echo "$1 $2 Df testmanagerd[17714:d0a7] [com.apple.dt.xctest:Default] <XCTDProcessMonitor: 0x1060a5080> passing update com.tylervick.waddle@/x/Waddle.app pid: $3 state: running foreground to Optional(<XCTDProcessMonitor>)"
}

# 1. The #396 shape: three launches, one reported 82.8 s late. The late one
#    must be named SLOW with its pid and lag, and must not vanish into a
#    median that looks healthy.
#    Pid 300 has a second update 2.7 s after its first; only the first
#    counts, or the median below would read 3.0 s.
make_fixture "$TMP/a"
{
    tracked 2026-11-20 02:01:00.000 100; update 2026-11-20 02:01:00.100 100
    tracked 2026-11-20 02:03:37.740 35785
    tracked 2026-11-20 02:06:27.000 300; update 2026-11-20 02:06:27.300 300
    update 2026-11-20 02:05:00.540 35785
    update 2026-11-20 02:06:30.000 300
} | sort > "$TMP/a/launches.txt"
cat > "$TMP/a/poster.txt" <<'EOF2'
2026-11-20 02:02:51.644 Df PosterBoard[4296:16c73] [com.apple.PosterBoard:Prewarm] Starting prewarm...
2026-11-20 02:05:10.469 Df PosterBoard[4296:16c73] [com.apple.PosterBoard:Prewarm] (096E016/prewarm) Prewarm is complete; executed in 137.519488 seconds
EOF2
cat > "$TMP/a/session.log" <<'EOF2'
00:05:55.844 xcodebuild[15229:51375] 0A1B: Launched app with identifier: com.tylervick.WaddleUITests.xctrunner (pid = 18252)
00:07:24.818 xcodebuild[15229:41869] Test runner session received application launch request: <XCTProcessLaunchParameters: 0x1> bundleID: com.tylervick.waddle
00:08:17.574 xcodebuild[15229:41869] Stored token 1 for launch of com.tylervick.waddle at /x/Waddle.app
00:08:49.079 xcodebuild[15229:51838] 0A1B: Launched app with identifier: com.tylervick.waddle (pid = 19388)
00:09:31.295 xcodebuild[15229:41869] Test runner session received application launch request: <XCTProcessLaunchParameters: 0x2> bundleID: com.tylervick.waddle
EOF2
out="$(report "$TMP/a")" || fail "exited non-zero: $out"
echo "$out" | grep -q "launches tracked: 3  with an update: 3  median lag 0.3 s  worst 82.8 s" || fail "wrong lag summary; got: $out"
echo "$out" | grep -q "SLOW  pid 35785 tracked 02:03:37.740  lag 82.8 s" || fail "late launch not named; got: $out"
if echo "$out" | grep -q "no launch lagged"; then fail "claimed no slow launch beside a slow one"; fi
echo "$out" | grep -q "02:02:51.644  Starting prewarm..." || fail "prewarm line missing or untrimmed; got: $out"
echo "$out" | grep -q "requested 00:07:24.818  launch issued after 52.8 s  launched 31.5 s later" || fail "wrong first-launch line; got: $out"
[ -d "$TMP/a/out/simulator.logarchive" ] || fail "archive not left for upload"
[ ! -d "$TMP/a/out/diagnostics" ] || fail "exported diagnostics left behind"
pass "names the late launch, prints the prewarm lines and times the first launch"

# 2. A healthy run says so in words, so its log can be grepped for the claim.
make_fixture "$TMP/b"
{
    tracked 2026-11-20 02:01:00.000 100; update 2026-11-20 02:01:00.100 100
    tracked 2026-11-20 02:02:00.000 200; update 2026-11-20 02:02:00.700 200
} > "$TMP/b/launches.txt"
out="$(report "$TMP/b")" || fail "exited non-zero: $out"
echo "$out" | grep -q "with an update: 2  median lag 0.1 s  worst 0.7 s" || fail "wrong summary; got: $out"
echo "$out" | grep -q "no launch lagged more than 10 s" || fail "healthy run not stated; got: $out"
echo "$out" | grep -q "(no lines)" || fail "empty PosterBoard section not marked; got: $out"
echo "$out" | grep -q "could not export diagnostics" || fail "missing session log not reported; got: $out"
pass "states a healthy run in words and survives a bundle with no session log"

# 3. A launch the runner was never told about is listed, not dropped: that is
#    a launch still waiting when the log was collected.
make_fixture "$TMP/c"
{
    tracked 2026-11-20 02:01:00.000 100; update 2026-11-20 02:01:00.100 100
    tracked 2026-11-20 02:02:00.000 200
} > "$TMP/c/launches.txt"
out="$(report "$TMP/c")" || fail "exited non-zero: $out"
echo "$out" | grep -q "launches tracked: 2  with an update: 1" || fail "wrong counts; got: $out"
echo "$out" | grep -q "NEVER pid 200 tracked 02:02:00.000" || fail "unreported launch dropped; got: $out"
pass "lists a launch that never got its update"

# 4. A lag that crosses midnight is 0.5 s, not minus a day.
make_fixture "$TMP/d"
{ tracked 2026-11-19 23:59:59.800 100; update 2026-11-20 00:00:00.300 100; } > "$TMP/d/launches.txt"
out="$(report "$TMP/d")" || fail "exited non-zero: $out"
echo "$out" | grep -q "median lag 0.5 s  worst 0.5 s" || fail "midnight lag wrong; got: $out"
pass "measures a lag across midnight"

# 5. The log cannot be collected: non-zero, with what simctl said. Printing
#    "no launch lagged" over an archive that does not exist would be a
#    measurement nobody made.
make_fixture "$TMP/e"
echo 1 > "$TMP/e/collect.status"
if report "$TMP/e" >"$TMP/out5" 2>&1; then fail "reported on a log it could not collect"; fi
grep -q "could not collect the simulator log" "$TMP/out5" || fail "wrong message: $(cat "$TMP/out5")"
if grep -q "no launch lagged" "$TMP/out5"; then fail "printed a verdict without a log"; fi
pass "fails, with simctl's words, when the log cannot be collected"

# 6. The device was shut down when the run ended (xcodebuild does that to a
#    device it booted itself; run 44786994189 lost its log this way). The log
#    store is on disk: boot once more, collect, and report as usual.
make_fixture "$TMP/f"
: > "$TMP/f/collect.fails.once"
{ tracked 2026-11-20 02:01:00.000 100; update 2026-11-20 02:01:00.100 100; } > "$TMP/f/launches.txt"
out="$(report "$TMP/f")" || fail "gave up on a shut-down device: $out"
echo "$out" | grep -q "booting it to read its log" || fail "did not say it booted the device; got: $out"
grep -q "^booted UDID-1$" "$TMP/f/boots" || fail "did not boot the device"
echo "$out" | grep -q "launches tracked: 1  with an update: 1" || fail "no report after the second collect; got: $out"
pass "boots a shut-down device to read its log"

echo "All ui-test-launch-report tests passed."
