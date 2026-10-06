#!/bin/bash
# Records Instruments traces of one engine session on an attached iPhone, and
# refuses to record anything that could not be called a measurement.
#
# Issue #246: this project has no frame-time baseline of any kind, and the
# issue's Verification section lists what turns a trace into one -- a physical
# device, a Release build, a named WAD and map, at least two runs, an engine
# framework that matches its sources. Each of those is a thing a person
# forgets once. So each is either enforced here (the script exits non-zero,
# having recorded nothing) or written into conditions.json beside the traces,
# where a number cannot be separated from it.
#
#   Scripts/profile-session.sh                      # the attached iPhone
#   Scripts/profile-session.sh --template 'Time Profiler' --runs 3
#   Scripts/profile-session.sh --simulator-plumbing-check --device <sim UDID>
#
# The workload is a demo lump out of a bundled Freedoom IWAD, played back
# through App/Sources/ProfileHarness.swift: recorded input driving a
# deterministic simulation, so every run renders the same tics from the same
# positions and nobody touches the phone. --mode playdemo (default) runs it in
# real time, the 35 Hz tic and the uncapped renderer exactly as a player gets
# them; --mode timedemo runs one tic per frame as fast as the device goes.
#
# Processor Trace is the default template because it is the issue's first
# choice, but it needs iPhone 16-class hardware; --template picks another and
# the one used is recorded. A template this Xcode does not list is refused
# before anything is built.
#
# --simulator-plumbing-check runs the identical pipeline against a simulator
# so the launch seam, the workload and the capture can be exercised without
# hardware. Its output directory, conditions.json and a NOT-A-MEASUREMENT.txt
# all say so: simulator timings are the Mac's, not a phone's.
#
# Fails CLOSED: a device query that errors, a device that is not what the mode
# requires, or a run that leaves no .trace all refuse rather than continue.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

DEVICE="" TEMPLATE="" RUNS=2 WAD="freedoom2.wad" DEMO="demo1" MODE="playdemo"
TIME_LIMIT="" OUT="" PLUMBING=0
usage() { sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "error: $1" >&2; shift; for l in "$@"; do echo "       $l" >&2; done; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --simulator-plumbing-check) PLUMBING=1; shift ;;
    --device|--template|--runs|--wad|--demo|--mode|--time-limit|--output-dir)
      [ $# -ge 2 ] || die "$1 needs a value."
      case "$1" in
        --device) DEVICE="$2" ;; --template) TEMPLATE="$2" ;; --runs) RUNS="$2" ;;
        --wad) WAD="$2" ;; --demo) DEMO="$2" ;; --mode) MODE="$2" ;;
        --time-limit) TIME_LIMIT="$2" ;; --output-dir) OUT="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" "see: Scripts/profile-session.sh --help" ;;
  esac
done

case "$RUNS" in ''|*[!0-9]*) die "--runs must be a number, got '$RUNS'." ;; esac
if [ "$RUNS" -lt 2 ]; then
  die "--runs $RUNS: one run shows no run-to-run spread, and issue #246 does" \
      "not accept a single-run figure as a measurement. Ask for at least 2."
fi
case "$MODE" in playdemo|timedemo) ;; *) die "--mode must be playdemo or timedemo, got '$MODE'." ;; esac
# The shelf titles LibraryService gives the two bundled IWADs; the app finds
# the game to start by this name.
case "$WAD" in
  freedoom1.wad) GAME="Freedoom Phase 1" ;;
  freedoom2.wad) GAME="Freedoom Phase 2" ;;
  *) die "--wad must be freedoom1.wad or freedoom2.wad: only the bundled" \
         "IWADs are the same bytes on every install, got '$WAD'." ;;
esac
if [ -z "$TEMPLATE" ]; then
  if [ "$PLUMBING" = 1 ]; then TEMPLATE="Time Profiler"; else TEMPLATE="Processor Trace"; fi
fi

# Profiling a framework that does not match the sources attributes the numbers
# to the wrong code. The guard prints its own rebuild guidance.
"$ROOT/Scripts/check-engine-fresh.sh" \
  || die "refusing to profile a stale engine (Scripts/check-engine-fresh.sh failed)."
[ -d "$ROOT/App/Waddle.xcodeproj" ] || die "App/Waddle.xcodeproj is missing." "run: mise run generate"
WAD_PATH="$ROOT/App/Resources/GameData/$WAD"
[ -f "$WAD_PATH" ] || die "$WAD_PATH is missing." "run: mise run fetch-freedoom"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Reads the demo lump's own header, so the map in conditions.json is the one
# the WAD actually plays rather than one somebody typed. Prints five lines:
# map, skill, tics, seconds, lump sha256 ("unknown" where the format does not
# say). Exits 3 when the WAD has no such lump.
demo_facts() {
  python3 - "$WAD_PATH" "$DEMO" "$WAD" <<'PY'
import hashlib, struct, sys
path, lump, wad = sys.argv[1], sys.argv[2].upper().encode(), sys.argv[3]
with open(path, "rb") as f:
    _, count, offset = struct.unpack("<4sii", f.read(12))
    f.seek(offset)
    entries = [struct.unpack("<ii8s", f.read(16)) for _ in range(count)]
    found = [e for e in entries if e[2].rstrip(b"\0").upper() == lump]
    if not found:
        sys.exit(3)
    f.seek(found[-1][0])
    data = f.read(found[-1][1])
version = data[0] if data else 0
skill = episode = level = tics = None
if version <= 110 and len(data) > 13:           # vanilla 1.4-1.9
    skill, episode, level = data[1], data[2], data[3]
    players = sum(1 for b in data[9:13] if b) or 1
    tics = (len(data) - 14) // (4 * players)
elif 200 <= version <= 214 and len(data) > 10:  # Boom, MBF, MBF21
    skill, episode, level = data[8], data[9], data[10]
if level is None:
    print("unknown")
elif wad == "freedoom1.wad":
    print("E%dM%d" % (episode, level))
else:
    print("MAP%02d" % level)
print("unknown" if skill is None else skill + 1)
print("unknown" if tics is None else tics)
print("unknown" if tics is None else "%.1f" % (tics / 35.0))
print(hashlib.sha256(data).hexdigest())
PY
}
if demo_facts > "$TMP/demo.txt"; then :; else
  die "could not read lump '$DEMO' from $WAD (missing lump or unreadable WAD)."
fi
MAP="$(sed -n 1p "$TMP/demo.txt")"; SKILL="$(sed -n 2p "$TMP/demo.txt")"
TICS="$(sed -n 3p "$TMP/demo.txt")"; DEMO_SECONDS="$(sed -n 4p "$TMP/demo.txt")"
DEMO_SHA="$(sed -n 5p "$TMP/demo.txt")"
WAD_SHA="$(shasum -a 256 "$WAD_PATH" | cut -d' ' -f1)"
if [ -z "$TIME_LIMIT" ]; then
  # A backstop, not the stop: the app exits when the demo ends and that ends
  # the recording. Real-time playback gets its length plus launch slack.
  if [ "$TICS" != unknown ]; then TIME_LIMIT="$(( TICS / 35 + 60 ))s"; else TIME_LIMIT="300s"; fi
fi

COMMIT="$(git -C "$ROOT" rev-parse HEAD)" || die "could not read the app commit."
DIRTY=false
if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then DIRTY=true; fi
if [ "$DIRTY" = true ] && [ "$PLUMBING" = 0 ]; then
  die "the working tree has uncommitted changes, so no commit names what" \
      "would be measured. Commit or set them aside first."
fi

# One query, eight lines: status (ok|none|many|notfound), udid, reality, name,
# marketing name, product type, OS version, OS build. With no --device it
# picks the only connected PHYSICAL device; simulators are never auto-picked.
if xcrun devicectl list devices --json-output "$TMP/devices.json" > "$TMP/devicectl.log" 2>&1; then :; else
  cat "$TMP/devicectl.log" >&2
  die "xcrun devicectl could not list devices; refusing to guess at one."
fi
pick_device() {
  python3 - "$TMP/devices.json" "$DEVICE" <<'PY'
import json, sys
wanted = sys.argv[2]
rows = []
for d in json.load(open(sys.argv[1])).get("result", {}).get("devices", []):
    hw, dev = d.get("hardwareProperties", {}), d.get("deviceProperties", {})
    conn = d.get("connectionProperties", {})
    rows.append({
        "udid": hw.get("udid") or d.get("identifier") or "unknown",
        "id": d.get("identifier"),
        "reality": hw.get("reality") or "unknown",
        "name": dev.get("name") or "unknown",
        "model": hw.get("marketingName") or "unknown",
        "product": hw.get("productType") or "unknown",
        "os": dev.get("osVersionNumber") or "unknown",
        "build": dev.get("osBuildUpdate") or "unknown",
        "connected": conn.get("tunnelState") == "connected"
                     or conn.get("pairingState") == "paired",
    })
if wanted:
    hits = [r for r in rows if wanted in (r["udid"], r["id"], r["name"])]
    status = "ok" if len(hits) == 1 else ("many" if hits else "notfound")
else:
    hits = [r for r in rows if r["reality"] == "physical" and r["connected"]]
    status = "ok" if len(hits) == 1 else ("many" if hits else "none")
print(status)
if status == "ok":
    for key in ("udid", "reality", "name", "model", "product", "os", "build"):
        print(hits[0][key])
else:
    for r in hits:
        print("%s  %s (%s)" % (r["udid"], r["name"], r["model"]))
PY
}
pick_device > "$TMP/device.txt" || die "could not parse the devicectl device list."
case "$(sed -n 1p "$TMP/device.txt")" in
  ok) ;;
  none) die "no physical iOS device is connected." \
            "Plug the iPhone in, unlock it, trust this Mac, and turn on" \
            "Settings > Privacy & Security > Developer Mode." ;;
  notfound) die "no device matches --device '$DEVICE' (xcrun devicectl list devices)." ;;
  *) sed -n '2,$p' "$TMP/device.txt" >&2
     die "more than one device matches; pick one with --device <UDID>." ;;
esac
UDID="$(sed -n 2p "$TMP/device.txt")"; REALITY="$(sed -n 3p "$TMP/device.txt")"
DEV_NAME="$(sed -n 4p "$TMP/device.txt")"; DEV_MODEL="$(sed -n 5p "$TMP/device.txt")"
DEV_PRODUCT="$(sed -n 6p "$TMP/device.txt")"; OS_VERSION="$(sed -n 7p "$TMP/device.txt")"
OS_BUILD="$(sed -n 8p "$TMP/device.txt")"
if [ "$PLUMBING" = 1 ]; then
  [ -n "$DEVICE" ] || die "--simulator-plumbing-check needs --device <simulator UDID>."
  [ "$REALITY" = simulated ] \
    || die "--simulator-plumbing-check is for a simulator; '$DEV_NAME' is $REALITY." \
           "Drop the flag to measure on it."
elif [ "$REALITY" != physical ]; then
  die "'$DEV_NAME' is a $REALITY device. A simulator runs on the Mac's CPU, so" \
      "a trace of it is not the measurement issue #246 asks for." \
      "(--simulator-plumbing-check exercises the pipeline there, labelled as such.)"
fi

if xcrun xctrace list templates > "$TMP/templates.txt" 2>&1; then :; else
  cat "$TMP/templates.txt" >&2
  die "xcrun xctrace could not list its templates."
fi
grep -Fxq "$TEMPLATE" "$TMP/templates.txt" \
  || die "this Xcode has no Instruments template named '$TEMPLATE'." \
         "see: xcrun xctrace list templates"

if [ "$PLUMBING" = 1 ]; then SDK_DIR=Release-iphonesimulator; else SDK_DIR=Release-iphoneos; fi
SLUG="$(printf '%s' "$TEMPLATE" | tr 'A-Z ' 'a-z-')"
if [ -z "$OUT" ]; then
  OUT="$ROOT/build/profiles/$(date -u +%Y%m%dT%H%M%SZ)-$SLUG"
  if [ "$PLUMBING" = 1 ]; then OUT="$ROOT/build/profiles/PLUMBING-NOT-A-MEASUREMENT-$(date -u +%Y%m%dT%H%M%SZ)"; fi
fi
mkdir -p "$OUT"
: > "$TMP/runs.tsv"

# conditions.json is written before the first run and again after the last,
# so a session that dies half way still says what it was recording.
write_conditions() {
  # Values travel as environment, not interpolated into the program: a device
  # name is whatever its owner typed, quotes and backslashes included.
  P_PLUMBING="$PLUMBING" P_NOTE="$NOTE" P_TEMPLATE="$TEMPLATE" P_NAME="$DEV_NAME" \
  P_MODEL="$DEV_MODEL" P_PRODUCT="$DEV_PRODUCT" P_REALITY="$REALITY" \
  P_OS="$OS_VERSION" P_BUILD="$OS_BUILD" P_UDID="$UDID" P_COMMIT="$COMMIT" \
  P_DIRTY="$DIRTY" P_FP="$ENGINE_FP" P_WAD="$WAD" P_WAD_SHA="$WAD_SHA" \
  P_GAME="$GAME" P_DEMO="$DEMO" P_DEMO_SHA="$DEMO_SHA" P_MODE="$MODE" P_MAP="$MAP" \
  P_SKILL="$SKILL" P_TICS="$TICS" P_SECONDS="$DEMO_SECONDS" P_LIMIT="$TIME_LIMIT" \
  P_RUNS="$RUNS" P_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  python3 - "$OUT/conditions.json" "$TMP/runs.tsv" <<'PY'
import json, os, sys
e = os.environ
runs = []
for line in open(sys.argv[2]):
    n, trace, status, seconds, toc = line.rstrip("\n").split("\t")
    runs.append({"run": int(n), "trace": trace, "xctrace_exit": int(status),
                 "wall_seconds": int(seconds), "toc": toc or None})
json.dump({
    "measurement": e["P_PLUMBING"] != "1",
    "note": e["P_NOTE"],
    "recorded_utc": e["P_NOW"],
    "template": e["P_TEMPLATE"],
    "configuration": "Release",
    "device": {"name": e["P_NAME"], "model": e["P_MODEL"],
               "product_type": e["P_PRODUCT"], "reality": e["P_REALITY"],
               "os_version": e["P_OS"], "os_build": e["P_BUILD"], "udid": e["P_UDID"]},
    "app": {"commit": e["P_COMMIT"], "dirty": e["P_DIRTY"] == "true"},
    "engine_fingerprint": e["P_FP"],
    "workload": {"wad": e["P_WAD"], "wad_sha256": e["P_WAD_SHA"], "game": e["P_GAME"],
                 "demo": e["P_DEMO"], "demo_sha256": e["P_DEMO_SHA"], "mode": e["P_MODE"],
                 "map": e["P_MAP"], "skill": e["P_SKILL"], "tics": e["P_TICS"],
                 "demo_seconds_at_35hz": e["P_SECONDS"],
                 "engine_arguments": ["-" + e["P_MODE"], e["P_DEMO"], "-nogui"]},
    "time_limit": e["P_LIMIT"],
    "runs_requested": int(e["P_RUNS"]),
    "runs": runs,
}, open(sys.argv[1], "w"), indent=2)
PY
}
ENGINE_FP="$(cat "$ROOT/Vendor/out/WoofEngine.xcframework.fingerprint" 2>/dev/null || echo unknown)"
NOTE="Device measurement for issue #246."
if [ "$PLUMBING" = 1 ]; then
  NOTE="NOT A MEASUREMENT. Simulator plumbing check: these timings are the Mac's CPU, not an iPhone's."
  echo "$NOTE" > "$OUT/NOT-A-MEASUREMENT.txt"
  echo "*** $NOTE ***"
fi
write_conditions
echo "profile-session: $TEMPLATE, $RUNS runs, Release, $WAD $DEMO ($MAP, -$MODE)"
echo "profile-session: $DEV_NAME -- $DEV_MODEL ($DEV_PRODUCT), $OS_VERSION ($OS_BUILD), $REALITY"
echo "profile-session: app $COMMIT, output $OUT"

# Release, plus the one symbol that compiles the launch seam in. Quoted so
# the shell leaves \$(inherited) for xcodebuild: without it the override would
# replace Release's own conditions instead of extending them. ARCHS=arm64
# because Release builds every architecture and WoofEngine.xcframework has no
# x86_64 simulator slice to link (ci.yml's simulator builds pass the same).
DERIVED="$ROOT/build/profile-session"
SIGNING=()
if [ "$PLUMBING" = 0 ]; then SIGNING=(-allowProvisioningUpdates); fi
if xcodebuild -project "$ROOT/App/Waddle.xcodeproj" -scheme Waddle \
     -configuration Release -destination "id=$UDID" -derivedDataPath "$DERIVED" \
     ${SIGNING[@]+"${SIGNING[@]}"} \
     SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) WADDLE_PROFILE_HARNESS' \
     ARCHS=arm64 build> "$OUT/xcodebuild.log" 2>&1; then :; else
  grep -E "error:|BUILD FAILED" "$OUT/xcodebuild.log" | head -20 >&2 || true
  die "the Release build failed; full log: $OUT/xcodebuild.log"
fi
APP="$DERIVED/Build/Products/$SDK_DIR/Waddle.app"
[ -d "$APP" ] || die "the build left no app at $APP."
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$APP/Info.plist")" \
  || die "could not read the bundle identifier from $APP/Info.plist."

if [ "$PLUMBING" = 1 ]; then
  xcrun simctl bootstatus "$UDID" -b > "$OUT/install.log" 2>&1 || die "simulator $UDID did not boot; see $OUT/install.log"
  xcrun simctl install "$UDID" "$APP" >> "$OUT/install.log" 2>&1 || die "install failed; see $OUT/install.log"
else
  xcrun devicectl device install app --device "$UDID" "$APP" > "$OUT/install.log" 2>&1 \
    || die "install failed (is the phone unlocked and trusted?); see $OUT/install.log"
fi

n=1
while [ "$n" -le "$RUNS" ]; do
  trace="$OUT/run-$n.trace"
  echo "profile-session: run $n of $RUNS -- recording (limit $TIME_LIMIT)"
  started="$(date +%s)"
  status=0
  # xctrace's status is recorded, not trusted: it exits non-zero for a target
  # that ends itself, which is how every run here ends. The trace is the proof.
  xcrun xctrace record --template "$TEMPLATE" --device "$UDID" \
    --time-limit "$TIME_LIMIT" --output "$trace" --run-name "run-$n" --no-prompt \
    --env "WADDLE_PROFILE_GAME=$GAME" --env "WADDLE_PROFILE_DEMO=$DEMO" \
    --env "WADDLE_PROFILE_MODE=$MODE" \
    --launch -- "$BUNDLE_ID" > "$OUT/run-$n.xctrace.log" 2>&1 || status=$?
  seconds="$(( $(date +%s) - started ))"
  [ -d "$trace" ] || die "run $n left no trace (xctrace exit $status); see $OUT/run-$n.xctrace.log"
  # The table of contents names the schemas a later `xctrace export --xpath`
  # can pull numbers from. Welcome when it works, never a reason to fail.
  toc=""
  if xcrun xctrace export --input "$trace" --toc --output "$OUT/run-$n.toc.xml" >> "$OUT/run-$n.xctrace.log" 2>&1; then
    toc="run-$n.toc.xml"
  else
    echo "profile-session: note: could not export a table of contents for run $n"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$n" "run-$n.trace" "$status" "$seconds" "$toc" >> "$TMP/runs.tsv"
  echo "profile-session: run $n done in ${seconds}s (xctrace exit $status)"
  n=$(( n + 1 ))
done
write_conditions

if [ "$PLUMBING" = 1 ]; then echo "*** $NOTE ***"; fi
echo "profile-session: $RUNS traces and conditions.json in $OUT"
