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
make_repo() { # name, mutate-script
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
    git add -A; git commit -qm base
    git branch -f base-ref
    eval "$2"
    git add -A; git commit -qm head
    cd - >/dev/null
    echo "$d"
}

verdict() { (cd "$1" && ./Scripts/check-red-green.sh base-ref); }

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
[ "$(cd "$r" && PATH="$r/bin:$PATH" ./Scripts/check-red-green.sh base-ref)" = "proved-by-compile" ] \
    || fail "expected proved-by-compile"
pass "swift: a reverted tree that will not compile is proved-by-compile"

# 15. Build succeeds, tests fail -> proved. A genuine test failure must still
#     reach `proved` once the simulator is confirmed available -- the guard
#     added for case 19 below must not over-broadly swallow this.
r="$(make_repo sw_proved "$mk_swift")"; stub_xcodebuild "$r" 0 65; stub_xcrun_available "$r"
[ "$(cd "$r" && PATH="$r/bin:$PATH" ./Scripts/check-red-green.sh base-ref)" = "proved" ] \
    || fail "expected proved"
pass "swift: a reverted tree whose tests fail is proved"

# 16. Build succeeds, tests pass -> vacuous.
r="$(make_repo sw_vacuous "$mk_swift")"; stub_xcodebuild "$r" 0 0; stub_xcrun_available "$r"
[ "$(cd "$r" && PATH="$r/bin:$PATH" ./Scripts/check-red-green.sh base-ref)" = "vacuous" ] \
    || fail "expected vacuous"
pass "swift: a reverted tree whose tests still pass is vacuous"

# 17. EVERY class in a changed test file is targeted, not just the one whose
#     name matches the file. ImportNoticesTests.swift in the real repo declares
#     two; missing the second would silently halve the proof.
grep -q 'only-testing:WADdleTests/ThingTests' "$r/xcb.log" || fail "did not target ThingTests"
grep -q 'only-testing:WADdleTests/ThingExtraTests' "$r/xcb.log" || fail "did not target the second class in the file"
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
[ "$(cd "$r" && PATH="$r/bin:$PATH" ./Scripts/check-red-green.sh base-ref)" = "error" ] \
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

echo "All check-red-green tests passed."
