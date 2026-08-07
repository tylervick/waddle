# Agent Substrate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make WADdle's backlog and hard-won technical knowledge durable and
machine-readable — labelled GitHub issues, a tracked `CLAUDE.md`, and
`docs/learnings/` — with a CI-enforced check so none of it silently decays.

**Architecture:** Three artifacts and one guard. `CLAUDE.md` holds always-true
rules under a hard line cap. `docs/learnings/` holds one hard-won fact per file
with an index. GitHub issues hold the backlog, extracted from the gitignored
`.superpowers/sdd/progress.md` ledger and formatted so an unattended agent can
consume them. `Scripts/check-substrate.sh` asserts all three stay well-formed
and runs in CI alongside the three script self-tests already there.

**Tech Stack:** Bash (matching the existing `Scripts/` conventions), GitHub CLI
(`gh`), GitHub Actions, Markdown.

**Spec:** `docs/superpowers/specs/2026-08-06-agent-substrate-design.md`

**Branch:** `tylervick/agent-substrate-spec` (already created; the spec is
committed there at `b288ae1`).

## Global Constraints

- `CLAUDE.md` hard cap: **50 lines**. Over the cap, content moves to `docs/learnings/`.
- Every `agent:eligible` issue body must contain three literal level-2 headings,
  each with a non-empty section: `## Definition of done`, `## Verification`, `## Provenance`.
- `docs/learnings/INDEX.md` must be in exact bijection with the `.md` files in
  `docs/learnings/` — one index entry per file, no entry pointing at a missing file.
- Never agent-eligible: physical-device work, App Store Connect (#28),
  screenshot/metadata judgment, engine vendor re-pins, anything touching signing
  or the release path. These get `agent:blocked` with the reason in the issue.
- Bash scripts: `set -euo pipefail`, `ROOT` derived from the script's own
  location, header comment explaining *why* the script exists — matching
  `Scripts/check-engine-fresh.sh`.
- Script self-tests are **hermetic**: build a fixture repo in `mktemp -d`, copy
  the script under test into it, never touch the real tree. Matching
  `Scripts/test-check-engine-fresh.sh`.
- Conventional commits. No Claude/AI attribution in commit messages or PR bodies.
- `.superpowers/sdd/progress.md` stays gitignored — it is read, never modified.

---

### Task 1: `CLAUDE.md` and the `docs/learnings/` shape

Creates the always-on rules file and the learnings directory with its index and
two seed entries, so Task 2's guard has a real subject to validate.

**Files:**
- Create: `CLAUDE.md`
- Create: `docs/learnings/INDEX.md`
- Create: `docs/learnings/woof-engine-pin.md`
- Create: `docs/learnings/engine-resource-layout.md`

**Interfaces:**
- Consumes: nothing.
- Produces: the file layout Task 2 checks — `CLAUDE.md` at repo root,
  `docs/learnings/INDEX.md`, and sibling `*.md` learning files. Index entry
  format is `- [Title](filename.md) — hook`, one per line.

- [ ] **Step 1: Write `CLAUDE.md`**

```markdown
# WADdle — working rules

An iOS port of the Woof! Doom engine. See `README.md` for build instructions and
`docs/learnings/INDEX.md` for traps this project has already paid for.

## Build & test

- Bootstrap: `mise run bootstrap`. Verify: `mise run test`.
- Never run two `xcodebuild` test sessions against one simulator at the same
  time — they cross-contaminate and produce spurious kills and failures.
- The engine build is deliberately separate from archiving.
  `Scripts/check-engine-fresh.sh` refuses stale frameworks; do not bypass it.

## Engine invariants

- The Woof pin is master `798acebd`. Upstream has no SDL3 release tag, so
  SDL2-era tags such as `woof_15.3.0` must never be used.
- The engine save flag is `-save`, not `-savedir`.
- `woof.pk3` lives at the app bundle root; IWADs live in `GameData/`, whose
  folder reference must never be renamed to "Resources".

## Changes

- Conventional commits, matching existing history (`fix(ui):`, `docs(app-store):`).
- Never edit or delete a test to make it pass.
- Work lands through pull requests, never directly on `main`.
- Hit a trap worth remembering? Add a file under `docs/learnings/` and one line
  to its `INDEX.md`, in the same PR.
- A learning that can be an executable check should become one —
  `Scripts/check-engine-fresh.sh` is the pattern — and the learning file then
  points at the check instead of restating it.
```

- [ ] **Step 2: Verify it is under the 50-line cap**

Run: `wc -l < CLAUDE.md`
Expected: a number ≤ 50 (the content above is ~33).

- [ ] **Step 3: Write `docs/learnings/woof-engine-pin.md`**

```markdown
# The Woof pin is a master commit, not a release tag

`Engine/woof` is pinned to master `798acebd`. Upstream Woof! has **no SDL3
release tag** — every published tag, including `woof_15.3.0`, is SDL2-era and
will not build against this project's SDL3 vendoring. The engine's version
string still reports "Woof 15.2.0"; that is expected and not evidence of a
wrong pin.

**What to do instead:** treat the pin as a commit SHA. Bumping it means
choosing a newer master commit and re-running `Scripts/vendor-woof.sh`, never
resolving a tag.

**Provenance:** Plan 1 Task 5, which was blocked mid-task by exactly this —
`woof_15.3.0` was tried first and had to be re-pinned to master.
```

- [ ] **Step 4: Write `docs/learnings/engine-resource-layout.md`**

```markdown
# Engine resource paths are load-bearing and non-obvious

Three placements the engine and Xcode both depend on:

- **`woof.pk3` sits at the app bundle root.** The engine finds it via
  `SDL_GetBasePath()` with no override, so it cannot be nested.
- **IWADs live in `GameData/`.** The Xcode folder reference must *never* be
  renamed to "Resources" — a top-level folder reference by that name triggers an
  Xcode codesign bug that breaks `simctl install`.
- **The save flag is `-save <dir>`, not `-savedir`.** Saves are per-preset, at
  `Documents/Saves/<preset-id>/`.

`-complevel` accepts exactly `vanilla`, `boom`, `mbf`, `mbf21`.

**Provenance:** Plan 1 Tasks 8 and 9. The "Resources" naming trap cost a full
debugging cycle; the `-savedir` spelling shipped in the design spec and had to
be corrected in commit `b85aea6`.
```

- [ ] **Step 5: Write `docs/learnings/INDEX.md`**

```markdown
# Learnings Index

One file per hard-won fact. Add an entry here in the same PR that adds the file —
`Scripts/check-substrate.sh` enforces the bijection.

- [The Woof pin is a master commit, not a release tag](woof-engine-pin.md) — why `woof_15.3.0` must never be used
- [Engine resource paths are load-bearing and non-obvious](engine-resource-layout.md) — woof.pk3, GameData/, and the `-save` flag
```

- [ ] **Step 6: Verify the bijection by hand (the guard does not exist yet)**

Run: `ls docs/learnings/*.md | grep -v INDEX && grep -c '](.*\.md)' docs/learnings/INDEX.md`
Expected: two learning files listed, and the count `2`.

- [ ] **Step 7: Commit**

```bash
git add CLAUDE.md docs/learnings/
git commit -m "docs: add CLAUDE.md and the learnings directory

CLAUDE.md carries only always-true rules, under a 50-line cap. Hard-won facts
get one file each under docs/learnings/ with an index entry, seeded here with
the engine pin and the resource-layout traps."
```

---

### Task 2: `Scripts/check-substrate.sh` and its self-test

The guard that keeps the substrate well-formed, plus CI wiring. Written
test-first.

**Files:**
- Create: `Scripts/check-substrate.sh`
- Create: `Scripts/test-check-substrate.sh`
- Modify: `.github/workflows/ci.yml` (the `permissions` block and the "Verify the build-script helpers" step)

**Interfaces:**
- Consumes: the file layout from Task 1.
- Produces: `Scripts/check-substrate.sh`, exit 0 when the substrate is
  well-formed and exit 1 with one `error:` line per problem on stderr. It prints
  a `skip - ` line to stdout when `gh` is missing or unauthenticated. Later
  tasks rely on it passing.

- [ ] **Step 1: Write the failing self-test**

Create `Scripts/test-check-substrate.sh`:

```bash
#!/bin/bash
# Tests for Scripts/check-substrate.sh.
#
# Fully HERMETIC: builds a fake repo in a temp dir and runs the guard there.
# Nothing here touches the real CLAUDE.md or docs/learnings/.
#
# Every case runs with PATH stripped to /usr/bin:/bin so `gh` is invisible.
# That is deliberate: it pins the issue-format check's skip path, which is the
# behaviour CI depends on when no token is present, and it keeps the whole
# suite offline and deterministic.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

# Fake repo mirroring the layout the guard walks.
make_fixture() { # dest
    mkdir -p "$1/Scripts" "$1/docs/learnings"
    cp "$ROOT/Scripts/check-substrate.sh" "$1/Scripts/"
    printf '# rules\n' > "$1/CLAUDE.md"
    printf '# A learning\n' > "$1/docs/learnings/alpha.md"
    printf '# Learnings Index\n\n- [A learning](alpha.md) — hook\n' \
        > "$1/docs/learnings/INDEX.md"
}
check() { env PATH=/usr/bin:/bin "$1/Scripts/check-substrate.sh"; }

# 1. Well-formed substrate -> pass, and announce the skipped issue check.
make_fixture "$TMP/a"
check "$TMP/a" >"$TMP/out" 2>&1 || fail "refused a well-formed substrate: $(cat "$TMP/out")"
grep -q "^skip - " "$TMP/out" || fail "did not report the gh skip; got: $(cat "$TMP/out")"
pass "passes a well-formed substrate and skips the issue check without gh"

# 2. Missing CLAUDE.md -> refuse.
make_fixture "$TMP/b"; rm "$TMP/b/CLAUDE.md"
if check "$TMP/b" >"$TMP/out" 2>&1; then fail "passed with no CLAUDE.md"; fi
grep -q "CLAUDE.md is missing" "$TMP/out" || fail "missing-CLAUDE.md error unclear"
pass "fails when CLAUDE.md is missing"

# 3. CLAUDE.md over the cap -> refuse, and name the cap.
make_fixture "$TMP/c"; seq 1 51 > "$TMP/c/CLAUDE.md"
if check "$TMP/c" >"$TMP/out" 2>&1; then fail "passed a 51-line CLAUDE.md"; fi
grep -q "50-line cap" "$TMP/out" || fail "over-cap error does not name the cap"
pass "fails when CLAUDE.md exceeds the 50-line cap"

# 4. Learning file with no index entry -> refuse.
make_fixture "$TMP/d"; printf '# Orphan\n' > "$TMP/d/docs/learnings/orphan.md"
if check "$TMP/d" >"$TMP/out" 2>&1; then fail "passed an unindexed learning"; fi
grep -q "orphan.md has 0 index entries" "$TMP/out" || fail "orphan error unclear"
pass "fails when a learning file is missing from the index"

# 5. Learning file indexed twice -> refuse. A duplicate entry means one of them
#    is stale, and a reader following the wrong one gets the wrong hook.
make_fixture "$TMP/e"
printf -- '- [Again](alpha.md) — dupe\n' >> "$TMP/e/docs/learnings/INDEX.md"
if check "$TMP/e" >"$TMP/out" 2>&1; then fail "passed a doubly-indexed learning"; fi
grep -q "alpha.md has 2 index entries" "$TMP/out" || fail "duplicate error unclear"
pass "fails when a learning file is indexed more than once"

# 6. Index pointing at a file that does not exist -> refuse.
make_fixture "$TMP/f"
printf -- '- [Ghost](ghost.md) — nothing here\n' >> "$TMP/f/docs/learnings/INDEX.md"
if check "$TMP/f" >"$TMP/out" 2>&1; then fail "passed an index entry with no file"; fi
grep -q "points at missing file: ghost.md" "$TMP/out" || fail "dangling-entry error unclear"
pass "fails when the index points at a missing file"

# 7. Missing INDEX.md -> refuse.
make_fixture "$TMP/g"; rm "$TMP/g/docs/learnings/INDEX.md"
if check "$TMP/g" >"$TMP/out" 2>&1; then fail "passed with no INDEX.md"; fi
grep -q "INDEX.md is missing" "$TMP/out" || fail "missing-index error unclear"
pass "fails when INDEX.md is missing"

# 8. All problems are reported in one run, not just the first. A guard that
#    stops at the first error turns one fix-up into several round trips.
make_fixture "$TMP/h"; rm "$TMP/h/CLAUDE.md"
printf '# Orphan\n' > "$TMP/h/docs/learnings/orphan.md"
if check "$TMP/h" >"$TMP/out" 2>&1; then fail "passed a doubly-broken substrate"; fi
grep -q "CLAUDE.md is missing" "$TMP/out" || fail "did not report the CLAUDE.md problem"
grep -q "orphan.md has 0 index entries" "$TMP/out" || fail "did not report the index problem"
pass "reports every problem in a single run"

echo "All check-substrate tests passed."
```

- [ ] **Step 2: Run the self-test to verify it fails**

```bash
chmod +x Scripts/test-check-substrate.sh
Scripts/test-check-substrate.sh
```

Expected: FAIL — `cp: .../Scripts/check-substrate.sh: No such file or directory`.

- [ ] **Step 3: Write `Scripts/check-substrate.sh`**

```bash
#!/bin/bash
# Structural checks for the agent substrate: CLAUDE.md, docs/learnings/, and
# the format of agent-eligible GitHub issues.
#
# These three artifacts are conventions, and conventions decay silently. An
# unindexed learning is invisible to anyone who reads only the index; a
# CLAUDE.md that grows without bound stops being read at all; an issue with no
# stated definition of done invites an agent to declare victory early. Each
# failure is quiet and each is cheap to catch mechanically, so it is caught
# mechanically.
#
# Reports EVERY problem in one run rather than stopping at the first, so a
# fix-up is one round trip.
#
# The issue-format check needs network and an authenticated `gh`. It skips
# cleanly when either is absent -- CI without a token must not fail here.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE_MD="$ROOT/CLAUDE.md"
LEARNINGS="$ROOT/docs/learnings"
INDEX="$LEARNINGS/INDEX.md"
CAP=50

status=0
err() { echo "error: $*" >&2; status=1; }

# 1. CLAUDE.md exists and stays within the cap.
if [ ! -f "$CLAUDE_MD" ]; then
    err "CLAUDE.md is missing — the always-on rules file is required substrate."
else
    lines="$(wc -l < "$CLAUDE_MD" | tr -d '[:space:]')"
    if [ "$lines" -gt "$CAP" ]; then
        err "CLAUDE.md is $lines lines, over the ${CAP}-line cap — move detail into docs/learnings/."
    fi
fi

# 2. INDEX.md and the learning files are in exact bijection.
if [ ! -f "$INDEX" ]; then
    err "$INDEX is missing."
else
    while IFS= read -r f; do
        base="$(basename "$f")"
        n="$(grep -cF "]($base)" "$INDEX" || true)"
        if [ "$n" -ne 1 ]; then
            err "docs/learnings/$base has $n index entries in INDEX.md, expected exactly 1."
        fi
    done < <(find "$LEARNINGS" -maxdepth 1 -name '*.md' ! -name 'INDEX.md' | sort)

    while IFS= read -r target; do
        [ -f "$LEARNINGS/$target" ] \
            || err "INDEX.md points at missing file: $target"
    done < <(grep -oE '\]\([^)]+\.md\)' "$INDEX" | sed -E 's/^\]\(//; s/\)$//' | sort -u)
fi

# 3. Every open agent:eligible issue carries the three required sections.
if ! command -v gh >/dev/null 2>&1; then
    echo "skip - gh not installed; agent:eligible issue format not checked"
elif ! gh auth status >/dev/null 2>&1; then
    echo "skip - gh not authenticated; agent:eligible issue format not checked"
else
    for n in $(gh issue list --label agent:eligible --state open \
                   --json number --jq '.[].number'); do
        body="$(gh issue view "$n" --json body --jq .body)"
        for heading in 'Definition of done' 'Verification' 'Provenance'; do
            section="$(printf '%s\n' "$body" | awk -v h="## $heading" '
                $0 == h { inside = 1; next }
                inside && /^## / { exit }
                inside { print }
            ')"
            if [ -z "$(printf '%s' "$section" | tr -d '[:space:]')" ]; then
                err "issue #$n is agent:eligible but has no content under '## $heading'."
            fi
        done
    done
fi

exit "$status"
```

- [ ] **Step 4: Run the self-test to verify it passes**

```bash
chmod +x Scripts/check-substrate.sh
Scripts/test-check-substrate.sh
```

Expected: eight `ok - ` lines then `All check-substrate tests passed.`

- [ ] **Step 5: Run the guard against the real repository**

Run: `Scripts/check-substrate.sh`
Expected: exit 0. It prints nothing except an issue-check line — `skip - ` if
you have no `gh` auth, or silence if you do and no `agent:eligible` issues exist
yet (there are none until Task 6).

- [ ] **Step 6: Wire both into CI**

In `.github/workflows/ci.yml`, replace the `permissions` block:

```yaml
# The build needs only the repo. check-substrate.sh additionally reads open
# issues to verify their format; without issues:read it degrades to a skip
# rather than a failure, but then the format goes unenforced.
permissions:
  contents: read
  issues: read
```

and extend the existing "Verify the build-script helpers" step:

```yaml
      - name: Verify the build-script helpers
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          Scripts/test-engine-fingerprint.sh
          Scripts/test-check-engine-fresh.sh
          Scripts/test-release-args.sh
          Scripts/test-check-substrate.sh
          Scripts/check-substrate.sh
```

- [ ] **Step 7: Commit**

```bash
git add Scripts/check-substrate.sh Scripts/test-check-substrate.sh .github/workflows/ci.yml
git commit -m "build: add check-substrate.sh and run it in CI

Asserts CLAUDE.md stays under its line cap, that docs/learnings/ and its index
stay in bijection, and that every agent:eligible issue states a definition of
done, a verification command, and its provenance. The issue check skips
cleanly without a token so CI never fails for a missing one."
```

---

### Task 3: Learnings — engine, SDL, and build traps

Four more learning files covering the engine-side traps. Every fact below is
transcription from `.superpowers/sdd/progress.md` and the per-user memory store,
not new research.

**Files:**
- Create: `docs/learnings/sdl-main-ready-and-sigterm.md`
- Create: `docs/learnings/orientation-needs-both-halves.md`
- Create: `docs/learnings/engine-console-output-is-invisible.md`
- Create: `docs/learnings/soft-keyboard-keydown-keyup-pairing.md`
- Modify: `docs/learnings/INDEX.md`

**Interfaces:**
- Consumes: the index format and guard from Tasks 1–2.
- Produces: nothing later tasks call. Validated by `Scripts/check-substrate.sh`.

- [ ] **Step 1: Write `docs/learnings/sdl-main-ready-and-sigterm.md`**

```markdown
# SDL startup and signal handling inside the SwiftUI-owned app

Two non-negotiables for hosting the engine under a SwiftUI app that owns the
process:

- **`SDL_SetMainReady()` must be called before the first `SDL_Init`.** SDL's
  normal entry point is bypassed when SwiftUI owns `main`, and without this call
  initialisation fails in ways that do not name the cause.
- **`SIGTERM` is `SIG_IGN`'d for the duration of an engine session.**
  `xcodebuild` sends stray `SIGTERM`s that SDL converts into quit events, which
  ends the session mid-test and looks like an engine crash.

**Provenance:** Plan 1 Task 8 (SwiftUI-owned architecture) and Task 10, where
the stray-`SIGTERM` behaviour was root-caused after it presented as random test
kills.
```

- [ ] **Step 2: Write `docs/learnings/orientation-needs-both-halves.md`**

```markdown
# Orientation support needs both halves, or it silently does nothing

Supporting rotation requires **both**:

1. The orientation entries in `Info.plist`, and
2. `SDL_HINT_ORIENTATIONS` set in `woof_ios.c`.

With the plist alone everything *looks* correct and rotation is silently
ignored: SDL's `UIKit_GetSupportedOrientations` falls back to the game window's
aspect ratio, and because that window is non-resizable and landscape, every
session is pinned to landscape.

**Provenance:** Plan 4 Task 7b, commit `a9acd51`. The plist-only version was
believed correct until the hint was found by reading SDL's source.
```

- [ ] **Step 3: Write `docs/learnings/engine-console-output-is-invisible.md`**

```markdown
# Engine console output does not reach `log stream`

The engine's diagnostics are `fprintf`-based, so they never enter the unified
logging system. `log stream` shows nothing no matter how the filters are set,
which reads as "the engine printed nothing" when it printed plenty.

**What to do instead:** export stdout from the `.xcresult` bundle, or launch
with `simctl launch --console-pty`.

**Provenance:** Plan 1 diagnosis, after time was lost assuming silence meant
the engine had not reached the failing code.
```

- [ ] **Step 4: Write `docs/learnings/soft-keyboard-keydown-keyup-pairing.md`**

```markdown
# Every injected keydown must be paired with a keyup

`WoofIOS_InjectChar` posts `ev_keydown`, then `ev_text`, then `ev_keyup`. The
final keyup is not optional: an unconsumed cheat letter whose keyup never
arrives latches in `gamekeydown[]`, and the player then walks in that direction
forever with no visible cause.

Injection is gated by `WoofIOS_GetTextInputContext`, which returns
`GAMEPLAY`, `SAVENAME`, or `NONE`. Each inject function context-guards
individually — characters are dropped in `NONE`, and backspace/confirm are
honoured only in `SAVENAME` — because the context is polled at 0.25s and a
naive single check races against it.

**Provenance:** PR #7 (soft keyboard), merged as `4e6868e`. The latching bug was
found on device via `iddqd`.
```

- [ ] **Step 5: Add four entries to `docs/learnings/INDEX.md`**

Append below the existing two entries:

```markdown
- [SDL startup and signal handling inside the SwiftUI-owned app](sdl-main-ready-and-sigterm.md) — SDL_SetMainReady and the SIGTERM bracket
- [Orientation support needs both halves, or it silently does nothing](orientation-needs-both-halves.md) — Info.plist *and* SDL_HINT_ORIENTATIONS
- [Engine console output does not reach `log stream`](engine-console-output-is-invisible.md) — use xcresult stdout or --console-pty
- [Every injected keydown must be paired with a keyup](soft-keyboard-keydown-keyup-pairing.md) — or cheat letters latch and the player walks forever
```

- [ ] **Step 6: Run the guard**

Run: `Scripts/check-substrate.sh`
Expected: exit 0. If it reports `has 0 index entries`, an index line is missing
or its filename does not match.

- [ ] **Step 7: Commit**

```bash
git add docs/learnings/
git commit -m "docs(learnings): record the engine, SDL, and input traps

SDL_SetMainReady and the SIGTERM bracket, the two halves orientation support
needs, why engine output never reaches log stream, and the keydown/keyup
pairing that stops cheat letters latching."
```

---

### Task 4: Learnings — iOS, UIKit, and tooling traps

The remaining six learning files, plus pruning the facts that are now duplicated
in the per-user memory store.

**Files:**
- Create: `docs/learnings/ios26-tabview-accessibility.md`
- Create: `docs/learnings/ios26-list-swipe-actions-row-height.md`
- Create: `docs/learnings/swiftui-menu-cannot-host-sliders.md`
- Create: `docs/learnings/sdl-window-gesture-recognizers.md`
- Create: `docs/learnings/worktree-setup-traps.md`
- Create: `docs/learnings/simulator-test-hazards.md`
- Modify: `docs/learnings/INDEX.md`
- Modify: `doom-ios-project-facts.md` in the per-user memory store
- Modify: `MEMORY.md` in the per-user memory store

**Interfaces:**
- Consumes: the index format and guard from Tasks 1–2.
- Produces: nothing later tasks call.

- [ ] **Step 1: Write `docs/learnings/ios26-tabview-accessibility.md`**

```markdown
# iOS 26 TabView tab-bar buttons ignore accessibility identifiers

Setting `.accessibilityIdentifier` on a `TabView` tab never reaches the rendered
tab-bar button, so UI tests cannot address tabs the usual way.

**What to do instead:**

- Switch tabs by label: `app.tabBars.buttons["Play"]`, `app.tabBars.buttons["Library"]`.
- Assert the resulting pane by identifier: `app.otherElements["playTab"]`,
  `app.otherElements["libraryTab"]`.
- The add-PWAD menu is `app.buttons["addPWADMenu"].tap()` followed by
  `addPWADButton-<display>`.

**Provenance:** Plan 2 Task 8, recorded as the explicit UI-test contract for
Task 9.
```

- [ ] **Step 2: Write `docs/learnings/ios26-list-swipe-actions-row-height.md`**

```markdown
# iOS 26 List swipe actions change shape with row height

Swipe-action rendering is driven by **row height**, not by any modifier:

- A single-line row gets a full-height red capsule with "🗑 Delete" inside it.
- A taller row — LibraryView's two-line row at roughly 66pt — gets a fixed-size
  red icon button with the "Delete" caption *below and outside* the red.

The second looks like a clipped background but is the system idiom; the Files
app renders identically.

Stripping `.accessibilityElement(children: .combine)`, `.contextMenu`, and
`.deleteDisabled` changes nothing — this was bisected empirically on 2026-07-31.
The only escape hatch is an explicit `.swipeActions` whose button label is
text-only (`Button("Delete", role: .destructive)`), which restores the
full-height capsule even on a tall row; `Label("Delete", systemImage: "trash")`
renders the same as `.onDelete`.

**Decision:** keep the stock look. Do not re-investigate.
```

- [ ] **Step 3: Write `docs/learnings/swiftui-menu-cannot-host-sliders.md`**

```markdown
# SwiftUI `Menu` cannot render `Slider` rows

`UIMenu` has no slider element, so a `Slider` placed in a `Menu` silently fails
to appear. This is a UIKit limitation surfacing through SwiftUI, not a layout
bug to be worked around.

**What to do instead:** the touch-tuning sliders live in the Control Feel sheet
(`ControlFeelView`), opened from the gear menu.

**Provenance:** PR #3 (touch tuning), where the sliders were first attempted
inside the gear `Menu`.
```

- [ ] **Step 4: Write `docs/learnings/sdl-window-gesture-recognizers.md`**

```markdown
# Gesture recognizers do not fire inside SDL's own UIWindow

A `UITapGestureRecognizer` attached to the touch overlay reaches `.recognized`
but its target-action **never runs**. KVO-diagnosed: no UIViewController-hosted
scene backs SDL's directly-owned `UIWindow`, and the action dispatch depends on
one.

Plain responder-chain delivery — `touchesBegan` / `touchesMoved` /
`touchesEnded` — works normally.

**What to do instead:** implement gestures by counting touches in the responder
callbacks. The four-finger soft-keyboard tap is done this way, not with a
recognizer. This applies to any future gesture work on that overlay.

**Provenance:** soft-keyboard branch, 2026-07-21.
```

- [ ] **Step 5: Write `docs/learnings/worktree-setup-traps.md`**

```markdown
# Setting up a second worktree has two traps

Setup is: symlink `Vendor` and `App/Resources/GameData` from the primary
checkout, copy `woof.pk3`, then run `Scripts/generate-build-info.sh` and
`xcodegen`.

**Trap 1 — `.gitignore` does not hide a `Vendor` symlink.** The `Vendor/`
pattern does not match a symlink, because trailing-slash patterns do not match
symlinks. Hide it through
`$(git rev-parse --git-common-dir)/info/exclude` — note *common*-dir: the
per-worktree git dir has no `info/` and its exclude file is never read.

**Trap 2 — the copied `Vendor/build` cache points at the other checkout.** A
fresh worktree inherits gitignored `Vendor/build/` containing `CMakeCache.txt`
files with the *primary* checkout's path hardcoded, and `mise run build-engine`
then fails. Fix: `rm -rf Vendor/build` and rebuild. Confirm first that it is not
a symlink to the other worktree.

**Provenance:** touch-tuning worktree 2026-07-18 (trap 1), soft-keyboard
worktree 2026-07-21 (trap 2).
```

- [ ] **Step 6: Write `docs/learnings/simulator-test-hazards.md`**

```markdown
# Simulator hazards that produce misleading test results

*(The rule against two concurrent `xcodebuild` sessions on one simulator lives
in `CLAUDE.md` — it applies to every run, not just these cases.)*

- **The iPhone 17 Pro simulator never rotates its interface** under
  `XCUIDevice.shared.orientation`, caused by a stale
  `SimulatorWindowOrientation=LandscapeRight` in the
  `com.apple.iphonesimulator` prefs. iPhone 17 Pro Max works.
  `testSessionSurvivesRotation` carries a launcher-probe `XCTSkip` guard for
  such simulators.
- **`XCUIScreen` screenshots of a landscape interface arrive sideways** in a
  portrait buffer. `Scripts/capture-screenshots.sh` compensates; anything new
  that captures screenshots must too.
- **`RealWADTests` needs `Scripts/provision-test-wads.sh`** run after app
  install, plus the WADs in `~/Downloads/doom-test-wads/`. Without them that one
  test class fails and nothing else does — a failure there usually means missing
  fixtures, not a regression.

**Provenance:** Plan 2 Task 9, Plan 3 Task 6, and the Plan 4 screenshot work.
```

- [ ] **Step 7: Add six entries to `docs/learnings/INDEX.md`**

```markdown
- [iOS 26 TabView tab-bar buttons ignore accessibility identifiers](ios26-tabview-accessibility.md) — address tabs by label, panes by identifier
- [iOS 26 List swipe actions change shape with row height](ios26-list-swipe-actions-row-height.md) — the stock idiom, already bisected; do not re-investigate
- [SwiftUI `Menu` cannot render `Slider` rows](swiftui-menu-cannot-host-sliders.md) — why tuning lives in the Control Feel sheet
- [Gesture recognizers do not fire inside SDL's own UIWindow](sdl-window-gesture-recognizers.md) — use responder-chain touches instead
- [Setting up a second worktree has two traps](worktree-setup-traps.md) — the Vendor symlink and the stale CMakeCache
- [Simulator hazards that produce misleading test results](simulator-test-hazards.md) — rotation, screenshot orientation, and RealWADTests fixtures
```

- [ ] **Step 8: Run the guard**

Run: `Scripts/check-substrate.sh`
Expected: exit 0, with twelve learning files in bijection with the index.

- [ ] **Step 9: Prune the migrated facts from the per-user memory store**

The spec requires migration, not duplication — a fact held in both places
eventually disagrees with itself.

Edit `doom-ios-project-facts.md` in the per-user memory store
and delete the bullets now covered by `docs/learnings/`: the Woof pin and save
flag, `SDL_SetMainReady`/SIGTERM, engine console output, the TabView UI-test
contract, orientation's two halves, the simulator rotation and screenshot
hazards, the `Menu`/`Slider` limitation, the gesture-recognizer finding, the
worktree traps, the List swipe-action bisection, and the keydown/keyup pairing.

Keep what is genuinely not repo-technical: repository and bundle identifiers,
merge and PR status, App Store submission state, the 1Password signing
behaviour, and the location of the test WADs.

Replace the deleted content with one pointer line:

```markdown
- Repo-technical traps now live in the repository at `docs/learnings/` (indexed in `docs/learnings/INDEX.md`) — read those, not this file, for engine/SDL/UIKit/tooling specifics.
```

Then update the `MEMORY.md` hook for that entry to say the same, so the index
does not advertise content the file no longer holds.

- [ ] **Step 10: Commit**

```bash
git add docs/learnings/
git commit -m "docs(learnings): record the iOS, UIKit, and tooling traps

TabView accessibility identifiers, List swipe-action row-height behaviour, the
Menu/Slider limitation, gesture recognizers in SDL's window, the two worktree
setup traps, and the simulator hazards that produce misleading results."
```

---

### Task 5: Labels and the issue template

Backlog scaffolding, so Task 6 has somewhere to put its output.

**Files:**
- Create: `.github/ISSUE_TEMPLATE/agent-eligible.md`
- No source changes; labels are created through `gh`.

**Interfaces:**
- Consumes: nothing.
- Produces: the labels `agent:eligible`, `agent:blocked`, `test`, `chore`,
  `deps`, `size:xs`, `size:s`, `size:m`, and the three-heading issue body format
  that `Scripts/check-substrate.sh` check 3 validates.

- [ ] **Step 1: Create the labels**

The repository already has `bug`, `documentation`, `enhancement`,
`dependencies`, and the GitHub defaults. These extend rather than replace them.
`--force` makes the step re-runnable.

```bash
gh label create "agent:eligible" --color "0e8a16" --force \
  --description "May be claimed by an unattended run"
gh label create "agent:blocked"  --color "b60205" --force \
  --description "Needs a human; reason stated in the issue"
gh label create "test"           --color "fbca04" --force \
  --description "Test coverage or test infrastructure"
gh label create "chore"          --color "cfd3d7" --force \
  --description "Maintenance with no user-visible change"
gh label create "deps"           --color "0366d6" --force \
  --description "Dependency or toolchain bump needing code changes"
gh label create "size:xs"        --color "c2e0c6" --force \
  --description "One file plus one test"
gh label create "size:s"         --color "c2e0c6" --force \
  --description "One module, no cross-cutting change"
gh label create "size:m"         --color "c2e0c6" --force \
  --description "Crosses Engine/, or touches multiple modules"
```

- [ ] **Step 2: Verify the labels exist**

Run: `gh label list --limit 40 | grep -E 'agent:|size:|^test|^chore|^deps'`
Expected: eight lines.

- [ ] **Step 3: Write `.github/ISSUE_TEMPLATE/agent-eligible.md`**

```markdown
---
name: Agent-eligible task
about: A self-contained task an unattended run may claim
labels: ["agent:eligible"]
---

<!--
All three sections below are required and must be non-empty --
Scripts/check-substrate.sh fails CI otherwise. Add a kind label (bug,
enhancement, documentation, test, chore, deps) and a size label
(size:xs, size:s, size:m).

Size is an estimate. If the work turns out larger or smaller, correct the
label when the PR lands rather than leaving it wrong -- the labels are what
make separate pieces of work comparable to each other.
-->

## Definition of done

<!-- One sentence naming the condition that must become true. Name the observable
     change, not the activity: "ZipExtractor rejects any entry whose uncompressed
     size exceeds the cap, and a test proves it" -- not "fix the size cap". -->

## Verification

<!-- The exact command that demonstrates it. -->

```
mise run test
```

## Provenance

<!-- Where this came from: the plan, review, or PR that deferred it. -->
```

- [ ] **Step 4: Confirm the template does not break the guard**

Run: `Scripts/check-substrate.sh`
Expected: exit 0. The template is a file on disk, not an issue, so check 3 does
not see it — this confirms the guard is not over-reaching.

- [ ] **Step 5: Commit**

```bash
git add .github/ISSUE_TEMPLATE/agent-eligible.md
git commit -m "build: add the agent-eligible issue template

Ships the three headings check-substrate.sh requires, so a hand-filed issue
starts in the right shape. Labels were created through gh and are not tracked
in the repository."
```

---

### Task 6: Triage the Plan 1 and Plan 2 ledger candidates

The first of three extraction passes. Each produces GitHub issues **and** a
tracked triage record, so the extraction itself is reviewable — a reviewer
cannot otherwise tell a considered "already fixed" from an overlooked item.

**Files:**
- Create: `docs/superpowers/plans/2026-08-06-agent-substrate-triage.md`
- Read only: `.superpowers/sdd/progress.md` (gitignored; never modified)

**Interfaces:**
- Consumes: labels and the body format from Task 5.
- Produces: `docs/superpowers/plans/2026-08-06-agent-substrate-triage.md`, a
  table Tasks 7 and 8 append to. Columns: `Candidate | Origin | Disposition | Note`.
  Disposition is one of `issue #N`, `already fixed`, `unreproducible`, `won't fix`, `blocked #N`.

- [ ] **Step 1: Create the triage record with its header and the Plan 1 rows pending**

```markdown
# Ledger triage record

Extraction of `.superpowers/sdd/progress.md` into GitHub issues, per
`docs/superpowers/specs/2026-08-06-agent-substrate-design.md`. That ledger is
gitignored and exists on one machine; this file is the durable account of what
was in it and what happened to each item.

Every candidate was checked against current code before classification.
"Unreproducible" means the described condition could not be found at HEAD — the
spec prefers recording that over filing on suspicion.

| Candidate | Origin | Disposition | Note |
| --- | --- | --- | --- |
```

- [ ] **Step 2: Triage the Plan 1 candidates**

For each of the twelve below: locate the referenced code (`grep -rn` the named
symbol under `Engine/` or `Scripts/`), decide the disposition, and append a row.

1. `libSDL3_test.a` installed despite `SDL_TESTS=OFF` — Plan 1 Task 4
2. `woof_ios.c` cross-thread `I_Error` longjmp UB (theoretical) — Plan 1 Task 5
3. `i_system.c` `errmsg` `strcat` accumulates across sessions — Plan 1 Task 5
4. `src/CMakeLists.txt` one-char whitespace drift from pristine — Plan 1 Task 5
5. `fetch-freedoom.sh` dead `-z EXPECTED_HASH` branch under `pipefail` — Plan 1 Task 7
6. `COPYING*` find last-write-wins — Plan 1 Task 7
7. `memset` `sa_mask` instead of `sigemptyset` — Plan 1 Task 10
8. Unreachable `return 0` path skips SIGTERM restore — Plan 1 Task 10
9. `AddWadInMem` data buffer leak (unreachable) — Plan 1 Task 10
10. `M_LoadDefaults` `strdup` leak (pre-existing) — Plan 1 Task 10
11. Autoquit timer session-scoping — Plan 1 final review
12. `I_AtSignal` per-session growth — Plan 1 final review

- [ ] **Step 3: Triage the Plan 2 candidates**

Same procedure for these thirteen. Note that several were closed by later plans
— item 13's size cap was implemented during Plan 3, so expect `already fixed`
there while its two follow-ups remain open.

13. `ZipExtractor` per-entry size cap — Plan 2 Task 4
14. No direct `sha1(of:)` / `.unreadable` tests — Plan 2 Task 3
15. `allLoadouts` sort ordering has no direct test — Plan 2 Task 5
16. Bundled pseudo-hash means user-imported Freedoom copies do not dedupe — Plan 2 Task 5
17. `adoptLooseFiles` reject-check is post-hoc by basename — Plan 2 Task 6
18. Two `LoadoutArguments` tests leave `Saves/<uuid>` litter — Plan 2 Task 7
19. Preset-editor create-error swallowed by `try?` — Plan 2 Task 8
20. `LibraryView` multi-delete last-blocked-list only (dead code today) — Plan 2 Task 8
21. `fatalError` on container init — Plan 2 Task 8
22. `testWrongIWADPairingFailsSoft` name no longer matches its scenario — Plan 2 Task 9
23. Mixed-result zips delete rejected members — Plan 2 final review
24. Share-sheet import gives no UI feedback / no `LibraryView` refresh — Plan 2 final review
25. `guard` vs `precondition` on `EngineSession.play` — Plan 2 final review

- [ ] **Step 4: File an issue for each still-valid candidate**

Use this shape. `--body-file -` avoids quoting problems with multi-line bodies.

```bash
gh issue create \
  --title "ZipExtractor: no per-entry uncompressed size cap" \
  --label "agent:eligible" --label "bug" --label "size:s" \
  --body-file - <<'EOF'
## Definition of done

ZipExtractor rejects any entry whose uncompressed size exceeds the cap, and a
test proves both the reject path and that a normal archive still extracts.

## Verification

```
xcodebuild -project App/WADdle.xcodeproj -scheme WADdle \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:WADdleTests test
```

## Provenance

Plan 2 Task 4 review, deferred as a minor: flagged as a zip-bomb and
storage-exhaustion vector.
EOF
```

Anything on the never-eligible list — physical device, App Store Connect,
screenshots and metadata, engine vendor re-pins, signing or release — gets
`agent:blocked` instead of `agent:eligible`, with the reason as the first line
of the body. Blocked issues do not need the three headings; the guard only
inspects `agent:eligible` ones.

- [ ] **Step 5: Record every disposition**

Append one row per candidate. Example rows:

```markdown
| ZipExtractor per-entry size cap | P2 T4 | already fixed | Implemented during Plan 3 Task 7; cap present at `ZipExtractor.swift`. |
| No end-to-end oversize-only-zip test | P2 T4 | issue #41 | Follow-up to the cap above. |
| `src/CMakeLists.txt` whitespace drift | P1 T5 | won't fix | One character; re-vendoring would reintroduce it. |
| `AddWadInMem` data buffer leak | P1 T10 | unreproducible | Path not present at HEAD. |
```

- [ ] **Step 6: Run the guard against the newly filed issues**

Run: `Scripts/check-substrate.sh`
Expected: exit 0. Any issue missing a heading is reported by number — fix the
issue body on GitHub and re-run. This is the first run where check 3 does real
work.

- [ ] **Step 7: Commit**

```bash
git add docs/superpowers/plans/2026-08-06-agent-substrate-triage.md
git commit -m "docs: triage the Plan 1 and Plan 2 ledger candidates

Twenty-five candidates checked against current code and extracted into issues.
The record captures every disposition, including already-fixed and
unreproducible, since the source ledger is gitignored and single-machine."
```

---

### Task 7: Triage the Plan 3 ledger candidates

**Files:**
- Modify: `docs/superpowers/plans/2026-08-06-agent-substrate-triage.md`

**Interfaces:**
- Consumes: the triage record and column format from Task 6.
- Produces: additional rows in the same table.

- [ ] **Step 1: Triage these thirteen candidates**

Same procedure as Task 6 — locate, decide, file, record.

1. `beginSessionForTesting` not `#if DEBUG` gated — P3 T3
2. `weaponPrevButton` sits inside the stick region; a near-miss starts a stick track — P3 T4
3. `OverlayButton` square hit area versus circular visual — P3 T4
4. Unused-code warning at `ContentView:46` — P3 T6 hygiene
5. `FORCE_TOUCH_OVERLAY` needs a one-line "test-only" note — P3 T6 hygiene
6. `Task.detached` not under `.task` cancellation — P3 T7
7. No end-to-end oversize-only-zip `ImportService` test — P3 T7
8. `UInt64(maxEntryBytes)` traps if a negative value is injected — P3 T7
9. `touch_event_count` not reset across sessions — P3 T1 forward note
10. Hardcoded "512 MB" string — P3 final review
11. Per-axis/button debug getters so tests can assert *which* control was driven — P3 post-PR
12. `TouchButton.east` dead code — P3 post-PR
13. `TouchOverlayView` dead default parameter — P3 post-PR

Deadzone stacking and turn feel are **not** candidates: they require on-device
tuning, so they are `agent:blocked` with "needs physical device" as the reason.

- [ ] **Step 2: Run the guard**

Run: `Scripts/check-substrate.sh`
Expected: exit 0.

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/plans/2026-08-06-agent-substrate-triage.md
git commit -m "docs: triage the Plan 3 ledger candidates

Thirteen input and touch-overlay candidates extracted. On-device tuning items
are recorded as agent:blocked rather than filed as eligible work."
```

---

### Task 8: Triage the Plan 4 candidates and label the existing open issues

The final pass. Also brings the four issues that already exist into the taxonomy
so the backlog is uniform.

**Files:**
- Modify: `docs/superpowers/plans/2026-08-06-agent-substrate-triage.md`
- Modify: `README.md` (a pointer to `CLAUDE.md` and `docs/learnings/`)

**Interfaces:**
- Consumes: the triage record from Tasks 6–7.
- Produces: the complete backlog. After this task
  `gh issue list --label agent:eligible` is the sole entry point Spec 2 consumes.

- [ ] **Step 1: Triage these seven candidates**

1. `suggestedIWAD` doc comment omits the most-recent tie-break — P4 T3
2. `metadata.md:190` stale "landscape-only" phrase — P4 T7b
3. Overlay fixed-pixel layout unverified below ~573×545 iPad windows, no min-size guard — P4 T7b
4. Mixed-zip rejected-member edge — P4 final review
5. Preset-editor `try?` swallow — P4 final review *(may duplicate Task 6 candidate 19; if so record it as a duplicate rather than filing twice)*
6. Container-init recovery — P4 final review
7. Case-sensitive IWAD hint branch, cosmetic — P4 final review

- [ ] **Step 2: Label the four existing open issues**

```bash
gh issue edit 13 --add-label "agent:eligible" --add-label "size:xs"
gh issue edit 14 --add-label "agent:eligible" --add-label "chore" --add-label "size:s"
gh issue edit 15 --add-label "agent:eligible" --add-label "size:xs"
gh issue edit 28 --add-label "agent:blocked"
```

Issues 13, 14, and 15 then need the three headings added to their bodies —
`gh issue edit <n> --body-file -` — or check 3 fails. Issue 28 is App Store
Connect work, owner-only by construction, so it is blocked and needs no
headings. Renovate's dashboard (#19) is a bot-managed issue and gets no labels.

- [ ] **Step 3: Add a pointer to `README.md`**

Insert after the opening description, before `## Licensing`:

```markdown
## Working in this repository

`CLAUDE.md` carries the rules that apply to every change. `docs/learnings/`
records the traps this project has already paid for — read
[its index](docs/learnings/INDEX.md) before debugging anything that feels like
it should already work.
```

- [ ] **Step 4: Run the full CI-equivalent gate locally**

```bash
Scripts/test-engine-fingerprint.sh
Scripts/test-check-engine-fresh.sh
Scripts/test-release-args.sh
Scripts/test-check-substrate.sh
Scripts/check-substrate.sh
```

Expected: all pass, `check-substrate.sh` exits 0 with no `error:` lines.

- [ ] **Step 5: Verify the spec's definition of done**

```bash
gh issue list --label agent:eligible --state open
```

Expected: a non-empty list. Open two at random and confirm each is actionable by
someone with no prior context — a stated definition of done, a runnable
verification command, and provenance.

- [ ] **Step 6: Commit and open the PR**

```bash
git add docs/superpowers/plans/2026-08-06-agent-substrate-triage.md README.md
git commit -m "docs: triage the Plan 4 candidates and label the open issues

Completes the ledger extraction. The four pre-existing issues join the
taxonomy, and README points at CLAUDE.md and the learnings index."

git push -u origin tylervick/agent-substrate-spec
gh pr create --fill
```

---

## Verification

The spec's definition of done, checked at the end of Task 8:

- A fresh clone plus `gh issue list --label agent:eligible` yields a non-empty
  list of items each independently actionable by someone with no prior context.
- `Scripts/check-substrate.sh` passes in CI.

## Notes for the implementer

**Triage is the expensive part and the easiest to rush.** Reproducing ~45
candidates against current code is slower than transcribing them, and
transcription produces a backlog that looks healthy and is partly fiction — the
first thing an unattended loop would then do is chase ghosts. `unreproducible`
and `already fixed` are correct, valuable outcomes. The goal is a true backlog,
not a large one.

**The candidate count exceeds the spec's estimate.** The spec says "roughly 25";
enumerating Plans 1–4 yields about 45 candidates, many of which will resolve to
already-fixed. That is a counting difference, not a scope change — the spec's
estimate was drawn from a grep of lines mentioning deferrals, and several lines
carry more than one item.

**`.superpowers/sdd/progress.md` is read-only here.** It stays gitignored; the
triage record is what makes the extraction durable.
