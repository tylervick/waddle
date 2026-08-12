# Red-Green Test Proof Signal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the agent loop's CodeRabbit-dependent leading signal with a mechanically computed proof that a change's test fails without that change.

**Architecture:** One hermetically testable shell guard, `Scripts/check-red-green.sh`, classifies a diff into a verdict. A CI job runs it and prints a greppable marker line; the loop records the verdict from the first CI run into its trial record, and `Scripts/loop-report.sh` aggregates it. The guard never gates the build and the loop never acts on its verdict — both are load-bearing, see Global Constraints.

**Tech Stack:** bash 3.2 (macOS), git plumbing, xcodebuild, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-08-10-test-proof-signal-design.md` (commit 72170e6). Read it before Task 1.

## Global Constraints

- `set -euo pipefail` in every script; macOS **bash 3.2** — no associative arrays, no `${var^^}`, no `mapfile`.
- **Never mask an exit status you then interpret as data.** Read `docs/learnings/masked-exit-status-fails-open.md` first. Test status directly: `if out="$(cmd)"; then`. Keep `|| true` only where a non-zero status *is* the expected answer (`grep -c` with no matches).
- **The CI job must exit 0 on every verdict, including `vacuous`.** A gating proof would make the loop iterate until it went green, and the signal would read `proved` forever.
- **The loop protocol must not act on a `vacuous` verdict.** Record it; do not fix it.
- Verdict vocabulary is exactly: `proved`, `proved-by-compile`, `vacuous`, `no-test`, `n/a`, `error`. No others.
- `error` means *unknown*, never *bad*. It is never folded into a score, and if any evaluated domain errors the whole verdict is `error`.
- `proved-by-compile` is impossible in the shell domain — there is no compile step.
- Never weaken, delete, or skip an existing test. Existing counts that must hold: `test-loop-report.sh` 23, `test-loop-precheck.sh` 14, `test-check-simulator-available.sh` 8.
- Conventional commits. No `Co-Authored-By`, no Claude/AI mention. **Never write a bare `Closes #N` / `Fixes #N` / `Resolves #N` in a commit message** — a commit in this repo once closed a live issue that way.
- Commit with the repo's default signing config. Do **not** override `gpg.ssh.program`; the owner's key lives in the 1Password agent and an `ssh-keygen` override breaks it.

---

## File Structure

| File | Responsibility |
|---|---|
| `Scripts/check-red-green.sh` (create) | Classify a diff into one verdict. The whole mechanism. |
| `Scripts/test-check-red-green.sh` (create) | Hermetic tests, git fixtures + stubbed `xcodebuild`. |
| `.github/workflows/ci.yml` (modify) | Run the guard, print `TEST_PROOF: <verdict>`, never fail. |
| `Scripts/loop-prompt.md` (modify) | Record `test_proof_first` and `test_proof_domains`. |
| `Scripts/loop-report.sh` (modify) | Aggregate the new field. |
| `Scripts/test-loop-report.sh` (modify) | Cover the aggregation. |

**Working-tree safety (applies to Tasks 2–5).** The guard mutates the checkout in place and restores it. It therefore **refuses to run unless `git status --porcelain` is empty**, and installs an `EXIT` trap that restores before the script can leave by any path. A temp worktree was considered and rejected: a fresh worktree has no `Vendor` symlink or generated xcodeproj, so a Swift build there would pay the full bootstrap cost and the `Vendor/build` trap (issue 72).

---

### Task 1: Diff classification — domains, `n/a`, and `no-test`

**Files:**
- Create: `Scripts/check-red-green.sh`
- Create: `Scripts/test-check-red-green.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `Scripts/check-red-green.sh <base-ref>` printing one verdict on stdout, exit 0. Later tasks add runners behind the classification this task establishes. Internal function names later tasks call: `classify_domain`, `swift_src`, `swift_test`, `shell_src`, `shell_test`.

- [ ] **Step 1: Write the failing test**

Create `Scripts/test-check-red-green.sh`:

```bash
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

# Builds a git repo with a base commit, then applies $2 as a shell script that
# edits the tree, and commits that as HEAD. Prints the repo path.
make_repo() { # name, mutate-script
    d="$TMP/$1"; mkdir -p "$d"; cd "$d"
    git init -q .; git config user.email t@e.st; git config user.name T
    mkdir -p App/Sources App/Tests Scripts
    echo 'let x = 1' > App/Sources/Thing.swift
    echo 'nothing' > README.md
    # The guard under test must be committed BEFORE the base commit. Copying
    # it in afterwards leaves it untracked, so `git status --porcelain` is
    # non-empty and the guard's own dirty-tree refusal fires on every case.
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

echo "All check-red-green tests passed."
```

- [ ] **Step 2: Run it to verify it fails**

Run: `chmod +x Scripts/test-check-red-green.sh && Scripts/test-check-red-green.sh`
Expected: FAIL — `Scripts/check-red-green.sh` does not exist yet.

- [ ] **Step 3: Write the minimal implementation**

Create `Scripts/check-red-green.sh`:

```bash
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

# One domain's verdict, given its source and test file lists. Task 3 and Task 4
# replace the `run_*` calls; until then a domain with both halves is `error`,
# which is honest -- nothing has been proved yet.
classify_domain() { # name, src, test
    if [ -z "$2" ]; then echo "absent"; return; fi
    if [ -z "$3" ]; then echo "no-test"; return; fi
    echo "error"
}

sw="$(classify_domain swift "$(swift_src)" "$(swift_test)")"
sh="$(classify_domain shell "$(shell_src)" "$(shell_test)")"

if [ "$sw" = "absent" ] && [ "$sh" = "absent" ]; then
    echo "n/a"
    exit 0
fi
# Single-domain case only until Task 5 adds combination.
if [ "$sw" != "absent" ]; then echo "$sw"; else echo "$sh"; fi
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `Scripts/test-check-red-green.sh`
Expected: all 5 cases `ok -`, ending `All check-red-green tests passed.`

- [ ] **Step 5: Commit**

```bash
chmod +x Scripts/check-red-green.sh Scripts/test-check-red-green.sh
git add Scripts/check-red-green.sh Scripts/test-check-red-green.sh
git commit -m "feat(loop): classify a diff into red-green domains"
```

---

### Task 2: Revert and restore

**Files:**
- Modify: `Scripts/check-red-green.sh`
- Modify: `Scripts/test-check-red-green.sh`

**Interfaces:**
- Consumes: `swift_src`, `shell_src` from Task 1.
- Produces: `revert_src <base> <paths...>` and an `EXIT` trap calling `restore_tree`. Tasks 3 and 4 call `revert_src` before running tests and rely on the trap for cleanup.

This is the highest-risk task in the plan: a revert that silently does nothing produces a false `vacuous`, which is worse than an error because it looks like a measurement.

- [ ] **Step 1: Write the failing tests**

Append to `Scripts/test-check-red-green.sh`, before the final `echo`:

```bash
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
```

- [ ] **Step 2: Run to verify the new cases fail**

Run: `Scripts/test-check-red-green.sh`
Expected: FAIL at case 6 — nothing reverts or restores yet.

- [ ] **Step 3: Implement revert and restore**

In `Scripts/check-red-green.sh`, add after the `shell_test()` definitions:

```bash
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
            # back from base. Remove it again.
            rm -f "$p"
        fi
    done
    REVERTED=""
}
trap restore_tree EXIT

# Put the given paths into their BASE state: restore modified and
# change-deleted files from base, delete files the change added.
revert_src() { # paths (newline separated)
    printf '%s\n' "$1" | while IFS= read -r p; do
        [ -n "$p" ] || continue
        if git cat-file -e "$BASE:$p" 2>/dev/null; then
            git checkout "$BASE" -- "$p"
        else
            rm -f "$p"
        fi
    done
    REVERTED="$REVERTED
$1"
}
```

`REVERTED` is assigned in the parent shell, not inside the `while` — a `while` fed by a pipe runs in a subshell in bash 3.2 and any assignment inside it is lost. This is the same class of trap as `docs/learnings/masked-exit-status-fails-open.md`: work that appears to happen and silently does not.

Then in `classify_domain`, replace the `echo "error"` branch with:

```bash
    revert_src "$2"
    # Test hook: prove the EXIT trap restores the tree even on a hard failure.
    if [ -n "${RED_GREEN_DIE_AFTER_REVERT:-}" ]; then exit 70; fi
    echo "error"
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `Scripts/test-check-red-green.sh`
Expected: 8 cases `ok -`.

- [ ] **Step 5: Commit**

```bash
git add Scripts/check-red-green.sh Scripts/test-check-red-green.sh
git commit -m "feat(loop): revert and restore source files around a red-green run"
```

---

### Task 3: The shell domain runner

**Files:**
- Modify: `Scripts/check-red-green.sh`
- Modify: `Scripts/test-check-red-green.sh`

**Interfaces:**
- Consumes: `revert_src`, `shell_src`, `shell_test` from Tasks 1–2.
- Produces: `run_shell_domain <src> <test>` printing `proved` | `vacuous` | `no-test`. Never prints `proved-by-compile` — shell has no compile step.

Built before the Swift runner because it needs no build toolchain, so it exercises the revert machinery end to end with nothing stubbed.

- [ ] **Step 1: Write the failing tests**

Append to `Scripts/test-check-red-green.sh`:

```bash
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
```

- [ ] **Step 2: Run to verify the new cases fail**

Run: `Scripts/test-check-red-green.sh`
Expected: FAIL at case 9 — the domain still returns `error`.

- [ ] **Step 3: Implement the shell runner**

Add to `Scripts/check-red-green.sh`:

```bash
# The test for Scripts/foo.sh is Scripts/test-foo.sh, by name and nothing
# cleverer. A changed script with no matching suite is unproven, which is
# `no-test` -- not `error`, because nothing failed: the proof is simply absent.
run_shell_domain() { # src, test
    suites=""
    printf '%s\n' "$1" | while IFS= read -r s; do
        [ -n "$s" ] || continue
        t="Scripts/test-$(basename "$s")"
        [ -f "$t" ] && echo "$t"
    done > "$TMPDIR_RG/suites"
    suites="$(cat "$TMPDIR_RG/suites")"
    if [ -z "$suites" ]; then echo "no-test"; return; fi

    revert_src "$1"
    rc=0
    printf '%s\n' "$suites" | while IFS= read -r t; do
        [ -n "$t" ] || continue
        "./$t" >/dev/null 2>&1 || exit 1
    done || rc=1
    restore_tree

    # Non-zero means at least one suite noticed the revert. That is the proof.
    if [ "$rc" -eq 1 ]; then echo "proved"; else echo "vacuous"; fi
}
```

Add near the top, after `cd "$ROOT"`:

```bash
# Scratch space for lists that must cross a subshell boundary.
TMPDIR_RG="$(mktemp -d)"
```

and extend the trap so it cleans up too:

```bash
trap 'restore_tree; rm -rf "$TMPDIR_RG"' EXIT
```

Then in `classify_domain`, dispatch on the domain name:

```bash
classify_domain() { # name, src, test
    if [ -z "$2" ]; then echo "absent"; return; fi
    if [ "$1" = "shell" ]; then run_shell_domain "$2" "$3"; return; fi
    if [ -z "$3" ]; then echo "no-test"; return; fi
    revert_src "$2"
    if [ -n "${RED_GREEN_DIE_AFTER_REVERT:-}" ]; then exit 70; fi
    echo "error"
}
```

The shell domain decides `no-test` itself, from whether a *matching* suite exists, rather than from whether any `test-*.sh` changed.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `Scripts/test-check-red-green.sh`
Expected: 11 cases `ok -`.

- [ ] **Step 5: Commit**

```bash
git add Scripts/check-red-green.sh Scripts/test-check-red-green.sh
git commit -m "feat(loop): prove shell changes by reverting and rerunning their suites"
```

---

### Task 4: The Swift domain runner

**Files:**
- Modify: `Scripts/check-red-green.sh`
- Modify: `Scripts/test-check-red-green.sh`

**Interfaces:**
- Consumes: `revert_src`, `restore_tree`, `swift_src`, `swift_test`.
- Produces: `run_swift_domain <src> <test>` printing `proved` | `proved-by-compile` | `vacuous`.

**Why two xcodebuild invocations.** `xcodebuild test` exits 65 for a compile failure *and* for a test failure, so one invocation cannot tell them apart. Run `build-for-testing` first — failure there is `proved-by-compile` — then `test-without-building`.

**Why class names are parsed, not inferred.** `App/Tests/ImportNoticesTests.swift` declares both `ImportNoticesTests` and `ImportNoticesMessageTests`. Filename inference would silently run half the file.

- [ ] **Step 1: Write the failing tests**

Append to `Scripts/test-check-red-green.sh`:

```bash
# A stubbed xcodebuild whose behaviour is driven by two files, so each case
# can choose independently whether the build and the tests succeed.
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

mk_swift='
echo "let y = 2" >> App/Sources/Thing.swift
cat > App/Tests/ThingTests.swift <<"EOS"
import XCTest
final class ThingTests: XCTestCase { func testA() {} }
final class ThingExtraTests: XCTestCase { func testB() {} }
EOS'

# 12. Build fails with the source reverted -> proved-by-compile.
r="$(make_repo sw_compile "$mk_swift")"; stub_xcodebuild "$r" 65 0
[ "$(cd "$r" && PATH="$r/bin:$PATH" ./Scripts/check-red-green.sh base-ref)" = "proved-by-compile" ] \
    || fail "expected proved-by-compile"
pass "swift: a reverted tree that will not compile is proved-by-compile"

# 13. Build succeeds, tests fail -> proved.
r="$(make_repo sw_proved "$mk_swift")"; stub_xcodebuild "$r" 0 65
[ "$(cd "$r" && PATH="$r/bin:$PATH" ./Scripts/check-red-green.sh base-ref)" = "proved" ] \
    || fail "expected proved"
pass "swift: a reverted tree whose tests fail is proved"

# 14. Build succeeds, tests pass -> vacuous.
r="$(make_repo sw_vacuous "$mk_swift")"; stub_xcodebuild "$r" 0 0
[ "$(cd "$r" && PATH="$r/bin:$PATH" ./Scripts/check-red-green.sh base-ref)" = "vacuous" ] \
    || fail "expected vacuous"
pass "swift: a reverted tree whose tests still pass is vacuous"

# 15. EVERY class in a changed test file is targeted, not just the one whose
#     name matches the file. ImportNoticesTests.swift in the real repo declares
#     two; missing the second would silently halve the proof.
grep -q 'only-testing:WADdleTests/ThingTests' "$r/xcb.log" || fail "did not target ThingTests"
grep -q 'only-testing:WADdleTests/ThingExtraTests' "$r/xcb.log" || fail "did not target the second class in the file"
pass "swift: targets every XCTestCase class declared in a changed test file"
```

- [ ] **Step 2: Run to verify the new cases fail**

Run: `Scripts/test-check-red-green.sh`
Expected: FAIL at case 12 — the Swift domain still returns `error`.

- [ ] **Step 3: Implement the Swift runner**

Add to `Scripts/check-red-green.sh`:

```bash
# Every `final class X: XCTestCase` / `class X: XCTestCase` declared in the
# changed test files. Parsed from content because one file may declare several
# and nothing enforces that a file's name matches its classes.
test_classes() { # test paths
    printf '%s\n' "$1" | while IFS= read -r f; do
        [ -n "$f" ] && [ -f "$f" ] || continue
        grep -hoE '^[[:space:]]*(final[[:space:]]+)?class[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:[[:space:]]*XCTestCase' "$f" \
            | sed -E 's/.*class[[:space:]]+([A-Za-z0-9_]+).*/\1/'
    done | sort -u
}

run_swift_domain() { # src, test
    test_classes "$2" > "$TMPDIR_RG/classes"
    if [ ! -s "$TMPDIR_RG/classes" ]; then echo "error"; return; fi

    only=""
    while IFS= read -r c; do
        [ -n "$c" ] && only="$only -only-testing:WADdleTests/$c"
    done < "$TMPDIR_RG/classes"

    revert_src "$1"
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
```

Add near the top, beside `TMPDIR_RG`:

```bash
# Overridable so the hermetic suite never needs a real simulator.
RG_DESTINATION="${RG_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2}"
```

and dispatch in `classify_domain`:

```bash
    if [ "$1" = "swift" ]; then
        if [ -z "$3" ]; then echo "no-test"; return; fi
        run_swift_domain "$2" "$3"
        return
    fi
```

A changed test file declaring no `XCTestCase` class yields `error`, not `vacuous`: nothing was run, so nothing was proved.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `Scripts/test-check-red-green.sh`
Expected: 15 cases `ok -`.

- [ ] **Step 5: Commit**

```bash
git add Scripts/check-red-green.sh Scripts/test-check-red-green.sh
git commit -m "feat(loop): prove swift changes by reverting and rerunning their test classes"
```

---

### Task 5: Combining domains

**Files:**
- Modify: `Scripts/check-red-green.sh`
- Modify: `Scripts/test-check-red-green.sh`

**Interfaces:**
- Consumes: both runners.
- Produces: final stdout contract — the verdict on line 1, and the evaluated domains on line 2 as `domains: swift`, `domains: shell`, `domains: swift+shell`, or `domains: none`. Task 6 parses both lines; Task 7 records both.

- [ ] **Step 1: Write the failing tests**

Append to `Scripts/test-check-red-green.sh`:

```bash
# 16. Mixed domains take the WORSE verdict: a proved swift half must not mask
#     a vacuous shell half.
mk_mixed="$mk_shell_vacuous"'
echo "let y = 2" >> App/Sources/Thing.swift
cat > App/Tests/ThingTests.swift <<"EOS"
import XCTest
final class ThingTests: XCTestCase { func testA() {} }
EOS'
r="$(make_repo mixed "$mk_mixed")"; stub_xcodebuild "$r" 0 65
out="$(cd "$r" && PATH="$r/bin:$PATH" ./Scripts/check-red-green.sh base-ref)"
[ "$(echo "$out" | head -1)" = "vacuous" ] || fail "expected worst-of vacuous, got: $out"
echo "$out" | grep -q "domains: swift+shell" || fail "did not report both domains; got: $out"
pass "a mixed pull request takes the worse of the two verdicts"

# 17. `error` is not a rank -- it dominates everything, because a
#     half-computed proof is not a proof.
mk_err="$mk_shell_proved"'
echo "let y = 2" >> App/Sources/Thing.swift
echo "// no XCTestCase here" > App/Tests/ThingTests.swift'
r="$(make_repo errdom "$mk_err")"; stub_xcodebuild "$r" 0 0
[ "$(cd "$r" && PATH="$r/bin:$PATH" ./Scripts/check-red-green.sh base-ref | head -1)" = "error" ] \
    || fail "error did not dominate a proved sibling domain"
pass "error in one domain dominates a proved verdict in the other"

# 18. The n/a case reports no domains.
r="$(make_repo na2 'echo more >> README.md')"
(cd "$r" && ./Scripts/check-red-green.sh base-ref) | grep -q "domains: none" \
    || fail "n/a did not report 'domains: none'"
pass "an n/a verdict reports no evaluated domains"
```

- [ ] **Step 2: Run to verify they fail**

Run: `Scripts/test-check-red-green.sh`
Expected: FAIL at case 16 — no combination or domains line yet.

- [ ] **Step 3: Implement combination**

Replace the final dispatch block in `Scripts/check-red-green.sh` with:

```bash
# Worst-of, most severe first. `error` is deliberately absent: it is not a
# rank but an absence of measurement, and is handled before this is consulted.
severity() { # verdict
    case "$1" in
        vacuous)           echo 4 ;;
        no-test)           echo 3 ;;
        proved-by-compile) echo 2 ;;
        proved)            echo 1 ;;
        *)                 echo 0 ;;
    esac
}

domains=""
[ "$sw" != "absent" ] && domains="swift"
[ "$sh" != "absent" ] && domains="${domains:+$domains+}shell"

if [ -z "$domains" ]; then
    echo "n/a"
    echo "domains: none"
    exit 0
fi

if [ "$sw" = "error" ] || [ "$sh" = "error" ]; then
    echo "error"
    echo "domains: $domains"
    exit 0
fi

worst="$sw"; [ "$sw" = "absent" ] && worst="$sh"
if [ "$sh" != "absent" ] && [ "$(severity "$sh")" -gt "$(severity "$worst")" ]; then
    worst="$sh"
fi
echo "$worst"
echo "domains: $domains"
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `Scripts/test-check-red-green.sh`
Expected: 18 cases `ok -`.

- [ ] **Step 5: Commit**

```bash
git add Scripts/check-red-green.sh Scripts/test-check-red-green.sh
git commit -m "feat(loop): combine red-green domains, worst-of with error dominating"
```

---

### Task 6: The CI job

**Files:**
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `Scripts/check-red-green.sh`, stdout line 1 = verdict, line 2 = `domains: ...`.
- Produces: two log lines the loop greps — `TEST_PROOF: <verdict>` and `TEST_PROOF_DOMAINS: <domains>`.

- [ ] **Step 1: Add the test script to the helper step**

In `.github/workflows/ci.yml`, in the `Verify the build-script helpers` step, add after `Scripts/test-check-simulator-available.sh`:

```yaml
          Scripts/test-check-red-green.sh
```

- [ ] **Step 2: Add the job step**

Add after the `Run unit tests` step:

```yaml
      # The loop's leading signal: does the test shipped with this change
      # actually fail without the change? Prints a greppable marker the same
      # way check-simulator-available.sh does.
      #
      # `|| true` and `continue-on-error` are BOTH deliberate and neither is
      # sloppiness: this step must never fail the build. A gating proof would
      # make the loop iterate until it went green, and the signal would read
      # `proved` on every trial forever -- the exact defect that made
      # coderabbit_findings_first a pre-fix snapshot. See
      # docs/superpowers/specs/2026-08-10-test-proof-signal-design.md.
      - name: Red-green test proof
        continue-on-error: true
        env:
          RG_DESTINATION: platform=iOS Simulator,name=${{ env.SIMULATOR_DEVICE }},OS=${{ env.SIMULATOR_OS }}
        run: |
          out="$(Scripts/check-red-green.sh "origin/${{ github.base_ref || 'main' }}" || echo 'error')"
          echo "TEST_PROOF: $(printf '%s\n' "$out" | head -1)"
          echo "TEST_PROOF_DOMAINS: $(printf '%s\n' "$out" | sed -n 's/^domains: //p')"
```

- [ ] **Step 3: Verify the workflow parses**

Run: `ruby -ryaml -e 'YAML.load_file(".github/workflows/ci.yml"); puts "ci.yml OK"'`
Expected: `ci.yml OK`

- [ ] **Step 4: Verify the guard suite still passes**

Run: `Scripts/test-check-red-green.sh && Scripts/check-substrate.sh && echo GREEN`
Expected: 18 `ok -` lines then `GREEN`.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: report the red-green test proof without gating the build"
```

---

### Task 7: Record the verdict in the trial record

**Files:**
- Modify: `Scripts/loop-prompt.md`

**Interfaces:**
- Consumes: the `TEST_PROOF:` / `TEST_PROOF_DOMAINS:` log lines from Task 6.
- Produces: `test_proof_first` and `test_proof_domains` fields in the trial record, read by Task 8.

- [ ] **Step 1: Add the fields to the record template**

In the section 6 markdown template, after the `coderabbit_findings_after` line, add:

```markdown
test_proof_first: <proved|proved-by-compile|vacuous|no-test|n/a|error — from the FIRST CI run, before any fix round>
test_proof_domains: <swift|shell|swift+shell|none>
```

- [ ] **Step 2: Add the read instruction to section 4.1**

In section 4.1, where CI is polled, add:

```markdown
When CI concludes, read the red-green proof from the same run — it is the
leading signal and replaces `coderabbit_findings_first` in that role:

```bash
gh run view "$RUN_ID" --log | grep -oE 'TEST_PROOF(_DOMAINS)?: .*' | tail -2
```

Record both as literals, from the **first** CI run only. If a later fix round
triggers another run, its proof is post-fix and must not overwrite these — the
same rule, and the same reason, as `coderabbit_findings_first`. If the lines
are absent, record `test_proof_first: error`: the proof was not computed, which
is not the same as the change failing to prove anything.

**Never act on this verdict.** A `vacuous` result is a real defect and you will
be standing next to it, but section 4's fix phase covers red CI and trusted-app
review findings only. A measurement you are instructed to improve stops being a
measurement.
```

- [ ] **Step 3: Verify no other section contradicts it**

Run: `grep -n "test_proof\|leading signal" Scripts/loop-prompt.md`
Expected: the new section 4.1 text and the two template fields, with no older
text still calling `coderabbit_findings_first` the leading signal.

- [ ] **Step 4: Commit**

```bash
git add Scripts/loop-prompt.md
git commit -m "feat(loop): record the red-green proof as the leading signal"
```

---

### Task 8: Aggregate the verdict in the report

**Files:**
- Modify: `Scripts/loop-report.sh`
- Modify: `Scripts/test-loop-report.sh`

**Interfaces:**
- Consumes: `test_proof_first` from the trial record.
- Produces: a per-prompt-version breakdown line.

- [ ] **Step 1: Write the failing tests**

Add to `Scripts/test-loop-report.sh`, following the existing fixture helpers:

```bash
# Counts each verdict separately. n/a and error are absences, not scores, and
# must never be counted as though the run proved nothing.
make_trial "$D" proof1 pr-opened 101 5 "" 0 proved
make_trial "$D" proof2 pr-opened 102 5 "" 0 vacuous
make_trial "$D" proof3 pr-opened 103 5 "" 0 n/a
make_trial "$D" proof4 pr-opened 104 5 "" 0 error
out="$(run_report "$D")"
echo "$out" | grep -q "test proof: 1 proved, 1 vacuous" \
    || fail "did not summarise proved/vacuous counts; got: $out"
echo "$out" | grep -q "2 not measured (1 n/a, 1 error)" \
    || fail "folded absent measurements into a score; got: $out"
pass "reports red-green verdicts and keeps n/a and error out of the scores"
```

Extend `make_trial` to accept the verdict as its final argument and emit
`test_proof_first: <verdict>` in the record's front matter.

- [ ] **Step 2: Run to verify it fails**

Run: `Scripts/test-loop-report.sh`
Expected: FAIL — the report does not read the field yet.

- [ ] **Step 3: Implement aggregation**

In `Scripts/loop-report.sh`, add `test_proof_first` as a seventh `|`-delimited
field in the `rows+=(...)` construction, then per prompt version:

```bash
        proved=0; provedc=0; vac=0; notest=0; nap=0; errp=0
        # ... inside the existing per-row loop:
        tp="$(printf '%s' "$r" | cut -d'|' -f7)"
        case "$tp" in
            proved)            proved=$((proved + 1)) ;;
            proved-by-compile) provedc=$((provedc + 1)) ;;
            vacuous)           vac=$((vac + 1)) ;;
            no-test)           notest=$((notest + 1)) ;;
            n/a)               nap=$((nap + 1)) ;;
            *)                 errp=$((errp + 1)) ;;
        esac
```

and after the existing findings lines:

```bash
        echo "    test proof: $proved proved, $vac vacuous, $provedc proved-by-compile, $notest no-test"
        if [ "$((nap + errp))" -gt 0 ]; then
            echo "      ($((nap + errp)) not measured ($nap n/a, $errp error) -- absent measurements, not zeros)"
        fi
```

A record written before this field existed lands in `errp` via the `*` branch,
which is correct: the proof was never computed for it.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `Scripts/test-loop-report.sh`
Expected: 24 `ok -` lines (23 existing plus the new case).

- [ ] **Step 5: Verify against real data**

```bash
git fetch origin loop-trials
rm -rf /tmp/lt && mkdir -p /tmp/lt
git archive origin/loop-trials docs/loop-trials | tar -x -C /tmp/lt
Scripts/loop-report.sh /tmp/lt/docs/loop-trials
```

Expected: every existing trial reports under "not measured" as `error`, since
none of them carry the field. The CodeRabbit lines must be unchanged.

- [ ] **Step 6: Commit**

```bash
git add Scripts/loop-report.sh Scripts/test-loop-report.sh
git commit -m "feat(loop): aggregate red-green verdicts in the trial report"
```

---

## Self-Review

**Spec coverage.** Verdict vocabulary → Tasks 1–5. Mechanism and revert
semantics → Tasks 1–2. Test selection by parsed class name → Task 4. CI job and
the never-gate rule → Task 6. Snapshot semantics and the do-not-act rule →
Task 7. Domain table, name-based shell mapping, worst-of, error dominance →
Tasks 3 and 5. Trial fields and report treatment of `n/a` / `error` → Tasks 7
and 8. `coderabbit_findings_first` retained as secondary → untouched by every
task, which is the requirement.

**Not covered, deliberately:** the spec's "restore the working tree" is
implemented as refuse-if-dirty plus an `EXIT` trap rather than a temp worktree,
for the reason given under File Structure. Task 2 case 8 tests the trap
directly.

**Type consistency.** `classify_domain` is introduced in Task 1 and extended in
Tasks 3–4 with the same signature `(name, src, test)`. `revert_src` and
`restore_tree` keep their Task 2 signatures throughout. `TMPDIR_RG` and
`RG_DESTINATION` are declared once and used in Tasks 3–4 only.
