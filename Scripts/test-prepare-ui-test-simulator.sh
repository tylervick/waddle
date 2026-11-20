#!/bin/bash
# Tests for Scripts/prepare-ui-test-simulator.sh.
#
# Fully HERMETIC: stubs `xcrun`, `sysctl`, `date` and `sleep` on a controlled
# PATH. Never boots or queries a real simulator. The stub `sleep` records what
# it was asked for and takes a tenth of a second, which is what lets the
# script's two background log readers land between looks.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

IMMEDIATE='2026-11-19 00:06:25.388 Df PosterBoard[1:2] [com.apple.PosterBoard:DataStore] Gallery controller requested snapshot prewarm for role: PRPosterRoleLockScreen (reason: PBFPowerLogReasonExtensionsUpdated)'
CALLING='2026-11-19 00:06:25.800 Df PosterBoard[1:2] [com.apple.PosterBoard:DataStore] Calling prewarmSnapshotsForRequests with 184 requests'
DONE='2026-11-19 00:08:04.655 Df PosterBoard[1:2] [com.apple.PosterBoard:DataStore] Successfully prewarmed gallery snapshots for role: PRPosterRoleLockScreen'
DEFERRED='2026-11-20 01:45:12.069 E  PosterBoard[1:2] [com.apple.PosterBoard:DataStore] Gallery controller requested snapshot prewarm for role PRPosterRoleLockScreen, but prewarm has not run and uptime 392s is within 600s boot window; deferring to -prewarm:'

# A fixture is a directory: bin/ holds the stubs, and these files steer them.
#   uptime        host uptime in seconds (the stub date says "now" is 2000000000)
#   stream.<n>    lines the log stream delivers during the n-th poll sleep
#   stream.dies   if present, the log stream exits at once with a failure
#   backfill      what the one `log show` from boot prints; the single word
#                 FAIL makes that query fail
#   boot.status   exit status of `simctl bootstatus` (default 0)
make_fixture() { # dest uptime
    mkdir -p "$1/bin"
    echo "$2" > "$1/uptime"
    : > "$1/calls"
    cat > "$1/bin/xcrun" <<'STUB'
#!/bin/bash
F="$(cd "$(dirname "$0")/.." && pwd)"
echo "xcrun $*" >> "$F/calls"
if [ "$1 $2" = "simctl list" ]; then
cat <<'LIST'
== Devices ==
-- iOS 26.3 --
    iPhone 18 Pro (OLD00000-0000-0000-0000-000000000000) (Shutdown)
-- iOS 27.0 --
    iPhone 18 (CCCC1111-2222-3333-4444-555566667777) (Shutdown)
    iPhone 18 Pro (AAAA1111-2222-3333-4444-555566667777) (Shutdown)
    iPad Pro 13-inch (M5) (DDDD1111-2222-3333-4444-555566667777) (Shutdown)
LIST
exit 0
fi
if [ "$1 $2" = "simctl bootstatus" ] && [ "$4" = "-b" ]; then
    echo "Monitoring boot status for $3."
    if [ -f "$F/boot.status" ]; then exit "$(cat "$F/boot.status")"; fi
    exit 0
fi
if [ "$1 $2 $4 $5" = "simctl spawn log stream" ]; then
    if [ -f "$F/stream.dies" ]; then echo "log: stream failed" >&2; exit 1; fi
    exec /bin/sleep 20
fi
if [ "$1 $2 $4 $5" = "simctl spawn log show" ]; then
    if [ ! -f "$F/backfill" ]; then exit 0; fi
    if [ "$(cat "$F/backfill")" = "FAIL" ]; then echo "log: could not open local log store" >&2; exit 1; fi
    cat "$F/backfill"
    exit 0
fi
echo "stub xcrun: unhandled args: $*" >&2
exit 64
STUB
    cat > "$1/bin/sysctl" <<'STUB'
#!/bin/bash
F="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$*" = "-n kern.boottime" ]; then
    if [ -f "$F/boottime" ]; then cat "$F/boottime"; exit 0; fi
    echo "{ sec = $(( 2000000000 - $(cat "$F/uptime") )), usec = 0 } Tue May 18 03:33:20 2033"
    exit 0
fi
if [ "$*" = "-n vm.loadavg" ]; then echo "{ 1.00 1.00 1.00 }"; exit 0; fi
echo "stub sysctl: unhandled args: $*" >&2
exit 64
STUB
    cat > "$1/bin/date" <<'STUB'
#!/bin/bash
if [ "$*" = "+%s" ]; then echo 2000000000; exit 0; fi
exec /bin/date "$@"
STUB
    cat > "$1/bin/sleep" <<'STUB'
#!/bin/bash
F="$(cd "$(dirname "$0")/.." && pwd)"
echo "sleep $*" >> "$F/calls"
if [ "$1" = 10 ]; then
    n=$(( $(cat "$F/polls" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$F/polls"
    if [ -f "$F/stream.$n" ]; then cat "$F/stream.$n" >> "$F/work/stream.txt"; fi
    /bin/sleep 0.1
fi
STUB
    chmod +x "$1/bin/xcrun" "$1/bin/sysctl" "$1/bin/date" "$1/bin/sleep"
}

prepare() { # dir device os
    env PATH="$1/bin:/usr/bin:/bin" GITHUB_OUTPUT="$1/github_output" \
        SIMULATOR_READY_TIMEOUT=50 SIMULATOR_READY_POLL=10 \
        SIMULATOR_READY_WORK_DIR="$1/work" \
        "$ROOT/Scripts/prepare-ui-test-simulator.sh" "$2" "$3"
}

# 1. The whole happy path: a host already past the boot window boots at once,
#    sees the renders start, then finish, and says SETTLED. Also pins the UDID:
#    the 27.0 device, not the same name under 26.3 and not "iPhone 18".
make_fixture "$TMP/a" 700
printf '%s\n%s\n' "$IMMEDIATE" "$CALLING" > "$TMP/a/stream.1"
printf '%s\n' "$DONE" > "$TMP/a/stream.2"
out="$(prepare "$TMP/a" "iPhone 18 Pro" 27.0)" || fail "exited non-zero on the happy path: $out"
echo "$out" | grep -q "WADDLE_SIMULATOR_SETTLED" || fail "no SETTLED marker; got: $out"
[ "$(cat "$TMP/a/polls")" = 2 ] || fail "expected to settle on the third look, after 2 poll sleeps; made $(cat "$TMP/a/polls")"
echo "$out" | grep -q "rendering the gallery (184 requests)" || fail "did not announce the render; got: $out"
grep -q "^udid=AAAA1111-2222-3333-4444-555566667777$" "$TMP/a/github_output" || fail "wrong or missing udid output: $(cat "$TMP/a/github_output")"
grep -q "^xcrun simctl bootstatus AAAA1111-2222-3333-4444-555566667777 -b$" "$TMP/a/calls" || fail "did not boot the matched device"
if grep -q "^sleep [0-9][0-9][0-9]" "$TMP/a/calls"; then fail "waited for the boot window on a host already past it"; fi
if echo "$out" | grep -q "Monitoring boot status"; then fail "printed bootstatus's narration on a successful boot"; fi
pass "boots at once past the boot window and reports SETTLED when the renders finish"

# 2. Inside the boot window: waits out exactly the remainder BEFORE booting.
#    Booting first is the whole bug -- the gallery then arrives inside the
#    window and PosterBoard defers the renders into the test session.
make_fixture "$TMP/b" 230
printf '%s\n%s\n' "$IMMEDIATE" "$DONE" > "$TMP/b/stream.1"
out="$(prepare "$TMP/b" "iPhone 18 Pro" 27.0)" || fail "exited non-zero inside the boot window: $out"
echo "$out" | grep -q "waiting 370s before booting" || fail "did not announce the 370 s wait; got: $out"
[ "$(grep -m1 -E '^(sleep 370|xcrun simctl bootstatus)' "$TMP/b/calls")" = "sleep 370" ] \
    || fail "booted before waiting out the boot window: $(cat "$TMP/b/calls")"
echo "$out" | grep -q "WADDLE_SIMULATOR_SETTLED" || fail "no SETTLED marker; got: $out"
pass "waits out the rest of the boot window before it boots"

# 3. PosterBoard deferred anyway: NOT settled, exit 0, and the reason plus its
#    own line are in the warning. Calling this SETTLED would label an exposed
#    run as a protected one, which is the one thing the marker exists to tell.
make_fixture "$TMP/c" 700
printf '%s\n' "$DEFERRED" > "$TMP/c/stream.1"
out="$(prepare "$TMP/c" "iPhone 18 Pro" 27.0)" || fail "a deferral must not fail the run: $out"
echo "$out" | grep -q "::warning::WADDLE_SIMULATOR_NOT_SETTLED reason=deferred" || fail "no deferred warning; got: $out"
echo "$out" | grep -q "uptime 392s is within 600s boot window" || fail "warning does not quote PosterBoard's line; got: $out"
if echo "$out" | grep -q "WADDLE_SIMULATOR_SETTLED"; then fail "reported SETTLED for a deferred render"; fi
pass "reports NOT_SETTLED reason=deferred, with PosterBoard's line, and does not fail the run"

# 4. The line never comes: NOT settled by timeout after TIMEOUT/POLL looks,
#    exit 0, naming both readers as healthy. Pins that the wait is bounded and
#    that it does not end early.
make_fixture "$TMP/d" 700
printf '%s\n%s\n' "$IMMEDIATE" "$CALLING" > "$TMP/d/stream.1"
out="$(prepare "$TMP/d" "iPhone 18 Pro" 27.0)" || fail "a timeout must not fail the run: $out"
echo "$out" | grep -q "::warning::WADDLE_SIMULATOR_NOT_SETTLED reason=timeout" || fail "no timeout warning; got: $out"
echo "$out" | grep -q "log stream running, log show from boot ok" || fail "did not report the readers' state; got: $out"
[ "$(cat "$TMP/d/polls")" = 5 ] || fail "expected 5 looks at the log (50 s / 10 s), made $(cat "$TMP/d/polls")"
pass "gives up after the bounded wait with NOT_SETTLED reason=timeout"

# 5. Both readers dead is not a quiet simulator: the run still ends
#    NOT_SETTLED, and the warning says the silence was the readers'.
make_fixture "$TMP/e" 700
: > "$TMP/e/stream.dies"
echo FAIL > "$TMP/e/backfill"
out="$(prepare "$TMP/e" "iPhone 18 Pro" 27.0)" || fail "dead log readers must not fail the run: $out"
echo "$out" | grep -q "reason=timeout" || fail "no timeout warning; got: $out"
echo "$out" | grep -q "log stream exited, log show from boot failed" || fail "did not say the readers died; got: $out"
pass "says so when the silence is the log readers' and not the simulator's"

# 5b. A line written BEFORE the stream attached reaches the wait through the
#     one `log show` from boot. Without that reader a gallery that arrives
#     during the boot would be waited on until the timeout.
make_fixture "$TMP/e2" 700
printf '%s\n%s\n%s\n' "$IMMEDIATE" "$CALLING" "$DONE" > "$TMP/e2/backfill"
out="$(prepare "$TMP/e2" "iPhone 18 Pro" 27.0)" || fail "exited non-zero: $out"
echo "$out" | grep -q "WADDLE_SIMULATOR_SETTLED" || fail "a line from before the stream attached was missed; got: $out"
pass "sees a line written before the stream attached"

# 5c. The stream alone is enough when the `log show` fails.
make_fixture "$TMP/e3" 700
echo FAIL > "$TMP/e3/backfill"
printf '%s\n%s\n' "$IMMEDIATE" "$DONE" > "$TMP/e3/stream.1"
out="$(prepare "$TMP/e3" "iPhone 18 Pro" 27.0)" || fail "exited non-zero: $out"
echo "$out" | grep -q "WADDLE_SIMULATOR_SETTLED" || fail "a failed log show stopped it settling; got: $out"
pass "settles from the stream when the log show fails"

# 6. No such device: exit 1, and nothing is booted.
make_fixture "$TMP/f" 700
if prepare "$TMP/f" "iPhone 17 Pro" 27.0 >"$TMP/out6" 2>&1; then fail "accepted a device that is not listed"; fi
grep -q "no available simulator named 'iPhone 17 Pro' on iOS 27.0" "$TMP/out6" || fail "wrong message: $(cat "$TMP/out6")"
if grep -q "bootstatus" "$TMP/f/calls"; then fail "booted something although the device was not found"; fi
pass "refuses a device that is not listed, without booting anything"

# 6b. A parenthesised device name resolves to its own UDID.
make_fixture "$TMP/f2" 700
printf '%s\n%s\n' "$IMMEDIATE" "$DONE" > "$TMP/f2/stream.1"
prepare "$TMP/f2" "iPad Pro 13-inch (M5)" 27.0 >/dev/null || fail "did not resolve a parenthesised device name"
grep -q "^udid=DDDD1111" "$TMP/f2/github_output" || fail "wrong udid for the iPad: $(cat "$TMP/f2/github_output")"
pass "resolves a device whose own name has parentheses"

# 7. The simulator does not boot: exit 1, with bootstatus's own output. A test
#    session against it would fail every launch and read as the diff's fault.
make_fixture "$TMP/g" 700
echo 149 > "$TMP/g/boot.status"
if prepare "$TMP/g" "iPhone 18 Pro" 27.0 >"$TMP/out7" 2>&1; then fail "carried on although the simulator did not boot"; fi
grep -q "did not boot" "$TMP/out7" || fail "wrong message: $(cat "$TMP/out7")"
grep -q "Monitoring boot status" "$TMP/out7" || fail "hid bootstatus's output on a failed boot: $(cat "$TMP/out7")"
pass "fails when the simulator does not boot"

# 8. kern.boottime in a shape it cannot parse: exit 1 before booting, not a
#    silent "uptime is huge, boot now", which is the deferral this prevents.
make_fixture "$TMP/h" 700
echo "garbage" > "$TMP/h/boottime"
if prepare "$TMP/h" "iPhone 18 Pro" 27.0 >"$TMP/out8" 2>&1; then fail "carried on without a readable boot time"; fi
grep -q "could not parse kern.boottime" "$TMP/out8" || fail "wrong message: $(cat "$TMP/out8")"
if grep -q "bootstatus" "$TMP/h/calls"; then fail "booted although the boot time was unreadable"; fi
pass "fails closed when the host's boot time cannot be parsed"

echo "All prepare-ui-test-simulator tests passed."
