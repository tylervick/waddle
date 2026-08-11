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
    git add -A; git commit -qm base
    git branch -f base-ref
    eval "$2"
    git add -A; git commit -qm head
    cd - >/dev/null
    echo "$d"
}

verdict() { (cd "$1" && ./Scripts/check-red-green.sh base-ref); }

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
r="$(make_repo trap_case 'echo "let y = 2" >> App/Sources/Thing.swift; echo "// t" > App/Tests/ThingTests.swift')"
(cd "$r" && RED_GREEN_DIE_AFTER_REVERT=1 ./Scripts/check-red-green.sh base-ref >/dev/null 2>&1 || true)
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

echo "All check-red-green tests passed."
