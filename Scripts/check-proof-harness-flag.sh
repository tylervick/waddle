#!/bin/bash
# Refuses a tree where the Revyl proof-of-changes overlay flag has come apart.
#
# OverlayPresenter hides the touch overlay whenever GameController reports an
# attached keyboard or gamepad, which Revyl's devices evidently do -- the first
# proof-of-changes run failed the "overlay is visible" invariant for exactly
# that reason, and the invariant was softened to excuse it. XCUITest solves
# this with the WADDLE_FORCE_TOUCH_OVERLAY launch environment variable, but
# proof-of-changes drives an already-installed app and .revyl/config.yaml
# accepts no launch-variable field at ANY level (every candidate name was
# probed against `revyl config validate`; proof_of_changes takes only enabled /
# harness / always_verify / system_prompt). So the flag is compiled in instead.
# See docs/learnings/revyl-proof-cannot-set-launch-env.md.
#
# That leaves three things that must agree, in three different files, none of
# which fails loudly on its own:
#
#   1. App/Sources/Touch/OverlayPresenter.swift must still read the symbol.
#      Delete the `#if` and both build flags become dead settings that no
#      compiler or linter complains about.
#   2. .github/workflows/ci.yml must set it on the revyl-preview build. THIS
#      is the build proof-of-changes installs -- .revyl/config.yaml sets
#      pr_review.build.kind: ci_upload_to_revyl, so its own build_commands do
#      not run on the pull-request path at all.
#   3. .revyl/config.yaml must set it on build_commands, for `revyl build` /
#      `revyl test run --build`, which DO use that recipe.
#
# Both settings are matched as the exact string, single quotes included,
# because the quoting is load-bearing twice: bare, the runner's shell expands
# $(inherited) as command substitution; absent, xcodebuild's command-line
# override REPLACES the Debug value rather than extending it, silently dropping
# DEBUG and with it every `#if DEBUG` seam in the app (WADDLE_FORCE_TOUCH_OVERLAY,
# WADDLE_RESET_STORE, WADDLE_TOUCH_SCHEME). A build with the flag but without
# $(inherited) still compiles and still runs; it just quietly stops being a
# Debug build.
#
# Finally: while the flag is in force the overlay has no legitimate reason to
# be missing, so the old exemption wording must not creep back into the
# always_verify invariant or the system prompt. A config that both forces the
# overlay and tells the agent its absence is fine proves nothing.
#
# There is no skip path. Every input is a tracked file in this repository; if
# one is unreadable that is a failure, not an absence.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Overridable so the test suite can point the guard at fixtures instead of the
# real tree. Callers in CI pass nothing.
SWIFT_FILE="${PROOF_HARNESS_SWIFT_FILE:-$ROOT/App/Sources/Touch/OverlayPresenter.swift}"
CI_FILE="${PROOF_HARNESS_CI_FILE:-$ROOT/.github/workflows/ci.yml}"
REVYL_FILE="${PROOF_HARNESS_REVYL_FILE:-$ROOT/.revyl/config.yaml}"

# Built by concatenation rather than written literally: the needle contains
# single quotes AND a $(...) that must survive into grep unexpanded.
SQ="'"
NEEDLE="SWIFT_ACTIVE_COMPILATION_CONDITIONS=${SQ}\$(inherited) WADDLE_PROOF_HARNESS${SQ}"

violations=0
err() {
    echo "error: $1" >&2
    violations=$((violations + 1))
}

for f in "$SWIFT_FILE" "$CI_FILE" "$REVYL_FILE"; do
    if [ ! -r "$f" ]; then
        err "cannot read $f"
    fi
done
if [ "$violations" -ne 0 ]; then
    echo "check-proof-harness-flag: $violations problem(s)" >&2
    exit 1
fi

# 1. The app still reads the symbol. Anchored to a `#if` so that a mention in
#    a comment alone -- which is what a half-finished revert leaves behind --
#    does not satisfy it.
if ! grep -Eq '^[[:space:]]*#if[[:space:]]+WADDLE_PROOF_HARNESS[[:space:]]*$' "$SWIFT_FILE"; then
    err "$SWIFT_FILE no longer has a '#if WADDLE_PROOF_HARNESS' branch, so both build flags below are dead settings"
fi

# 2 and 3. Both builds set it, with the quoting intact.
if ! grep -Fq "$NEEDLE" "$CI_FILE"; then
    err "$CI_FILE does not pass ${NEEDLE} -- this is the build proof-of-changes installs (pr_review.build.kind: ci_upload_to_revyl), so without it the flag never reaches a pull-request proof run"
fi
if ! grep -Fq "$NEEDLE" "$REVYL_FILE"; then
    err "$REVYL_FILE does not pass ${NEEDLE} on build_commands -- 'revyl build' and 'revyl test run --build' would produce an artifact whose overlay still hides"
fi

# 4. The exemption must not come back while the flag is in force. Matched as
#    the phrase the original invariant and system prompt both used.
if grep -Fq "its absence is correct" "$REVYL_FILE"; then
    err "$REVYL_FILE still tells the proof agent that a missing overlay is correct, which contradicts WADDLE_PROOF_HARNESS forcing it visible; drop the exemption or drop the flag"
fi

if [ "$violations" -ne 0 ]; then
    echo "check-proof-harness-flag: $violations problem(s)" >&2
    exit 1
fi

echo "check-proof-harness-flag: ok - symbol read in Swift, flag set in both builds, no stale exemption"
