# Waddle Name Consistency Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `Waddle` the canonical spelling of the app's name everywhere text is typed, confine the `WADdle` wordmark to `Design/`, and rename the local checkout and Orca project to match — without losing worktree history, automation history, or Claude session history.

**Architecture:** Phase 1 is a single pull request that renames the Xcode target/scheme/module, the product strings, and the living docs, guarded by a new `Scripts/check-name-consistency.sh` written *first* so the rename has a failing check to satisfy. Phase 2 is an operational migration of three path-keyed systems (filesystem, Orca's `orca-data.json`, Claude's `~/.claude/projects/`) performed with Orca quit and every mutation backed up. Phase 3 is a single App Store Connect API call.

**Tech Stack:** bash guard scripts, XcodeGen (`App/project.yml` → generated `.xcodeproj`), mise tasks, GitHub Actions, Swift/SwiftUI, SQLite-free JSON registries, App Store Connect REST API.

**Spec:** `docs/superpowers/specs/2026-08-16-waddle-name-consistency-design.md`

## Global Constraints

- The canonical name is **`Waddle`**. `WADdle` is a wordmark, never typed as text in new work.
- **Do not touch** the lowercase family — `com.tylervick.waddle`, the UTIs `com.tylervick.waddle.*`, `tylervick/waddle`, `Design/waddle-mark.png`, `.waddleScrollSurface()`. Already correct.
- **Do not touch** `WADDLE_*` environment variables. SCREAMING_SNAKE reads identically for either casing.
- **Do not touch** `docs/superpowers/plans/` or `docs/superpowers/specs/` — dated records, frozen by spec §2.4.
- **Do not touch** `App/ExportOptions-ci.plist:32` (`WADdle App Store CI`) — the name of a provisioning profile registered in Apple's developer portal. Renaming it here without renaming it there breaks CI signing with an opaque error.
- Conventional commits, matching existing history (`fix(ui):`, `docs(app-store):`).
- Work lands through pull requests, never directly on `main`.
- Never edit or delete a test to make it pass.
- Branch is already created: `tylervick/waddle-name-consistency`.

---

## File Structure

**Created:**
- `Scripts/check-name-consistency.sh` — the guard. Scans tracked files for the wordmark spelling outside its stated exemptions. One responsibility: enforce §1 of the spec.
- `Scripts/test-check-name-consistency.sh` — hermetic tests for the guard, using throwaway git repos.
- `docs/learnings/the-name-is-waddle.md` — records the rule and points at the check.

**Renamed:**
- `App/Sources/WADdleApp.swift` → `App/Sources/WaddleApp.swift`

**Modified (clusters, per spec §2):**
- Xcode identity: `App/project.yml`
- Build invocations: `mise.toml`, `.github/workflows/{ci,ui-tests,testflight,cold-build}.yml`, `.github/actions/setup-waddle-build/action.yml`, `Scripts/{archive,capture-screenshots,check-red-green,build-deps,generate-build-info,provision-test-wads,upload,test-build-deps,test-check-red-green,test-fetch-testflight-feedback}.sh`, `Scripts/loop-prompt.md`, `Scripts/extract-mark.py`, `.claude/skills/*/SKILL.md`
- Module imports: all 40 files under `App/Tests/` and `App/UITests/` carrying `@testable import WADdle`
- Product strings: `App/Sources/Diagnostics/DiagnosticsExporter.swift`, `App/Sources/UI/{AboutView,ShelfView}.swift`, `App/Sources/Library/{ImportService,LibraryService}.swift`, `App/Tests/DiagnosticsExporterTests.swift`, `PRIVACY.md`, `App/Resources/Licenses/NOTICES.md`
- Engine strings: `Engine/woof/src/woof_ios.c:235`, `Engine/woof/src/i_input.c:1034`
- Living docs: `CLAUDE.md`, `README.md`, `Design/README.md`, `Engine/WOOF_UPSTREAM.md`, `docs/learnings/*.md`, `docs/learnings/INDEX.md`, `docs/app-store/{metadata,submission-checklist}.md`, `docs/manual-testing.md`
- CI wiring: `.github/workflows/ci.yml` "Verify the build-script helpers" step

---

# Phase 1 — The repo rename (one pull request)

## Task 1: The guard, written before the rename it enforces

The guard comes first so the rename has a failing check to satisfy. It is deliberately **not** wired into CI in this task — CI would go red against a tree that has not been renamed yet. Task 6 wires it.

**Files:**
- Create: `Scripts/check-name-consistency.sh`
- Test: `Scripts/test-check-name-consistency.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `Scripts/check-name-consistency.sh`, exit 0 when clean and exit 1 listing every offending path otherwise. Task 6 wires it into `.github/workflows/ci.yml`. Its exemption list is referenced by `docs/learnings/the-name-is-waddle.md` in Task 6.

- [ ] **Step 1: Write the failing test**

Create `Scripts/test-check-name-consistency.sh`:

```bash
#!/bin/bash
# Tests for Scripts/check-name-consistency.sh.
#
# Fully HERMETIC: builds throwaway git repos in a temp dir and runs the guard
# there. Nothing here reads the real working tree, so the suite gives the same
# verdict before and after the rename it exists to enforce.
#
# GIT_CONFIG_GLOBAL/SYSTEM are cut off rather than patched per-command: this
# machine sets commit.gpgsign and tag.gpgSign through the 1Password agent, and
# an inherited signing config makes fixture commits hang or fail with errors
# that name neither signing nor config. See
# docs/learnings/git-fixtures-inherit-signing-config.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# A fixture repo whose only wordmark spellings sit in exempt paths.
make_fixture() { # dest
    mkdir -p "$1/Scripts" "$1/Design" "$1/App/Sources" \
             "$1/docs/superpowers/specs" "$1/docs/superpowers/plans" \
             "$1/docs/learnings"
    cp "$ROOT/Scripts/check-name-consistency.sh" "$1/Scripts/"
    printf 'Waddle is the name.\n'                  > "$1/README.md"
    printf 'wordmark studies: WADdle\n'             > "$1/Design/README.md"
    printf 'ran -scheme WADdle back then\n'         > "$1/docs/superpowers/specs/2026-01-01-old-design.md"
    printf 'and -only-testing:WADdleTests\n'        > "$1/docs/superpowers/plans/2026-01-01-old-plan.md"
    printf 'forbids the WADdle spelling\n'          > "$1/docs/learnings/the-name-is-waddle.md"
    printf '<string>WADdle App Store CI</string>\n' > "$1/App/ExportOptions-ci.plist"
    printf 'struct WaddleApp {}\n'                  > "$1/App/Sources/WaddleApp.swift"
    ( cd "$1" && git init -q . && git add -A && git commit -qm base )
}
check() { "$1/Scripts/check-name-consistency.sh"; }

# 1. Only exempt paths carry the spelling -> pass, silently.
make_fixture "$TMP/a"
check "$TMP/a" >"$TMP/out" 2>&1 || fail "refused a clean tree: $(cat "$TMP/out")"
[ ! -s "$TMP/out" ] || fail "should be silent on success, printed: $(cat "$TMP/out")"
pass "passes a clean tree silently"

# 2. A tracked source file carrying the spelling -> refuse, and name the file.
make_fixture "$TMP/b"
printf 'let name = "WADdle"\n' > "$TMP/b/App/Sources/Thing.swift"
( cd "$TMP/b" && git add -A && git commit -qm add )
if check "$TMP/b" >"$TMP/out" 2>&1; then fail "passed a tree spelling the name WADdle"; fi
grep -q "App/Sources/Thing.swift" "$TMP/out" || fail "error did not name the offending file"
pass "fails and names a tracked file carrying the wordmark spelling"

# 3. Design/ is exempt by rule -- the wordmark lives there.
make_fixture "$TMP/c"
printf 'WADdle WADdle WADdle\n' > "$TMP/c/Design/wordmark-notes.md"
( cd "$TMP/c" && git add -A && git commit -qm add )
check "$TMP/c" >"$TMP/out" 2>&1 || fail "refused Design/: $(cat "$TMP/out")"
pass "exempts Design/"

# 4. Dated records under docs/superpowers/ are exempt by rule.
make_fixture "$TMP/d"
printf 'xcodebuild -scheme WADdle\n' > "$TMP/d/docs/superpowers/specs/2026-02-02-another.md"
( cd "$TMP/d" && git add -A && git commit -qm add )
check "$TMP/d" >"$TMP/out" 2>&1 || fail "refused a dated spec: $(cat "$TMP/out")"
pass "exempts dated plans and specs"

# 5. Untracked files are not ours to spell.
make_fixture "$TMP/e"
printf 'WADdle\n' > "$TMP/e/App/Sources/Untracked.swift"
check "$TMP/e" >"$TMP/out" 2>&1 || fail "refused an untracked file: $(cat "$TMP/out")"
pass "ignores untracked files"

# 6. Every offender is reported in one run, not just the first.
make_fixture "$TMP/f"
printf 'WADdle\n' > "$TMP/f/App/Sources/One.swift"
printf 'WADdle\n' > "$TMP/f/App/Sources/Two.swift"
( cd "$TMP/f" && git add -A && git commit -qm add )
if check "$TMP/f" >"$TMP/out" 2>&1; then fail "passed a tree with two offenders"; fi
grep -q "App/Sources/One.swift" "$TMP/out" || fail "did not report the first offender"
grep -q "App/Sources/Two.swift" "$TMP/out" || fail "did not report the second offender"
pass "reports every offender in one run"

echo "all check-name-consistency tests passed"
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
chmod +x Scripts/test-check-name-consistency.sh
Scripts/test-check-name-consistency.sh
```

Expected: FAIL — `cp: Scripts/check-name-consistency.sh: No such file or directory`. The guard does not exist yet.

- [ ] **Step 3: Write the guard**

Create `Scripts/check-name-consistency.sh`:

```bash
#!/bin/bash
# Refuses tracked files that spell the app's name "WADdle".
#
# The name is "Waddle". "WADdle" is a WORDMARK -- a visual treatment of that
# name, not a spelling of it. That distinction decays silently, because a
# stylized spelling reads as deliberate wherever it lands, so nobody deletes
# it. The previous rename (BoomBox -> WADdle) left residue that survived for
# weeks; this check exists so the next one does not.
#
# Scans TRACKED files only. Build outputs, vendored archives and generated
# projects are not ours to spell.
#
# Reports EVERY offending file in one run rather than stopping at the first,
# so a fix-up is one round trip.
#
# The exemptions below are RULES, each with a reason. A new entry here is a
# signal that the rule is being eroded -- argue it in review, do not add it
# quietly. See docs/learnings/the-name-is-waddle.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Path prefixes that may carry the wordmark spelling, and why.
EXEMPT=(
    'Design/'                                 # the wordmark itself lives here
    'docs/superpowers/plans/'                 # dated records of completed work
    'docs/superpowers/specs/'                 # dated records of completed work
    'docs/learnings/the-name-is-waddle.md'    # states the rule, must name the spelling
    'Scripts/check-name-consistency.sh'       # this guard
    'Scripts/test-check-name-consistency.sh'  # and its tests
    'App/ExportOptions-ci.plist'              # a provisioning-profile name registered
                                              # in Apple's portal, not product text;
                                              # rename it there first, at next
                                              # profile regeneration
)

is_exempt() { # path
    local path="$1" prefix
    for prefix in "${EXEMPT[@]}"; do
        case "$path" in "$prefix"*) return 0 ;; esac
    done
    return 1
}

offenders=()
while IFS= read -r path; do
    is_exempt "$path" || offenders+=("$path")
done < <(git ls-files -z | xargs -0 grep -Il -- 'WADdle' 2>/dev/null || true)

if [ "${#offenders[@]}" -gt 0 ]; then
    echo "error: the app's name is \"Waddle\". \"WADdle\" is the wordmark and" >&2
    echo "       belongs only in Design/. These tracked files spell it \"WADdle\":" >&2
    printf '         %s\n' "${offenders[@]}" >&2
    echo "       If one of these genuinely needs the wordmark, say why in review" >&2
    echo "       before adding it to EXEMPT in $0." >&2
    exit 1
fi
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
chmod +x Scripts/check-name-consistency.sh
Scripts/test-check-name-consistency.sh
```

Expected: PASS — six `ok - ` lines, then `all check-name-consistency tests passed`.

- [ ] **Step 5: Confirm the guard is red against the real tree**

This is the red state the rest of Phase 1 turns green. It is a *verification*, not a failure:

```bash
Scripts/check-name-consistency.sh; echo "exit=$?"
```

Expected: `exit=1`, listing **79 files**. Task 6 Step 5 checks that count reaches zero. A materially different number means the exemption list does not match the tree — investigate before sweeping anything.

- [ ] **Step 6: Commit**

```bash
git add Scripts/check-name-consistency.sh Scripts/test-check-name-consistency.sh
git commit -m "feat(scripts): add the Waddle name-consistency guard

The name is Waddle; WADdle is a wordmark. Written before the rename it
enforces, so the sweep has a failing check to satisfy. Not yet wired into
CI -- the tree is still red against it."
```

---

## Task 2: Xcode identity, build invocations, and the module rename

These must land in one commit. Renaming the target renames the Swift module, which invalidates every `@testable import WADdle` at once; a partial change does not compile.

**Files:**
- Modify: `App/project.yml` (15 occurrences), `mise.toml` (5), `.github/workflows/ci.yml` (9), `.github/workflows/ui-tests.yml` (6), `.github/workflows/testflight.yml` (1), `.github/actions/setup-waddle-build/action.yml` (1), `Scripts/archive.sh` (3), `Scripts/capture-screenshots.sh` (4), `Scripts/check-red-green.sh` (4), `Scripts/build-deps.sh` (2), `Scripts/generate-build-info.sh` (1), `Scripts/provision-test-wads.sh` (1), `Scripts/upload.sh` (1), `Scripts/test-build-deps.sh` (1), `Scripts/test-check-red-green.sh` (2), `Scripts/test-fetch-testflight-feedback.sh` (1), `Scripts/loop-prompt.md` (5), `Scripts/extract-mark.py` (1), `.claude/skills/waddle-filing-an-issue/SKILL.md` (4), `.claude/skills/waddle-writing-a-guard-script/SKILL.md` (2)
- Rename: `App/Sources/WADdleApp.swift` → `App/Sources/WaddleApp.swift`
- Modify: all files under `App/Tests/` and `App/UITests/` carrying `@testable import WADdle`

**Interfaces:**
- Consumes: `Scripts/check-name-consistency.sh` from Task 1.
- Produces: Xcode project `App/Waddle.xcodeproj`, scheme `Waddle`, targets `Waddle` / `WaddleTests` / `WaddleUITests`, Swift module `Waddle`, `@main struct WaddleApp`. Tasks 3 and 4 build against these names.

- [ ] **Step 1: Rename the app entry point**

```bash
git mv App/Sources/WADdleApp.swift App/Sources/WaddleApp.swift
sed -i '' 's/WADdleApp/WaddleApp/g' App/Sources/WaddleApp.swift
```

- [ ] **Step 2: Sweep the identity and build-invocation cluster**

Every remaining occurrence in these files is either the target, the scheme, the module, the generated project, or a derived artifact name (`WADdle.xcarchive`, `WADdle.ipa`, `WADdle.app`) — all of which follow the target rename. A blanket substitution is correct here:

```bash
sed -i '' 's/WADdle/Waddle/g' \
  App/project.yml \
  mise.toml \
  .github/workflows/ci.yml \
  .github/workflows/ui-tests.yml \
  .github/workflows/testflight.yml \
  .github/actions/setup-waddle-build/action.yml \
  Scripts/archive.sh \
  Scripts/capture-screenshots.sh \
  Scripts/check-red-green.sh \
  Scripts/build-deps.sh \
  Scripts/generate-build-info.sh \
  Scripts/provision-test-wads.sh \
  Scripts/upload.sh \
  Scripts/test-build-deps.sh \
  Scripts/test-check-red-green.sh \
  Scripts/test-fetch-testflight-feedback.sh \
  Scripts/loop-prompt.md \
  Scripts/extract-mark.py \
  .claude/skills/waddle-filing-an-issue/SKILL.md \
  .claude/skills/waddle-writing-a-guard-script/SKILL.md
```

- [ ] **Step 3: Sweep the module imports**

```bash
git ls-files -z 'App/Tests/*' 'App/UITests/*' \
  | xargs -0 grep -l 'WADdle' \
  | xargs sed -i '' 's/WADdle/Waddle/g'
```

- [ ] **Step 4: Verify the sweep left nothing behind in this cluster**

```bash
git grep -n 'WADdle' -- App/project.yml mise.toml .github Scripts App/Tests App/UITests App/Sources/WaddleApp.swift .claude
```

Expected: no output. (`App/ExportOptions-ci.plist` is not in this list — it is exempt and must still contain `WADdle App Store CI`.)

- [ ] **Step 5: Regenerate the Xcode project**

```bash
rm -rf App/WADdle.xcodeproj App/BoomBox.xcodeproj
mise run generate
ls -d App/Waddle.xcodeproj
```

Expected: `App/Waddle.xcodeproj` exists. `App/BoomBox.xcodeproj` was untracked residue from the previous rename; deleting it is part of this task.

- [ ] **Step 6: Run the full suite**

```bash
mise run test
```

Expected: PASS. `RealWADTests` failures without the fixtures described in `docs/learnings/simulator-test-hazards.md` are expected and are not a regression — see `CLAUDE.md`. Any *compile* error naming module `WADdle` means Step 3 missed a file.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor: rename the Xcode target, scheme and module to Waddle

Target, scheme, generated project, Swift module and every derived
artifact name (xcarchive, ipa, app) move together -- the module rename
invalidates every @testable import at once, so a partial change does not
compile. Also drops App/BoomBox.xcodeproj, untracked residue from the
previous rename."
```

---

> **Correction (found during execution, 2026-08-16):** Tasks 2 and 3 **cannot be
> split**, and the plan was wrong to try. Task 2's sweep of `App/UITests/` does
> not only change `@testable import` — it also rewrites assertions about
> on-screen text (`app.navigationBars["WADdle"]`,
> `app.descendants(...)["WADdle & Woof! — GPL-2.0"]`) whose matching strings live
> in Task 3's `ShelfView` and `AboutView`. Landing Task 2 alone leaves three UI
> tests red: `ShipUITests/testAboutScreenShowsLicensesAndBuild`,
> `PresetCreationTests/testCreatingPresetClosesSheetAndShowsTileOnPlay`, and
> `DemoLoopReplayTests/testDoom2AfterFreedoomDoesNotCrashOnReplay`. They were
> executed as one commit.

## Task 3: User-facing product strings

**Files:**
- Modify: `App/Sources/Diagnostics/DiagnosticsExporter.swift` (4), `App/Sources/UI/AboutView.swift` (2), `App/Sources/UI/ShelfView.swift` (3), `App/Sources/Library/ImportService.swift` (1), `App/Sources/Library/LibraryService.swift` (1), `PRIVACY.md` (2), `App/Resources/Licenses/NOTICES.md` (1)
- Test: `App/Tests/DiagnosticsExporterTests.swift`

**Interfaces:**
- Consumes: module `Waddle` from Task 2.
- Produces: diagnostics archive named `Waddle-diagnostics.zip`; share-sheet title `"Waddle diagnostics"`.

- [ ] **Step 1: Update the failing test first**

`App/Tests/DiagnosticsExporterTests.swift` asserts on the archive filename. Change the expectation to the new name — this is updating an assertion to match an intended behaviour change, not weakening a test:

```bash
sed -i '' 's/WADdle-diagnostics/Waddle-diagnostics/g' App/Tests/DiagnosticsExporterTests.swift
```

- [ ] **Step 2: Run it to verify it fails**

```bash
xcodebuild -project App/Waddle.xcodeproj -scheme Waddle \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:WaddleTests/DiagnosticsExporterTests test 2>&1 | tail -20
```

Expected: FAIL — the exporter still produces `WADdle-diagnostics.zip` while the test now expects `Waddle-diagnostics.zip`.

- [ ] **Step 3: Rename the product strings**

```bash
sed -i '' 's/WADdle/Waddle/g' \
  App/Sources/Diagnostics/DiagnosticsExporter.swift \
  App/Sources/UI/AboutView.swift \
  App/Sources/UI/ShelfView.swift \
  App/Sources/Library/ImportService.swift \
  App/Sources/Library/LibraryService.swift \
  PRIVACY.md \
  App/Resources/Licenses/NOTICES.md
```

- [ ] **Step 4: Run it to verify it passes**

```bash
xcodebuild -project App/Waddle.xcodeproj -scheme Waddle \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:WaddleTests/DiagnosticsExporterTests test 2>&1 | tail -20
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "fix(ui): rename user-facing product strings to Waddle

The diagnostics archive becomes Waddle-diagnostics.zip and its share
sheet Waddle diagnostics. Archives testers already sent keep the old
name, which is harmless for correlation."
```

---

## Task 4: Vendored engine strings

Isolated in its own commit because it is the only change that invalidates the engine framework: `Scripts/check-engine-fresh.sh` fingerprints all of `Engine/woof`, so this forces a ~25-minute rebuild locally and a cold build in CI. Both files are already local patches on the `798acebd` pin, so editing them is legitimate.

**Files:**
- Modify: `Engine/woof/src/woof_ios.c:235`, `Engine/woof/src/i_input.c:1034`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: controller descriptor named `"Waddle Touch Controls"`; a rebuilt `Vendor/out/WoofEngine.xcframework` with a matching `.fingerprint` stamp.

- [ ] **Step 1: Confirm the guard is currently green on the engine**

```bash
Scripts/check-engine-fresh.sh && echo "engine fresh before the edit"
```

Expected: silent success. If it already fails, rebuild first (`mise run build-engine`) so this task's rebuild is attributable to this task.

- [ ] **Step 2: Rename the two strings**

```bash
sed -i '' 's/WADdle/Waddle/g' Engine/woof/src/woof_ios.c Engine/woof/src/i_input.c
git diff --stat Engine/
```

Expected: exactly two files, one line changed in each.

- [ ] **Step 3: Verify the guard now refuses — this proves the fingerprint covers these files**

```bash
Scripts/check-engine-fresh.sh; echo "exit=$?"
```

Expected: `exit=1` with "engine sources/scripts changed since WoofEngine.xcframework was built".

- [ ] **Step 4: Rebuild the engine**

```bash
mise run build-engine
```

Expected: completes in roughly 25 minutes.

- [ ] **Step 5: Verify the guard is green again**

```bash
Scripts/check-engine-fresh.sh && echo "engine fresh after rebuild"
```

Expected: silent success.

- [ ] **Step 6: Commit**

```bash
git add Engine/woof/src/woof_ios.c Engine/woof/src/i_input.c
git commit -m "refactor(engine): rename the controller descriptor to Waddle

Both files already carry local patches on the 798acebd pin. Isolated in
its own commit because check-engine-fresh.sh fingerprints all of
Engine/woof, so this is the change that forces the rebuild."
```

---

## Task 5: The App Store metadata rewrite

`docs/app-store/metadata.md` needs more than substitution — its naming rationale argues *from* the casing, so a blind sweep would leave an argument that no longer parses.

**Files:**
- Modify: `docs/app-store/metadata.md` (17), `docs/app-store/submission-checklist.md` (4)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: the approved store name string `"Waddle: WAD Player"`, which Task 9 sends to App Store Connect.

- [ ] **Step 1: Sweep the checklist**

`submission-checklist.md` occurrences are all plain references to the app name:

```bash
sed -i '' 's/WADdle/Waddle/g' docs/app-store/submission-checklist.md
```

- [ ] **Step 2: Sweep metadata.md, then repair the rationale by hand**

```bash
sed -i '' 's/WADdle/Waddle/g' docs/app-store/metadata.md
```

The sweep produces `"Waddle: WAD Player"` as the store name, which is correct, and `**The bare "Waddle" is not available**`, which is also correct — the 409 was case-insensitive. Two passages are left incoherent by it and must be replaced by hand.

**Note:** `docs/app-store/` is *not* exempt from the guard, so neither replacement may spell the wordmark literally. Describe it instead.

Replace the paragraph beginning "The original naming rationale stands otherwise" — the sweep turns it into "*Waddle* hides **WAD** inside *waddle*", which says nothing — with:

```markdown
The original naming rationale stands otherwise: the name is *Waddle*, and the
wordmark capitalizes its first three letters so that **WAD** — the Doom file
format the app plays — is visible inside it, in the whimsical spirit of the
source-port lineage it belongs to (its engine is **Woof!**, alongside *Crispy
Doom* and *Chocolate Doom*). That stylization is a visual treatment, not a
spelling: it lives in `Design/` and never in typed text. See
`docs/learnings/the-name-is-waddle.md`. The suffix does double duty against the
crowding risk noted below: it separates us from the *Waddle* cluster and makes
the listing searchable on "wad player", while the subtitle still carries the
plain description.
```

Replace the **Scope note** paragraph, which records the BoomBox rename and after the sweep reads as though the target was always spelled `Waddle`, with:

```markdown
**Scope note:** there have been two renames, both pre-submission while they
were still free to change. The first (2026-07) moved everything off BoomBox —
the bundle ID (`com.tylervick.waddle`, lowercase), the Xcode
target/scheme/project, the GitHub repo (`tylervick/waddle`), the UTI
identifiers (`com.tylervick.waddle.*`), and the `WADDLE_*` test-seam env vars.
The second (2026-08-16) settled the casing: the name is plain *Waddle*
everywhere text is typed, and the stylized form is the wordmark only. Nothing
user- or developer-facing retains "BoomBox".
```

The availability finding — the `409 ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE.DIFFERENT_ACCOUNT` on the bare name, and the conclusion that the suffix is forced rather than chosen — is unchanged and must survive intact. Do not let the rewrite imply the bare name became available.

- [ ] **Step 3: Verify no stale spelling and no broken claim**

```bash
git grep -n 'WADdle' -- docs/app-store/
git grep -n 'Waddle: WAD Player' -- docs/app-store/metadata.md
```

Expected: the first command prints nothing; the second finds the store name.

- [ ] **Step 4: Commit**

```bash
git add docs/app-store/
git commit -m "docs(app-store): store name becomes Waddle: WAD Player

The casing argument moves to the wordmark: the name is Waddle, and the
WADdle wordmark is what makes the WAD visible. The availability finding
-- the bare name is held by another account, so the suffix is forced --
is unchanged."
```

---

## Task 6: Living docs, the learning, and wiring the guard

**Files:**
- Modify: `CLAUDE.md` (3), `README.md` (16), `Design/README.md` (1), `Engine/WOOF_UPSTREAM.md` (1), `docs/manual-testing.md` (1), `docs/learnings/INDEX.md` (1), `docs/learnings/*.md` (13 across 4 files)
- Create: `docs/learnings/the-name-is-waddle.md`
- Modify: `.github/workflows/ci.yml` — the "Verify the build-script helpers" step

**Interfaces:**
- Consumes: `Scripts/check-name-consistency.sh` and `Scripts/test-check-name-consistency.sh` from Task 1.
- Produces: a green `Scripts/check-name-consistency.sh` against the whole tree.

- [ ] **Step 1: Sweep the living docs**

`Design/README.md` is swept even though `Design/` is exempt from the guard — the exemption covers artwork, and the README is prose:

```bash
sed -i '' 's/WADdle/Waddle/g' \
  CLAUDE.md \
  README.md \
  Design/README.md \
  Engine/WOOF_UPSTREAM.md \
  docs/manual-testing.md \
  docs/learnings/INDEX.md \
  docs/learnings/a-second-destination-needs-a-live-device-test.md \
  docs/learnings/ui-tests-are-red-at-head.md \
  docs/learnings/xcodegen-needs-bootstrapped-resources.md \
  docs/learnings/xcodegen-source-snapshot-hides-new-tests.md
```

- [ ] **Step 2: Write the learning**

Create `docs/learnings/the-name-is-waddle.md`:

```markdown
# The name is "Waddle"; "WADdle" is the wordmark

The app is called **Waddle**. `WADdle` is a *wordmark* — a visual treatment
that makes the **WAD** visible inside the name — and it belongs in `Design/`,
not in typed text. `Scripts/check-name-consistency.sh` is the check.

This has now cost two renames. `BoomBox` → `WADdle` (2026-07) left residue that
survived for weeks, including an `App/BoomBox.xcodeproj` nobody noticed;
`WADdle` → `Waddle` (2026-08-16) is the second. A stylized spelling is
self-camouflaging: it reads as deliberate wherever it lands, so nobody deletes
it on sight. That is why the rule is mechanical rather than remembered.

**Three things are NOT the wordmark and must not be swept:**

- `WADDLE_*` test-seam environment variables — SCREAMING_SNAKE reads
  identically either way.
- The lowercase family: `com.tylervick.waddle`, the `com.tylervick.waddle.*`
  UTIs, `tylervick/waddle`, `Design/waddle-mark.png`, `.waddleScrollSurface()`.
  Changing the bundle ID or UTIs would orphan every installed build's saves and
  document associations.
- `WADdle App Store CI` in `App/ExportOptions-ci.plist` — a provisioning-profile
  name registered in Apple's developer portal. Renaming it here without renaming
  it there breaks CI signing with an opaque error. Rename it at the next profile
  regeneration, portal first.

**Dated records under `docs/superpowers/` are frozen.** They are cited as
provenance by the guard scripts and skill guides, every stale identifier in them
fails loudly at the point of use (`-scheme WADdle` → "scheme not found"), and
sweeping them would fabricate: `2026-07-20-soft-keyboard-input-design.md` reads
`WADdle (com.tylervick.BoomBox)`, recording a window that really existed. When
reading a plan written before 2026-08-16, translate build commands yourself.
```

- [ ] **Step 3: Index the learning**

`Scripts/check-substrate.sh` enforces an exact bijection between `docs/learnings/INDEX.md` and the files beside it, so this is required, not optional. It keys on the `](filename.md)` link target only, so the link text is free — which matters here, because **`INDEX.md` is not exempt from the new guard and must not spell the wordmark.** The learning file itself may (it is exempt); its index entry may not. Append to the list in `docs/learnings/INDEX.md`:

```markdown
- [The name is "Waddle"; the stylized form is only a wordmark](the-name-is-waddle.md) — two renames have leaked residue; `Scripts/check-name-consistency.sh` is the check, and the env vars, bundle ID and provisioning-profile name are deliberately not swept
```

- [ ] **Step 4: Wire the guard into CI**

In `.github/workflows/ci.yml`, inside the `Verify the build-script helpers` step, add the test suite alongside its peers (after `Scripts/test-check-substrate.sh`):

```yaml
          Scripts/test-check-name-consistency.sh
```

and add the guard itself next to `Scripts/check-substrate.sh` near the end of the same step:

```yaml
          # The app's name is Waddle; the stylized form is a wordmark and
          # belongs only in Design/. Pure text scan of tracked files; no
          # network, no token. (This comment cannot quote the spelling it
          # forbids -- ci.yml is not on the guard's exemption list.)
          Scripts/check-name-consistency.sh
```

- [ ] **Step 5: Verify the guard is green against the whole tree**

```bash
Scripts/check-name-consistency.sh && echo "name consistency: clean"
Scripts/test-check-name-consistency.sh
Scripts/check-substrate.sh && echo "substrate: clean"
```

Expected: all three succeed. The first is the count from Task 1 Step 5 reaching zero.

- [ ] **Step 6: Confirm only intended residue remains**

```bash
git grep -l 'WADdle' -- . ':!docs/superpowers' ':!Design'
```

Expected: exactly four paths, every one a stated exemption —

```
App/ExportOptions-ci.plist
Scripts/check-name-consistency.sh
Scripts/test-check-name-consistency.sh
docs/learnings/the-name-is-waddle.md
```

Anything else in that list is a file the sweep missed.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "docs: sweep living docs to Waddle and wire the name guard

Adds the learning recording why the rule is mechanical, indexes it as
check-substrate.sh requires, and turns the guard on in CI now that the
tree satisfies it."
```

---

## Task 7: Full verification and the pull request

**Files:** none modified.

**Interfaces:**
- Consumes: everything from Tasks 1–6.
- Produces: a merged `main` carrying the rename, which Phase 2 assumes.

- [ ] **Step 1: Clean-tree check**

```bash
git status --porcelain
```

Expected: empty. A non-empty tree makes `Scripts/check-red-green.sh` refuse — see `docs/learnings/fixture-stub-trips-own-dirty-tree-guard.md`.

- [ ] **Step 2: Regenerate and run the whole suite from scratch**

```bash
mise run generate
mise run test
```

Expected: PASS, with the `RealWADTests` caveat from `CLAUDE.md`.

- [ ] **Step 3: Run every guard**

```bash
Scripts/check-engine-fresh.sh   && echo "engine ok"
Scripts/check-name-consistency.sh && echo "name ok"
Scripts/check-substrate.sh      && echo "substrate ok"
Scripts/check-icon-json.sh      && echo "icon json ok"
Scripts/check-masked-gh-status.sh && echo "gh status ok"
```

Expected: all five print their ok line.

- [ ] **Step 4: Push and open the pull request**

```bash
git push -u origin tylervick/waddle-name-consistency
gh pr create --title "refactor: make Waddle the canonical name" --body "$(cat <<'EOF'
The app's name is **Waddle**. `WADdle` is a wordmark, and this makes that
distinction real: the plain name everywhere text is typed, the stylization
confined to `Design/`.

Implements `docs/superpowers/specs/2026-08-16-waddle-name-consistency-design.md`.

- Xcode target/scheme/module, generated project, and every derived artifact name
- User-facing product strings, including `Waddle-diagnostics.zip`
- Two vendored engine strings — which is why this PR forces an engine rebuild
- Living docs; App Store name becomes "Waddle: WAD Player"
- New `Scripts/check-name-consistency.sh`, wired into CI, so this does not drift a third time

**Deliberately not swept:** `WADDLE_*` env vars, the lowercase family
(`com.tylervick.waddle`, the UTIs, the git remote), the `WADdle App Store CI`
provisioning-profile name registered in Apple's portal, and the dated records
under `docs/superpowers/` — reasoning in `docs/learnings/the-name-is-waddle.md`.
EOF
)"
```

- [ ] **Step 5: Wait for CI, then merge**

Expect a cold build: Task 4 changed engine sources, so the cached framework is invalid and CI rebuilds it.

---

# Phase 2 — The machine-side migration

Phase 2 runs **after** the Phase 1 pull request merges. It mutates state outside the repo, so every step is backed up before it is changed. Nothing here is TDD-able; each step is instead paired with a verification that must pass before the next begins.

## Task 8: Quiesce and back up

**Files:** none in the repo.

**Interfaces:**
- Consumes: a merged Phase 1.
- Produces: backups at `~/waddle-rename-backup/`, and a disabled automation.

- [ ] **Step 1: Disable the loop automation**

It fires at 09:00/13:00/17:00; a run landing mid-migration would create a worktree against a path that is moving.

```bash
orca automations edit 8a0d5727-9d5c-46a6-b0ef-92d5accf3859 --disabled
orca automations show 8a0d5727-9d5c-46a6-b0ef-92d5accf3859 | grep -E 'name|enabled|runPath'
```

Expected: `enabled: false`.

- [ ] **Step 2: Quit Orca and its daemon**

Orca holds `orca-data.json` in memory and rewrites it continuously — the raw occurrence count was observed moving from 248 to 212 within minutes. Editing it while Orca runs loses the edit.

```bash
osascript -e 'quit app "Orca"' || true
pkill -f 'orca.*daemon' || true
sleep 5
pgrep -fl orca || echo "orca is down"
```

Expected: `orca is down`.

- [ ] **Step 3: Back up everything Phase 2 will mutate**

```bash
mkdir -p ~/waddle-rename-backup
cp "$HOME/Library/Application Support/orca/profiles/local-default/orca-data.json" \
   ~/waddle-rename-backup/orca-data.json.before
cp ~/.claude.json ~/waddle-rename-backup/claude.json.before
ls -la ~/waddle-rename-backup
```

Expected: both files present and non-empty.

---

## Task 9: Move the directory

**Files:** none in the repo.

**Interfaces:**
- Consumes: a quiesced Orca from Task 8.
- Produces: the checkout at `/Users/tyler/Documents/waddle`.

- [ ] **Step 1: Move it**

```bash
mv ~/Documents/doom-ios-2026 ~/Documents/waddle
ls -d ~/Documents/waddle
```

- [ ] **Step 2: Clear the poisoned CMake cache**

`orca.yaml` documents that these caches hardcode absolute paths (`CMAKE_CACHEFILE_DIR`, `*_SOURCE_DIR`), so a cache inherited at a new path makes `build-engine.sh` fail. It regenerates on demand.

```bash
rm -rf ~/Documents/waddle/Vendor/build
```

- [ ] **Step 3: Verify git and the engine survived the move**

```bash
cd ~/Documents/waddle
git status --porcelain && echo "tree clean"
git worktree list
Scripts/check-engine-fresh.sh && echo "engine still fresh"
```

Expected: clean tree; one worktree at the new path; **engine still fresh** — the fingerprint is content-based, so the move must not have invalidated it. If it did, something other than the move changed the sources.

---

## Task 10: Rewrite the Orca registry

**Files:** none in the repo.

**Interfaces:**
- Consumes: the backup from Task 8, the moved directory from Task 9.
- Produces: an Orca registry pointing at `/Users/tyler/Documents/waddle`, with all worktree, session, and automation-run history intact.

- [ ] **Step 1: Rewrite the paths and display names**

A single global substitution covers the repo path, the workspaces path, and the display name at once:

```bash
python3 - <<'PY'
import os, shutil
p = os.path.expanduser('~/Library/Application Support/orca/profiles/local-default/orca-data.json')
shutil.copy(p, p + '.pre-rename')
s = open(p).read()
before = s.count('doom-ios-2026')
s = s.replace('/Users/tyler/Documents/doom-ios-2026', '/Users/tyler/Documents/waddle')
s = s.replace('/Users/tyler/orca/workspaces/doom-ios-2026', '/Users/tyler/orca/workspaces/waddle')
s = s.replace('doom-ios-2026', 'waddle')
open(p, 'w').write(s)
print(f"rewrote {before} occurrences; {s.count('doom-ios-2026')} remain")
PY
```

Expected: `0 remain`.

- [ ] **Step 2: Move the workspaces directory to match**

```bash
mv ~/orca/workspaces/doom-ios-2026 ~/orca/workspaces/waddle
ls -d ~/orca/workspaces/waddle
```

- [ ] **Step 3: Restart Orca and verify the records**

```bash
open -a Orca
sleep 20
orca repo list | grep -i waddle
orca automations show 8a0d5727-9d5c-46a6-b0ef-92d5accf3859 | grep -E 'name|runPath|enabled'
orca worktree list | head -8
```

Expected: the repo is named `waddle` at `/Users/tyler/Documents/waddle`; `runPath` is the new path; the worktree list shows the main worktree **with its existing comment preserved**. A missing comment means the ids did not survive — restore from `~/waddle-rename-backup/orca-data.json.before` and stop.

---

## Task 11: Claude session history

**Files:**
- Modify: `~/.claude.json`; the two memory files naming the old path.

**Interfaces:**
- Consumes: the backup from Task 8.
- Produces: session history and agent memory reachable from the new path.

- [ ] **Step 1: Rename the project session directories**

```bash
cd ~/.claude/projects
mv -- -Users-tyler-Documents-doom-ios-2026 -Users-tyler-Documents-waddle
for d in *orca-workspaces-doom-ios-2026*; do
  mv -- "$d" "${d/orca-workspaces-doom-ios-2026/orca-workspaces-waddle}"
done
ls -d *waddle* | wc -l
ls -d *doom-ios-2026* 2>/dev/null | wc -l
```

Expected: 58 directories matching `waddle` (1 main + 57 workspaces), 0 matching the old name.

- [ ] **Step 2: Verify the sessions and memory came along**

```bash
ls ~/.claude/projects/-Users-tyler-Documents-waddle/*.jsonl | wc -l
ls ~/.claude/projects/-Users-tyler-Documents-waddle/memory/
```

Expected: 27 session files, and the memory directory with `MEMORY.md` beside its entries.

- [ ] **Step 3: Rewrite `~/.claude.json`**

```bash
python3 - <<'PY'
import json, os, shutil
p = os.path.expanduser('~/.claude.json')
shutil.copy(p, p + '.pre-rename')
s = open(p).read()
before = s.count('doom-ios-2026')
s = s.replace('doom-ios-2026', 'waddle')
json.loads(s)  # refuse to write anything that is not valid JSON
open(p, 'w').write(s)
print(f"rewrote {before} occurrences")
PY
```

Expected: ~60 occurrences rewritten, and no exception — the `json.loads` is a guard against writing a corrupt config.

- [ ] **Step 4: Correct the memory files that name the old path**

```bash
cd ~/.claude/projects/-Users-tyler-Documents-waddle/memory
grep -rl 'doom-ios-2026' . | xargs sed -i '' 's|Documents/doom-ios-2026|Documents/waddle|g'
grep -rn 'doom-ios-2026' . || echo "memory clean"
```

Expected: `memory clean`.

---

## Task 12: Re-enable and verify end to end

**Files:** none.

**Interfaces:**
- Consumes: Tasks 9–11.
- Produces: a working loop automation at the new path.

- [ ] **Step 1: Run the loop's own precheck from the new path**

This exercises the automation's entry conditions without burning a run.

```bash
cd ~/Documents/waddle
Scripts/loop-precheck.sh; echo "exit=$?"
```

Expected: the same verdict it gave before the move. An exit status meaning "not eligible" is fine; an error naming a missing path is not.

- [ ] **Step 2: Re-enable the automation**

```bash
orca automations edit 8a0d5727-9d5c-46a6-b0ef-92d5accf3859 --enabled
orca automations show 8a0d5727-9d5c-46a6-b0ef-92d5accf3859 | grep -E 'enabled|nextRunAt|runPath'
```

Expected: `enabled: true`, a future `nextRunAt`, and the new `runPath`.

- [ ] **Step 3: Confirm the automation's run history survived**

```bash
orca automations runs 8a0d5727-9d5c-46a6-b0ef-92d5accf3859 | head -5
```

Expected: historical runs still listed. If the list is empty, the id rewrite broke the join — restore `orca-data.json` from the backup.

---

## Task 13: The `boombox` project id — optional, last

Deliberately separate. It is unknown whether Orca re-derives the durable project id from the git remote on load or treats it as opaque; if it half-re-derives, this could mint a duplicate project. Attempt it only once Tasks 9–12 are verified clean.

**Files:** none.

**Interfaces:**
- Consumes: a verified-clean Task 12.
- Produces: project id `github:tylervick/waddle`.

- [ ] **Step 1: Quit Orca again**

```bash
osascript -e 'quit app "Orca"' || true
pkill -f 'orca.*daemon' || true
sleep 5
pgrep -fl orca || echo "orca is down"
```

- [ ] **Step 2: Rewrite the id**

```bash
python3 - <<'PY'
import os, shutil
p = os.path.expanduser('~/Library/Application Support/orca/profiles/local-default/orca-data.json')
shutil.copy(p, p + '.pre-boombox')
s = open(p).read()
before = s.lower().count('boombox')
s = s.replace('github:tylervick/boombox', 'github:tylervick/waddle')
s = s.replace('tylervick/boombox', 'tylervick/waddle')
open(p, 'w').write(s)
print(f"had {before} boombox occurrences; {s.lower().count('boombox')} remain")
PY
```

Expected: `0 remain` (193 rewritten).

- [ ] **Step 3: Restart and verify no duplicate project appeared**

```bash
open -a Orca
sleep 20
orca project list
orca repo list | grep -i waddle
orca automations runs 8a0d5727-9d5c-46a6-b0ef-92d5accf3859 | head -5
```

Expected: exactly **one** Waddle project, id `github:tylervick/waddle`; one repo; run history intact.

- [ ] **Step 4: Roll back immediately if anything doubled**

If `orca project list` shows two Waddle entries, or the run history emptied:

```bash
osascript -e 'quit app "Orca"'; pkill -f 'orca.*daemon'; sleep 5
cp ~/Library/Application\ Support/orca/profiles/local-default/orca-data.json.pre-boombox \
   ~/Library/Application\ Support/orca/profiles/local-default/orca-data.json
open -a Orca
```

The legacy id is cosmetic; keeping it costs nothing.

---

# Phase 3 — App Store Connect

## Task 14: Rename the store listing

**Files:** none in the repo.

**Interfaces:**
- Consumes: the approved store name from Task 5 (`Waddle: WAD Player`).
- Produces: an updated App Store Connect app-info localization.

- [ ] **Step 1: Mint a token and find the en-US localization id**

```bash
cd ~/Documents/waddle
TOKEN="$(Scripts/asc-jwt.sh)"
APP_ID="$(curl -sf -H "Authorization: Bearer $TOKEN" \
  'https://api.appstoreconnect.apple.com/v1/apps?filter[bundleId]=com.tylervick.waddle' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])')"
INFO_ID="$(curl -sf -H "Authorization: Bearer $TOKEN" \
  "https://api.appstoreconnect.apple.com/v1/apps/$APP_ID/appInfos" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])')"
curl -sf -H "Authorization: Bearer $TOKEN" \
  "https://api.appstoreconnect.apple.com/v1/appInfos/$INFO_ID/appInfoLocalizations" \
  | python3 -c 'import json,sys; [print(d["id"], d["attributes"]["locale"], d["attributes"]["name"]) for d in json.load(sys.stdin)["data"]]'
```

Expected: one row, locale `en-US`, name `WADdle: WAD Player`. Note its id.

- [ ] **Step 2: Send the rename**

Substitute the id from Step 1 for `<LOC_ID>`:

```bash
curl -sS -X PATCH -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  "https://api.appstoreconnect.apple.com/v1/appInfoLocalizations/<LOC_ID>" \
  -d '{"data":{"type":"appInfoLocalizations","id":"<LOC_ID>","attributes":{"name":"Waddle: WAD Player"}}}' \
  | python3 -m json.tool
```

Expected: HTTP 200 with `"name": "Waddle: WAD Player"`.

If it returns `409` with a state error, the app version is not editable — a version is in review. **Report that and stop.** The rename rides with the next version; do not work around it.

- [ ] **Step 3: Confirm**

```bash
curl -sf -H "Authorization: Bearer $TOKEN" \
  "https://api.appstoreconnect.apple.com/v1/appInfos/$INFO_ID/appInfoLocalizations" \
  | python3 -c 'import json,sys; [print(d["attributes"]["locale"], d["attributes"]["name"]) for d in json.load(sys.stdin)["data"]]'
```

Expected: `en-US Waddle: WAD Player`.

---

## Task 15: Restart the Claude session

- [ ] **Step 1:** Exit this Claude Code session.
- [ ] **Step 2:** Start a new one from `~/Documents/waddle`.
- [ ] **Step 3:** Confirm prior history and memory are reachable — `/resume` should list the 27 earlier sessions, and the memory index should load as usual.

This is last because the session performing the work runs inside the directory Task 9 moves.
