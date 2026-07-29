# CI Build & Test Workflows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add GitHub Actions CI to a repo that currently has none — build + unit tests on every PR, UI tests on manual dispatch — and replace `archive.sh`'s mtime-based stale-engine guard with a content fingerprint that doubles as the CI cache key.

**Architecture:** One new script, `Scripts/engine-fingerprint.sh`, prints a content hash of everything that determines the built engine framework. Three consumers share it: `build-engine.sh` stamps it beside the framework, `archive.sh` compares against that stamp, and CI uses it as a cache key. A composite action at `.github/actions/setup-waddle-build/` holds the setup preamble both workflows need, so each workflow file stays short and the follow-up TestFlight PR is cheap.

**Tech Stack:** GitHub Actions (`macos-26` runner), `xcodebuild`, `xcodegen`, `mise`, CMake/Ninja, bash.

**Spec:** `docs/superpowers/specs/2026-07-28-ci-build-scripts-design.md`

## Global Constraints

- Runner image: **`macos-26`** (arm64). Xcode pinned to **26.2**; simulator runtime pinned to **26.2**; default simulator device **`iPhone 17 Pro`**.
- CLI tools (`cmake`, `ninja`, `xcodegen`) come from **`mise`**, so `mise.toml` stays the single source of truth for versions. Do not `brew install` them.
- **`WADdleUITests/RealWADTests` must never run in CI.** It requires non-redistributable WADs (~300 MB) from `~/Downloads/doom-test-wads/`.
- `ci.yml` runs **unit tests only** (`-only-testing:WADdleTests`). The `WADdle` scheme's test action includes `WADdleUITests`, so the filter is required, not optional.
- The engine fingerprint must be **working-tree based** (not git-object based), **path-independent**, and **order-independent**. See Task 1.
- Every guard must **fail closed**: any error computing a fingerprint, or any missing stamp, refuses the archive.
- **Commit messages must not include Co-Authored-By lines or any AI/Claude attribution.**
- Scope is PR 1 only. `testflight.yml` is a follow-up PR and must not be created here.

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `Scripts/engine-fingerprint.sh` | Create | Print one content hash of `Engine/woof/` + the two build scripts. Single definition, three consumers. |
| `Scripts/test-engine-fingerprint.sh` | Create | Hermetic bash tests for the fingerprint's four load-bearing properties. |
| `Scripts/build-engine.sh` | Modify | Write the fingerprint stamp after a successful framework build. |
| `Scripts/check-engine-fresh.sh` | Create | Verify the built framework matches its sources. The stale guard, extracted from `archive.sh` so it is testable without running a build. |
| `Scripts/test-check-engine-fresh.sh` | Create | Hermetic tests for the guard, including the fresh-worktree mtime regression. |
| `Scripts/archive.sh` | Modify | Replace the inline `find -newer` mtime guard with a call to `check-engine-fresh.sh`. |
| `.github/actions/setup-waddle-build/action.yml` | Create | Shared preamble: pin Xcode, mise, caches, build engine, stage data, xcodegen. |
| `.github/workflows/ci.yml` | Create | PR + push-to-main: build and run unit tests. |
| `.github/workflows/ui-tests.yml` | Create | `workflow_dispatch` only: run the UI suite minus `RealWADTests`. |

## Design refinement discovered while planning

The spec says each build script runs only on a cache miss but doesn't specify how the two caches nest. **Order matters and is worth getting right:** `build-engine.sh` merges `libSDL3.a` and `libopenal.a` *into* `libWoofEngine.a`, and `App/project.yml` depends only on the xcframework. The deps output under `Vendor/out/{iphoneos,iphonesimulator}` is therefore build-time-only — nothing needs it once the framework exists.

So the composite action restores the **engine cache first**, and nests the deps cache and `build-deps.sh` under an engine-cache *miss*. On a hit, deps are skipped entirely. The common case — editing `Engine/woof` without touching `build-deps.sh` — then costs one engine rebuild (~5 min) instead of deps plus engine (~40 min).

---

### Task 1: Engine fingerprint script

The load-bearing piece. Everything else depends on it, and it's the only part of this PR that's fully testable locally.

**Files:**
- Create: `Scripts/engine-fingerprint.sh`
- Test: `Scripts/test-engine-fingerprint.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `Scripts/engine-fingerprint.sh` — takes no arguments, prints a single 64-character lowercase hex SHA-256 on stdout followed by a newline, exits 0 on success and non-zero on any failure. Callers in Tasks 2 and 3 rely on exactly this contract.

- [ ] **Step 1: Write the failing test**

Create `Scripts/test-engine-fingerprint.sh`. It builds a hermetic fake repo in a temp dir so it can mutate inputs without touching the real tree, then checks the real repo for the two properties that need real data.

```bash
#!/bin/bash
# Tests for Scripts/engine-fingerprint.sh.
#
# Most assertions run against a HERMETIC fake repo built in a temp dir --
# the fingerprint's whole job is to change when inputs change, and proving
# that requires mutating inputs. Doing that in the real tree would risk
# leaving the working copy dirty if the script aborts partway.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/Scripts/engine-fingerprint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# --- hermetic fixture -------------------------------------------------
# Mirrors the real layout the script walks: Engine/woof/** plus the two
# build scripts. Contents are stubs; only their bytes matter here.
make_fixture() { # dest
    mkdir -p "$1/Scripts" "$1/Engine/woof/src" "$1/Engine/woof/third-party"
    cp "$SCRIPT" "$1/Scripts/engine-fingerprint.sh"
    echo 'stub build-engine' > "$1/Scripts/build-engine.sh"
    echo 'stub build-deps'   > "$1/Scripts/build-deps.sh"
    echo 'int main(void){}'  > "$1/Engine/woof/src/d_main.c"
    echo 'add_subdirectory(x)' > "$1/Engine/woof/third-party/CMakeLists.txt"
}
fp() { "$1/Scripts/engine-fingerprint.sh"; } # repo-root -> hash

make_fixture "$TMP/a"
BASE="$(fp "$TMP/a")"

# 1. Well-formed output: exactly one 64-char lowercase hex line.
[[ "$BASE" =~ ^[0-9a-f]{64}$ ]] || fail "not a 64-char hex hash: '$BASE'"
pass "emits a 64-char lowercase hex hash"

# 2. Deterministic across repeated runs with no edits.
[ "$(fp "$TMP/a")" = "$BASE" ] || fail "not deterministic across runs"
pass "deterministic across repeated runs"

# 3. Path-independent: same content at a different path -> same hash.
#    This is what lets a worktree, a fresh clone, and the CI checkout dir
#    all agree, and it is why the script hashes repo-RELATIVE paths.
make_fixture "$TMP/b-different-name"
[ "$(fp "$TMP/b-different-name")" = "$BASE" ] || fail "hash depends on checkout path"
pass "path-independent"

# 4. Independent of the caller's working directory.
[ "$(cd / && fp "$TMP/a")" = "$BASE" ] || fail "hash depends on caller cwd"
pass "independent of caller cwd"

# 5. Sensitive to an edit anywhere under Engine/woof -- including OUTSIDE
#    src/, which the old mtime guard did not watch at all.
echo 'changed' >> "$TMP/a/Engine/woof/src/d_main.c"
[ "$(fp "$TMP/a")" != "$BASE" ] || fail "ignored an edit under Engine/woof/src"
pass "detects edits under Engine/woof/src"

make_fixture "$TMP/c"
echo 'changed' >> "$TMP/c/Engine/woof/third-party/CMakeLists.txt"
[ "$(fp "$TMP/c")" != "$BASE" ] || fail "ignored an edit outside Engine/woof/src"
pass "detects edits elsewhere under Engine/woof"

# 6. Sensitive to either build script.
make_fixture "$TMP/d"; echo 'x' >> "$TMP/d/Scripts/build-deps.sh"
[ "$(fp "$TMP/d")" != "$BASE" ] || fail "ignored an edit to build-deps.sh"
pass "detects edits to build-deps.sh"

make_fixture "$TMP/e"; echo 'x' >> "$TMP/e/Scripts/build-engine.sh"
[ "$(fp "$TMP/e")" != "$BASE" ] || fail "ignored an edit to build-engine.sh"
pass "detects edits to build-engine.sh"

# 7. Sensitive to a NEW file (not just edits to known ones).
make_fixture "$TMP/f"; echo 'new' > "$TMP/f/Engine/woof/src/new_file.c"
[ "$(fp "$TMP/f")" != "$BASE" ] || fail "ignored a newly added engine source"
pass "detects newly added engine sources"

# 8. Fails CLOSED when the engine tree is missing, rather than printing
#    the hash of an empty set -- which would silently validate any stamp.
make_fixture "$TMP/g"; rm -rf "$TMP/g/Engine/woof"
if fp "$TMP/g" >/dev/null 2>&1; then fail "succeeded with Engine/woof missing"; fi
pass "fails closed when Engine/woof is missing"

make_fixture "$TMP/h"; rm -f "$TMP/h/Scripts/build-deps.sh"
if fp "$TMP/h" >/dev/null 2>&1; then fail "succeeded with build-deps.sh missing"; fi
pass "fails closed when a build script is missing"

# --- real repo --------------------------------------------------------
# The fixture is tiny; confirm the properties hold over the real 761-file
# tree too, and that it stays fast enough for archive.sh to call inline.
REAL="$("$SCRIPT")"
[[ "$REAL" =~ ^[0-9a-f]{64}$ ]] || fail "real repo: malformed hash"
[ "$(cd / && "$SCRIPT")" = "$REAL" ] || fail "real repo: cwd-dependent"
pass "real repo: well-formed and cwd-independent"

echo "All engine-fingerprint tests passed."
```

Make it executable:

```bash
chmod +x Scripts/test-engine-fingerprint.sh
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `Scripts/test-engine-fingerprint.sh`

Expected: FAIL. `Scripts/engine-fingerprint.sh` does not exist yet, so `cp` in `make_fixture` fails and the script aborts with a non-zero exit.

- [ ] **Step 3: Write the implementation**

Create `Scripts/engine-fingerprint.sh`:

```bash
#!/bin/bash
# Prints one content hash covering everything that determines the contents
# of Vendor/out/WoofEngine.xcframework: the vendored engine tree and the two
# scripts that build it.
#
# Three consumers share this single definition:
#   1. Scripts/build-engine.sh -- stamps the value beside the built framework
#   2. Scripts/archive.sh      -- compares stamp vs. current content (stale guard)
#   3. CI                      -- engine cache key
#
# Three properties are load-bearing (all covered by
# Scripts/test-engine-fingerprint.sh):
#
#   - PATH-INDEPENDENT. Hashes repo-relative paths, so a worktree, a fresh
#     clone, and the CI checkout directory all agree on the same content.
#     Feeding absolute paths to shasum would make the hash vary by location.
#
#   - ORDER-INDEPENDENT. `LC_ALL=C sort -z` normalizes the file list, so the
#     result never depends on filesystem enumeration order.
#
#   - WORKING-TREE BASED, not git-object based. `git rev-parse HEAD:Engine/woof`
#     would be faster and exact, but it only sees COMMITTED content -- and
#     catching "I edited engine source and forgot to rebuild" is the guard's
#     entire purpose. Uncommitted edits must change this value.
#
# Covers all of Engine/woof, not just src/, so changes to the vendored
# CMakeLists.txt or third-party/ invalidate too; the old mtime guard watched
# only src/ and was blind to those. `set -euo pipefail` makes any unreadable
# input abort rather than emit a hash over a partial file set.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
{
    find Engine/woof -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256
    shasum -a 256 Scripts/build-engine.sh Scripts/build-deps.sh
} | shasum -a 256 | awk '{print $1}'
```

Make it executable:

```bash
chmod +x Scripts/engine-fingerprint.sh
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `Scripts/test-engine-fingerprint.sh`

Expected: PASS — eleven `ok - ...` lines, then `All engine-fingerprint tests passed.`

- [ ] **Step 5: Confirm it is fast enough to call inline**

Run: `time Scripts/engine-fingerprint.sh`

Expected: a 64-char hash in well under one second (~0.1s over the real 761-file tree). `archive.sh` calls this before a multi-minute build, so anything sub-second is free.

- [ ] **Step 6: Commit**

```bash
git add Scripts/engine-fingerprint.sh Scripts/test-engine-fingerprint.sh
git commit -m "feat(build): add content fingerprint for the engine framework

Hashes Engine/woof plus build-engine.sh/build-deps.sh into a single value,
path- and cwd-independent and based on working-tree content so uncommitted
edits are visible. Becomes the shared definition behind the archive stale
guard and the CI engine cache key."
```

---

### Task 2: Stamp the framework and replace the stale-engine guard

Makes the fingerprint load-bearing. Splitting this in two would leave a stamp nobody reads, or a guard with nothing to read.

**Files:**
- Modify: `Scripts/build-engine.sh` (append after the `xcodebuild -create-xcframework` step)
- Create: `Scripts/check-engine-fresh.sh`
- Modify: `Scripts/archive.sh:13-38` (replace both the missing-framework check and the mtime guard with one call)
- Test: `Scripts/test-check-engine-fresh.sh` (create)

**Interfaces:**
- Consumes: `Scripts/engine-fingerprint.sh` from Task 1 — no arguments, prints one 64-char hex hash, non-zero exit on failure.
- Produces:
  - The stamp file `Vendor/out/WoofEngine.xcframework.fingerprint`, containing exactly that hash. Task 3 caches this path alongside the framework so a restored CI cache carries a valid stamp.
  - `Scripts/check-engine-fresh.sh` — takes no arguments, exits 0 when the built framework matches current sources, exits 1 with guidance on stderr otherwise. Silent on success.

**Why the guard is extracted into its own script rather than left inline in `archive.sh`:** it makes the guard testable. `archive.sh` continues past the guard into `xcodegen`, a full Release build, `rm -rf Vendor/archive/export`, and a signed export — so exercising the guard's *success* path in place would either run a multi-minute signed build or require stubbing `xcodebuild`, which cannot work because `archive.sh` deliberately re-invokes it as `PATH="/usr/bin:$PATH" xcodebuild` and would find the real binary ahead of any stub. A standalone script is testable against a fake tree in milliseconds, and gives the follow-up TestFlight PR a freshness check it can call as its own CI step.

- [ ] **Step 1: Write the failing test**

Create `Scripts/test-check-engine-fresh.sh`. Every assertion runs against a fake repo tree in a temp dir — no real build, and nothing under `Vendor/` is touched.

```bash
#!/bin/bash
# Tests for Scripts/check-engine-fresh.sh.
#
# Fully HERMETIC: builds a fake repo in a temp dir and runs the guard there.
# Nothing here touches the real Vendor/ tree.
#
# The guard deliberately lives in its own script rather than inline in
# archive.sh precisely so this test can exist: archive.sh continues past the
# guard into xcodegen, a full Release build, `rm -rf Vendor/archive/export`,
# and a signed export. Exercising the guard's SUCCESS path through archive.sh
# would either run that whole build or require stubbing xcodebuild -- which
# cannot work, because archive.sh re-invokes it as `PATH="/usr/bin:$PATH"
# xcodebuild` and would find the real binary ahead of any stub, and because
# the `rm -rf` would destroy real local artifacts on the way past.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# Fake repo mirroring the real layout the guard and fingerprint walk.
make_fixture() { # dest
    mkdir -p "$1/Scripts" "$1/Engine/woof/src" "$1/Vendor/out"
    cp "$ROOT/Scripts/engine-fingerprint.sh"  "$1/Scripts/"
    cp "$ROOT/Scripts/check-engine-fresh.sh"  "$1/Scripts/"
    echo 'stub build-engine' > "$1/Scripts/build-engine.sh"
    echo 'stub build-deps'   > "$1/Scripts/build-deps.sh"
    echo 'int main(void){}'  > "$1/Engine/woof/src/d_main.c"
    # A directory is all the guard checks for -- it never opens the framework.
    mkdir -p "$1/Vendor/out/WoofEngine.xcframework"
}
stamp()  { "$1/Scripts/engine-fingerprint.sh" > "$1/Vendor/out/WoofEngine.xcframework.fingerprint"; }
check()  { "$1/Scripts/check-engine-fresh.sh"; }

# 1. Framework missing entirely -> refuse, and say how to build it.
make_fixture "$TMP/a"; stamp "$TMP/a"; rm -rf "$TMP/a/Vendor/out/WoofEngine.xcframework"
if check "$TMP/a" >"$TMP/out" 2>&1; then fail "passed with no framework"; fi
grep -q "build the engine first" "$TMP/out" || fail "missing-framework error lacks build guidance"
pass "fails closed when the framework is missing"

# 2. Framework present but never stamped -> refuse.
make_fixture "$TMP/b"
if check "$TMP/b" >"$TMP/out" 2>&1; then fail "passed with no stamp file"; fi
grep -q "rebuild before archiving" "$TMP/out" || fail "missing-stamp error lacks rebuild guidance"
pass "fails closed when the stamp is missing"

# 3. Stamp that does not match current content -> refuse.
make_fixture "$TMP/c"; stamp "$TMP/c"
echo 'edited after the build' >> "$TMP/c/Engine/woof/src/d_main.c"
if check "$TMP/c" >"$TMP/out" 2>&1; then fail "passed with a stale stamp"; fi
grep -q "rebuild before archiving" "$TMP/out" || fail "mismatch error lacks rebuild guidance"
pass "fails closed when sources changed since the build"

# 4. A build-script edit also invalidates, not just engine sources.
make_fixture "$TMP/d"; stamp "$TMP/d"
echo 'x' >> "$TMP/d/Scripts/build-deps.sh"
if check "$TMP/d" >"$TMP/out" 2>&1; then fail "passed after build-deps.sh changed"; fi
pass "fails closed when a build script changed"

# 5. Matching stamp -> pass, silently.
make_fixture "$TMP/e"; stamp "$TMP/e"
check "$TMP/e" >"$TMP/out" 2>&1 || fail "refused a valid stamp: $(cat "$TMP/out")"
[ ! -s "$TMP/out" ] || fail "should be silent on success, printed: $(cat "$TMP/out")"
pass "passes silently when the stamp matches"

# 6. THE REGRESSION THIS REPLACES. Content is byte-identical, but every
#    engine source now has an mtime NEWER than the framework -- exactly what
#    a fresh worktree checkout or a restored CI cache produces. The old
#    `find -newer` guard fired here and demanded a ~25-minute rebuild that
#    would have changed nothing.
make_fixture "$TMP/f"; stamp "$TMP/f"
touch "$TMP/f/Engine/woof/src/d_main.c" "$TMP/f/Scripts/build-deps.sh"
check "$TMP/f" >"$TMP/out" 2>&1 || fail "tripped on newer mtimes despite identical content"
pass "ignores mtimes when content is unchanged (fresh-worktree regression)"

# 7. Unreadable sources -> refuse, rather than passing on a failed compare.
make_fixture "$TMP/g"; stamp "$TMP/g"; rm -rf "$TMP/g/Engine/woof"
if check "$TMP/g" >"$TMP/out" 2>&1; then fail "passed when sources could not be read"; fi
pass "fails closed when the fingerprint cannot be computed"

echo "All check-engine-fresh tests passed."
```

Make it executable:

```bash
chmod +x Scripts/test-check-engine-fresh.sh
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `Scripts/test-check-engine-fresh.sh`

Expected: FAIL. `Scripts/check-engine-fresh.sh` does not exist yet, so the `cp` in `make_fixture` fails and the script aborts non-zero.

- [ ] **Step 3: Write the stamp in `build-engine.sh`**

In `Scripts/build-engine.sh`, replace the final `echo` line:

```bash
echo "Built $OUT/WoofEngine.xcframework and staged App/Resources/woof.pk3"
```

with:

```bash
# Stamp the framework with a fingerprint of the sources that produced it.
# Scripts/archive.sh compares against this to refuse shipping a stale
# engine, and CI uses the same value as its cache key. Written LAST, only
# after -create-xcframework succeeded, so a failed build never leaves a
# stamp claiming the framework is current.
"$ROOT/Scripts/engine-fingerprint.sh" > "$OUT/WoofEngine.xcframework.fingerprint"
echo "Built $OUT/WoofEngine.xcframework and staged App/Resources/woof.pk3"
```

- [ ] **Step 4: Write `Scripts/check-engine-fresh.sh`**

Create `Scripts/check-engine-fresh.sh`:

```bash
#!/bin/bash
# Refuses to proceed when Vendor/out/WoofEngine.xcframework does not match
# the sources that should have produced it. Exits 0 and prints nothing when
# the framework is current; exits 1 with rebuild guidance otherwise.
#
# The heavy engine build (SDL/OpenAL + Woof) is deliberately NOT part of
# archiving, but a framework that does not match its sources silently ships
# stale bits -- that is how a missing SDL_CAMERA=OFF (ITMS-90683) or an
# unbuilt engine fix reaches App Review. Fail loudly instead; rebuilding is a
# separate, explicit step.
#
# Compares CONTENT, not mtimes. The previous `find -newer` guard fired
# whenever sources merely had newer timestamps than the framework -- which is
# what a fresh worktree checkout or a restored CI cache always produces, even
# when the bytes are identical -- and demanded a ~25-minute rebuild that
# changed nothing. Content comparison also widens coverage from
# Engine/woof/src to all of Engine/woof, so edits to the vendored
# CMakeLists.txt or third-party/ now count; they were invisible before.
#
# Fails CLOSED: an unreadable source tree, a failure to compute the
# fingerprint, or a missing stamp all refuse, rather than letting bits of
# unknown provenance through.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FW="$ROOT/Vendor/out/WoofEngine.xcframework"
STAMP="$FW.fingerprint"

if [ ! -d "$FW" ]; then
  echo "error: $FW is missing." >&2
  echo "       build the engine first: mise run bootstrap" >&2
  echo "       (or: Scripts/build-deps.sh && Scripts/build-engine.sh)" >&2
  exit 1
fi
if ! CURRENT_FP="$("$ROOT/Scripts/engine-fingerprint.sh")"; then
  echo "error: could not fingerprint the engine sources (a source or build" >&2
  echo "       script is missing or unreadable) — refusing to continue." >&2
  exit 1
fi
if [ ! -f "$STAMP" ]; then
  echo "error: $STAMP is missing — the framework predates this guard, or was" >&2
  echo "       assembled by hand." >&2
  echo "       rebuild before archiving: Scripts/build-deps.sh && Scripts/build-engine.sh" >&2
  exit 1
fi
if [ "$CURRENT_FP" != "$(cat "$STAMP")" ]; then
  echo "error: engine sources/scripts changed since WoofEngine.xcframework was built." >&2
  echo "       rebuild before archiving: Scripts/build-deps.sh && Scripts/build-engine.sh" >&2
  echo "       (build-deps.sh is only needed when SDL/OpenAL config changed)" >&2
  exit 1
fi
```

Make it executable:

```bash
chmod +x Scripts/check-engine-fresh.sh
```

- [ ] **Step 5: Call the guard from `archive.sh`**

In `Scripts/archive.sh`, replace lines 8-38 — the whole guard block, from the comment beginning `# Guard against archiving a STALE engine.` through the `fi` that closes `if [ -n "$STALE" ]` — with:

```bash
# Refuse to archive a framework that does not match its sources. Extracted
# into its own script so it is testable without running a build, and so the
# TestFlight workflow can call it as a standalone step.
"$ROOT/Scripts/check-engine-fresh.sh"
```

`set -euo pipefail` at the top of `archive.sh` already aborts on a non-zero exit, so no explicit `||` handling is needed. The `FW=` assignment on line 13 goes away with the block; confirm nothing later in `archive.sh` still references `$FW` (as of this plan, nothing does — `ARCHIVE=` is a separate path built further down).

- [ ] **Step 6: Run the test to verify it passes**

Run: `Scripts/test-check-engine-fresh.sh`

Expected: PASS — seven `ok - ...` lines, then `All check-engine-fresh tests passed.`

- [ ] **Step 7: Verify the fingerprint tests still pass**

Run: `Scripts/test-engine-fingerprint.sh`

Expected: PASS. Step 3 edited `build-engine.sh`, which the fingerprint covers — confirm the helper is unaffected by its own inputs changing.

- [ ] **Step 8: Verify `archive.sh` still parses, without running a build**

Run: `bash -n Scripts/archive.sh`

Expected: no output, exit 0. This is a syntax check only. Do **not** run `Scripts/archive.sh` itself to test the edit — it continues into a full signed Release build and deletes `Vendor/archive/export/`.

- [ ] **Step 9: Stamp the existing local framework**

```bash
Scripts/engine-fingerprint.sh > Vendor/out/WoofEngine.xcframework.fingerprint
Scripts/check-engine-fresh.sh && echo "guard passes against the local build"
```

The local framework was built before the stamp existed, so without this the next `Scripts/archive.sh` correctly refuses with "stamp is missing". Editing `build-engine.sh` in Step 3 also changed the fingerprint, so stamp after that edit, not before.

Expected: `guard passes against the local build`. If the guard still refuses, the fingerprint is not stable — stop and report rather than re-stamping in a loop.

- [ ] **Step 10: Commit**

```bash
git add Scripts/build-engine.sh Scripts/check-engine-fresh.sh \
        Scripts/test-check-engine-fresh.sh Scripts/archive.sh
git commit -m "fix(build): guard archives on engine content, not mtimes

build-engine.sh now stamps the framework with its source fingerprint, and
the freshness check compares against that stamp. Fixes the false positive
where a fresh worktree or a restored cache checks out byte-identical sources
with newer mtimes and demands a ~25-minute rebuild that changes nothing.
Also widens coverage from Engine/woof/src to all of Engine/woof.

The check lives in its own script so it is testable without running a build
and so CI can call it standalone."
```

---

### Task 3: Composite setup action and `ci.yml`

Bundled: the composite action produces nothing observable on its own, and `ci.yml` is its first consumer. This task ends with a green run on GitHub, which is the only way to verify either.

**Files:**
- Create: `.github/actions/setup-waddle-build/action.yml`
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `Scripts/engine-fingerprint.sh` (Task 1) for the cache key; `Vendor/out/WoofEngine.xcframework.fingerprint` (Task 2) as a cached path.
- Produces: the composite action `./.github/actions/setup-waddle-build`, taking one required input `xcode-version` (string, e.g. `"26.2"`). After it runs, the working directory has a generated `App/WADdle.xcodeproj`, a built `Vendor/out/WoofEngine.xcframework`, staged `App/Resources/GameData/` and `App/Resources/woof.pk3`, and the pinned Xcode selected. Task 4 and the follow-up TestFlight PR both call it exactly this way.

- [ ] **Step 1: Write the composite action**

Create `.github/actions/setup-waddle-build/action.yml`:

```yaml
name: Set up WADdle build
description: >-
  Pins the toolchain, restores or builds the Woof! engine framework and its
  SDL3/OpenAL dependencies, stages game data, and generates the Xcode project.

inputs:
  xcode-version:
    description: Xcode version to select; must match a version on the runner image.
    required: true

runs:
  using: composite
  steps:
    - name: Select Xcode ${{ inputs.xcode-version }}
      shell: bash
      run: |
        APP="/Applications/Xcode_${{ inputs.xcode-version }}.app"
        if [ ! -d "$APP" ]; then
          echo "::error::$APP not found on this runner image."
          echo "Installed Xcode versions:"
          ls -d /Applications/Xcode*.app
          exit 1
        fi
        sudo xcode-select -s "$APP"
        xcodebuild -version

    # cmake / ninja / xcodegen at the versions mise.toml pins. The image
    # ships cmake and ninja at other versions and no xcodegen at all, so
    # this is what keeps CI's toolchain identical to a developer's.
    - name: Install pinned CLI tools
      uses: jdx/mise-action@v2

    - name: Compute engine fingerprint
      id: fingerprint
      shell: bash
      run: echo "value=$(Scripts/engine-fingerprint.sh)" >> "$GITHUB_OUTPUT"

    # The engine cache is restored FIRST and the deps cache is nested under
    # a miss, because build-engine.sh merges libSDL3.a and libopenal.a INTO
    # libWoofEngine.a and project.yml depends only on the xcframework. Once
    # the framework exists, Vendor/out/{iphoneos,iphonesimulator} is dead
    # weight -- so an engine hit skips the deps restore entirely.
    #
    # No restore-keys on either cache, deliberately: a near-miss would hand
    # back a framework that does not match its inputs, which is the exact
    # failure this design exists to prevent. A miss must mean a rebuild.
    - name: Restore engine framework
      id: engine-cache
      uses: actions/cache@v4
      with:
        path: |
          Vendor/out/WoofEngine.xcframework
          Vendor/out/WoofEngine.xcframework.fingerprint
          App/Resources/woof.pk3
        key: engine-xcode${{ inputs.xcode-version }}-${{ steps.fingerprint.outputs.value }}

    - name: Restore SDL3 + OpenAL Soft
      id: deps-cache
      if: steps.engine-cache.outputs.cache-hit != 'true'
      uses: actions/cache@v4
      with:
        path: |
          Vendor/out/iphoneos
          Vendor/out/iphonesimulator
        key: deps-xcode${{ inputs.xcode-version }}-${{ hashFiles('Scripts/build-deps.sh') }}

    - name: Build SDL3 + OpenAL Soft
      if: steps.engine-cache.outputs.cache-hit != 'true' && steps.deps-cache.outputs.cache-hit != 'true'
      shell: bash
      run: Scripts/build-deps.sh

    - name: Build engine framework
      if: steps.engine-cache.outputs.cache-hit != 'true'
      shell: bash
      run: Scripts/build-engine.sh

    # 24 MB, checksum-verified. Left uncached so every run re-exercises the
    # checksum against the pinned upstream release.
    - name: Fetch Freedoom
      shell: bash
      run: Scripts/fetch-freedoom.sh

    # Must run BEFORE xcodegen: App/Sources/Generated/ is gitignored, and
    # xcodegen's source scan is a static snapshot taken at generate time --
    # if the file is absent then, it never enters Compile Sources at all and
    # every BuildInfo reference fails to compile. See the script's header.
    - name: Seed build info
      shell: bash
      run: Scripts/generate-build-info.sh

    - name: Generate Xcode project
      shell: bash
      working-directory: App
      run: xcodegen generate
```

- [ ] **Step 2: Write `ci.yml`**

Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  pull_request:
  push:
    branches: [main]

# Supersede in-flight runs when a PR is pushed again.
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

env:
  # Toolchain pins live here so a bump is a one-line edit. XCODE_VERSION also
  # feeds both cache keys inside the setup action.
  XCODE_VERSION: "26.2"
  SIMULATOR_OS: "26.2"
  SIMULATOR_DEVICE: "iPhone 17 Pro"

jobs:
  build-and-test:
    name: Build + unit tests
    runs-on: macos-26
    # Generous: a cold run builds SDL3, OpenAL Soft and Woof for two
    # platforms (~40-60 min). Warm runs land in 5-10.
    timeout-minutes: 90
    steps:
      - uses: actions/checkout@v4

      # Cheap (~0.1s each) and they guard the value both cache keys depend
      # on, plus the check that stops a stale engine from being shipped.
      - name: Verify the build-script helpers
        run: |
          Scripts/test-engine-fingerprint.sh
          Scripts/test-check-engine-fresh.sh

      - uses: ./.github/actions/setup-waddle-build
        with:
          xcode-version: ${{ env.XCODE_VERSION }}

      # -only-testing:WADdleTests is REQUIRED, not a tuning choice: the
      # WADdle scheme's test action also includes WADdleUITests, which boot
      # the real engine and belong to the manually-dispatched ui-tests
      # workflow.
      - name: Run unit tests
        env:
          DESTINATION: platform=iOS Simulator,name=${{ env.SIMULATOR_DEVICE }},OS=${{ env.SIMULATOR_OS }}
        run: |
          xcodebuild -project App/WADdle.xcodeproj -scheme WADdle \
            -destination "$DESTINATION" \
            -only-testing:WADdleTests \
            -resultBundlePath TestResults.xcresult \
            test

      - name: Upload test results
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: ci-test-results
          path: TestResults.xcresult
          retention-days: 7
```

- [ ] **Step 3: Lint both files before pushing**

```bash
brew install actionlint
actionlint
```

Expected: no output (actionlint exits 0 and prints nothing when clean). Fix anything it reports. This catches expression-syntax and context-availability errors locally instead of burning a ~40-minute cold CI run on a typo.

- [ ] **Step 4: Commit and push**

```bash
git add .github/actions/setup-waddle-build/action.yml .github/workflows/ci.yml
git commit -m "ci: build and unit-test every PR on macos-26

Pins Xcode 26.2 and takes cmake/ninja/xcodegen from mise so CI matches a
developer machine. Caches the engine framework keyed on its content
fingerprint, with the SDL/OpenAL deps cache nested under an engine miss --
the framework already contains those libs, so a hit skips them entirely.

Shared setup lives in a composite action so ui-tests and the follow-up
TestFlight workflow reuse one definition of the cache keys."
git push -u origin tylervick/CI-build-scripts
```

- [ ] **Step 5: Open the PR**

```bash
gh pr create --title "CI: build + unit tests, UI tests on dispatch" \
  --body "$(cat <<'EOF'
Adds GitHub Actions to a repo that had none.

- `ci.yml` — build + unit tests on every PR and push to main
- `ui-tests.yml` — the UI suite on manual dispatch, minus `RealWADTests`
- Shared setup in a composite action, so the follow-up TestFlight PR is small
- `archive.sh`'s stale-engine guard now compares engine **content** rather
  than mtimes, fixing the fresh-worktree false positive

Design: `docs/superpowers/specs/2026-07-28-ci-build-scripts-design.md`

TestFlight upload is deliberately a follow-up PR.
EOF
)"
```

- [ ] **Step 6: Watch the first run and drive it green**

```bash
gh run watch
```

The first run is **cold** — Actions caches are branch-scoped and `main` has none to inherit, so expect 40-60 minutes while SDL3, OpenAL Soft and Woof build for both platforms.

If it fails, read the log for the failing step and fix forward. Likely failure points, in rough order of probability:

- **`/Applications/Xcode_26.2.app` not found.** The step prints the installed versions; pick the closest 26.2+ and update `XCODE_VERSION`.
- **`OS=26.2` simulator runtime unavailable.** Run `xcrun simctl list runtimes` in a debug step and set `SIMULATOR_OS` to one that exists.
- **`build-deps.sh` or `build-engine.sh` failing on the runner.** These have only ever run on one developer machine; a missing system dependency would surface here for the first time.

Do not add `continue-on-error` to work around a failure. A red CI that lies is worse than none.

- [ ] **Step 7: Confirm the cache actually works**

Push an empty commit and watch the second run:

```bash
git commit --allow-empty -m "ci: verify warm cache path"
git push
gh run watch
```

Expected: the "Restore engine framework" step reports a cache hit, "Build SDL3 + OpenAL Soft" and "Build engine framework" both show as skipped, and the run finishes in roughly 5-10 minutes. If the engine cache misses on an unchanged tree, the fingerprint is not stable across runs — stop and diagnose before continuing, because that breaks the cache and the archive guard alike.

Then drop the empty commit:

```bash
git reset --hard HEAD~1 && git push --force-with-lease
```

---

### Task 4: `ui-tests.yml`

**Files:**
- Create: `.github/workflows/ui-tests.yml`

**Interfaces:**
- Consumes: `./.github/actions/setup-waddle-build` from Task 3, with input `xcode-version`.
- Produces: nothing other tasks depend on.

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/ui-tests.yml`:

```yaml
name: UI Tests

# Manual dispatch only, by choice. These tests boot a real Metal/OpenGL
# engine session in the simulator, so they are the slow, flake-prone half of
# the suite and are kept off the PR path. The trade-off is that nothing runs
# them automatically -- add a `schedule:` block here if they start to rot.
on:
  workflow_dispatch:
    inputs:
      device:
        description: Simulator device name
        required: false
        default: "iPhone 17 Pro"
      only_testing:
        description: >-
          Optional -only-testing filter, e.g. WADdleUITests/EngineSmokeTests.
          Leave blank to run the whole suite except RealWADTests.
        required: false
        default: ""

env:
  XCODE_VERSION: "26.2"
  SIMULATOR_OS: "26.2"

jobs:
  ui-tests:
    name: UI tests
    runs-on: macos-26
    timeout-minutes: 90
    steps:
      - uses: actions/checkout@v4

      - uses: ./.github/actions/setup-waddle-build
        with:
          xcode-version: ${{ env.XCODE_VERSION }}

      # Inputs go through env rather than direct ${{ }} interpolation into
      # the script body, so a value containing shell metacharacters cannot
      # break out of the command.
      - name: Run UI tests
        env:
          DESTINATION: platform=iOS Simulator,name=${{ inputs.device }},OS=${{ env.SIMULATOR_OS }}
          ONLY_TESTING: ${{ inputs.only_testing }}
        run: |
          ARGS=(
            -project App/WADdle.xcodeproj
            -scheme WADdle
            -destination "$DESTINATION"
            -resultBundlePath UITestResults.xcresult
          )
          if [ -n "$ONLY_TESTING" ]; then
            ARGS+=(-only-testing:"$ONLY_TESTING")
          else
            # RealWADTests needs Scythe / Sunlust / Eviternity II from
            # ~/Downloads/doom-test-wads -- non-redistributable and ~300 MB,
            # so it can never run here. Excluding it is a hard requirement.
            ARGS+=(-only-testing:WADdleUITests)
            ARGS+=(-skip-testing:WADdleUITests/RealWADTests)
          fi
          xcodebuild "${ARGS[@]}" test

      # Always, not just on failure: a passing UI run is also the artifact
      # you want when checking whether a flake reproduced.
      - name: Upload test results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: ui-test-results
          path: UITestResults.xcresult
          retention-days: 7
```

- [ ] **Step 2: Lint**

```bash
actionlint
```

Expected: no output.

- [ ] **Step 3: Commit and push**

```bash
git add .github/workflows/ui-tests.yml
git commit -m "ci: add manually-dispatched UI test workflow

Runs the UI suite minus RealWADTests, which needs non-redistributable WADs.
Dispatch-only: these boot a real engine session in the simulator and are
kept off the PR path. Device and test filter are dispatch inputs."
git push
```

- [ ] **Step 4: Dispatch a narrow run first**

```bash
gh workflow run ui-tests.yml --ref tylervick/CI-build-scripts \
  -f only_testing=WADdleUITests/EngineSmokeTests
gh run watch
```

Start with the single smoke class rather than the whole suite. It is the fastest signal on the one genuinely unverified question in this plan — whether a hosted runner's simulator can boot the engine at all. Its cache is already warm from Task 3, so this should take only a few minutes.

If the engine cannot boot on a hosted runner, **stop and report** rather than papering over it. That finding changes what `ui-tests.yml` is worth, and it should be recorded in the PR rather than hidden behind a retry.

- [ ] **Step 5: Dispatch the full suite**

```bash
gh workflow run ui-tests.yml --ref tylervick/CI-build-scripts
gh run watch
```

Expected: every UI class except `RealWADTests` runs. Confirm in the log that `RealWADTests` was skipped and did not attempt to run.

Record the wall-clock time and any flaky classes in a PR comment — that is the data behind any later decision to add a schedule.

- [ ] **Step 6: Update the PR description with results**

```bash
gh pr comment --body "Verified on CI:
- \`ci.yml\` cold: <N> min; warm (cache hit): <N> min
- \`ui-tests.yml\` full suite: <N> min, <N> tests, flakes: <none|list>
- Engine boots on a hosted runner: <yes|no>"
```

Fill in the real numbers. The engine-boot line is the one that was unknowable before this PR.

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| `Scripts/engine-fingerprint.sh` — path/order-independent, working-tree based | Task 1 |
| Three consumers share one mechanism | Task 1 (definition), Task 2 (stamp + guard), Task 3 (cache key) |
| `archive.sh` guard replacement, fails closed | Task 2 |
| Composite action shares the preamble | Task 3 |
| Two caches, no `restore-keys`, Xcode in key but not fingerprint | Task 3 |
| Freedoom uncached | Task 3 |
| `ci.yml` triggers, concurrency, `-only-testing:WADdleTests`, xcresult artifact | Task 3 |
| `ui-tests.yml` dispatch-only, `device` + `only_testing` inputs, `RealWADTests` excluded | Task 4 |
| Verification criteria (7 listed in spec) | Tasks 1 and 2 automate all 7 |
| Out of scope: `testflight.yml`, cold-cache schedule, README badge | Not present in any task |

**Placeholder scan:** No TBD/TODO. Every code step carries complete content. The only intentional blanks are the `<N>` placeholders in Task 4 Step 6, which are runtime measurements that cannot exist before the run.

**Type consistency:** `Scripts/engine-fingerprint.sh` takes no arguments and prints one hash on stdout in Tasks 1, 2, and 3. The stamp path is `Vendor/out/WoofEngine.xcframework.fingerprint` in Task 2 (written by `build-engine.sh`), Task 2 (read by `check-engine-fresh.sh`), and Task 3 (cached) — identical in all three. The composite action's single input is `xcode-version` where it is defined (Task 3) and where it is called (Tasks 3 and 4).

**One gap found and closed during review:** the spec's verification list is written as manual checks. Tasks 1 and 2 automate all of them into `Scripts/test-engine-fingerprint.sh` and `Scripts/test-check-engine-fresh.sh`, and `ci.yml` runs both on every PR. The fingerprint is load-bearing for both the ship guard and the cache, so it should not rest on remembering to check it by hand.

**Defect found in this plan during pre-flight and corrected:** Task 2 originally tested the guard by running the real `archive.sh` under stubbed `xcodegen`/`xcodebuild`. That could not have worked and would have caused damage: `archive.sh` runs `rm -rf "$ROOT/Vendor/archive/export"` (destroying real local artifacts) and then re-invokes `PATH="/usr/bin:$PATH" xcodebuild`, which places the real binary ahead of any stub. Extracting the guard into `Scripts/check-engine-fresh.sh` makes it hermetically testable and gives the follow-up TestFlight PR a standalone check to call.
