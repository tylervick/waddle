#!/bin/bash
# Collects the simulator's system log after a UI-test run and prints the two
# measurements issues #386 and #396 were diagnosed with, so a passing run can
# be compared with a failing one.
#
# Before this, only a FAILED run carried the simulator's log (inside the result
# bundle's diagnostics), so nobody could say how often the wallpaper prewarm
# ran without hurting anything, or how slow a first launch is when it passes.
#
# It prints:
#   - PosterBoard's gallery and prewarm lines: whether the lock-screen snapshot
#     renders ran at boot or were deferred into the test session, and when;
#   - for every launch of the app, the lag from runningboardd tracking the
#     process to testmanagerd passing "running foreground" to the test runner
#     (the wait that expires in #396), as a count, a median, a worst and every
#     launch over 10 s;
#   - from the result bundle's session log, how long xcodebuild took between
#     the first test asking for the app and the launch being issued (the stall
#     in #386).
# and leaves the log archive at <out-dir>/simulator.logarchive for upload.
#
# This is a measurement, not a guard: it never judges the run. It exits
# non-zero only when it could not collect the log at all, and the workflow
# step that calls it is continue-on-error.
#
# Usage: Scripts/ui-test-launch-report.sh <udid> <result-bundle> <out-dir>
#   <result-bundle> may be missing; the session-log section is then skipped.
set -euo pipefail

if [ $# -ne 3 ]; then
    echo "usage: $0 <udid> <result-bundle> <out-dir>" >&2
    exit 2
fi
UDID="$1"
BUNDLE="$2"
OUT="$3"
BUNDLE_ID="${WADDLE_BUNDLE_ID:-com.tylervick.waddle}"

# Absolute, because `log collect` runs inside the simulator, whose working
# directory is not this one: a relative path failed in run 44771876139 with
# "failed to create directory".
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
ARCHIVE="$OUT/simulator.logarchive"
rm -rf "$ARCHIVE"

# `log` here is /usr/bin/log; bash has no builtin of that name (zsh does).
# CoreSimulator's own log is the only record of a device being shut down or
# failing to boot, and it is small.
if [ -f "$HOME/Library/Logs/CoreSimulator/CoreSimulator.log" ]; then
    cp "$HOME/Library/Logs/CoreSimulator/CoreSimulator.log" "$OUT/CoreSimulator.log"
fi

collect() { xcrun simctl spawn "$UDID" log collect --output "$ARCHIVE" >"$OUT/log-collect.txt" 2>&1; }
if ! collect; then
    # `log collect` runs inside the simulator, so it needs the device booted,
    # and xcodebuild shuts down a device it had to boot itself (run
    # 44786994189). The log store is on disk and survives that: boot the
    # device once more only to read it.
    echo "could not collect the simulator log from $UDID on the first try:"
    cat "$OUT/log-collect.txt"
    echo "booting it to read its log"
    rm -rf "$ARCHIVE"
    if ! xcrun simctl bootstatus "$UDID" -b >"$OUT/bootstatus.txt" 2>&1 || ! collect; then
        echo "::warning::could not collect the simulator log from $UDID:"
        cat "$OUT/log-collect.txt"
        exit 1
    fi
fi

# show <predicate> <file>: the matching lines, compact, header and footer
# dropped, into <file>. Returns non-zero when the archive could not be read,
# which is not the same thing as a query that matched nothing: a section whose
# read failed prints that, and never a verdict over lines nobody read.
show() {
    if ! log show --archive "$ARCHIVE" --style compact --predicate "$1" > "$2.raw" 2> "$2.err"; then
        : > "$2"
        return 1
    fi
    grep -E '^[0-9]{4}-' "$2.raw" > "$2" || true
    rm -f "$2.raw" "$2.err"
}

echo "== PosterBoard: lock-screen gallery snapshots and prewarm =="
if show 'process == "PosterBoard" AND (eventMessage CONTAINS "requested snapshot prewarm" OR eventMessage CONTAINS "Calling prewarmSnapshotsForRequests" OR eventMessage CONTAINS "Successfully prewarmed gallery snapshots" OR eventMessage CONTAINS "Failed to prewarm gallery snapshots" OR eventMessage CONTAINS "Starting prewarm" OR eventMessage CONTAINS "prewarmSnapshotsForRequests completed" OR eventMessage CONTAINS "Prewarm is complete")' "$OUT/posterboard-lines.txt"; then
    sed -E 's/^([0-9-]+ [0-9:.]+) .*\] /\1  /' "$OUT/posterboard-lines.txt" | cut -c1-240 > "$OUT/posterboard.txt"
    if [ -s "$OUT/posterboard.txt" ]; then cat "$OUT/posterboard.txt"; else echo "(no lines)"; fi
else
    echo "(could not read the archive: $(head -1 "$OUT/posterboard-lines.txt.err"))"
fi

echo
echo "== App launches: lag from process tracked to 'running foreground' reaching the test runner =="
if ! show "(process == \"testmanagerd\" AND eventMessage CONTAINS \"XCTDProcessMonitor\" AND eventMessage CONTAINS \"passing update\" AND eventMessage CONTAINS \"running foreground\") OR (process == \"runningboardd\" AND eventMessage CONTAINS \"Now tracking process: [app<$BUNDLE_ID\")" "$OUT/launch-lines.txt"; then
    echo "(could not read the archive: $(head -1 "$OUT/launch-lines.txt.err")); no launch was measured"
else
awk -v app="$BUNDLE_ID" '
    function secs(d, t,    p) { split(t, p, ":"); return substr(d, 9, 2) * 86400 + p[1] * 3600 + p[2] * 60 + p[3] }
    {
        now = secs($1, $2)
        if (index($0, "Now tracking process: [app<" app)) {
            s = $0; sub(/.*Now tracking process: \[app<[^]]*:/, "", s); sub(/\].*/, "", s)
            tracked[s] = now; at[s] = $2; order[++n] = s
        } else if (match($0, /pid: [0-9]+ state: running foreground/)) {
            s = substr($0, RSTART + 5); sub(/ .*/, "", s)
            if ((s in tracked) && !(s in lag)) lag[s] = now - tracked[s]
        }
    }
    END {
        m = 0
        for (i = 1; i <= n; i++) {
            s = order[i]
            if (s in lag) { v[++m] = lag[s]; if (lag[s] > 10) slow = slow sprintf("  SLOW  pid %s tracked %s  lag %.1f s\n", s, at[s], lag[s]) }
            else never = never sprintf("  NEVER pid %s tracked %s  no running-foreground update\n", s, at[s])
        }
        for (i = 2; i <= m; i++) { x = v[i]; for (j = i - 1; j >= 1 && v[j] > x; j--) v[j + 1] = v[j]; v[j + 1] = x }
        if (m == 0) { print "launches tracked: " n ", none with an update" }
        else printf "launches tracked: %d  with an update: %d  median lag %.1f s  worst %.1f s\n", n, m, v[int((m + 1) / 2)], v[m]
        printf "%s%s", slow, never
        if (slow == "") print "no launch lagged more than 10 s"
    }
' "$OUT/launch-lines.txt" | tee "$OUT/launch-lag.txt"
fi

echo
echo "== First launch, from xcodebuild's session log =="
if [ ! -d "$BUNDLE" ]; then
    echo "(no result bundle at $BUNDLE)"
    exit 0
fi
DIAG="$OUT/diagnostics"
rm -rf "$DIAG"
if ! xcrun xcresulttool export diagnostics --path "$BUNDLE" --output-path "$DIAG" >"$OUT/xcresulttool.txt" 2>&1; then
    echo "(could not export diagnostics from $BUNDLE)"
    cat "$OUT/xcresulttool.txt"
    exit 0
fi
SESSION="$(find "$DIAG" -name 'Session-*.log' | head -1)"
if [ -z "$SESSION" ]; then
    echo "(no session log in $BUNDLE)"
else
    # The three lines of the FIRST launch, in order, and only if all three
    # belong to it: a launch that never completed must not borrow the next
    # test's request as its own "launched" line.
    awk -v app="$BUNDLE_ID" '
        function secs(t,    p) { split(t, p, ":"); return p[1] * 3600 + p[2] * 60 + p[3] }
        $2 !~ /^xcodebuild/ { next }
        /received application launch request/ {
            if (req == "") { req = $1; next }
            if (done == "") exit
        }
        req != "" && tok == "" && /Stored token 1 for launch/ { tok = $1; next }
        tok != "" && done == "" && index($0, "Launched app with identifier: " app " ") { done = $1; exit }
        END {
            if (req == "") { print "(the session log has no launch request)"; exit }
            if (tok == "" || done == "") { printf "requested %s  (the first launch never completed in the session log)\n", req; exit }
            a = secs(tok) - secs(req); b = secs(done) - secs(tok)
            if (a < 0) a += 86400
            if (b < 0) b += 86400
            printf "requested %s  launch issued after %.1f s  launched %.1f s later\n", req, a, b
        }
    ' "$SESSION" | tee "$OUT/first-launch.txt"
fi
# The exported diagnostics of a failed run hold a second copy of the system
# log; the archive above is the one to upload.
rm -rf "$DIAG"
