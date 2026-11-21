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
# workflows carry the iPad and Duo pins and a `${{ env... }}` use, mise.toml
# carries the iPad leg, and the dispatch inputs carry a second input with its
# own default, because those are the lines a loose match would mistake for
# the phone's.
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
on:
  workflow_dispatch:
    inputs:
      device:
        description: Simulator device name
        required: false
        default: "iPhone 18 Pro"
      only_testing:
        description: Optional -only-testing filter
        required: false
        default: ""
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

- `device` — simulator device name. Default `iPhone 18 Pro`.
- `only_testing` — an optional `-only-testing` filter.
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

# Rewrites one fixture file through a sed expression, for the files that now
# name the phone on two lines the guard holds to separate rules: a case must
# still break exactly one of them.
edit() { # file sed-expression
    sed "$2" "$1" > "$1.new"
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

# 2b. The stale phone on the live DEVICE= line and the right default only in
#     a comment (issue #416): rule 5 loosened from a whole-line match to a
#     substring match would be satisfied by the comment.
make_fixture "$TMP/provcomment"; leave_behind "$TMP/provcomment/provision-test-wads.sh"
echo '# was: DEVICE="${1:-iPhone 18 Pro}"' >> "$TMP/provcomment/provision-test-wads.sh"
expect_refusal "$TMP/provcomment" "provision-test-wads.sh does not default" "provisioning default in a comment"
pass "the right provisioning default in a comment does not satisfy the check"

# 3. mise.toml left on the old phone, with the iPad leg intact -- so the
#    iPad's destination line must not be able to stand in for the phone's.
make_fixture "$TMP/mise"; leave_behind "$TMP/mise/mise.toml"
expect_refusal "$TMP/mise" "mise.toml does not run the whole scheme" "stale mise.toml"
pass "a mise.toml phone leg on another phone is refused"

# 3b. The stale phone on the live line and the right one only in a comment
#     above it (review of PR #407): a substring match was satisfied by the
#     comment and reported a clean tree.
make_fixture "$TMP/misecomment"; leave_behind "$TMP/misecomment/mise.toml"
echo "#   -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test" >> "$TMP/misecomment/mise.toml"
expect_refusal "$TMP/misecomment" "mise.toml does not run the whole scheme" "mise.toml destination in a comment"
pass "the right mise.toml destination in a comment does not satisfy the check"

# 3c. Two live whole-scheme legs, one right and one stale: the right one must
#     not vouch for the other.
make_fixture "$TMP/misetwo"
echo "  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test" >> "$TMP/misetwo/mise.toml"
expect_refusal "$TMP/misetwo" "mise.toml has 2 whole-scheme test legs" "two phone legs"
pass "a second whole-scheme leg on another phone is refused"

# 3d. No whole-scheme leg at all (the command reshaped, or the task removed)
#     fails closed and says the leg is missing, not that it is stale.
make_fixture "$TMP/misenone"
grep -v "' test\$" "$TMP/misenone/mise.toml" > "$TMP/misenone/mise.new"
mv "$TMP/misenone/mise.new" "$TMP/misenone/mise.toml"
expect_refusal "$TMP/misenone" "mise.toml has 0 whole-scheme test legs" "no phone leg"
pass "a mise.toml with no whole-scheme leg fails closed"

# 4. The README's copy of the command left behind. Only the command line:
#    the dispatch-input line below it is rule 7's (cases 4b-4d).
make_fixture "$TMP/readme"
edit "$TMP/readme/README.md" "/' test\$/s/iPhone 18 Pro/iPhone 17 Pro/"
expect_refusal "$TMP/readme" "README.md does not run the whole scheme" "stale README"
pass "a README command on another phone is refused"

# 4b. The README's statement of the dispatch `device` default left behind
#     (issue #416), with the command above it right.
make_fixture "$TMP/readmedefault"
edit "$TMP/readmedefault/README.md" '/^- `device`/s/iPhone 18 Pro/iPhone 17 Pro/'
expect_refusal "$TMP/readmedefault" \
    "README.md documents the dispatch 'device' default as \"iPhone 17 Pro\"" "stale README dispatch default"
pass "a README dispatch default on another phone is refused"

# 4c. The line gone or reworded past recognition fails closed: an unread
#     line is not an agreeing one.
make_fixture "$TMP/readmenone"
edit "$TMP/readmenone/README.md" '/^- `device`/d'
expect_refusal "$TMP/readmenone" "README.md has no '- \`device\`" "README without the dispatch default"
pass "a README with no dispatch-default line fails closed"

# 4d. Two such lines, one right and one stale: the right one must not vouch
#     for the other.
make_fixture "$TMP/readmetwo"
echo '- `device` — simulator device name. Default `iPhone 17 Pro`.' >> "$TMP/readmetwo/README.md"
expect_refusal "$TMP/readmetwo" "README.md has 2 " "two README dispatch defaults"
pass "a second README dispatch-default line is refused"

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

# 5d. A correct default line and a later plain reassignment to the old phone
#     (issue #416): the default line is there, and the script would still run
#     on the stale destination.
make_fixture "$TMP/rgtwice"
echo 'RG_DESTINATION="platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2"' >> "$TMP/rgtwice/check-red-green.sh"
expect_refusal "$TMP/rgtwice" "check-red-green.sh assigns RG_DESTINATION on 2 lines" "second red-green assignment"
pass "a second RG_DESTINATION assignment is refused"

# 6. ui-tests.yml on another device, then on another OS. Only the env pin:
#    the dispatch default above it is rule 6's (cases 6b-6d).
make_fixture "$TMP/uidev"
edit "$TMP/uidev/ui-tests.yml" '/^  SIMULATOR_DEVICE: /s/iPhone 18 Pro/iPhone 17 Pro/'
expect_refusal "$TMP/uidev" 'ui-tests.yml pins SIMULATOR_DEVICE "iPhone 17 Pro"' "stale ui-tests device"
make_fixture "$TMP/uios"
sed 's/SIMULATOR_OS: "27.0"/SIMULATOR_OS: "26.2"/' "$TMP/uios/ui-tests.yml" > "$TMP/uios/ui.new"
mv "$TMP/uios/ui.new" "$TMP/uios/ui-tests.yml"
expect_refusal "$TMP/uios" 'ui-tests.yml pins SIMULATOR_OS "26.2"' "stale ui-tests OS"
pass "ui-tests.yml on another device or OS is refused"

# 6b. The workflow_dispatch `device` default left behind with the env pin
#     right (issue #416). A dispatch always carries the default, so this is
#     the phone every `gh workflow run ui-tests.yml` asks the runner for.
make_fixture "$TMP/uidefault"
edit "$TMP/uidefault/ui-tests.yml" '/^        default: /s/iPhone 18 Pro/iPhone 17 Pro/'
expect_refusal "$TMP/uidefault" \
    "ui-tests.yml defaults the dispatch 'device' input to \"iPhone 17 Pro\"" "stale dispatch default"
pass "a dispatch device default on another phone is refused"

# 6c. The stale default on `device`, and the right phone as ANOTHER input's
#     default: a match on any `default:` line would take the neighbour's.
make_fixture "$TMP/uineighbour"
edit "$TMP/uineighbour/ui-tests.yml" '/^        default: /s/iPhone 18 Pro/iPhone 17 Pro/'
edit "$TMP/uineighbour/ui-tests.yml" 's/^        default: ""$/        default: "iPhone 18 Pro"/'
expect_refusal "$TMP/uineighbour" \
    "ui-tests.yml defaults the dispatch 'device' input to \"iPhone 17 Pro\"" "neighbouring input default"
pass "another input's default does not stand in for the device input's"

# 6d. The default gone (the input removed, or reshaped past recognition)
#     fails closed. The neighbour's default is still there and must not be
#     read in its place.
make_fixture "$TMP/uinodefault"
edit "$TMP/uinodefault/ui-tests.yml" '/^        default: "iPhone 18 Pro"$/d'
expect_refusal "$TMP/uinodefault" "ui-tests.yml has no workflow_dispatch 'device' input" "no dispatch default"
pass "a ui-tests.yml with no dispatch device default fails closed"

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
    *"check-simulator-pins: 7 problem(s)"*) ;;
    *) fail "expected all seven dependents reported after a ci.yml bump; got: $out" ;;
esac
pass "a ci.yml bump nothing followed reports every dependent"

# 8. ci.yml with no SIMULATOR_DEVICE pin (renamed, or moved into a matrix)
#    fails closed. The iPad and Duo pins are still there and must not be read
#    in its place; an empty device would otherwise "match" nothing and the
#    error would blame seven innocent lines.
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

# 8c. A SIMULATOR_DEVICE at another nesting depth -- a step-level `env:`, as
#     a job that needs a second phone would write it -- is not the
#     workflow-level pin, in either workflow (issue #416). Accepted: with the
#     two-space anchor dropped from pin_values each file would "pin twice".
make_fixture "$TMP/nested"
for f in ci.yml ui-tests.yml; do
    cat >> "$TMP/nested/$f" <<'NESTED'
jobs:
  other:
    steps:
      - env:
          SIMULATOR_DEVICE: "iPhone 17 Pro"
          SIMULATOR_OS: "26.2"
NESTED
done
out="$(check "$TMP/nested" 2>&1)" || fail "read a step-level SIMULATOR_DEVICE as the workflow pin; got: $out"
pass "a pin at another nesting depth is not read as the workflow-level pin"

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
