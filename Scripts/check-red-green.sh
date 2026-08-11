#!/bin/bash
# Prints one red-green verdict for the diff between a base ref and HEAD:
# whether the tests shipped with a change actually fail without that change.
#
# Verdicts: proved | proved-by-compile | vacuous | no-test | n/a | error
# See docs/superpowers/specs/2026-08-10-test-proof-signal-design.md.
#
# `error` means the proof could not be computed. It never means "bad", and it
# is never folded into a score -- see docs/learnings/masked-exit-status-fails-open.md
# for why this repo treats an absent measurement as absent.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Scratch space for lists that must cross a subshell boundary.
TMPDIR_RG="$(mktemp -d)"

# Overridable so the hermetic suite never needs a real simulator.
RG_DESTINATION="${RG_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2}"

BASE_REF="${1:-origin/main}"

# Mutating a dirty tree could not be reliably undone, and this script's whole
# job is to mutate and restore. Refuse rather than risk the owner's work.
if [ -n "$(git status --porcelain)" ]; then
    echo "error: refusing to run against a dirty working tree; commit or stash first" >&2
    exit 1
fi

BASE="$(git merge-base HEAD "$BASE_REF")"
changed="$(git diff --name-only "$BASE" HEAD)"

# Domain membership. Printed one path per line; empty output means the domain
# has no files of that kind in this diff.
swift_src()  { printf '%s\n' "$changed" | grep -E '^App/Sources/.*\.swift$'        || true; }
swift_test() { printf '%s\n' "$changed" | grep -E '^App/Tests/.*\.swift$'          || true; }
shell_src()  { printf '%s\n' "$changed" | grep -E '^Scripts/[^/]*\.sh$' | grep -v '^Scripts/test-' || true; }
shell_test() { printf '%s\n' "$changed" | grep -E '^Scripts/test-[^/]*\.sh$'       || true; }

# Paths this run reverted, so the trap knows exactly what to put back. A
# newline-separated list; bash 3.2 has no arrays worth the trouble here.
REVERTED=""

# Restore every reverted path to its HEAD state. Runs from an EXIT trap, so it
# must be safe to call when nothing was reverted and must not itself abort --
# a failed restore that killed the script would leave the tree mutated.
restore_tree() {
    [ -n "$REVERTED" ] || return 0
    printf '%s\n' "$REVERTED" | while IFS= read -r p; do
        [ -n "$p" ] || continue
        if git cat-file -e "HEAD:$p" 2>/dev/null; then
            git checkout HEAD -- "$p" 2>/dev/null || true
        else
            # HEAD does not have it: the change deleted it and we brought it
            # back from base. `revert_src` staged that base copy with `git
            # checkout "$BASE" -- "$p"`, so a plain `rm -f` here would delete
            # the working-tree file but leave it staged -- an index entry
            # HEAD doesn't have, reported as a dirty "AD" instead of clean.
            # Removing it from the index too is what actually matches HEAD.
            git rm -f -q --ignore-unmatch -- "$p" 2>/dev/null || true
            rm -f "$p" 2>/dev/null || true
        fi
    done
    REVERTED=""
}
trap 'restore_tree; rm -rf "$TMPDIR_RG"' EXIT

# Put the given paths into their BASE state: restore modified and
# change-deleted files from base, delete files the change added.
#
# `git checkout "$BASE" -- "$p"` is unmasked and can abort the whole script
# under `errexit` (disk full, EPERM, an APFS case-collision). Record each path
# in REVERTED the instant it is actually reverted, not as one batch appended
# after the loop -- a batch append would lose every already-reverted path from
# an aborted run, since they'd never make it into REVERTED at all. The loop
# reads via `< <(...)` rather than `printf ... |`, too: a pipe would run the
# loop in a subshell in bash, and REVERTED assigned there would vanish the
# same way it would in a `$(...)` capture -- see
# docs/learnings/command-substitution-discards-callee-state.md.
revert_src() { # paths (newline separated)
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        if git cat-file -e "$BASE:$p" 2>/dev/null; then
            git checkout "$BASE" -- "$p"
        else
            rm -f "$p"
        fi
        REVERTED="$REVERTED
$p"
    done < <(printf '%s\n' "$1")
}

# The test for Scripts/foo.sh is Scripts/test-foo.sh, by name and nothing
# cleverer. A changed script with no matching suite is unproven, which is
# `no-test` -- not `error`, because nothing failed: the proof is simply absent.
run_shell_domain() { # src, test
    suites=""
    printf '%s\n' "$1" | while IFS= read -r s; do
        [ -n "$s" ] || continue
        t="Scripts/test-$(basename "$s")"
        # Not `[ -f "$t" ] && echo "$t"`: a source file with no matching
        # suite is the ordinary, expected case, but it makes that `&&` list's
        # own status 1 -- and as the last command run in the loop body, that
        # becomes the whole `while` compound's status. Unguarded, `errexit`
        # aborts the script right there. See
        # docs/learnings/loop-body-last-status-triggers-errexit.md.
        if [ -f "$t" ]; then echo "$t"; fi
    done > "$TMPDIR_RG/suites"
    suites="$(cat "$TMPDIR_RG/suites")"
    if [ -z "$suites" ]; then echo "no-test"; return; fi

    revert_src "$1"
    rc=0
    # Reads via `< <(...)`, not `printf ... |`: a pipe forks a subshell in
    # bash, and this loop needs the `[ -x "$t" ]` check below to actually
    # reach `errexit` in the *current* shell, not die invisibly inside a
    # subshell -- see docs/learnings/command-substitution-discards-callee-state.md,
    # which documents the same subshell-erases-state trap one call shape over.
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        # Unguarded, on purpose. A suite that isn't executable never ran --
        # it neither passed nor failed -- so folding its permission-denied
        # (exit 126) into the same `|| rc=1` as a real assertion failure
        # would print `proved` from a broken commit, never having noticed
        # the revert at all. That is the exact fabrication this feature
        # exists to prevent, so it is not treated as data: left unguarded,
        # `errexit` aborts the whole script right here, the same hard-stop
        # `revert_src` already relies on for its own unmasked `git
        # checkout`. The `EXIT` trap restores the tree; the caller sees a
        # non-zero exit and no verdict, i.e. the proof could not be
        # computed. See docs/learnings/exit-status-conflates-failed-with-never-ran.md.
        [ -x "$t" ]
        # Capture the real exit status instead of collapsing it with `||`:
        # 126 (not executable -- the `-x` check above should already have
        # ruled this out, but a `noexec` mount or a race is still possible)
        # and 127 (command not found -- a bad shebang, a missing
        # interpreter) both mean the suite died before its assertions ever
        # ran. A genuine assertion failure is conventionally exit 1 (and
        # this repo's own suites use exactly that -- see e.g. this file's
        # own fixtures). Anything else nonzero is treated as a real,
        # noticed failure, not a "never ran": drawing the line any wider
        # risks reading a legitimate assertion failure as an infra problem,
        # which is its own kind of fabrication.
        status=0
        "./$t" >/dev/null 2>&1 || status=$?
        case "$status" in
            0) : ;;
            126 | 127) exit 1 ;;
            *) rc=1 ;;
        esac
    done < <(printf '%s\n' "$suites")
    restore_tree

    # Non-zero means at least one suite noticed the revert. That is the proof.
    if [ "$rc" -eq 1 ]; then echo "proved"; else echo "vacuous"; fi
}

# Every `final class X: XCTestCase` / `class X: XCTestCase` declared in the
# changed test files. Parsed from content because one file may declare
# several and nothing enforces that a file's name matches its classes --
# App/Tests/ImportNoticesTests.swift declares both ImportNoticesTests and
# ImportNoticesMessageTests, and filename inference would silently run only
# half the file.
test_classes() { # test paths
    printf '%s\n' "$1" | while IFS= read -r f; do
        [ -n "$f" ] && [ -f "$f" ] || continue
        # `|| true` on the whole pipe, not just the `grep`: a file with no
        # matching class (the ordinary, expected input to the `error` check
        # below) makes `grep -o` exit 1 for "no lines selected", and under
        # `pipefail` that becomes this pipeline's own status even though
        # `sed` itself runs and exits 0. Unguarded, that status would be the
        # last thing this loop iteration runs -- the same shape
        # docs/learnings/loop-body-last-status-triggers-errexit.md warns
        # about, just reached through `pipefail` instead of a trailing `&&`.
        # Confirmed by a standalone repro before touching this file: without
        # the `|| true`, a single classless test file aborts the whole
        # script under `errexit`, silently, before `run_swift_domain` ever
        # gets to report `error` itself.
        grep -hoE '^[[:space:]]*(final[[:space:]]+)?class[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:[[:space:]]*XCTestCase' "$f" \
            | sed -E 's/.*class[[:space:]]+([A-Za-z0-9_]+).*/\1/' || true
    done | sort -u
}

run_swift_domain() { # src, test
    test_classes "$2" > "$TMPDIR_RG/classes"
    # No class was parsed out of any changed test file: nothing to run, so
    # nothing was proved. This is `error`, not `vacuous` -- `vacuous` means
    # the tests ran and didn't notice the revert; this means they never ran
    # at all. See docs/learnings/exit-status-conflates-failed-with-never-ran.md.
    if [ ! -s "$TMPDIR_RG/classes" ]; then echo "error"; return; fi

    only=""
    while IFS= read -r c; do
        # `if`/`fi`, not `[ -n "$c" ] && only="..."`: the latter's status is
        # 1 for a blank line, and unguarded that is fatal under `errexit` as
        # the last command of this loop body -- see
        # docs/learnings/loop-body-last-status-triggers-errexit.md. Nothing
        # in `test_classes` above actually emits a blank line today, so this
        # is defensive, not a reproduced failure, but the fix costs nothing
        # and closes the shape on sight.
        if [ -n "$c" ]; then only="$only -only-testing:WADdleTests/$c"; fi
    done < "$TMPDIR_RG/classes"

    revert_src "$1"
    # Two xcodebuild invocations, not one `xcodebuild test`: that single
    # invocation exits 65 for a compile failure and for a test failure
    # alike, which would be exactly the failed-vs-never-ran conflation
    # docs/learnings/exit-status-conflates-failed-with-never-ran.md warns
    # against -- a build that never reached a single assertion reading as
    # `proved`. `build-for-testing` isolates the compile step: any failure
    # there means no test in this run ever executed, which is
    # `proved-by-compile` -- a real proof, but a weaker one than the tests
    # themselves noticing the revert. Only `test-without-building` failing,
    # once the build already succeeded, is the stronger `proved`.
    # shellcheck disable=SC2086 -- $only is a deliberately word-split flag list
    if ! xcodebuild -project App/WADdle.xcodeproj -scheme WADdle \
            -destination "$RG_DESTINATION" $only build-for-testing >/dev/null 2>&1; then
        restore_tree
        echo "proved-by-compile"
        return
    fi
    # shellcheck disable=SC2086
    if ! xcodebuild -project App/WADdle.xcodeproj -scheme WADdle \
            -destination "$RG_DESTINATION" $only test-without-building >/dev/null 2>&1; then
        restore_tree
        echo "proved"
        return
    fi
    restore_tree
    echo "vacuous"
}

# One domain's verdict, given its source and test file lists.
classify_domain() { # name, src, test
    if [ -z "$2" ]; then echo "absent"; return; fi
    if [ "$1" = "shell" ]; then run_shell_domain "$2" "$3"; return; fi
    if [ "$1" = "swift" ]; then
        if [ -z "$3" ]; then echo "no-test"; return; fi
        run_swift_domain "$2" "$3"
        return
    fi
}

# classify_domain is called with its output redirected to a file, not wrapped
# in `$(...)`. Command substitution forks a subshell in bash, and both
# run_shell_domain and run_swift_domain call revert_src (which sets
# REVERTED) and can themselves die mid-run under `errexit` (e.g. an
# unguarded precondition failing); either effect done inside a subshell would
# vanish the instant the subshell exits, leaving the parent's REVERTED empty
# and a hard failure unable to actually stop the script. A
# redirect runs the function in this same shell, so both survive.
verdict_tmp="$(mktemp)"
classify_domain swift "$(swift_src)" "$(swift_test)" > "$verdict_tmp"
sw="$(cat "$verdict_tmp")"
classify_domain shell "$(shell_src)" "$(shell_test)" > "$verdict_tmp"
sh="$(cat "$verdict_tmp")"
rm -f "$verdict_tmp"

if [ "$sw" = "absent" ] && [ "$sh" = "absent" ]; then
    echo "n/a"
    exit 0
fi
# Single-domain case only until Task 5 adds combination.
if [ "$sw" != "absent" ]; then echo "$sw"; else echo "$sh"; fi
