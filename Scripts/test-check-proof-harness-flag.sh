#!/bin/bash
# Tests for Scripts/check-proof-harness-flag.sh.
#
# Fully HERMETIC for the discrimination cases: every one builds its own trio of
# fixture files under $TMP and points the guard at them with the
# PROOF_HARNESS_*_FILE overrides. Nothing there reads the repository.
#
# Case 7 is the deliberate exception, on the model of
# test-check-masked-gh-status.sh: it runs the guard against the REAL tree, so
# that dropping the flag from ci.yml or .revyl/config.yaml fails CI rather than
# passing a suite made entirely of fixtures.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

SQ="'"
GOOD_SETTING="SWIFT_ACTIVE_COMPILATION_CONDITIONS=${SQ}\$(inherited) WADDLE_PROOF_HARNESS${SQ}"

# Builds a fixture trio in $1. Callers then edit one file to break one rule,
# so every case differs from a passing tree in exactly one way.
make_fixture() { # dir
    mkdir -p "$1"
    cat > "$1/OverlayPresenter.swift" <<'SWIFT'
    private var overlayForcedVisibleByHarness: Bool {
        #if WADDLE_PROOF_HARNESS
        return true
        #elseif DEBUG
        return ProcessInfo.processInfo.environment["WADDLE_FORCE_TOUCH_OVERLAY"] != nil
        #else
        return false
        #endif
    }
SWIFT
    cat > "$1/ci.yml" <<CI
          xcodebuild -project App/Waddle.xcodeproj -scheme Waddle \\
            ENABLE_DEBUG_DYLIB=NO CODE_SIGNING_ALLOWED=NO ARCHS=arm64 \\
            ${GOOD_SETTING} \\
            build
CI
    cat > "$1/config.yaml" <<REVYL
                build_commands:
                    - xcodebuild -project App/Waddle.xcodeproj ARCHS=arm64 ${GOOD_SETTING}
        always_verify:
            - "Once in a game, the touch control overlay is visible over the rendered view."
REVYL
}

check() { # dir
    env PROOF_HARNESS_SWIFT_FILE="$1/OverlayPresenter.swift" \
        PROOF_HARNESS_CI_FILE="$1/ci.yml" \
        PROOF_HARNESS_REVYL_FILE="$1/config.yaml" \
        "$ROOT/Scripts/check-proof-harness-flag.sh"
}

# 1. The shape the repository is meant to be in -> exit 0. Without this case
#    every later case could be passing for the wrong reason (e.g. the guard
#    refusing everything).
make_fixture "$TMP/ok"
check "$TMP/ok" >/dev/null || fail "refused a correctly wired tree"
pass "accepts a tree with the symbol read and the flag set in both builds"

# 2. The Swift branch deleted but the build flags left behind. This is what a
#    partial revert leaves, and it is invisible to the compiler: both settings
#    stay valid, they just stop meaning anything.
make_fixture "$TMP/noswift"
cat > "$TMP/noswift/OverlayPresenter.swift" <<'SWIFT'
    // WADDLE_PROOF_HARNESS used to be read here.
    private var overlayForcedVisibleByHarness: Bool { false }
SWIFT
if check "$TMP/noswift" >/dev/null 2>&1; then
    fail "accepted a tree whose Swift no longer reads WADDLE_PROOF_HARNESS"
fi
pass "rejects a mention in a comment as a substitute for a '#if' branch"

# 3. Flag missing from ci.yml. The important one: .revyl/config.yaml sets
#    pr_review.build.kind: ci_upload_to_revyl, so this is the ONLY build a
#    pull-request proof run ever installs, and a tree that sets the flag only
#    in .revyl/config.yaml looks correct while doing nothing.
make_fixture "$TMP/noci"
cat > "$TMP/noci/ci.yml" <<'CI'
          xcodebuild -project App/Waddle.xcodeproj -scheme Waddle \
            ENABLE_DEBUG_DYLIB=NO CODE_SIGNING_ALLOWED=NO ARCHS=arm64 \
            build
CI
if check "$TMP/noci" >/dev/null 2>&1; then
    fail "accepted a tree with no flag on the ci.yml revyl-preview build"
fi
pass "rejects a tree where only .revyl/config.yaml carries the flag"

# 4. Flag missing from .revyl/config.yaml -- the reverse gap, which breaks
#    `revyl build` and `revyl test run --build` while pull requests stay fine.
make_fixture "$TMP/norevyl"
cat > "$TMP/norevyl/config.yaml" <<'REVYL'
                build_commands:
                    - xcodebuild -project App/Waddle.xcodeproj ARCHS=arm64
        always_verify:
            - "Once in a game, the touch control overlay is visible over the rendered view."
REVYL
if check "$TMP/norevyl" >/dev/null 2>&1; then
    fail "accepted a tree with no flag on .revyl/config.yaml build_commands"
fi
pass "rejects a tree where only ci.yml carries the flag"

# 5. THE quoting trap, and the reason this guard matches a literal rather than
#    grepping for the symbol. Dropping $(inherited) leaves a build that still
#    compiles and still defines WADDLE_PROOF_HARNESS -- it just silently stops
#    being a Debug build, taking every `#if DEBUG` seam with it.
make_fixture "$TMP/noinherited"
cat > "$TMP/noinherited/ci.yml" <<CI
          xcodebuild -project App/Waddle.xcodeproj -scheme Waddle \\
            ARCHS=arm64 SWIFT_ACTIVE_COMPILATION_CONDITIONS=WADDLE_PROOF_HARNESS \\
            build
CI
if check "$TMP/noinherited" >/dev/null 2>&1; then
    fail "accepted SWIFT_ACTIVE_COMPILATION_CONDITIONS without \$(inherited)"
fi
pass "rejects a setting that would replace DEBUG instead of extending it"

# 6. The exemption creeping back. A config that forces the overlay visible and
#    simultaneously tells the agent a missing overlay is fine cannot fail, so
#    the invariant would silently stop testing anything.
make_fixture "$TMP/exempt"
cat >> "$TMP/exempt/config.yaml" <<'REVYL'
            - "The overlay is visible unless a hardware keyboard is attached, in which case its absence is correct."
REVYL
if check "$TMP/exempt" >/dev/null 2>&1; then
    fail "accepted a config that still excuses a missing overlay"
fi
pass "rejects the restored 'its absence is correct' exemption"

# 7. Live assertion against the real repository -- see the header. Fixtures
#    prove the guard discriminates; this is what makes it bite on a real diff.
"$ROOT/Scripts/check-proof-harness-flag.sh" >/dev/null \
    || fail "the real tree does not satisfy check-proof-harness-flag.sh"
pass "the repository itself passes the guard"

echo "All check-proof-harness-flag tests passed."
