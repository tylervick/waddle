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
FAILED='2026-11-20 18:04:50.919 Df PosterBoard[1:2] [com.apple.PosterBoard:DataStore] Failed to prewarm gallery snapshots for role PRPosterRoleLockScreen: exceeded prewarm time; invalidating runtime assertion.'
DEFERRED='2026-11-20 01:45:12.069 E  PosterBoard[1:2] [com.apple.PosterBoard:DataStore] Gallery controller requested snapshot prewarm for role PRPosterRoleLockScreen, but prewarm has not run and uptime 392s is within 600s boot window; deferring to -prewarm:'

# A fixture is a directory: bin/ holds the stubs, and these files steer them.
#   uptime        host uptime in seconds when the script starts. The stub
#                 clock starts at 2000000000 and moves only when the stub
#                 `sleep` is called, by what it was asked to sleep.
#   clock.tick    if present, every reading of the clock also moves it on by
#                 this many seconds: time spent working, not sleeping
#   stream.<n>    lines the log stream delivers during the n-th poll sleep
#   stream.dies   if present, the log stream exits at once with a failure
#   stream.dies.once  the same, for the first stream only
#   state.<n>     what the n-th `simctl list devices` says the device's state
#                 is (default Booted)
#   backfill      what every `log show` from boot prints; the single word
#                 FAIL makes the query fail
#   backfill.<n>  the same for the n-th pass only
#   state.all     the device's state on every `simctl list devices`
#   backfill.slow if present, that `log show` runs for 23 s instead
#   boot.status   exit status of `simctl bootstatus` (default 0)
make_fixture() { # dest uptime
    mkdir -p "$1/bin"
    echo "$2" > "$1/uptime"
    : > "$1/calls"
    cat > "$1/bin/xcrun" <<'STUB'
#!/bin/bash
F="$(cd "$(dirname "$0")/.." && pwd)"
echo "xcrun $*" >> "$F/calls"
if [ "$*" = "simctl list devices" ]; then
    n=$(( $(cat "$F/statecalls" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$F/statecalls"
    state=Booted
    if [ -f "$F/state.all" ]; then state="$(cat "$F/state.all")"; fi
    if [ -f "$F/state.$n" ]; then state="$(cat "$F/state.$n")"; fi
    echo "-- iOS 27.0 --"
    echo "    iPhone 18 Pro (AAAA1111-2222-3333-4444-555566667777) ($state)"
    exit 0
fi
if [ "$*" = "simctl list devices available" ]; then
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
    if [ -f "$F/stream.dies.once" ]; then rm "$F/stream.dies.once"; echo "log: stream failed" >&2; exit 1; fi
    # What the real tool prints first, on stdout: the predicate, and with it
    # every string the script searches for. A stub without this line is how
    # a wait that matched its own search string passed fifteen cases.
    echo 'Filtering the log data using "process == "PosterBoard" AND (composedMessage CONTAINS "requested snapshot prewarm" OR composedMessage CONTAINS "Calling prewarmSnapshotsForRequests" OR composedMessage CONTAINS "Successfully prewarmed gallery snapshots" OR composedMessage CONTAINS "Failed to prewarm gallery snapshots")"'
    exec /bin/sleep 20
fi
if [ "$1 $2 $4 $5" = "simctl spawn log show" ]; then
    if [ -f "$F/backfill.slow" ]; then exec /bin/sleep 23; fi
    n=$(( $(cat "$F/passes" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$F/passes"
    f="$F/backfill.$n"
    if [ ! -f "$f" ]; then f="$F/backfill"; fi
    echo "Timestamp               Ty Process[PID:TID]"
    if [ ! -f "$f" ]; then exit 0; fi
    if [ "$(cat "$f")" = "FAIL" ]; then echo "log: could not open local log store" >&2; exit 1; fi
    cat "$f"
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
F="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$*" = "+%s" ]; then
    now=$(( $(cat "$F/clock" 2>/dev/null || echo 0) + $(cat "$F/clock.tick" 2>/dev/null || echo 0) ))
    echo "$now" > "$F/clock"
    echo $(( 2000000000 + now ))
    exit 0
fi
exec /bin/date "$@"
STUB
    cat > "$1/bin/sleep" <<'STUB'
#!/bin/bash
F="$(cd "$(dirname "$0")/.." && pwd)"
echo "sleep $*" >> "$F/calls"
echo $(( $(cat "$F/clock" 2>/dev/null || echo 0) + $1 )) > "$F/clock"
if [ "$1" = 10 ]; then
    n=$(( $(cat "$F/polls" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$F/polls"
    if [ -f "$F/stream.$n" ]; then cat "$F/stream.$n" >> "$F/work/stream.txt"; fi
    /bin/sleep 0.1
fi
STUB
    chmod +x "$1/bin/xcrun" "$1/bin/sysctl" "$1/bin/date" "$1/bin/sleep"
}

prepare() { # dir device os [timeout]
    env PATH="$1/bin:/usr/bin:/bin" GITHUB_OUTPUT="$1/github_output" \
        SIMULATOR_READY_TIMEOUT="${4:-50}" SIMULATOR_READY_POLL=10 \
        SIMULATOR_READY_WORK_DIR="$1/work" \
        "$ROOT/Scripts/prepare-ui-test-simulator.sh" "$2" "$3"
}

# 0. THE DEFECT THIS SUITE MISSED. `log stream` echoes its predicate as its
#    first line of output, and the predicate contains "Successfully prewarmed
#    gallery snapshots". With nothing from PosterBoard at all, the wait must
#    run to its bound and say NOT_SETTLED. The first version printed SETTLED
#    here at the first look: in CI, before PosterBoard's real line in 5 of 12
#    runs, and on a fresh simulator 10 s after boot with no gallery yet.
make_fixture "$TMP/z" 700
out="$(prepare "$TMP/z" "iPhone 18 Pro" 27.0)" || fail "exited non-zero: $out"
grep -q "Filtering the log data" "$TMP/z/work/stream.txt" || fail "the stub stream did not write its header; this case would prove nothing"
if echo "$out" | grep -q "WADDLE_SIMULATOR_SETTLED"; then fail "took log stream's echo of the predicate for PosterBoard's line: $out"; fi
echo "$out" | grep -q "reason=timeout" || fail "no timeout warning; got: $out"
pass "does not take log stream's echo of its own predicate for a log line"

# 1. The whole happy path: a host already past the boot window boots at once,
#    sees the renders start, then finish, and says SETTLED. Also pins the UDID:
#    the 27.0 device, not the same name under 26.3 and not "iPhone 18".
make_fixture "$TMP/a" 700
printf '%s\n%s\n' "$IMMEDIATE" "$CALLING" > "$TMP/a/stream.1"
printf '%s\n' "$DONE" > "$TMP/a/stream.2"
out="$(prepare "$TMP/a" "iPhone 18 Pro" 27.0)" || fail "exited non-zero on the happy path: $out"
echo "$out" | grep -q "WADDLE_SIMULATOR_SETTLED" || fail "no SETTLED marker; got: $out"
echo "$out" | grep -q "rendered, seen 20s after boot" || fail "did not report the wait by the clock (two sleeps of 10 s); got: $out"
echo "$out" | grep -q "rendering the gallery (184 requests)" || fail "did not announce the render; got: $out"
echo "$out" | grep -q "PosterBoard: 2026-11-19 00:08:04.655 Successfully prewarmed gallery snapshots for role: PRPosterRoleLockScreen" || fail "the marker does not quote the line it matched; got: $out"
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

# 3b. The renders outlast PosterBoard's own limit and it gives them up with a
#     different line (runs 44786985973 and 44779943032). That ends the burst
#     as surely as the success line; waiting on for a line that will not come
#     would cost the whole timeout on every such run.
make_fixture "$TMP/c2" 700
printf '%s\n%s\n' "$IMMEDIATE" "$CALLING" > "$TMP/c2/stream.1"
printf '%s\n' "$FAILED" > "$TMP/c2/stream.2"
out="$(prepare "$TMP/c2" "iPhone 18 Pro" 27.0)" || fail "exited non-zero: $out"
echo "$out" | grep -q "WADDLE_SIMULATOR_SETTLED gallery renders ended at PosterBoard's own time limit" || fail "did not end on the give-up line; got: $out"
echo "$out" | grep -q "PosterBoard: 2026-11-20 18:04:50.919 Failed to prewarm gallery snapshots" || fail "the marker does not quote the line; got: $out"
pass "ends the wait when PosterBoard gives the renders up at its own time limit"

# 4. The line never comes: NOT settled by timeout after TIMEOUT/POLL looks,
#    exit 0, naming both readers as healthy. Pins that the wait is bounded and
#    that it does not end early.
make_fixture "$TMP/d" 700
printf '%s\n%s\n' "$IMMEDIATE" "$CALLING" > "$TMP/d/stream.1"
out="$(prepare "$TMP/d" "iPhone 18 Pro" 27.0)" || fail "a timeout must not fail the run: $out"
echo "$out" | grep -q "::warning::WADDLE_SIMULATOR_NOT_SETTLED reason=timeout" || fail "no timeout warning; got: $out"
echo "$out" | grep -q "log stream running, last log show from boot ok" || fail "did not report the readers' state; got: $out"
[ "$(cat "$TMP/d/polls")" = 5 ] || fail "expected 5 looks at the log (50 s / 10 s), made $(cat "$TMP/d/polls")"
pass "gives up after the bounded wait with NOT_SETTLED reason=timeout"

# 4b. The bound is seconds, not looks. With 25 s allowed and 10 s between
#     looks, the last sleep is the 5 s that remain, and the wait ends at 25 s.
#     Counting looks instead let a 900 s wait run to 1350 on a slow runner.
make_fixture "$TMP/d2" 700
out="$(prepare "$TMP/d2" "iPhone 18 Pro" 27.0 25)" || fail "a timeout must not fail the run: $out"
echo "$out" | grep -q "reason=timeout -- no line from PosterBoard ending the gallery renders 25s after boot" || fail "did not stop at 25 s; got: $out"
[ "$(grep -c '^sleep ' "$TMP/d2/calls")" = 3 ] && grep -q '^sleep 5$' "$TMP/d2/calls" || fail "expected sleeps of 10, 10 and 5; got: $(grep '^sleep' "$TMP/d2/calls" | tr '\n' ' ')"
pass "bounds the wait in seconds and sleeps only what remains"

# 4c. Time spent working counts against the bound too. Here every reading of
#     the clock costs 4 s, so the 25 s are used up with far fewer than 25 s of
#     sleep asked for. A bound that added up its sleeps would run long.
make_fixture "$TMP/d3" 700
echo 4 > "$TMP/d3/clock.tick"
out="$(prepare "$TMP/d3" "iPhone 18 Pro" 27.0 25)" || fail "a timeout must not fail the run: $out"
echo "$out" | grep -q "reason=timeout" || fail "no timeout warning; got: $out"
slept=0; for n in $(grep '^sleep ' "$TMP/d3/calls" | cut -d' ' -f2); do slept=$(( slept + n )); done
[ "$slept" -lt 25 ] || fail "asked for ${slept}s of sleep although the clock was also moving while it worked"
pass "counts time spent working against the bound, not only time asleep"

# 5. Both readers dead is not a quiet simulator: the run still ends
#    NOT_SETTLED, and the warning says the silence was the readers'.
make_fixture "$TMP/e" 700
: > "$TMP/e/stream.dies"
echo FAIL > "$TMP/e/backfill"
out="$(prepare "$TMP/e" "iPhone 18 Pro" 27.0)" || fail "dead log readers must not fail the run: $out"
echo "$out" | grep -q "reason=timeout" || fail "no timeout warning; got: $out"
echo "$out" | grep -q "log stream exited, last log show from boot failed" || fail "did not say the readers died; got: $out"
pass "says so when the silence is the log readers' and not the simulator's"

# 5a. The device shut down under the wait (run 44786994189: bootstatus said
#     booted, and minutes later simctl said "device is not booted"). The wait
#     must notice, boot it again and go on reading, or xcodebuild boots it
#     itself and the renders land on the first test after all.
make_fixture "$TMP/e1" 700
: > "$TMP/e1/stream.dies.once"
echo Shutdown > "$TMP/e1/state.1"
printf '%s\n%s\n' "$IMMEDIATE" "$DONE" > "$TMP/e1/stream.1"
out="$(prepare "$TMP/e1" "iPhone 18 Pro" 27.0)" || fail "exited non-zero: $out"
echo "$out" | grep -q "the simulator is 'Shutdown', not Booted" || fail "did not notice the shut-down device; got: $out"
[ "$(grep -c '^xcrun simctl bootstatus' "$TMP/e1/calls")" = 2 ] || fail "expected a second boot; calls: $(cat "$TMP/e1/calls")"
echo "$out" | grep -q "WADDLE_SIMULATOR_SETTLED.*booted again 1 time(s)" || fail "did not settle after the second boot, or did not say it booted again; got: $out"
pass "boots a device that shut down under the wait, and says so"

# 5b. A line written BEFORE the stream attached reaches the wait through the
#     one `log show` from boot. Without that reader a gallery that arrives
#     during the boot would be waited on until the timeout.
make_fixture "$TMP/e2" 700
printf '%s\n%s\n%s\n' "$IMMEDIATE" "$CALLING" "$DONE" > "$TMP/e2/backfill"
out="$(prepare "$TMP/e2" "iPhone 18 Pro" 27.0)" || fail "exited non-zero: $out"
echo "$out" | grep -q "WADDLE_SIMULATOR_SETTLED" || fail "a line from before the stream attached was missed; got: $out"
pass "sees a line written before the stream attached"

# 5b2. The stream attaches late and never sees the line (on CI it attached 2
#      to 6 minutes after boot), and the line is not yet written when the
#      first `log show` runs. Only a LATER pass of the log show can see it, so
#      the log show has to be run again when it finishes.
make_fixture "$TMP/e5" 700
: > "$TMP/e5/backfill.1"
printf '%s\n%s\n%s\n' "$IMMEDIATE" "$CALLING" "$DONE" > "$TMP/e5/backfill.3"
out="$(prepare "$TMP/e5" "iPhone 18 Pro" 27.0)" || fail "exited non-zero: $out"
echo "$out" | grep -q "WADDLE_SIMULATOR_SETTLED" || fail "a line only a later log show could see was missed; got: $out"
[ "$(cat "$TMP/e5/passes")" -ge 3 ] || fail "the log show was not run again; passes: $(cat "$TMP/e5/passes")"
pass "runs the log show again, and settles on a line only a later pass sees"

# 5e. A device that will not stay up and a stream that will not stay attached
#     end as NOT_SETTLED after two re-boots and five re-attachments, not as a
#     boot or a spawn on every look until the job's own timeout.
make_fixture "$TMP/e6" 700
: > "$TMP/e6/stream.dies"
echo Shutdown > "$TMP/e6/state.all"
out="$(prepare "$TMP/e6" "iPhone 18 Pro" 27.0)" || fail "exited non-zero: $out"
echo "$out" | grep -q "reason=timeout" || fail "no timeout warning; got: $out"
[ "$(grep -c '^xcrun simctl bootstatus' "$TMP/e6/calls")" = 3 ] || fail "expected the first boot and 2 re-boots, got $(grep -c '^xcrun simctl bootstatus' "$TMP/e6/calls")"
[ "$(grep -c 'log stream' "$TMP/e6/calls")" = 6 ] || fail "expected the first stream and 5 re-attachments, got $(grep -c 'log stream' "$TMP/e6/calls")"
echo "$out" | grep -q "simulator 'Shutdown', booted again 2 time(s)" || fail "did not report the state it gave up in; got: $out"
pass "caps the re-boots at two and the stream re-attachments at five"

# 5c. The stream alone is enough when the `log show` fails.
make_fixture "$TMP/e3" 700
echo FAIL > "$TMP/e3/backfill"
printf '%s\n%s\n' "$IMMEDIATE" "$DONE" > "$TMP/e3/stream.1"
out="$(prepare "$TMP/e3" "iPhone 18 Pro" 27.0)" || fail "exited non-zero: $out"
echo "$out" | grep -q "WADDLE_SIMULATOR_SETTLED" || fail "a failed log show stopped it settling; got: $out"
pass "settles from the stream when the log show fails"

# 5d. A `log show` still running when the wait ends is stopped with it. It is
#     the child of a subshell, which a signal to the subshell does not reach;
#     left alone it would scan the log under the first test.
make_fixture "$TMP/e4" 700
: > "$TMP/e4/backfill.slow"
printf '%s\n%s\n' "$IMMEDIATE" "$DONE" > "$TMP/e4/stream.1"
prepare "$TMP/e4" "iPhone 18 Pro" 27.0 >/dev/null || fail "exited non-zero with a slow log show"
if pgrep -f "/bin/sleep 23" >/dev/null; then pkill -f "/bin/sleep 23"; fail "left the log show running after the wait ended"; fi
if pgrep -f "/bin/sleep 20" >/dev/null; then pkill -f "/bin/sleep 20"; fail "left the log stream running after the wait ended"; fi
pass "stops both log readers when the wait ends"

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
