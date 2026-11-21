#!/bin/bash
# Refuses a tree where the iPhone simulator named outside the workflows has
# come apart from the one ci.yml pins.
#
# Issue #360: the Xcode 27.1 bump (PR #349) moved SIMULATOR_DEVICE in ci.yml
# to iPhone 18 Pro, because the xcode-27 runner image has no iPhone 17 Pro,
# and left four other places naming the old phone: `mise run test`, the
# README's copy of that command, the default destination of
# Scripts/check-red-green.sh, and the default device of
# Scripts/provision-test-wads.sh. Nothing failed. Each is only ever run by
# hand, so the drift sat for eleven days, and the first fix (PR #404) still
# missed the last one -- which would have provisioned RealWADTests' fixtures
# onto a different simulator from the one `mise run test` runs them on.
#
# ci.yml's env block is the source of truth: SIMULATOR_DEVICE and
# SIMULATOR_OS. Everything else must say the same thing:
#
#   1. .github/workflows/ui-tests.yml pins the same two values.
#   2. Scripts/check-red-green.sh defaults RG_DESTINATION to that device AND
#      that OS (its suite's stubbed simulator list follows the default; the
#      suite itself fails if those two part), and assigns it nowhere else.
#   3. mise.toml's whole-scheme leg names that device.
#   4. README.md's copy of that command names that device.
#   5. Scripts/provision-test-wads.sh defaults to that device, so the
#      documented no-argument provisioning step lands on the simulator
#      RealWADTests then runs on.
#   6. ui-tests.yml's workflow_dispatch `device` input defaults to that
#      device. A manual dispatch always has inputs.device set to this default,
#      and the workflow reads `inputs.device || env.SIMULATOR_DEVICE`, so on a
#      dispatch this line, not the env pin of rule 1, picks the phone
#      (issue #416).
#   7. README.md's description of that input states the same default.
#
# 3-7 carry no OS on purpose (see the note in mise.toml), so only the device
# name is compared there.
#
# There is no skip path. Every input is a tracked file in this repository; if
# one is unreadable, or ci.yml does not carry exactly one of each pin, that is
# a failure, not an absence.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Overridable so the test suite can point the guard at fixtures instead of the
# real tree. Callers in CI pass nothing.
CI_FILE="${SIMULATOR_PINS_CI_FILE:-$ROOT/.github/workflows/ci.yml}"
UI_FILE="${SIMULATOR_PINS_UI_TESTS_FILE:-$ROOT/.github/workflows/ui-tests.yml}"
RG_FILE="${SIMULATOR_PINS_RED_GREEN_FILE:-$ROOT/Scripts/check-red-green.sh}"
MISE_FILE="${SIMULATOR_PINS_MISE_FILE:-$ROOT/mise.toml}"
README_FILE="${SIMULATOR_PINS_README_FILE:-$ROOT/README.md}"
PROVISION_FILE="${SIMULATOR_PINS_PROVISION_FILE:-$ROOT/Scripts/provision-test-wads.sh}"

violations=0
err() {
    echo "error: $1" >&2
    violations=$((violations + 1))
}
finish_if_violations() {
    if [ "$violations" -ne 0 ]; then
        echo "check-simulator-pins: $violations problem(s)" >&2
        exit 1
    fi
}

for f in "$CI_FILE" "$UI_FILE" "$RG_FILE" "$MISE_FILE" "$README_FILE" "$PROVISION_FILE"; do
    if [ ! -r "$f" ]; then
        err "cannot read $f"
    fi
done
finish_if_violations

# Prints the quoted value of a two-space-indented `KEY: "value"` line, one per
# match. The exact indentation and the trailing colon keep SIMULATOR_DEVICE
# from matching SIMULATOR_DEVICE_IPAD / _DUO, and keep a mention in a comment
# or a `${{ env.KEY }}` use from counting as a pin.
pin_values() { # file key
    sed -n -E "s/^  $2: \"([^\"]*)\"[[:space:]]*\$/\\1/p" "$1"
}

# Sets PIN to the single value of key in file, or records a violation. A
# global rather than stdout, because err() counts in this shell and a
# command substitution would discard the count
# (docs/learnings/command-substitution-discards-callee-state.md).
PIN=""
read_pin() { # file key
    local values count
    PIN=""
    values="$(pin_values "$1" "$2")"
    if [ -z "$values" ]; then
        err "$1 has no '  $2: \"...\"' line; it must pin exactly one"
        return 0
    fi
    count="$(printf '%s\n' "$values" | wc -l | tr -d ' ')"
    if [ "$count" -ne 1 ]; then
        err "$1 pins $2 $count times; it must pin exactly one"
        return 0
    fi
    PIN="$values"
}

# Sets PIN to the single line in `values`, or records a violation naming
# `what` in `file`. For the values that are not `KEY: "value"` pins.
read_one() { # file what values
    local count
    PIN=""
    if [ -z "$3" ]; then
        err "$1 has no $2; it must have exactly one"
        return 0
    fi
    count="$(printf '%s\n' "$3" | wc -l | tr -d ' ')"
    if [ "$count" -ne 1 ]; then
        err "$1 has $count $2 lines; it must have exactly one"
        return 0
    fi
    PIN="$3"
}

# Prints the quoted `default:` of the `device` input under
# `on.workflow_dispatch.inputs`, one per match. Scoped by indentation: the
# block opens at a two-space `workflow_dispatch:` and a six-space `device:`,
# and closes at the next line indented no deeper than its opener, so another
# input's default, or a `device:` key elsewhere in the file, is not read for
# it. Blank lines and comments neither close a block nor count as a default.
dispatch_device_defaults() { # file
    awk '
        /^[[:space:]]*(#|$)/ { next }
        { match($0, /^ */); indent = RLENGTH }
        indent <= 2 { in_dispatch = 0; in_device = 0 }
        /^  workflow_dispatch:[[:space:]]*$/ { in_dispatch = 1; next }
        in_dispatch && indent <= 6 { in_device = 0 }
        in_dispatch && /^      device:[[:space:]]*$/ { in_device = 1; next }
        in_device && /^        default: "[^"]*"[[:space:]]*$/ {
            sub(/^        default: "/, ""); sub(/"[[:space:]]*$/, ""); print
        }
    ' "$1"
}

read_pin "$CI_FILE" SIMULATOR_DEVICE; device="$PIN"
read_pin "$CI_FILE" SIMULATOR_OS; os="$PIN"
# Without the source of truth there is nothing to compare the rest against.
finish_if_violations

# 1. ui-tests.yml.
read_pin "$UI_FILE" SIMULATOR_DEVICE
if [ -n "$PIN" ] && [ "$PIN" != "$device" ]; then
    err "$UI_FILE pins SIMULATOR_DEVICE \"$PIN\", but ci.yml pins \"$device\""
fi
read_pin "$UI_FILE" SIMULATOR_OS
if [ -n "$PIN" ] && [ "$PIN" != "$os" ]; then
    err "$UI_FILE pins SIMULATOR_OS \"$PIN\", but ci.yml pins \"$os\""
fi

# 2. check-red-green.sh's default. Matched as the whole assignment so a
#    mention of the destination in a comment does not satisfy it, and exactly
#    one line may begin `RG_DESTINATION=`: a later reassignment would win over
#    a correct default line. grep -c exits 1 on a count of zero, which is an
#    answer here, not a failure; the file was proven readable above.
want="RG_DESTINATION=\"\${RG_DESTINATION:-platform=iOS Simulator,name=$device,OS=$os}\""
assignments="$(grep -c '^RG_DESTINATION=' "$RG_FILE" || true)"
if [ "$assignments" -gt 1 ]; then
    err "$RG_FILE assigns RG_DESTINATION on $assignments lines; expected only the default: $want"
elif ! grep -Fxq "$want" "$RG_FILE"; then
    err "$RG_FILE does not default to ci.yml's simulator; expected the line: $want"
fi

# 3 and 4. The whole-scheme `xcodebuild ... test` leg, in mise.toml and in the
#    README's copy of it. Anchored on the trailing "' test" so the iPad leg,
#    which ends "' \", cannot stand in for it, and matched as a whole line so
#    the right destination in a comment does not excuse a stale live one.
#    Exactly one such line per file: with two there would be a second
#    whole-scheme leg this guard was never told about.
want="  -destination 'platform=iOS Simulator,name=$device' test"
for f in "$MISE_FILE" "$README_FILE"; do
    # grep -c exits 1 on a count of zero, which is an answer here, not a
    # failure; the files were proven readable above.
    legs="$(grep -Ec "^  -destination 'platform=iOS Simulator,name=[^']*' test\$" "$f" || true)"
    if [ "$legs" -ne 1 ]; then
        err "$f has $legs whole-scheme test legs (lines of the form \"$want\"); expected exactly one"
    elif ! grep -Fxq -- "$want" "$f"; then
        err "$f does not run the whole scheme on ci.yml's simulator; expected the line: $want"
    fi
done

# 5. provision-test-wads.sh's default device.
want="DEVICE=\"\${1:-$device}\""
if ! grep -Fxq "$want" "$PROVISION_FILE"; then
    err "$PROVISION_FILE does not default to ci.yml's simulator; expected the line: $want"
fi

# 6. The device a manual UI Tests dispatch runs on.
read_one "$UI_FILE" "workflow_dispatch 'device' input with a '        default: \"...\"' line" \
    "$(dispatch_device_defaults "$UI_FILE")"
if [ -n "$PIN" ] && [ "$PIN" != "$device" ]; then
    err "$UI_FILE defaults the dispatch 'device' input to \"$PIN\", but ci.yml pins \"$device\""
fi

# 7. The README's statement of that default. The line is found by its
#    opening "- `device` " and read up to its closing "Default `...`.", so a
#    reworded line reports as missing instead of passing unread.
read_one "$README_FILE" "'- \`device\` ... Default \`...\`.' line documenting the dispatch input" \
    "$(sed -n -E 's/^- `device` .* Default `([^`]*)`\.[[:space:]]*$/\1/p' "$README_FILE")"
if [ -n "$PIN" ] && [ "$PIN" != "$device" ]; then
    err "$README_FILE documents the dispatch 'device' default as \"$PIN\", but ci.yml pins \"$device\""
fi

finish_if_violations
echo "check-simulator-pins: ok - \"$device\" (iOS $os) in ci.yml, ui-tests.yml (pin and dispatch default), check-red-green.sh, mise.toml, README.md (command and dispatch default) and provision-test-wads.sh"
