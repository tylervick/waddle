#!/bin/bash
# Tests for Scripts/profile-session.sh.
#
# Fully HERMETIC, bar case 14: the script runs from a throwaway repository
# with a stub check-engine-fresh.sh and a forty-line WAD, and `xcrun` and
# `xcodebuild` are stubs on PATH that log their arguments. No device, no
# simulator, no Xcode build and no Instruments recording is touched.
#
# What it cannot prove is that a real xctrace accepts these command lines on
# a real phone; --simulator-plumbing-check is the nearest thing to that.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# See docs/learnings/git-fixtures-inherit-signing-config.md.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

REPO="$TMP/repo"
mkdir -p "$REPO/Scripts" "$REPO/App/Waddle.xcodeproj" "$REPO/App/Resources/GameData" "$TMP/bin"
cp "$ROOT/Scripts/profile-session.sh" "$REPO/Scripts/"
# The guard's verdict is a file the cases flip; its own suite tests the guard.
cat > "$REPO/Scripts/check-engine-fresh.sh" <<'EOF'
#!/bin/bash
if [ -f "$(dirname "$0")/../.stale" ]; then echo "error: engine sources changed" >&2; exit 1; fi
EOF
chmod +x "$REPO/Scripts/check-engine-fresh.sh"
# A one-lump IWAD: a vanilla 1.9 demo on skill 4 (stored 3), MAP07, 350 tics.
python3 - "$REPO/App/Resources/GameData/freedoom2.wad" <<'PY'
import struct, sys
demo = bytes([109, 3, 1, 7, 0, 0, 0, 0, 0, 1, 0, 0, 0]) + bytes(4 * 350) + b"\x80"
with open(sys.argv[1], "wb") as f:
    f.write(struct.pack("<4sii", b"IWAD", 1, 12 + len(demo)) + demo)
    f.write(struct.pack("<ii8s", 12, len(demo), b"DEMO1"))
PY
printf 'build/\n.stale\n' > "$REPO/.gitignore"
git -C "$REPO" init -q
git -C "$REPO" add -A
git -C "$REPO" commit -q -m fixture
COMMIT="$(git -C "$REPO" rev-parse HEAD)"

PHONE=00008130-000A1B2C3D4E001E
SIM=8E5EEA92-C1E0-4ACA-BB16-90F0E675602A
device() {  # udid reality name marketing product build
  printf '{"identifier":"%s","hardwareProperties":{"udid":"%s","reality":"%s","marketingName":"%s","productType":"%s"},"deviceProperties":{"name":"%s","osVersionNumber":"27.0","osBuildUpdate":"%s"},"connectionProperties":{"tunnelState":"connected"}}' \
    "$1" "$1" "$2" "$4" "$5" "$3" "$6"
}
# The apostrophe is deliberate: it is in most real device names.
IPHONE="$(device "$PHONE" physical "Tyler's iPhone" "iPhone 15 Pro" iPhone16,1 24A335)"
SIMDEV="$(device "$SIM" simulated "iPhone 17" "iPhone 17" iPhone18,3 24A999)"
echo "{\"result\":{\"devices\":[$IPHONE,$SIMDEV]}}" > "$TMP/both.json"
echo "{\"result\":{\"devices\":[$SIMDEV]}}" > "$TMP/sim-only.json"

CALLS="$TMP/calls.log"
cat > "$TMP/bin/xcrun" <<'EOF'
#!/bin/bash
echo "xcrun $*" >> "$CALLS"
case "$1 $2 ${3:-}" in
  "devicectl list devices")
    [ -z "${STUB_DEVICECTL_FAIL:-}" ] || { echo "devicectl: CoreDevice is unavailable" >&2; exit 1; }
    cp "$STUB_DEVICES" "$5"; exit 0 ;;
  "devicectl device install"|"simctl bootstatus "*|"simctl install "*) exit 0 ;;
  "xctrace list templates") printf '== Standard Templates ==\nProcessor Trace\nTime Profiler\n'; exit 0 ;;
  "xctrace record "*)
    while [ $# -gt 0 ]; do
      if [ "$1" = --output ] && [ -z "${STUB_NO_TRACE:-}" ]; then mkdir -p "$2"; fi
      shift
    done
    # Non-zero on purpose: a target that ends itself makes xctrace do this.
    exit 54 ;;
  "xctrace export "*) exit 0 ;;
esac
echo "stub xcrun: unhandled args: $*" >&2; exit 64
EOF
cat > "$TMP/bin/xcodebuild" <<'EOF'
#!/bin/bash
echo "xcodebuild $*" >> "$CALLS"
sdk=iphoneos
case "$*" in *"id=8E5EEA92"*) sdk=iphonesimulator ;; esac
app="$STUB_REPO/build/profile-session/Build/Products/Release-$sdk/Waddle.app"
mkdir -p "$app"
plutil -create xml1 "$app/Info.plist"
plutil -insert CFBundleIdentifier -string cat.milo.waddle "$app/Info.plist"
EOF
chmod +x "$TMP/bin/xcrun" "$TMP/bin/xcodebuild"

# Runs the script; leaves its status in RC and its output in $TMP/out.
run() {
  : > "$CALLS"
  rm -rf "$REPO/build" "$TMP/o"
  RC=0
  env PATH="$TMP/bin:/usr/bin:/bin" CALLS="$CALLS" STUB_REPO="$REPO" \
      STUB_DEVICES="${DEVICES:-$TMP/both.json}" STUB_DEVICECTL_FAIL="${DEVICECTL_FAIL:-}" \
      STUB_NO_TRACE="${NO_TRACE:-}" \
      "$REPO/Scripts/profile-session.sh" --output-dir "$TMP/o" "$@" > "$TMP/out" 2>&1 || RC=$?
}
refused() {  # label, expected message; nothing may have been built or recorded
  [ "$RC" -ne 0 ] || fail "$1: exited 0"
  grep -q "$2" "$TMP/out" || { cat "$TMP/out" >&2; fail "$1: no '$2' in the output"; }
  if grep -q "^xcodebuild\|xctrace record" "$CALLS"; then fail "$1: built or recorded anyway"; fi
  pass "$1"
}
json() { python3 -c 'import json,sys
v = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): v = v[k]
print(v)' "$TMP/o/conditions.json" "$1"; }

# 1. A stale engine refuses before any device is even queried.
touch "$REPO/.stale"; run; rm "$REPO/.stale"
refused "a stale engine is refused" "refusing to profile a stale engine"
[ ! -s "$CALLS" ] || fail "a stale engine still reached xcrun"

# 2. One run has no spread; the issue's "at least two" is not advisory.
run --runs 1
refused "--runs 1 is refused" "no run-to-run spread"

# 3. No phone attached. Simulators are in the list and must not be picked.
DEVICES="$TMP/sim-only.json" run
refused "no physical device is refused, not swapped for a simulator" "no physical iOS device is connected"

# 4. A simulator named outright is still not a measurement.
run --device "$SIM"
refused "a simulator is refused for a real run" "is a simulated device"

# 5. A device query that fails is not an empty device list.
DEVICECTL_FAIL=1 run
refused "a failed device query fails closed" "could not list devices"

# 6. A template this Xcode lacks is refused before the build, not after it.
run --template "Processor Tracing"
refused "an unknown template is refused" "no Instruments template named"

# 7. Uncommitted changes: the recorded commit would not be what was built.
echo x > "$REPO/untracked"; run; rm "$REPO/untracked"
refused "a dirty tree is refused" "uncommitted changes"

# 8. The plumbing mode cannot be pointed at a phone and mistaken for a run.
run --simulator-plumbing-check --device "$PHONE"
refused "the plumbing check refuses a physical device" "is for a simulator"

# 9. The device run: the command lines a phone will actually be given.
run
[ "$RC" -eq 0 ] || { cat "$TMP/out" >&2; fail "happy path exited $RC"; }
build="$(grep '^xcodebuild' "$CALLS")"
for want in "-configuration Release" "-destination id=$PHONE" "-allowProvisioningUpdates" \
            'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) WADDLE_PROFILE_HARNESS'; do
  case "$build" in *"$want"*) ;; *) fail "build command lacks: $want" ;; esac
done
grep -q "devicectl device install app --device $PHONE .*Release-iphoneos/Waddle.app" "$CALLS" \
  || fail "the Release device app was not installed"
[ "$(grep -c 'xctrace record' "$CALLS")" = 2 ] || fail "expected 2 recordings by default"
grep -q "xctrace record --template Processor Trace --device $PHONE --time-limit 70s --output $TMP/o/run-2.trace .*--env WADDLE_PROFILE_GAME=Freedoom Phase 2 --env WADDLE_PROFILE_DEMO=demo1 --env WADDLE_PROFILE_MODE=playdemo --launch -- cat.milo.waddle" "$CALLS" \
  || { cat "$CALLS" >&2; fail "the record command line is not the expected one"; }
pass "a device run builds Release, installs, and records twice"

# 10. Every condition the issue lists is in conditions.json, read back from
#     the device and the WAD rather than echoed from the command line.
for pair in "measurement=True" "template=Processor Trace" "configuration=Release" \
            "device.name=Tyler's iPhone" "device.model=iPhone 15 Pro" "device.reality=physical" \
            "device.os_build=24A335" "app.commit=$COMMIT" "app.dirty=False" \
            "workload.wad=freedoom2.wad" "workload.map=MAP07" "workload.skill=4" \
            "workload.tics=350" "runs_requested=2"; do
  [ "$(json "${pair%%=*}")" = "${pair#*=}" ] || fail "conditions.json ${pair%%=*} is '$(json "${pair%%=*}")', wanted '${pair#*=}'"
done
[ "$(python3 -c 'import json,sys; print([r["xctrace_exit"] for r in json.load(open(sys.argv[1]))["runs"]])' "$TMP/o/conditions.json")" = "[54, 54]" ] \
  || fail "both runs, with xctrace's exit status, should be recorded"
[ ! -e "$TMP/o/NOT-A-MEASUREMENT.txt" ] || fail "a device run was stamped as not a measurement"
pass "conditions.json records device, OS build, commit, WAD, map, template and runs"

# 11. The template and run count are flags, and what was used is what is said.
run --template "Time Profiler" --runs 3 --mode timedemo
[ "$RC" -eq 0 ] || fail "--template/--runs run exited $RC"
[ "$(grep -c 'xctrace record --template Time Profiler .*WADDLE_PROFILE_MODE=timedemo' "$CALLS")" = 3 ] \
  || fail "expected 3 Time Profiler timedemo recordings"
[ "$(json template)" = "Time Profiler" ] || fail "the template used was not recorded"
pass "--template, --runs and --mode reach xctrace and the record"

# 12. A recording that leaves no trace fails the run instead of being counted.
NO_TRACE=1 run
[ "$RC" -ne 0 ] && grep -q "left no trace" "$TMP/out" || fail "a missing trace was not an error"
pass "a run with no trace fails"

# 13. Plumbing mode: same pipeline, simulator build, stamped three ways.
run --simulator-plumbing-check --device "$SIM"
[ "$RC" -eq 0 ] || { cat "$TMP/out" >&2; fail "plumbing run exited $RC"; }
[ "$(json measurement)" = False ] || fail "plumbing output claims to be a measurement"
grep -q "NOT A MEASUREMENT" "$TMP/o/NOT-A-MEASUREMENT.txt" || fail "no NOT-A-MEASUREMENT.txt"
grep -q "NOT A MEASUREMENT" "$TMP/out" || fail "plumbing run did not say so on stdout"
grep -q "simctl install $SIM .*Release-iphonesimulator/Waddle.app" "$CALLS" || fail "no simulator install"
grep -q "xctrace record --template Time Profiler --device $SIM" "$CALLS" || fail "plumbing did not default to Time Profiler"
if grep -q "allowProvisioningUpdates" "$CALLS"; then fail "plumbing build asked for provisioning"; fi
pass "the plumbing check runs the pipeline on a simulator and says it is not a measurement"

# 14. LIVE, against this checkout: the seam is compiled in by exactly one
#     symbol, and only profile-session.sh may set it. If an archive, CI or
#     Revyl build ever passed it, a shipping app would auto-start a demo for
#     anyone who set three environment variables.
grep -q "WADDLE_PROFILE_HARNESS" "$ROOT/App/Sources/ProfileHarness.swift" \
  || fail "ProfileHarness.swift no longer reads WADDLE_PROFILE_HARNESS"
others="$(grep -rl "WADDLE_PROFILE_HARNESS" "$ROOT/Scripts" "$ROOT/.github" "$ROOT/.revyl" "$ROOT/App/project.yml" "$ROOT/mise.toml" 2>/dev/null \
  | grep -v "/Scripts/profile-session.sh$" | grep -v "/Scripts/test-profile-session.sh$" || true)"
[ -z "$others" ] || fail "WADDLE_PROFILE_HARNESS is set outside profile-session.sh: $others"
pass "only profile-session.sh compiles the profiling seam in"

echo "All profile-session tests passed."
