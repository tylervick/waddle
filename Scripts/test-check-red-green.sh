#!/bin/bash
# Tests for Scripts/check-red-green.sh.
#
# Fully HERMETIC: every case builds a throwaway git repository in $TMP and
# runs the guard inside it. Nothing here reads or writes the real checkout.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# The fixture repos must not inherit the developer's git config -- signing in
# particular, since commit.gpgsign here routes through the 1Password agent and
# would make this hermetic test depend on the agent being unlocked. See
# docs/learnings/git-fixtures-inherit-signing-config.md.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

# Builds a git repo with a base commit, then applies $2 as a shell script that
# edits the tree, and commits that as HEAD. Prints the repo path.
#
# $3 is an optional second script applied *before* the base commit, for the
# cases that need a file to already exist at base -- a script whose suite is
# red at HEAD (case 24) or a pure rename (case 25) can only be expressed as a
# base-to-HEAD diff if the pre-change file is committed at base. It is a
# separate parameter rather than an addition to the shared base tree above on
# purpose: adding e.g. Scripts/foo.sh to every fixture's base would silently
# turn cases 9, 10 and 23's *added* foo.sh into a *modified* one, changing what
# their reverts do and weakening the cases without a single assertion moving.
make_repo() { # name, mutate-script, [base-mutate-script]
    d="$TMP/$1"; mkdir -p "$d"; cd "$d"
    git init -q .; git config user.email t@e.st; git config user.name T
    mkdir -p App/Sources App/Tests Scripts
    echo 'let x = 1' > App/Sources/Thing.swift
    echo 'nothing' > README.md
    # The guard under test must be committed as of base, not copied in after
    # head: copied in later it would sit untracked and trip the guard's own
    # dirty-tree refusal, and copied in as part of head it would show up as a
    # shell-domain source change in every fixture's diff.
    cp "$ROOT/Scripts/check-red-green.sh" Scripts/check-red-green.sh
    chmod +x Scripts/check-red-green.sh
    # run_swift_domain shells out to this guard before trusting a
    # test-without-building failure; committed at base for the same reason
    # check-red-green.sh itself is, and for the same reason never shows up as
    # a shell-domain change in any fixture's diff.
    cp "$ROOT/Scripts/check-simulator-available.sh" Scripts/check-simulator-available.sh
    chmod +x Scripts/check-simulator-available.sh
    # stub_xcodebuild (below) writes its fake binary and call log straight
    # into this same repo root, after this function has already returned --
    # untracked, that would trip the guard's own dirty-tree refusal the same
    # way a copied-in-after-head guard script would. Ignoring both up front,
    # as of base, keeps stub_xcodebuild's paths exactly as given while
    # leaving the guard's dirty check meaningful for everything else.
    printf '/bin/\n/xcb.log\n' > .gitignore
    eval "${3:-}"
    git add -A; git commit -qm base
    git branch -f base-ref
    eval "$2"
    git add -A; git commit -qm head
    cd - >/dev/null
    echo "$d"
}

# `head -1`, not the raw output: the stdout contract is two lines (verdict,
# then `domains: ...`), and callers of this helper only ever want the
# verdict. Without it every exact-match assertion below would compare a
# single word against a two-line string and fail on the domains line it was
# never asking about.
verdict() { (cd "$1" && ./Scripts/check-red-green.sh base-ref) | head -1; }

# A stubbed xcodebuild whose behaviour is driven by two files, so each case
# can choose independently whether the build and the tests succeed. Defined
# here, ahead of case 1, because case 8 (below) needs it too: proving the
# EXIT trap fires on a hard mid-run failure means the stub must say
# everything would otherwise succeed, so a hard failure can't be confused
# with a real, unstubbed xcodebuild simply having nothing to build.
stub_xcodebuild() { # dir, build-rc, test-rc
    mkdir -p "$1/bin"
    cat > "$1/bin/xcodebuild" <<STUB
#!/bin/bash
for a in "\$@"; do
  case "\$a" in
    build-for-testing)    echo "\$*" >> "$1/xcb.log"; exit $2 ;;
    test-without-building) echo "\$*" >> "$1/xcb.log"; exit $3 ;;
  esac
done
exit 0
STUB
    chmod +x "$1/bin/xcodebuild"
}

# A stubbed xcrun that enumerates RG_DESTINATION's hermetic default (iPhone
# 17 Pro / iOS 26.2) as available, so cases that reach test-without-building
# but are not specifically testing the simulator-availability guard don't
# trip it.
stub_xcrun_available() { # dir
    mkdir -p "$1/bin"
    cat > "$1/bin/xcrun" <<'STUB'
#!/bin/bash
if [ "$1" = "simctl" ] && [ "$2" = "list" ]; then
cat <<'EOF'
== Devices ==
-- iOS 26.2 --
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

# A stubbed xcrun that enumerates NOTHING at all, for any OS -- the CI
# run 31427755601 shape check-simulator-available.sh exists to catch.
stub_xcrun_unavailable() { # dir
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

# 1. No source file changed at all -> n/a.
r="$(make_repo na 'echo more >> README.md')"
[ "$(verdict "$r")" = "n/a" ] || fail "docs-only change should be n/a, got: $(verdict "$r")"
pass "a change touching no source file is n/a"

# 2. Source changed, no test touched -> no-test.
r="$(make_repo notest 'echo "let y = 2" >> App/Sources/Thing.swift')"
[ "$(verdict "$r")" = "no-test" ] || fail "source-only change should be no-test, got: $(verdict "$r")"
pass "source changed with no test touched is no-test"

# 3. A test-only change is n/a, not no-test -- there is no source to revert.
r="$(make_repo testonly 'echo "// t" > App/Tests/ThingTests.swift')"
[ "$(verdict "$r")" = "n/a" ] || fail "test-only change should be n/a, got: $(verdict "$r")"
pass "a test-only change is n/a, not no-test"

# 4. Scripts/loop-prompt.md is not source in either domain.
r="$(make_repo promptmd 'echo hi > Scripts/loop-prompt.md')"
[ "$(verdict "$r")" = "n/a" ] || fail "loop-prompt.md should be n/a, got: $(verdict "$r")"
pass "a non-.sh file under Scripts/ is not source in either domain"

# 5. A dirty working tree is refused outright, not silently worked around.
r="$(make_repo dirty 'echo "let y = 2" >> App/Sources/Thing.swift')"
echo scratch > "$r/App/Sources/Dirty.swift"
if (cd "$r" && ./Scripts/check-red-green.sh base-ref >"$TMP/d.out" 2>&1); then
    fail "ran against a dirty working tree instead of refusing"
fi
grep -q "working tree" "$TMP/d.out" || fail "refusal did not say why; got: $(cat "$TMP/d.out")"
pass "refuses to run against a dirty working tree"

# 6. Reverting must handle a file the change ADDED -- there is no base version
#    to check out, so it must be deleted. Getting this wrong leaves the new
#    source in place and fabricates a `vacuous`.
r="$(make_repo added 'echo "let z = 3" > App/Sources/New.swift; echo "// t" > App/Tests/NewTests.swift')"
(cd "$r" && ./Scripts/check-red-green.sh base-ref >/dev/null 2>&1 || true)
[ -f "$r/App/Sources/New.swift" ] || fail "an added source file was not restored after the run"
[ -z "$(cd "$r" && git status --porcelain)" ] || fail "tree left dirty: $(cd "$r" && git status --porcelain)"
pass "restores an added source file and leaves the tree clean"

# 7. Reverting must handle a file the change DELETED -- it has to come back
#    from base, then be removed again on restore.
r="$(make_repo deleted 'git rm -q App/Sources/Thing.swift; echo "// t" > App/Tests/ThingTests.swift')"
(cd "$r" && ./Scripts/check-red-green.sh base-ref >/dev/null 2>&1 || true)
[ ! -f "$r/App/Sources/Thing.swift" ] || fail "a deleted source file reappeared after restore"
[ -z "$(cd "$r" && git status --porcelain)" ] || fail "tree left dirty: $(cd "$r" && git status --porcelain)"
pass "restores a deleted source file and leaves the tree clean"

# 8. The tree is restored even when the run dies partway. Simulated by making
#    the runner blow up: the trap, not the happy path, must do the cleanup.
#    The test file must declare a real XCTestCase class: test_classes finding
#    one is what makes run_swift_domain reach revert_src at all -- a file
#    with no class (e.g. `// t`) returns `error` first, RED_GREEN_DIE_AFTER_REVERT
#    is never consulted, and this case would pass without exercising the
#    trap it claims to. The xcodebuild stub says BOTH invocations would
#    succeed (a clean `vacuous` run, exit 0, if the env var did nothing) --
#    so asserting a non-zero exit below is only possible because the hook
#    actually fired and killed the script, not because anything about the
#    stub or the fixture would have failed on its own.
mk_trap_case='
echo "let y = 2" >> App/Sources/Thing.swift
cat > App/Tests/ThingTests.swift <<"EOS"
import XCTest
final class ThingTests: XCTestCase { func testA() {} }
EOS'
r="$(make_repo trap_case "$mk_trap_case")"; stub_xcodebuild "$r" 0 0; stub_xcrun_available "$r"
if (cd "$r" && PATH="$r/bin:$PATH" RED_GREEN_DIE_AFTER_REVERT=1 ./Scripts/check-red-green.sh base-ref >/dev/null 2>&1); then
    fail "RED_GREEN_DIE_AFTER_REVERT should have killed the script even though the stub says everything would succeed"
fi
[ -z "$(cd "$r" && git status --porcelain)" ] || fail "tree left dirty after a mid-run failure: $(cd "$r" && git status --porcelain)"
grep -q 'let y = 2' "$r/App/Sources/Thing.swift" || fail "source not restored after a mid-run failure"
pass "restores the tree even when the run dies after reverting"

# 9. Shell: a test that fails once its script is reverted -> proved.
mk_shell_proved='
mkdir -p Scripts
cat > Scripts/foo.sh <<"EOS"
#!/bin/bash
echo fixed
EOS
cat > Scripts/test-foo.sh <<"EOS"
#!/bin/bash
[ "$(./Scripts/foo.sh)" = "fixed" ] || exit 1
EOS
chmod +x Scripts/foo.sh Scripts/test-foo.sh'
r="$(make_repo sh_proved "$mk_shell_proved")"
[ "$(verdict "$r")" = "proved" ] || fail "expected proved, got: $(verdict "$r")"
pass "shell: a test that fails without its script change is proved"

# 10. Shell: a test that still passes with the script reverted -> vacuous.
mk_shell_vacuous='
mkdir -p Scripts
cat > Scripts/foo.sh <<"EOS"
#!/bin/bash
echo fixed
EOS
cat > Scripts/test-foo.sh <<"EOS"
#!/bin/bash
exit 0
EOS
chmod +x Scripts/foo.sh Scripts/test-foo.sh'
r="$(make_repo sh_vacuous "$mk_shell_vacuous")"
[ "$(verdict "$r")" = "vacuous" ] || fail "expected vacuous, got: $(verdict "$r")"
pass "shell: a test that passes without the change is vacuous"

# 11. Shell: a changed script with no matching test-<name>.sh -> no-test,
#     even though some other test-*.sh changed in the same diff.
mk_shell_unmatched='
mkdir -p Scripts
echo "#!/bin/bash" > Scripts/bar.sh
cat > Scripts/test-foo.sh <<"EOS"
#!/bin/bash
exit 0
EOS
chmod +x Scripts/bar.sh Scripts/test-foo.sh'
r="$(make_repo sh_unmatched "$mk_shell_unmatched")"
[ "$(verdict "$r")" = "no-test" ] || fail "expected no-test, got: $(verdict "$r")"
pass "shell: a changed script with no matching suite is no-test"

# 12. Shell: a matching suite that exists but is not executable must never
#     read as `proved` -- it never ran, so it neither passed nor failed. A
#     permission error (exit 126) is not the same signal as a real assertion
#     failure; folding them together fabricates the exact measurement this
#     feature exists to prevent.
#
#     WHICH guard this reaches: the suite is non-executable *at HEAD*, and
#     `revert_src` only ever touches source files, so this fixture trips the
#     green-HEAD baseline's `[ -x "$t" ]` -- not the identical check in the
#     post-revert loop, which it never reaches. That is still real coverage
#     (the baseline must hard-stop rather than read 126 as "HEAD is red"),
#     and the clean-tree assertion below pins the stronger property that the
#     baseline aborts before a single file is reverted. The post-revert
#     guard needs a suite that is green at HEAD and only dies afterwards;
#     that is case 28.
mk_shell_not_executable='
mkdir -p Scripts
cat > Scripts/foo.sh <<"EOS"
#!/bin/bash
echo fixed
EOS
cat > Scripts/test-foo.sh <<"EOS"
#!/bin/bash
[ "$(./Scripts/foo.sh)" = "fixed" ] || exit 1
EOS
chmod +x Scripts/foo.sh
chmod -x Scripts/test-foo.sh'
r="$(make_repo sh_not_executable "$mk_shell_not_executable")"
out="$TMP/sh_not_executable.out"
if (cd "$r" && ./Scripts/check-red-green.sh base-ref >"$out" 2>&1); then
    fail "a non-executable suite should abort rather than print a verdict, got: $(cat "$out")"
fi
[ "$(cat "$out")" != "proved" ] || fail "a non-executable suite must never read as proved"
[ -z "$(cd "$r" && git status --porcelain)" ] || fail "tree left dirty after a non-executable suite aborts: $(cd "$r" && git status --porcelain)"
pass "shell: a suite that exists but isn't executable aborts instead of fabricating proved"

# 13. Shell: a matching suite that dies with "command not found" (exit 127 --
#     a bad shebang, a missing interpreter, a typo'd command) must never read
#     as `proved` either. It is executable and ran, but died before its
#     assertions did; exit 127 is not the same signal as a real assertion
#     failure (conventionally exit 1).
#
#     Like case 12, this suite is already broken *at HEAD*, so what it
#     actually exercises is the green-HEAD baseline's 127 arm: a suite that
#     could not run says nothing about HEAD's health and must hard-stop
#     rather than be counted as "HEAD is red" (which would print `error`, a
#     verdict, from a suite that never reported anything). Case 28 covers the
#     same arm on the other side of the revert.
mk_shell_command_not_found='
mkdir -p Scripts
cat > Scripts/foo.sh <<"EOS"
#!/bin/bash
echo fixed
EOS
cat > Scripts/test-foo.sh <<"EOS"
#!/bin/bash
nonexistent-command-xyz-123
EOS
chmod +x Scripts/foo.sh Scripts/test-foo.sh'
r="$(make_repo sh_command_not_found "$mk_shell_command_not_found")"
out="$TMP/sh_command_not_found.out"
if (cd "$r" && ./Scripts/check-red-green.sh base-ref >"$out" 2>&1); then
    fail "a suite exiting 127 should abort rather than print a verdict, got: $(cat "$out")"
fi
[ "$(cat "$out")" != "proved" ] || fail "a suite exiting 127 (command not found) must never read as proved"
[ -z "$(cd "$r" && git status --porcelain)" ] || fail "tree left dirty after a command-not-found suite aborts: $(cd "$r" && git status --porcelain)"
pass "shell: a suite that dies with command-not-found (127) aborts instead of fabricating proved"

mk_swift='
echo "let y = 2" >> App/Sources/Thing.swift
cat > App/Tests/ThingTests.swift <<"EOS"
import XCTest
final class ThingTests: XCTestCase { func testA() {} }
final class ThingExtraTests: XCTestCase { func testB() {} }
EOS'

# 14. Build fails with the source reverted -> proved-by-compile. No xcrun
#     stub needed: build-for-testing fails first, so the simulator-
#     availability check (which only guards test-without-building) is never
#     reached.
r="$(make_repo sw_compile "$mk_swift")"; stub_xcodebuild "$r" 65 0
[ "$(cd "$r" && PATH="$r/bin:$PATH" ./Scripts/check-red-green.sh base-ref | head -1)" = "proved-by-compile" ] \
    || fail "expected proved-by-compile"
pass "swift: a reverted tree that will not compile is proved-by-compile"

# 15. Build succeeds, tests fail -> proved. A genuine test failure must still
#     reach `proved` once the simulator is confirmed available -- the guard
#     added for case 19 below must not over-broadly swallow this.
r="$(make_repo sw_proved "$mk_swift")"; stub_xcodebuild "$r" 0 65; stub_xcrun_available "$r"
[ "$(cd "$r" && PATH="$r/bin:$PATH" ./Scripts/check-red-green.sh base-ref | head -1)" = "proved" ] \
    || fail "expected proved"
pass "swift: a reverted tree whose tests fail is proved"

# 16. Build succeeds, tests pass -> vacuous.
r="$(make_repo sw_vacuous "$mk_swift")"; stub_xcodebuild "$r" 0 0; stub_xcrun_available "$r"
[ "$(cd "$r" && PATH="$r/bin:$PATH" ./Scripts/check-red-green.sh base-ref | head -1)" = "vacuous" ] \
    || fail "expected vacuous"
pass "swift: a reverted tree whose tests still pass is vacuous"

# 17. EVERY class in a changed test file is targeted, not just the one whose
#     name matches the file. ImportNoticesTests.swift in the real repo declares
#     two; missing the second would silently halve the proof.
grep -q 'only-testing:WaddleTests/ThingTests' "$r/xcb.log" || fail "did not target ThingTests"
grep -q 'only-testing:WaddleTests/ThingExtraTests' "$r/xcb.log" || fail "did not target the second class in the file"
pass "swift: targets every XCTestCase class declared in a changed test file"

# 18. A changed test file that declares no XCTestCase class at all is
#     `error`, not `vacuous`: nothing ran, so nothing was proved. This is
#     also the fixture that catches the `test_classes` pipefail/errexit
#     hazard directly: a no-match `grep -o` feeding `sed` is the last
#     statement of a loop-body iteration, and unguarded it aborts the whole
#     script rather than letting run_swift_domain ever report `error` --
#     see docs/learnings/loop-body-last-status-triggers-errexit.md. xcodebuild
#     must never even run: nothing was there to prove.
mk_swift_no_classes='
echo "let y = 2" >> App/Sources/Thing.swift
echo "// no XCTestCase class here" > App/Tests/ThingTests.swift'
r="$(make_repo sw_no_classes "$mk_swift_no_classes")"; stub_xcodebuild "$r" 0 0
[ "$(cd "$r" && PATH="$r/bin:$PATH" ./Scripts/check-red-green.sh base-ref | head -1)" = "error" ] \
    || fail "expected error for a test file declaring no XCTestCase class"
[ ! -s "$r/xcb.log" ] || fail "xcodebuild should never run when no test class was found"
[ -z "$(cd "$r" && git status --porcelain)" ] || fail "tree left dirty: $(cd "$r" && git status --porcelain)"
pass "swift: a changed test file declaring no XCTestCase class is error, not vacuous"

# 19. A test-without-building failure must not read as `proved` when the
#     simulator itself never became available. CI run 31427755601 hit
#     exactly this against this same RG_DESTINATION default (see
#     docs/learnings/simulator-enumeration-race.md): build-for-testing can
#     succeed while CoreSimulator has enumerated nothing, and only
#     test-without-building actually needs a live device. The whole run must
#     abort (no verdict, tree restored) before test-without-building is ever
#     invoked -- proceeding to it and trusting its exit code would fabricate
#     the strongest verdict from an infrastructure hiccup.
r="$(make_repo sw_sim_unavailable "$mk_swift")"
stub_xcodebuild "$r" 0 65
stub_xcrun_unavailable "$r"
out="$TMP/sw_sim_unavailable.out"
if (cd "$r" && PATH="$r/bin:$PATH" SIMULATOR_CHECK_ATTEMPTS=1 SIMULATOR_CHECK_DELAY=0 \
        ./Scripts/check-red-green.sh base-ref >"$out" 2>&1); then
    fail "should have aborted instead of proceeding when the simulator never became available; got: $(cat "$out")"
fi
[ "$(cat "$out")" != "proved" ] || fail "an unavailable simulator must never read as proved"
grep -q "test-without-building" "$r/xcb.log" 2>/dev/null \
    && fail "test-without-building must never run when the simulator precheck fails"
[ -z "$(cd "$r" && git status --porcelain)" ] \
    || fail "tree left dirty after a simulator-unavailable abort: $(cd "$r" && git status --porcelain)"
pass "swift: an unbootable simulator aborts instead of fabricating proved from test-without-building"

# 20. Mixed domains take the WORSE verdict: a proved swift half must not mask
#     a vacuous shell half. Needs stub_xcrun_available, unlike the brief's
#     literal text: this fixture's swift half reaches test-without-building
#     (build 0, test 65), and per the hermeticity constraint this suite never
#     falls through to a real xcrun/simulator -- see case 19 just above,
#     which exists for exactly this reason.
mk_mixed="$mk_shell_vacuous"'
echo "let y = 2" >> App/Sources/Thing.swift
cat > App/Tests/ThingTests.swift <<"EOS"
import XCTest
final class ThingTests: XCTestCase { func testA() {} }
EOS'
r="$(make_repo mixed "$mk_mixed")"; stub_xcodebuild "$r" 0 65; stub_xcrun_available "$r"
out="$(cd "$r" && PATH="$r/bin:$PATH" ./Scripts/check-red-green.sh base-ref)"
[ "$(echo "$out" | head -1)" = "vacuous" ] || fail "expected worst-of vacuous, got: $out"
echo "$out" | grep -q "domains: swift+shell" || fail "did not report both domains; got: $out"
pass "a mixed pull request takes the worse of the two verdicts"

# 21. `error` is not a rank -- it dominates everything, because a
#     half-computed proof is not a proof.
mk_err="$mk_shell_proved"'
echo "let y = 2" >> App/Sources/Thing.swift
echo "// no XCTestCase here" > App/Tests/ThingTests.swift'
r="$(make_repo errdom "$mk_err")"; stub_xcodebuild "$r" 0 0
[ "$(cd "$r" && PATH="$r/bin:$PATH" ./Scripts/check-red-green.sh base-ref | head -1)" = "error" ] \
    || fail "error did not dominate a proved sibling domain"
pass "error in one domain dominates a proved verdict in the other"

# 22. The n/a case reports no domains.
r="$(make_repo na2 'echo more >> README.md')"
(cd "$r" && ./Scripts/check-red-green.sh base-ref) | grep -q "domains: none" \
    || fail "n/a did not report 'domains: none'"
pass "an n/a verdict reports no evaluated domains"

# 23. A genuinely discriminating regression test for the cross-domain
#     restore_tree/REVERTED hazard described in
#     docs/learnings/domain-composition-relies-on-strict-sequencing.md.
#     Case 20 does NOT catch this, on inspection: its swift verdict comes
#     entirely from stub_xcodebuild's fixed exit codes, and mk_shell_vacuous's
#     test-foo.sh is a bare `exit 0` that never reads a file -- neither half
#     is sensitive to whether the other domain's revert has actually been
#     restored yet, so it still passes even with run_swift_domain's
#     restore_tree calls no-op'd.
#
#     This fixture's shell suite instead inspects App/Sources/Thing.swift --
#     the *swift* half's own reverted file -- at the exact moment it runs.
#     Swift's own verdict is pinned at `proved` regardless (build 0, test 65
#     via the stub), so only the shell half's observation can move the
#     result. If run_swift_domain's restore_tree has already fired (today's
#     correct behaviour), Thing.swift is back to full HEAD content ("let y =
#     2" present) long before run_shell_domain's own revert_src ever runs,
#     and the suite sees nothing wrong -> vacuous, which dominates swift's
#     proved in the worst-of -> overall "vacuous". If that sequencing ever
#     broke -- e.g. batching or parallelising the two classify_domain calls,
#     the exact risk named in the learnings file's "Where else to look" --
#     Thing.swift would still be stuck in swift's BASE-reverted content when
#     this suite runs, the suite would notice and exit 1 -> proved, and
#     since both halves would then read `proved`, the worst-of no longer has
#     a `vacuous` to fall back on -> overall "proved". Proved to actually
#     discriminate (not just pass): see the fix report for the no-op/restore
#     round-trip.
mk_sequencing='
mkdir -p Scripts
cat > Scripts/foo.sh <<"EOS"
#!/bin/bash
echo fixed
EOS
cat > Scripts/test-foo.sh <<"EOS"
#!/bin/bash
if ! grep -q "let y = 2" App/Sources/Thing.swift; then
    exit 1
fi
exit 0
EOS
chmod +x Scripts/foo.sh Scripts/test-foo.sh
echo "let y = 2" >> App/Sources/Thing.swift
cat > App/Tests/ThingTests.swift <<"EOS"
import XCTest
final class ThingTests: XCTestCase { func testA() {} }
EOS'
r="$(make_repo sequencing "$mk_sequencing")"; stub_xcodebuild "$r" 0 65; stub_xcrun_available "$r"
out="$(cd "$r" && PATH="$r/bin:$PATH" ./Scripts/check-red-green.sh base-ref)"
[ "$(echo "$out" | head -1)" = "vacuous" ] \
    || fail "expected vacuous (swift's revert already restored before shell's suite ran), got: $out"
pass "shell's suite observes swift's source already restored to HEAD, not swift's in-flight revert"

# 24. THE SHELL DOMAIN'S GREEN-HEAD BASELINE. The suite is ALREADY failing at
#     HEAD -- the change broke its own test. Without a baseline run, `rc` comes
#     entirely from the reverted tree, the suite fails there too, and the trial
#     records `proved` for a change that broke its own tests. This is not
#     hypothetical: ci.yml runs a hardcoded list of shell suites, so a suite
#     absent from that list is green on the pull request by never having run,
#     which is exactly the state the spec's "CI already runs the full suite"
#     justification assumes cannot happen.
#
#     The fixture is issue 71's shape exactly: Scripts/foo.sh exists at base
#     (hence the base-mutate argument), HEAD changes it, and HEAD's own suite
#     fails against HEAD. Before the baseline check this returned `proved` --
#     the reverted foo.sh also fails the assertion, so the revert looked like
#     the cause. It must be `error` (the proof could not be computed), never a
#     verdict, and the tree must be untouched: nothing is ever reverted.
mk_head_red_base='
mkdir -p Scripts
cat > Scripts/foo.sh <<"EOS"
#!/bin/bash
echo old
EOS
chmod +x Scripts/foo.sh'
mk_head_red='
cat > Scripts/foo.sh <<"EOS"
#!/bin/bash
echo broken
EOS
cat > Scripts/test-foo.sh <<"EOS"
#!/bin/bash
[ "$(./Scripts/foo.sh)" = "fixed" ] || exit 1
EOS
chmod +x Scripts/test-foo.sh'
r="$(make_repo sh_head_red "$mk_head_red" "$mk_head_red_base")"
out="$(cd "$r" && ./Scripts/check-red-green.sh base-ref)"
[ "$(echo "$out" | head -1)" = "error" ] \
    || fail "a suite already failing at HEAD must be error, not a verdict; got: $out"
[ "$(echo "$out" | head -1)" != "proved" ] || fail "recorded proved for a change that broke its own tests"
echo "$out" | grep -q "domains: shell" || fail "did not report the shell domain; got: $out"
[ -z "$(cd "$r" && git status --porcelain)" ] \
    || fail "tree left dirty by the HEAD baseline run: $(cd "$r" && git status --porcelain)"
pass "shell: a suite already red at HEAD is error, not a fabricated proved"

# 25. A RENAMED SOURCE FILE. `git diff --name-only` has rename detection on by
#     default and prints only the destination path, so the revert deletes the
#     new name and never restores the old one -- the "reverted" tree is base
#     minus a file, which is not the base tree. `--no-renames` emits the
#     rename as a delete plus an add instead, and both flow through the
#     existing modified/added/deleted logic.
#
#     The fixture is a pure `git mv` with no content change, so the honest
#     verdict is `vacuous`: nothing behavioural changed, and the suites cannot
#     notice a revert that restores the same bytes under a different name.
#     Each suite asserts only that ONE of the two names exists, which is true
#     at HEAD (the new name) and true after a correct revert (the old name) --
#     but false after the buggy revert, where the new name is deleted and the
#     old one was never brought back, so both suites fail and the run reports
#     `proved` for a rename. That is the discrimination: vacuous when fixed,
#     proved when broken.
mk_rename_base='
mkdir -p Scripts
cat > Scripts/renamed-me.sh <<"EOS"
#!/bin/bash
echo same
EOS
cat > Scripts/test-renamed-me.sh <<"EOS"
#!/bin/bash
[ -f Scripts/renamed-me.sh ] || [ -f Scripts/renamed-you.sh ] || exit 1
exit 0
EOS
chmod +x Scripts/renamed-me.sh Scripts/test-renamed-me.sh'
mk_rename='
git mv Scripts/renamed-me.sh Scripts/renamed-you.sh
cat > Scripts/test-renamed-you.sh <<"EOS"
#!/bin/bash
[ -f Scripts/renamed-me.sh ] || [ -f Scripts/renamed-you.sh ] || exit 1
exit 0
EOS
chmod +x Scripts/test-renamed-you.sh'
r="$(make_repo sh_rename "$mk_rename" "$mk_rename_base")"
# The fixture only means anything if git really does collapse this to a rename
# without --no-renames; assert that directly rather than trusting the default.
[ "$(cd "$r" && git diff --name-only base-ref HEAD -- 'Scripts/renamed-*')" = "Scripts/renamed-you.sh" ] \
    || fail "fixture does not reproduce rename detection: $(cd "$r" && git diff --name-only base-ref HEAD)"
out="$(cd "$r" && ./Scripts/check-red-green.sh base-ref)"
[ "$(echo "$out" | head -1)" = "vacuous" ] \
    || fail "a pure rename with no behavioural change should be vacuous, got: $out"
[ -z "$(cd "$r" && git status --porcelain)" ] \
    || fail "tree left dirty after a rename: $(cd "$r" && git status --porcelain)"
pass "a renamed source file is reverted to the base tree, not to base minus a file"

# 26. A CHANGED SCRIPT WITH NO MATCHING SUITE CONTRIBUTES `no-test`, even when
#     a sibling script in the same diff does have one and that sibling's suite
#     noticed the revert. Case 11 cannot catch this: its fixture has a single
#     source file, so `no-test` fires from the "no suite matched anything at
#     all" early return rather than from the per-source contribution the spec
#     describes. Here Scripts/foo.sh is genuinely proved and Scripts/bar.sh is
#     unproven -- and bar.sh is reverted too, so it can be what made
#     test-foo.sh fail while foo.sh takes the credit. Worst-of puts `no-test`
#     above `proved`, so the pull request is `no-test`.
mk_partial_base='
mkdir -p Scripts
cat > Scripts/foo.sh <<"EOS"
#!/bin/bash
echo old
EOS
cat > Scripts/test-foo.sh <<"EOS"
#!/bin/bash
[ "$(./Scripts/foo.sh)" = "fixed" ] || exit 1
EOS
chmod +x Scripts/foo.sh Scripts/test-foo.sh'
mk_partial='
cat > Scripts/foo.sh <<"EOS"
#!/bin/bash
echo fixed
EOS
cat > Scripts/bar.sh <<"EOS"
#!/bin/bash
echo bar
EOS
chmod +x Scripts/bar.sh'
r="$(make_repo sh_partial "$mk_partial" "$mk_partial_base")"
out="$(cd "$r" && ./Scripts/check-red-green.sh base-ref)"
[ "$(echo "$out" | head -1)" = "no-test" ] \
    || fail "an unproven sibling script must contribute no-test, got: $out"
[ -z "$(cd "$r" && git status --porcelain)" ] \
    || fail "tree left dirty: $(cd "$r" && git status --porcelain)"
pass "shell: a changed script with no suite contributes no-test even when a sibling is proved"

# 27. ...and `vacuous` still outranks that `no-test`: the contribution is a
#     worst-of, not an override. Same fixture shape as case 26 with a suite
#     that cannot fail, so foo.sh's own half is vacuous. Collapsing to
#     `no-test` here would soften a real defect into a milder one.
mk_partial_vac='
cat > Scripts/foo.sh <<"EOS"
#!/bin/bash
echo fixed
EOS
cat > Scripts/test-foo.sh <<"EOS"
#!/bin/bash
exit 0
EOS
cat > Scripts/bar.sh <<"EOS"
#!/bin/bash
echo bar
EOS
chmod +x Scripts/bar.sh'
r="$(make_repo sh_partial_vac "$mk_partial_vac" "$mk_partial_base")"
[ "$(verdict "$r")" = "vacuous" ] \
    || fail "vacuous must outrank the no-test contribution, got: $(verdict "$r")"
pass "shell: vacuous still outranks an unproven sibling's no-test contribution"

# 28. THE POST-REVERT NEVER-RAN GUARD, which is the only shape that reaches
#     it. Cases 12 and 13 both break their suite at HEAD, so the green-HEAD
#     baseline hard-stops first and the identical check after `revert_src`
#     is never executed -- verified by mutation: neutering the post-revert
#     `[ -x "$t" ]` and changing its `126 | 127) exit 1` to `rc=1` leaves
#     both of those cases behaving exactly as before.
#
#     This suite is genuinely GREEN at HEAD and only dies afterwards, because
#     what it invokes is the very script the change added -- and the revert
#     deletes an added file. So it exits 127 on the reverted tree alone. With
#     the guard: the script aborts, the EXIT trap restores, no verdict. Without
#     it: 127 folds into `rc=1` and the run prints `proved`, the strongest
#     verdict this instrument can emit, for a suite that never reached an
#     assertion on either side of the revert. Same three assertions as cases
#     12 and 13, and here the clean-tree one is load-bearing rather than
#     trivially true: a revert really did happen before the abort.
mk_post_revert_127_base='
mkdir -p Scripts
cat > Scripts/test-foo.sh <<"EOS"
#!/bin/bash
./Scripts/foo.sh >/dev/null
EOS
chmod +x Scripts/test-foo.sh'
mk_post_revert_127='
cat > Scripts/foo.sh <<"EOS"
#!/bin/bash
echo fixed
EOS
chmod +x Scripts/foo.sh'
r="$(make_repo sh_post_revert_127 "$mk_post_revert_127" "$mk_post_revert_127_base")"
out="$TMP/sh_post_revert_127.out"
if (cd "$r" && ./Scripts/check-red-green.sh base-ref >"$out" 2>&1); then
    fail "a suite exiting 127 only after the revert should abort rather than print a verdict, got: $(cat "$out")"
fi
[ "$(cat "$out")" != "proved" ] \
    || fail "a suite that died with command-not-found on the reverted tree must never read as proved"
[ -z "$(cd "$r" && git status --porcelain)" ] \
    || fail "tree left dirty after a post-revert command-not-found abort: $(cd "$r" && git status --porcelain)"
pass "shell: a suite green at HEAD that dies 127 only after the revert aborts instead of fabricating proved"

# 29. THE DEPARTURE HALF OF A RENAME IS NOT AN UNPROVEN SOURCE. `--no-renames`
#     (case 25) expands `Scripts/foo.sh -> Scripts/bar.sh` into foo.sh deleted
#     plus bar.sh added, so BOTH names land in the shell domain's source list --
#     but only bar.sh exists at HEAD. Renaming a script and its suite together
#     is an ordinary refactor, and matching `Scripts/test-foo.sh` for the
#     departed foo.sh can never succeed: the suite moved with it. Counting that
#     as an unmatched source forces `no-test`, which outranks `proved` in the
#     worst-of, so the real proof earned by test-bar.sh is masked by a demand
#     for a test of code that no longer exists.
#
#     The rename here carries a real behavioural change (echo old -> echo
#     fixed) so the moved suite genuinely detects the revert -- that is what
#     makes the case discriminate by two ranks: `proved` when the rule is
#     right, `no-test` when the departed half is counted. Case 25's pure
#     `git mv` cannot catch this: both of its names have a suite at HEAD, so
#     nothing is ever unmatched there.
mk_rename_pair_base='
mkdir -p Scripts
cat > Scripts/foo.sh <<"EOS"
#!/bin/bash
echo old
EOS
cat > Scripts/test-foo.sh <<"EOS"
#!/bin/bash
[ "$(./Scripts/foo.sh)" = "old" ] || exit 1
exit 0
EOS
chmod +x Scripts/foo.sh Scripts/test-foo.sh'
mk_rename_pair='
git mv Scripts/foo.sh Scripts/bar.sh
git mv Scripts/test-foo.sh Scripts/test-bar.sh
cat > Scripts/bar.sh <<"EOS"
#!/bin/bash
echo fixed
EOS
cat > Scripts/test-bar.sh <<"EOS"
#!/bin/bash
[ "$(./Scripts/bar.sh)" = "fixed" ] || exit 1
exit 0
EOS
chmod +x Scripts/bar.sh Scripts/test-bar.sh'
r="$(make_repo sh_rename_pair "$mk_rename_pair" "$mk_rename_pair_base")"
# The case only means anything if the departed name really is in the list the
# guard consumes; assert that directly rather than trusting --no-renames to
# keep behaving this way.
[ "$(cd "$r" && git diff --no-renames --name-only base-ref HEAD -- Scripts/foo.sh)" = "Scripts/foo.sh" ] \
    || fail "fixture does not put the deleted half of the rename in the guard's source list"
out="$(cd "$r" && ./Scripts/check-red-green.sh base-ref)"
[ "$(echo "$out" | head -1)" = "proved" ] \
    || fail "renaming a script and its suite together must keep the proof the moved suite earned, got: $out"
[ -z "$(cd "$r" && git status --porcelain)" ] \
    || fail "tree left dirty after a script+suite rename: $(cd "$r" && git status --porcelain)"
pass "shell: renaming a script and its suite together is proved, not a forced no-test"

# 30. THE BOUNDARY case 29 must not overrun: a source that DOES exist at HEAD
#     with no suite named for it still contributes `no-test`, even when the
#     reason it exists is the same rename. Here only the script moves
#     (foo.sh -> bar.sh) and the old suite name is kept and updated, so at HEAD
#     there is a real `Scripts/bar.sh` with no `Scripts/test-bar.sh`. The
#     naming convention is the whole rule -- "by name and nothing cleverer" --
#     and test-foo.sh proving the change does not make bar.sh named-covered.
#
#     This case does not discriminate the case-29 fix on its own (before it,
#     the departed foo.sh was unmatched too, and the verdict was already
#     `no-test`). It is here to pin the boundary: a fix that skipped every
#     source involved in a rename, rather than only the paths absent from
#     HEAD, would turn this into `proved` and silently drop a genuinely
#     unproven script.
mk_rename_src_only='
git mv Scripts/foo.sh Scripts/bar.sh
cat > Scripts/bar.sh <<"EOS"
#!/bin/bash
echo fixed
EOS
cat > Scripts/test-foo.sh <<"EOS"
#!/bin/bash
[ "$(./Scripts/bar.sh)" = "fixed" ] || exit 1
exit 0
EOS
chmod +x Scripts/bar.sh'
r="$(make_repo sh_rename_src_only "$mk_rename_src_only" "$mk_rename_pair_base")"
out="$(cd "$r" && ./Scripts/check-red-green.sh base-ref)"
[ "$(echo "$out" | head -1)" = "no-test" ] \
    || fail "a script that exists at HEAD with no suite named for it must still be no-test, got: $out"
[ -z "$(cd "$r" && git status --porcelain)" ] \
    || fail "tree left dirty: $(cd "$r" && git status --porcelain)"
pass "shell: a renamed-to script with no suite of its own still contributes no-test"

# 31. THE SAME RULE, REACHED BY A PLAIN DELETION rather than a rename --
#     which is the point: `--no-renames` makes the two the same event, so the
#     rule cannot be about renames. Scripts/gone.sh and its suite are deleted
#     outright, with no arriving counterpart anywhere in the diff that rename
#     detection could ever have paired it with, while a sibling script is
#     genuinely proved. Demanding Scripts/test-gone.sh at HEAD is demanding a
#     suite for code the change removed, so it must not mask the sibling's
#     proof.
mk_delete_sibling_base='
mkdir -p Scripts
cat > Scripts/foo.sh <<"EOS"
#!/bin/bash
echo old
EOS
cat > Scripts/test-foo.sh <<"EOS"
#!/bin/bash
[ "$(./Scripts/foo.sh)" = "fixed" ] || exit 1
exit 0
EOS
cat > Scripts/gone.sh <<"EOS"
#!/bin/bash
echo gone
EOS
cat > Scripts/test-gone.sh <<"EOS"
#!/bin/bash
exit 0
EOS
chmod +x Scripts/foo.sh Scripts/test-foo.sh Scripts/gone.sh Scripts/test-gone.sh'
mk_delete_sibling='
cat > Scripts/foo.sh <<"EOS"
#!/bin/bash
echo fixed
EOS
git rm -q Scripts/gone.sh Scripts/test-gone.sh'
r="$(make_repo sh_delete_sibling "$mk_delete_sibling" "$mk_delete_sibling_base")"
out="$(cd "$r" && ./Scripts/check-red-green.sh base-ref)"
[ "$(echo "$out" | head -1)" = "proved" ] \
    || fail "a deleted script must not mask a sibling's proof with no-test, got: $out"
[ ! -f "$r/Scripts/gone.sh" ] || fail "the deleted script reappeared after restore"
[ -z "$(cd "$r" && git status --porcelain)" ] \
    || fail "tree left dirty after reverting a deleted script: $(cd "$r" && git status --porcelain)"
pass "shell: a deleted script and suite contribute nothing, not a no-test that masks a sibling"

# 32. ...and the DOMAIN-LEVEL `no-test` is deliberately untouched by all of
#     that. A change that only deletes a script and its suite matches no suite
#     at all, so the domain ran nothing and reports `no-test`. That is an
#     honest statement about an empty measurement, and unlike the per-source
#     contribution above it overrides nothing: there is no rival verdict for it
#     to mask. The alternative -- calling the domain absent and letting the
#     pull request score `n/a` -- would claim no source changed, which is
#     false, and would drop a real deletion out of the measurement entirely.
#     Pinned so that a future widening of the rule has to argue with a test.
mk_delete_only='git rm -q Scripts/foo.sh Scripts/test-foo.sh'
r="$(make_repo sh_delete_only "$mk_delete_only" "$mk_rename_pair_base")"
out="$(cd "$r" && ./Scripts/check-red-green.sh base-ref)"
[ "$(echo "$out" | head -1)" = "no-test" ] \
    || fail "a domain that matched no suite at all must still be no-test, got: $out"
echo "$out" | grep -q "domains: shell" || fail "did not report the shell domain; got: $out"
[ -z "$(cd "$r" && git status --porcelain)" ] \
    || fail "tree left dirty: $(cd "$r" && git status --porcelain)"
pass "shell: a change that only deletes a script and its suite is still no-test at the domain level"

echo "All check-red-green tests passed."
