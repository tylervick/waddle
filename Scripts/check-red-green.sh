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
trap restore_tree EXIT

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

# One domain's verdict, given its source and test file lists. Task 3 and Task 4
# replace the `run_*` calls; until then a domain with both halves is `error`,
# which is honest -- nothing has been proved yet.
classify_domain() { # name, src, test
    if [ -z "$2" ]; then echo "absent"; return; fi
    if [ -z "$3" ]; then echo "no-test"; return; fi
    revert_src "$2"
    # Test hook: prove the EXIT trap restores the tree even on a hard failure.
    if [ -n "${RED_GREEN_DIE_AFTER_REVERT:-}" ]; then exit 70; fi
    echo "error"
}

# classify_domain is called with its output redirected to a file, not wrapped
# in `$(...)`. Command substitution forks a subshell in bash, and this domain
# can call revert_src (which sets REVERTED) or, under the
# RED_GREEN_DIE_AFTER_REVERT test hook, `exit`; either one done inside a
# subshell would vanish the instant the subshell exits, leaving the parent's
# REVERTED empty and a hard failure unable to actually stop the script. A
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
