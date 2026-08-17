#!/bin/bash
# Tests for Scripts/check-simulator-available.sh.
#
# Fully HERMETIC: stubs `xcrun` on a controlled PATH. Never touches this
# machine's real simulators.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# Runs the guard with SIMULATOR_CHECK_DELAY=0 so retries cost nothing --
# a suite that really slept ~60s per case would not be acceptable here.
check() { # dir device os [attempts]
    env PATH="$1/bin:/usr/bin:/bin" SIMULATOR_CHECK_DELAY=0 \
        SIMULATOR_CHECK_ATTEMPTS="${4:-5}" \
        "$ROOT/Scripts/check-simulator-available.sh" "$2" "$3"
}

# 1. A matching, available device -> exit 0, and it prints what it matched.
make_fixture_match() { # dest
    mkdir -p "$1/bin"
    cat > "$1/bin/xcrun" <<'STUB'
#!/bin/bash
if [ "$1" = "simctl" ] && [ "$2" = "list" ]; then
cat <<'EOF'
== Devices ==
-- iOS 26.2 --
    iPhone 17 Pro (AAAA1111-2222-3333-4444-555566667777) (Shutdown)
    iPhone 17 Pro Max (BBBB1111-2222-3333-4444-555566667777) (Booted)
-- tvOS 17.2 --
EOF
exit 0
fi
echo "stub xcrun: unhandled args: $*" >&2
exit 64
STUB
    chmod +x "$1/bin/xcrun"
}
make_fixture_match "$TMP/a"
out="$(check "$TMP/a" "iPhone 17 Pro" 26.2)" || fail "refused a genuine match"
echo "$out" | grep -q "matched: iPhone 17 Pro (AAAA1111" || fail "did not print what it matched; got: $out"
pass "exits 0 and prints what it matched when the device is available"

# 1b. Exact-name matching: "iPhone 17" must not match "iPhone 17 Pro" via a
#     substring hit -- same fixture, a name that is a strict prefix of a real
#     entry but was never actually enumerated.
if check "$TMP/a" "iPhone 17" 26.2 1 >"$TMP/out1b" 2>&1; then
    fail "matched 'iPhone 17' against 'iPhone 17 Pro' via substring; got: $(cat "$TMP/out1b")"
fi
pass "does not substring-match a device name that is a prefix of a real one"

# 1c. A device whose OWN NAME is parenthesised. Every iPad is: "iPad Pro
#     13-inch (M4)", "iPad (A16)". The name used to be recovered by cutting
#     the line at its first " (", which reads that as "iPad Pro 13-inch" and
#     reports a device that is sitting right there as a bad destination pin --
#     so ci.yml's iPad leg could never have passed this guard. Both a
#     parenthesised name and its unparenthesised prefix are in the fixture, so
#     a parser that gets this right cannot also be substring-matching.
make_fixture_paren_names() { # dest
    mkdir -p "$1/bin"
    cat > "$1/bin/xcrun" <<'STUB'
#!/bin/bash
if [ "$1" = "simctl" ] && [ "$2" = "list" ]; then
cat <<'EOF'
== Devices ==
-- iOS 26.2 --
    iPad Pro 13-inch (CCCC1111-2222-3333-4444-555566667777) (Shutdown)
    iPad Pro 13-inch (M4) (AAAA1111-2222-3333-4444-555566667777) (Booted)
    iPad (A16) (BBBB1111-2222-3333-4444-555566667777) (Shutdown)
-- tvOS 17.2 --
EOF
exit 0
fi
echo "stub xcrun: unhandled args: $*" >&2
exit 64
STUB
    chmod +x "$1/bin/xcrun"
}
make_fixture_paren_names "$TMP/a2"
out="$(check "$TMP/a2" "iPad Pro 13-inch (M4)" 26.2)" || fail "refused a present device whose name is parenthesised"
echo "$out" | grep -q "matched: iPad Pro 13-inch (M4) (AAAA1111" \
    || fail "matched the wrong line for a parenthesised name; got: $out"
pass "matches a device whose own name contains parentheses"

# 1d. The same fixture, asking for the unparenthesised prefix that is also
#     genuinely present: it must match THAT device, not the (M4) one.
out="$(check "$TMP/a2" "iPad Pro 13-inch" 26.2)" || fail "refused the unparenthesised device that is present"
echo "$out" | grep -q "matched: iPad Pro 13-inch (CCCC1111" \
    || fail "a parenthesised name was accepted for its unparenthesised prefix; got: $out"
pass "keeps a parenthesised name distinct from its unparenthesised prefix"

# 2. Zero devices enumerated (any OS, any device) -> non-zero, carries the
#    infra marker, and dumps the full (empty) listing for diagnosis.
make_fixture_empty() { # dest
    mkdir -p "$1/bin"
    cat > "$1/bin/xcrun" <<'STUB'
#!/bin/bash
if [ "$1" = "simctl" ] && [ "$2" = "list" ]; then
cat <<'EOF'
== Devices ==
-- iOS 26.2 --
-- tvOS 17.2 --
EOF
exit 0
fi
echo "stub xcrun: unhandled args: $*" >&2
exit 64
STUB
    chmod +x "$1/bin/xcrun"
}
make_fixture_empty "$TMP/b"
if out="$(check "$TMP/b" "iPhone 17 Pro" 26.2 2 2>&1)"; then
    fail "passed despite zero devices enumerated"
fi
echo "$out" | grep -q "WADDLE_SIMULATOR_UNAVAILABLE" || fail "missing infra marker; got: $out"
echo "$out" | grep -q -- "-- iOS 26.2 --" || fail "did not dump the available-device list; got: $out"
pass "fails with the infra marker when zero devices are enumerated"

# 3. Devices enumerated, but none match the requested name/OS -> non-zero,
#    WITHOUT the infra marker -- this is a genuine pin problem a re-run will
#    not fix.
make_fixture_nomatch() { # dest
    mkdir -p "$1/bin"
    cat > "$1/bin/xcrun" <<'STUB'
#!/bin/bash
if [ "$1" = "simctl" ] && [ "$2" = "list" ]; then
cat <<'EOF'
== Devices ==
-- iOS 26.2 --
    iPhone 17 Pro Max (BBBB1111-2222-3333-4444-555566667777) (Booted)
-- tvOS 17.2 --
EOF
exit 0
fi
echo "stub xcrun: unhandled args: $*" >&2
exit 64
STUB
    chmod +x "$1/bin/xcrun"
}
make_fixture_nomatch "$TMP/c"
if out="$(check "$TMP/c" "iPhone 17 Pro" 26.2 2 2>&1)"; then
    fail "passed despite no matching device"
fi
echo "$out" | grep -q "WADDLE_SIMULATOR_UNAVAILABLE" && fail "infra marker present on a genuine pin problem; got: $out"
echo "$out" | grep -qi "pin problem" || fail "did not call out the pin-problem shape distinctly; got: $out"
pass "fails WITHOUT the infra marker when devices are enumerated but none match"

# 3b. Same idea, but the mismatch is the OS rather than the device name: the
#     device exists, just under a different runtime than requested.
make_fixture_wrong_os() { # dest
    mkdir -p "$1/bin"
    cat > "$1/bin/xcrun" <<'STUB'
#!/bin/bash
if [ "$1" = "simctl" ] && [ "$2" = "list" ]; then
cat <<'EOF'
== Devices ==
-- iOS 18.3 --
    iPhone 17 Pro (AAAA1111-2222-3333-4444-555566667777) (Shutdown)
-- tvOS 17.2 --
EOF
exit 0
fi
echo "stub xcrun: unhandled args: $*" >&2
exit 64
STUB
    chmod +x "$1/bin/xcrun"
}
make_fixture_wrong_os "$TMP/c2"
if out="$(check "$TMP/c2" "iPhone 17 Pro" 26.2 2 2>&1)"; then
    fail "passed despite the device existing only under a different OS"
fi
echo "$out" | grep -q "WADDLE_SIMULATOR_UNAVAILABLE" && fail "infra marker present when only the OS pin was wrong; got: $out"
pass "fails without the infra marker when the device exists under a different OS"

# 4. THE RETRY. Enumeration is empty on the first attempt, then populated
#    (with a real match) on the second -- proves the retry schedule actually
#    recovers from a cold-runner enumeration race instead of judging the
#    first query alone.
make_fixture_recovers() { # dest
    mkdir -p "$1/bin"
    : > "$1/attempts.log"
    cat > "$1/bin/xcrun" <<'STUB'
#!/bin/bash
FIX="$(dirname "$(dirname "$0")")"
echo x >> "$FIX/attempts.log"
n=$(wc -l < "$FIX/attempts.log" | tr -d '[:space:]')
if [ "$1" = "simctl" ] && [ "$2" = "list" ]; then
    if [ "$n" -lt 2 ]; then
        cat <<'EOF'
== Devices ==
-- iOS 26.2 --
-- tvOS 17.2 --
EOF
    else
        cat <<'EOF'
== Devices ==
-- iOS 26.2 --
    iPhone 17 Pro (AAAA1111-2222-3333-4444-555566667777) (Shutdown)
-- tvOS 17.2 --
EOF
    fi
    exit 0
fi
echo "stub xcrun: unhandled args: $*" >&2
exit 64
STUB
    chmod +x "$1/bin/xcrun"
}
make_fixture_recovers "$TMP/d"
out="$(check "$TMP/d" "iPhone 17 Pro" 26.2)" || fail "the retry never recovered a later, populated enumeration"
echo "$out" | grep -q "matched: iPhone 17 Pro" || fail "did not report the match once enumeration recovered; got: $out"
n="$(wc -l < "$TMP/d/attempts.log" | tr -d '[:space:]')"
[ "$n" -eq 2 ] || fail "expected exactly 2 attempts (retry then success), got $n"
pass "retries past an empty first enumeration and succeeds once a later one is populated"

# 5. simctl itself failing outright (nonzero exit, e.g. CoreSimulatorService
#    unreachable) must land in the SAME infra bucket as a successful-but-empty
#    enumeration -- not be treated as a data point of its own, and not be
#    masked into a false "zero enumerated" success. Also confirms the exit
#    status of the query is what decides this, not just its (empty) output.
make_fixture_xcrun_fails() { # dest
    mkdir -p "$1/bin"
    cat > "$1/bin/xcrun" <<'STUB'
#!/bin/bash
if [ "$1" = "simctl" ] && [ "$2" = "list" ]; then
    echo "simctl: A service error occurred." >&2
    exit 1
fi
echo "stub xcrun: unhandled args: $*" >&2
exit 64
STUB
    chmod +x "$1/bin/xcrun"
}
make_fixture_xcrun_fails "$TMP/e"
if out="$(check "$TMP/e" "iPhone 17 Pro" 26.2 2 2>&1)"; then
    fail "passed despite simctl itself failing on every attempt"
fi
echo "$out" | grep -q "WADDLE_SIMULATOR_UNAVAILABLE" || fail "a hard simctl failure was not folded into the infra bucket; got: $out"
pass "treats simctl itself failing as the same infra bucket as an empty enumeration"

# 6. Wrong argument count -> usage error, not a silent no-op or a crash from
#    an unset positional parameter under set -u.
if out="$(env PATH="$TMP/a/bin:/usr/bin:/bin" "$ROOT/Scripts/check-simulator-available.sh" "only-one-arg" 2>&1)"; then
    fail "accepted a single argument instead of requiring device and OS"
fi
echo "$out" | grep -qi "usage" || fail "wrong-arg-count case did not print usage; got: $out"
pass "requires exactly device name and OS version, or prints usage"

echo "All check-simulator-available tests passed."
