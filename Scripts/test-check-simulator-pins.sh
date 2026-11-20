#!/bin/bash
# Tests for Scripts/check-simulator-pins.sh.
#
# Fully HERMETIC for the discrimination cases: every one builds its own set of
# six fixture files under $TMP and points the guard at them with the
# SIMULATOR_PINS_*_FILE overrides. Nothing there reads the repository.
#
# The last case is the deliberate exception, on the model of
# test-check-masked-gh-status.sh: it runs the guard against the REAL tree, so
# that a pin drifting in ci.yml, mise.toml or a script fails CI rather than
# passing a suite made entirely of fixtures.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# Builds a passing fixture set in $1. Callers then edit one file to break one
# rule, so every case differs from a passing tree in exactly one way. The
# workflows carry the iPad and Duo pins and a `${{ env... }}` use, and
# mise.toml carries the iPad leg, because those are the lines a loose match
# would mistake for the phone's.
make_fixture() { # dir
    mkdir -p "$1"
    cat > "$1/ci.yml" <<'CI'
env:
  XCODE_VERSION: "27.1"
  # SIMULATOR_OS: "26.2" was the pin before the bump.
  SIMULATOR_OS: "27.0"
  SIMULATOR_DEVICE: "iPhone 18 Pro"
  SIMULATOR_DEVICE_IPAD: "iPad Pro 13-inch (M4)"
  SIMULATOR_DEVICE_DUO: "iPhone Duo"
  SIMULATOR_OS_DUO: "27.1"
jobs:
  build:
    steps:
      - env:
          DESTINATION: platform=iOS Simulator,name=${{ env.SIMULATOR_DEVICE }},OS=${{ env.SIMULATOR_OS }}
CI
    cat > "$1/ui-tests.yml" <<'UI'
env:
  SIMULATOR_OS: "27.0"
  SIMULATOR_DEVICE: "iPhone 18 Pro"
UI
    cat > "$1/check-red-green.sh" <<'RG'
#!/bin/bash
# Overridable so the hermetic suite never needs a real simulator.
RG_DESTINATION="${RG_DESTINATION:-platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0}"
RG
    cat > "$1/mise.toml" <<'MISE'
run = """
xcodebuild -project App/Waddle.xcodeproj -scheme Waddle \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' \
  -only-testing:WaddleTests test
xcodebuild -project App/Waddle.xcodeproj -scheme Waddle \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test
"""
MISE
    cat > "$1/README.md" <<'README'
xcodebuild -project App/Waddle.xcodeproj -scheme Waddle \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test
README
    cat > "$1/provision-test-wads.sh" <<'PROV'
#!/bin/bash
set -euo pipefail
DEVICE="${1:-iPhone 18 Pro}"
PROV
}

check() { # dir
    env SIMULATOR_PINS_CI_FILE="$1/ci.yml" \
        SIMULATOR_PINS_UI_TESTS_FILE="$1/ui-tests.yml" \
        SIMULATOR_PINS_RED_GREEN_FILE="$1/check-red-green.sh" \
        SIMULATOR_PINS_MISE_FILE="$1/mise.toml" \
        SIMULATOR_PINS_README_FILE="$1/README.md" \
        SIMULATOR_PINS_PROVISION_FILE="$1/provision-test-wads.sh" \
        "$ROOT/Scripts/check-simulator-pins.sh"
}

# Replaces every "iPhone 18 Pro" in one fixture file with "iPhone 17 Pro":
# the #360 shape, one file left behind by a bump.
leave_behind() { # file
    sed 's/iPhone 18 Pro/iPhone 17 Pro/g' "$1" > "$1.new"
    mv "$1.new" "$1"
}

# Asserts the guard refuses dir, with exactly one problem, naming `needle`.
# "Exactly one" matters: a case that breaks one file and gets two errors is
# passing for a reason it does not understand.
expect_refusal() { # dir needle label
    local out
    if out="$(check "$1" 2>&1)"; then
        fail "$3: accepted; got: $out"
    fi
    case "$out" in
        *"$2"*) ;;
        *) fail "$3: refused without naming '$2'; got: $out" ;;
    esac
    case "$out" in
        *"check-simulator-pins: 1 problem(s)"*) ;;
        *) fail "$3: expected exactly one problem; got: $out" ;;
    esac
}

# 1. The shape the repository is meant to be in -> exit 0. Without this case
#    every later case could be passing because the guard refuses everything.
make_fixture "$TMP/good"
out="$(check "$TMP/good" 2>&1)" || fail "refused a consistent tree; got: $out"
case "$out" in
    *'"iPhone 18 Pro" (iOS 27.0)'*) ;;
    *) fail "did not report the pin it read; got: $out" ;;
esac
pass "a tree where every file names ci.yml's simulator is accepted"

# 2. provision-test-wads.sh left on the old phone. This is the defect PR
#    #404's review found: the documented no-argument provisioning step put
#    RealWADTests' fixtures on a simulator `mise run test` does not use.
make_fixture "$TMP/prov"; leave_behind "$TMP/prov/provision-test-wads.sh"
expect_refusal "$TMP/prov" "provision-test-wads.sh does not default" "stale provisioning default"
pass "a provisioning default on another phone is refused"

# 3. mise.toml left on the old phone, with the iPad leg intact -- so the
#    iPad's destination line must not be able to stand in for the phone's.
make_fixture "$TMP/mise"; leave_behind "$TMP/mise/mise.toml"
expect_refusal "$TMP/mise" "mise.toml does not run the whole scheme" "stale mise.toml"
pass "a mise.toml phone leg on another phone is refused"

# 4. The README's copy of the command left behind.
make_fixture "$TMP/readme"; leave_behind "$TMP/readme/README.md"
expect_refusal "$TMP/readme" "README.md does not run the whole scheme" "stale README"
pass "a README command on another phone is refused"

# 5. check-red-green.sh's default left on the old phone.
make_fixture "$TMP/rgdev"; leave_behind "$TMP/rgdev/check-red-green.sh"
expect_refusal "$TMP/rgdev" "check-red-green.sh does not default" "stale red-green device"
pass "a red-green default on another phone is refused"

# 5b. Right phone, wrong OS. The default carries both, and iPhone 18 Pro does
#     not exist on every runtime, so a device-only comparison would pass a
#     destination xcodebuild cannot resolve.
make_fixture "$TMP/rgos"
sed 's/OS=27.0}/OS=26.2}/' "$TMP/rgos/check-red-green.sh" > "$TMP/rgos/rg.new"
mv "$TMP/rgos/rg.new" "$TMP/rgos/check-red-green.sh"
expect_refusal "$TMP/rgos" "check-red-green.sh does not default" "stale red-green OS"
pass "a red-green default on another OS is refused"

# 5c. The right destination only in a comment, the live default stale: what a
#     half-finished edit leaves behind.
make_fixture "$TMP/rgcomment"; leave_behind "$TMP/rgcomment/check-red-green.sh"
echo '# was: RG_DESTINATION="${RG_DESTINATION:-platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0}"' \
    >> "$TMP/rgcomment/check-red-green.sh"
expect_refusal "$TMP/rgcomment" "check-red-green.sh does not default" "red-green default in a comment"
pass "the right default in a comment does not satisfy the check"

# 6. ui-tests.yml on another device, then on another OS.
make_fixture "$TMP/uidev"; leave_behind "$TMP/uidev/ui-tests.yml"
expect_refusal "$TMP/uidev" 'ui-tests.yml pins SIMULATOR_DEVICE "iPhone 17 Pro"' "stale ui-tests device"
make_fixture "$TMP/uios"
sed 's/SIMULATOR_OS: "27.0"/SIMULATOR_OS: "26.2"/' "$TMP/uios/ui-tests.yml" > "$TMP/uios/ui.new"
mv "$TMP/uios/ui.new" "$TMP/uios/ui-tests.yml"
expect_refusal "$TMP/uios" 'ui-tests.yml pins SIMULATOR_OS "26.2"' "stale ui-tests OS"
pass "ui-tests.yml on another device or OS is refused"

# 7. ci.yml itself moves and nothing follows: the PR #349 shape, seen from the
#    other side. Every dependent is then wrong at once, and the guard must say
#    so for each rather than stop at the first -- the list is the to-do list.
make_fixture "$TMP/bump"
sed 's/SIMULATOR_DEVICE: "iPhone 18 Pro"/SIMULATOR_DEVICE: "iPhone 19 Pro"/' "$TMP/bump/ci.yml" > "$TMP/bump/ci.new"
mv "$TMP/bump/ci.new" "$TMP/bump/ci.yml"
if out="$(check "$TMP/bump" 2>&1)"; then
    fail "accepted a ci.yml bump nothing followed; got: $out"
fi
case "$out" in
    *"check-simulator-pins: 5 problem(s)"*) ;;
    *) fail "expected all five dependents reported after a ci.yml bump; got: $out" ;;
esac
pass "a ci.yml bump nothing followed reports every dependent"

# 8. ci.yml with no SIMULATOR_DEVICE pin (renamed, or moved into a matrix)
#    fails closed. The iPad and Duo pins are still there and must not be read
#    in its place; an empty device would otherwise "match" nothing and the
#    error would blame five innocent files.
make_fixture "$TMP/nopin"
grep -v '^  SIMULATOR_DEVICE: ' "$TMP/nopin/ci.yml" > "$TMP/nopin/ci.new"
mv "$TMP/nopin/ci.new" "$TMP/nopin/ci.yml"
expect_refusal "$TMP/nopin" "has no '  SIMULATOR_DEVICE:" "ci.yml without the pin"
pass "a ci.yml with no phone pin fails closed, and the iPad pin is not read for it"

# 8b. Two SIMULATOR_DEVICE pins: there is no single source of truth to hold
#     the others to.
make_fixture "$TMP/twopins"
echo '  SIMULATOR_DEVICE: "iPhone 17 Pro"' >> "$TMP/twopins/ci.yml"
expect_refusal "$TMP/twopins" "pins SIMULATOR_DEVICE 2 times" "ci.yml with two pins"
pass "a ci.yml that pins the phone twice is refused"

# 9. An unreadable input is a failure, not a skip: every input is a tracked
#    file, so its absence means the guard was pointed at the wrong place or
#    the file was renamed out from under it.
make_fixture "$TMP/missing"; rm "$TMP/missing/provision-test-wads.sh"
expect_refusal "$TMP/missing" "cannot read" "missing input"
pass "a missing input file fails closed"

# 10. NOT hermetic, on purpose: the real tree. Fixtures prove the rule; this
#     is what makes it bite when a pin moves.
out="$("$ROOT/Scripts/check-simulator-pins.sh" 2>&1)" \
    || fail "the repository's own simulator pins disagree; got: $out"
pass "the repository's own pins agree"

echo "All check-simulator-pins tests passed."
