# CI Build & Test Workflows — Design Spec

**Date:** 2026-07-28
**Status:** Implemented in PR #11 (2026-07-28)
**Branch:** `tylervick/CI-build-scripts`

## Problem

The repo has no CI. There is no `.github/` directory at the root, no workflow
registered on `tylervick/waddle`, and no run history. (The
`.github/workflows/*.yml` files under `Engine/woof/` and `Vendor/src/SDL/` are
vendored upstream copies; GitHub only reads workflows at the repo root, so
they are inert.)

Nothing verifies that a change compiles or that the unit tests pass before it
lands on `main`. For a public repo that expects outside clones, nothing
verifies that a from-scratch build still works either.

Two properties make this cheaper to fix than a typical iOS repo:

- **The build is already fully scripted and non-interactive.**
  `build-deps.sh`, `build-engine.sh`, `fetch-freedoom.sh`,
  `generate-build-info.sh`, `archive.sh`, and `upload.sh` all run headless,
  and `upload.sh` already authenticates with an App Store Connect API key
  rather than an Apple ID. The workflows are thin wrappers over existing
  scripts, not a reimplementation.
- **`tylervick/waddle` is public**, so standard GitHub-hosted macOS runners
  are free and unmetered under the 2026 Actions pricing. The 10x macOS
  multiplier does not apply. The only relevant cap is 5 concurrent macOS jobs
  on the Free plan.

## Scope

This spec covers the first of two PRs.

**In scope (PR 1):** `ci.yml`, `ui-tests.yml`, a shared composite setup
action, content-hash cache keys, and replacing `archive.sh`'s mtime-based
stale-engine guard with a content fingerprint.

**Follow-up (PR 2):** `testflight.yml` — archive, export, and upload to
TestFlight. It reuses the composite action from this PR, which is what keeps
it small.

**Explicitly deferred, not forgotten:** a scheduled cold-cache build that
ignores caches and builds deps + engine from scratch (would catch a break in
`build-deps.sh` / `build-engine.sh` within a week rather than whenever
someone next clones cold), and a README CI section with a status badge.

**Out of scope:** App Store submission. The submission checklist is almost
entirely App Store Connect forms and questionnaires with no API-driven
equivalent worth automating, and the project is not ready to submit.

## Runner environment

`macos-26` (arm64), which went GA in February 2026.

- Ships Xcode 26.0.1 through 26.6; default is 26.5. This project requires
  26.2+, and **26.2 is present on the image**, which is what we pin to.
- iOS simulator runtimes 26.2, 26.4, and 26.5 are installed. `iPhone 17 Pro`
  is a provisioned device, so `mise.toml`'s existing destination string works
  as-is.
- `cmake` and `ninja` are pre-installed but at versions other than the ones
  `mise.toml` pins. `xcodegen` is not installed at all.

**Toolchain decision:** pin Xcode to 26.2 via `xcode-select`, and provision
`cmake` / `ninja` / `xcodegen` through `mise` so `mise.toml` remains the
single source of truth for tool versions. This costs 1–2 minutes of cacheable
setup and buys exact parity with the development machine — a red build then
means a real problem rather than toolchain drift.

## Architecture

```
.github/
  actions/setup-waddle-build/action.yml   # shared preamble + caching
  workflows/ci.yml                        # pull_request + push to main
  workflows/ui-tests.yml                  # workflow_dispatch only
Scripts/engine-fingerprint.sh             # NEW — content hash
```

Both workflows need the same preamble: pin Xcode, install mise tools, restore
the engine cache, and only on a MISS restore the deps cache and build deps and
the engine — an engine-cache hit skips the deps cache and build-deps.sh
entirely, since build-engine.sh is what merges libSDL3.a and libopenal.a into
libWoofEngine.a and the Xcode project links only the xcframework, never
`Vendor/out/iphoneos`/`iphonesimulator` directly. Then fetch Freedoom, seed
build info, run `xcodegen`. That is roughly fifty lines.

A **composite action** shares it. Composite actions run inside the caller's
job, so caching and the filesystem behave normally. The alternatives were
rejected: duplicating the steps would copy the cache-key logic three times
once PR 2 lands, and divergence between copies is precisely the bug that
silently tests against a stale engine; a reusable workflow (`workflow_call`)
runs as a separate job, which would mean shuttling build outputs around as
artifacts rather than sharing a working directory.

## `Scripts/engine-fingerprint.sh`

The load-bearing new piece. It prints one SHA-256 covering the working-tree
content of `Engine/woof/`, `Scripts/build-engine.sh`, and
`Scripts/build-deps.sh`.

Requirements:

- **Path-independent.** Hash relative paths from the repo root, not absolute
  paths, so the value is stable across worktrees, clones, and the CI
  checkout directory.
- **Order-independent.** Sort the file list under `LC_ALL=C` so the result
  does not depend on filesystem enumeration order.
- **Working-tree based**, not `git`-object based. It must reflect uncommitted
  edits, because catching "I edited engine source and did not rebuild"
  locally is the guard's whole purpose.

Three consumers share this one mechanism:

1. `build-engine.sh` writes the value to
   `Vendor/out/WoofEngine.xcframework.fingerprint` after a successful build.
2. `archive.sh` recomputes it and compares against the stored stamp,
   replacing the `find -newer` mtime scan. A mismatch, a missing stamp, or a
   failure to compute the fingerprint at all must fail closed with the same
   rebuild guidance the current guard prints.
3. CI uses it as the engine cache key.

This is strictly better than the mtime guard in two ways. It no longer
false-positives when a fresh worktree or a cache restore reorders mtimes
relative to the built framework — the failure already hit locally and worked
around with `touch`. And it widens coverage from `Engine/woof/src` to all of
`Engine/woof`, so edits to the vendored `CMakeLists.txt` or `third-party/`
now invalidate; under the mtime scan those were invisible.

Hashing all of `Engine/woof` (rather than just `src`) will occasionally
invalidate on changes to vendored docs or CI files. That is an acceptable
trade for correctness: the vendored tree only changes when the engine pin is
updated, which is rare and already a deliberate, documented operation.

## Caching

Two caches. Both are small — 20 MB and 19 MB against a 10 GB per-repo budget.

| Cache | Contents | Key |
|---|---|---|
| deps | `Vendor/out/iphoneos`, `Vendor/out/iphonesimulator` | `deps-<xcode>-<hash of build-deps.sh>` |
| engine | `Vendor/out/WoofEngine.xcframework`, `App/Resources/woof.pk3`, `Vendor/out/WoofEngine.xcframework.fingerprint` | `engine-<xcode>-<engine-fingerprint>` |

`<xcode>` is the pinned Xcode version string (`26.2`), sourced from the same
`env:` block the workflows use for the toolchain pin, so a version bump moves
both keys together.

Each build script runs **only on a cache miss**. On a hit, the script is
skipped entirely, so `Vendor/src/` and `Vendor/build/` are never populated and
never need caching.

The Xcode version appears in both keys because it changes compiled output. It
is deliberately **absent from the fingerprint itself**, so that an Xcode
update does not trip `archive.sh`'s guard and force a local 25-minute
rebuild. Cache invalidation is cheap; a false stale-engine error is not.

No fallback `restore-keys` on either cache. A partial or near-miss restore
would produce a framework that does not match its inputs, which is the exact
failure mode this design exists to prevent.

Freedoom stays uncached. It is a 24 MB download, and re-running
`fetch-freedoom.sh` every time also re-exercises its checksum verification.

## `ci.yml`

Triggers on `pull_request` and on `push` to `main`. A `concurrency` group
keyed on the ref with `cancel-in-progress: true` stops superseded PR pushes
from piling up.

One job on `macos-26`, `timeout-minutes: 90` to cover a cold build. It runs
the composite setup action, then unit tests only:

```
xcodebuild -project App/WADdle.xcodeproj -scheme WADdle \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' \
  -only-testing:WADdleTests -resultBundlePath TestResults.xcresult test
```

`-only-testing:WADdleTests` is required because the `WADdle` scheme's test
action includes `WADdleUITests`, which must not run here.

The simulator runtime is pinned to match the pinned Xcode. Both versions live
in a single `env:` block at the top of the workflow so bumping the toolchain
is a one-line edit rather than a search-and-replace.

The `.xcresult` bundle uploads as an artifact on failure, since raw
`xcodebuild` console output is a poor debugging surface.

Expected wall clock: 5–10 minutes warm, 40–60 minutes cold.

## `ui-tests.yml`

`workflow_dispatch` only — no schedule, no PR trigger. Runnable from any
branch on demand.

Inputs:

- `device` — simulator device name, default `iPhone 17 Pro`.
- `only_testing` — optional test filter, so a single class can be run without
  editing YAML.

Same composite setup action, then the full test action with
`-skip-testing:WADdleUITests/RealWADTests`.

`RealWADTests` **cannot** run in CI. It requires Scythe, Sunlust, and
Eviternity II from `~/Downloads/doom-test-wads/` — non-redistributable and
roughly 300 MB. Excluding it is a hard requirement, not a tuning choice.

**Accepted trade-off:** with no schedule, this suite only catches what it is
deliberately pointed at, and it will rot if it goes unrun. The
`workflow_dispatch` inputs make ad-hoc runs cheap, which mitigates but does
not substitute for a schedule. Adding a `schedule:` block later is a
few-line change if that proves to be a problem.

## Verification

`engine-fingerprint.sh` and the `archive.sh` guard are testable locally and
must be verified before the PR opens:

- Fingerprint is stable across two consecutive runs with no edits.
- Fingerprint is identical when computed from two different checkout paths of
  the same content (proves path-independence).
- Fingerprint changes when a file under `Engine/woof/` is edited, and changes
  when `build-deps.sh` or `build-engine.sh` is edited.
- `archive.sh` fails closed with a missing stamp file.
- `archive.sh` fails closed with a stamp that does not match current content.
- `archive.sh` proceeds past the guard when the stamp matches.
- The previously-failing case now passes: a fresh worktree whose
  `Engine/woof/` mtimes are newer than the built framework, but whose content
  is unchanged, no longer trips the guard.

The workflows themselves cannot be verified without pushing. The first PR run
will be cold and slow because Actions caches are branch-scoped and `main` has
no cache to inherit yet.

## Risks

- **UITests on a hosted runner are unproven.** The suite boots a real
  Metal/OpenGL engine session in the simulator. Whether that is stable on a
  hosted runner is unknown until we push. This risk is confined to
  `ui-tests.yml`; `ci.yml`, the PR-blocking workflow, does not boot the
  engine.
- **Cold-build wall clock is an estimate**, extrapolated from ~25 minutes on
  a development machine to a 3-core hosted runner. The 90-minute job timeout
  has generous headroom, and the 6-hour hard limit is not in play.
- **`fetch-freedoom.sh` depends on a GitHub release URL** being reachable at
  build time. An upstream outage breaks CI. Accepted; caching the download
  would trade this for staleness on a pinned, checksum-verified artifact.
