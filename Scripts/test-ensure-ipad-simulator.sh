#!/bin/bash
# Tests for Scripts/ensure-ipad-simulator.sh.
#
# Fully HERMETIC: stubs `xcrun` on a controlled PATH. Never touches this
# machine's real simulators, and in particular never creates one -- a suite
# that really ran `simctl create` would leave a device behind on every run.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

IPAD="iPad Pro 13-inch (M4)"
TYPE="com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB"
EXISTING_UDID="1111AAAA-2222-3333-4444-555566667777"
CREATED_UDID="9999BBBB-8888-7777-6666-555544443333"

# One stub for every case; each fixture directory supplies the data files it
# wants. `create` appends to create.log so a case can assert not just what was
# created but THAT nothing was.
make_fixture() { # dir
    mkdir -p "$1/bin"
    : > "$1/create.log"
    printf '%s\n' "$CREATED_UDID" > "$1/created_udid"
    cat > "$1/runtimes.txt" <<'EOF'
== Runtimes ==
iOS 9.3 (9.3 - 13E230) - com.apple.CoreSimulator.SimRuntime.iOS-9-3
iOS 18.3 (18.3.1 - 22D8075) - com.apple.CoreSimulator.SimRuntime.iOS-18-3
iOS 26.2 (26.2 - 23C54) - com.apple.CoreSimulator.SimRuntime.iOS-26-2
tvOS 17.2 (17.2 - 21K364) - com.apple.CoreSimulator.SimRuntime.tvOS-17-2
EOF
    cat > "$1/bin/xcrun" <<'STUB'
#!/bin/bash
FIX="$(dirname "$(dirname "$0")")"
if [ "$1" = "simctl" ] && [ "$2" = "list" ] && [ "$3" = "devices" ]; then
    rc=0
    [ -f "$FIX/devices_rc" ] && rc="$(cat "$FIX/devices_rc")"
    if [ "$rc" -ne 0 ]; then
        echo "simctl: A service error occurred." >&2
        exit "$rc"
    fi
    cat "$FIX/devices.txt"
    exit 0
fi
if [ "$1" = "simctl" ] && [ "$2" = "list" ] && [ "$3" = "runtimes" ]; then
    cat "$FIX/runtimes.txt"
    exit 0
fi
if [ "$1" = "simctl" ] && [ "$2" = "create" ]; then
    printf '%s\n' "$*" >> "$FIX/create.log"
    rc=0
    [ -f "$FIX/create_rc" ] && rc="$(cat "$FIX/create_rc")"
    if [ "$rc" -ne 0 ]; then
        echo "Invalid device type: whatever" >&2
        exit "$rc"
    fi
    cat "$FIX/created_udid"
    exit 0
fi
echo "stub xcrun: unhandled args: $*" >&2
exit 64
STUB
    chmod +x "$1/bin/xcrun"
}

ensure() { # dir [args...]
    local dir="$1"; shift
    env PATH="$dir/bin:/usr/bin:/bin" "$ROOT/Scripts/ensure-ipad-simulator.sh" "$@"
}

created_count() { wc -l < "$1/create.log" | tr -d '[:space:]'; }

# 1. The device is already there under the requested runtime -> print its
#    UDID and create NOTHING. Re-running this on every CI job and every
#    `mise run test` must not accumulate simulators.
make_fixture "$TMP/present"
cat > "$TMP/present/devices.txt" <<EOF
== Devices ==
-- iOS 26.2 --
    iPhone 17 Pro (AAAA1111-2222-3333-4444-555566667777) (Shutdown)
    $IPAD ($EXISTING_UDID) (Shutdown)
-- tvOS 17.2 --
EOF
out="$(ensure "$TMP/present" 26.2 2>/dev/null)" || fail "refused an iPad that is already present"
[ "$out" = "$EXISTING_UDID" ] || fail "did not print the existing UDID; got: $out"
[ "$(created_count "$TMP/present")" -eq 0 ] || fail "created a duplicate device that already existed"
pass "prints the existing UDID and creates nothing when the iPad is already present"

# 1b. Only the UDID reaches stdout. Scripts/capture-screenshots.sh substitutes
#     this directly into `simctl boot`, so a stray progress line on stdout
#     would be passed to simctl as part of the device id.
n="$(printf '%s\n' "$out" | wc -l | tr -d '[:space:]')"
[ "$n" -eq 1 ] || fail "stdout carried $n lines, expected exactly the UDID"
pass "writes only the UDID to stdout; progress goes to stderr"

# 2. Absent -> create it, from the PINNED device type and the runtime derived
#    from the requested OS. The type is the whole point: `iPad (A16)` is 11"
#    class and would silently test the wrong size class.
make_fixture "$TMP/absent"
cat > "$TMP/absent/devices.txt" <<'EOF'
== Devices ==
-- iOS 26.2 --
    iPhone 17 Pro (AAAA1111-2222-3333-4444-555566667777) (Shutdown)
    iPad (A16) (CCCC1111-2222-3333-4444-555566667777) (Shutdown)
-- tvOS 17.2 --
EOF
out="$(ensure "$TMP/absent" 26.2 2>/dev/null)" || fail "did not create a missing iPad"
[ "$out" = "$CREATED_UDID" ] || fail "did not print the created UDID; got: $out"
[ "$(created_count "$TMP/absent")" -eq 1 ] || fail "expected exactly one create call"
grep -qF "$TYPE" "$TMP/absent/create.log" \
    || fail "created something other than the pinned 13\" device type: $(cat "$TMP/absent/create.log")"
grep -qF "com.apple.CoreSimulator.SimRuntime.iOS-26-2" "$TMP/absent/create.log" \
    || fail "did not derive the runtime id from the requested OS: $(cat "$TMP/absent/create.log")"
grep -qF "$IPAD" "$TMP/absent/create.log" \
    || fail "created the device under a different name: $(cat "$TMP/absent/create.log")"
pass "creates the pinned 13-inch device type under the requested runtime when absent"

# 2b. The pre-provisioned `iPad (A16)` in that same fixture must NOT have been
#     accepted as "an iPad is available". This is the trap the whole script
#     exists for, so it gets its own assertion rather than riding on case 2.
[ "$(created_count "$TMP/absent")" -eq 1 ] \
    || fail "accepted iPad (A16) as the 13-inch device instead of creating one"
pass "does not accept the 11-inch iPad (A16) as a substitute"

# 3. Present, but only under a different runtime than the one requested: that
#    is not the destination the caller asked for, so create one that is.
make_fixture "$TMP/wrongos"
cat > "$TMP/wrongos/devices.txt" <<EOF
== Devices ==
-- iOS 18.3 --
    $IPAD ($EXISTING_UDID) (Shutdown)
-- iOS 26.2 --
    iPhone 17 Pro (AAAA1111-2222-3333-4444-555566667777) (Shutdown)
EOF
out="$(ensure "$TMP/wrongos" 26.2 2>/dev/null)" || fail "failed when the iPad existed only under another runtime"
[ "$out" = "$CREATED_UDID" ] || fail "reused a device from the wrong runtime; got: $out"
grep -qF "iOS-26-2" "$TMP/wrongos/create.log" \
    || fail "did not create under the requested runtime: $(cat "$TMP/wrongos/create.log")"
pass "creates for the requested runtime when the device exists only under another"

# 4. Exact-name matching. A device whose name merely CONTAINS the pinned name
#    is some other device with unknown state, not this one.
make_fixture "$TMP/prefix"
cat > "$TMP/prefix/devices.txt" <<EOF
== Devices ==
-- iOS 26.2 --
    iPad Pro 11-inch (M4) (DDDD1111-2222-3333-4444-555566667777) (Shutdown)
    $IPAD spare (EEEE1111-2222-3333-4444-555566667777) (Shutdown)
EOF
out="$(ensure "$TMP/prefix" 26.2 2>/dev/null)" || fail "failed on a near-miss device name"
[ "$out" = "$CREATED_UDID" ] || fail "substring-matched a differently-named device; got: $out"
pass "does not substring-match a device whose name merely contains the pinned one"

# 5. No OS argument -> the newest INSTALLED runtime, chosen numerically. The
#    fixture deliberately includes iOS 9.3, which sorts after 18.3 and 26.2 as
#    text; a lexical pick would create the device on a decade-old runtime.
make_fixture "$TMP/newest"
cat > "$TMP/newest/devices.txt" <<'EOF'
== Devices ==
-- iOS 26.2 --
    iPhone 17 Pro (AAAA1111-2222-3333-4444-555566667777) (Shutdown)
EOF
out="$(ensure "$TMP/newest" 2>/dev/null)" || fail "failed with no OS argument"
[ "$out" = "$CREATED_UDID" ] || fail "printed the wrong UDID with no OS argument; got: $out"
grep -qF "com.apple.CoreSimulator.SimRuntime.iOS-26-2" "$TMP/newest/create.log" \
    || fail "did not pick the newest installed runtime: $(cat "$TMP/newest/create.log")"
pass "defaults to the newest installed iOS runtime, compared numerically"

# 6. --name prints the pinned name and touches CoreSimulator not at all. It is
#    read by callers that only need the name, and must not be able to fail
#    because a simulator service is unhappy.
make_fixture "$TMP/name"
cat > "$TMP/name/devices_rc" <<'EOF'
1
EOF
out="$(ensure "$TMP/name" --name)" || fail "--name failed"
[ "$out" = "$IPAD" ] || fail "--name printed '$out', expected '$IPAD'"
[ "$(created_count "$TMP/name")" -eq 0 ] || fail "--name created a device"
pass "--name prints the pinned device name without querying CoreSimulator"

# 7. `simctl list devices` failing outright is NOT the same as it reporting no
#    iPad. Creating one on a failed query would spawn a fresh device every
#    time CoreSimulator hiccuped. See docs/learnings/masked-exit-status-fails-open.md.
make_fixture "$TMP/listfails"
: > "$TMP/listfails/devices.txt"
printf '1\n' > "$TMP/listfails/devices_rc"
if out="$(ensure "$TMP/listfails" 26.2 2>"$TMP/listfails/err")"; then
    fail "passed despite the device query failing"
fi
[ -z "$out" ] || fail "printed a UDID after a failed query; got: $out"
[ "$(created_count "$TMP/listfails")" -eq 0 ] || fail "created a device after a failed query"
pass "fails, and creates nothing, when the device query itself errors"

# 8. `simctl create` failing must fail the script rather than emit an empty
#    destination id, which xcodebuild reports as a confusing "Unable to find a
#    device matching the provided destination specifier".
make_fixture "$TMP/createfails"
cat > "$TMP/createfails/devices.txt" <<'EOF'
== Devices ==
-- iOS 26.2 --
    iPhone 17 Pro (AAAA1111-2222-3333-4444-555566667777) (Shutdown)
EOF
printf '1\n' > "$TMP/createfails/create_rc"
if out="$(ensure "$TMP/createfails" 26.2 2>/dev/null)"; then
    fail "passed despite simctl create failing"
fi
[ -z "$out" ] || fail "printed something on stdout after a failed create; got: $out"
pass "fails when simctl create fails, without printing a UDID"

# 8b. Same, for a create that exits 0 but prints nothing.
make_fixture "$TMP/createsilent"
cp "$TMP/createfails/devices.txt" "$TMP/createsilent/devices.txt"
: > "$TMP/createsilent/created_udid"
if out="$(ensure "$TMP/createsilent" 26.2 2>/dev/null)"; then
    fail "passed despite create printing no UDID"
fi
[ -z "$out" ] || fail "printed something on stdout; got: $out"
pass "fails when simctl create succeeds but prints no UDID"

# 9. Too many arguments -> usage, not a silently ignored extra.
make_fixture "$TMP/args"
cp "$TMP/present/devices.txt" "$TMP/args/devices.txt"
if out="$(ensure "$TMP/args" 26.2 extra 2>&1)"; then
    fail "accepted an extra argument"
fi
echo "$out" | grep -qi "usage" || fail "did not print usage; got: $out"
pass "rejects extra arguments with a usage message"

echo "All ensure-ipad-simulator tests passed."
