# Learnings Index

One file per hard-won fact. Add an entry here in the same PR that adds the file —
`Scripts/check-substrate.sh` enforces the bijection.

- [The Woof pin is a master commit, not a release tag](woof-engine-pin.md) — why `woof_15.3.0` must never be used
- [Engine resource paths are load-bearing and non-obvious](engine-resource-layout.md) — woof.pk3, GameData/, and the `-save` flag
- [SDL startup and signal handling inside the SwiftUI-owned app](sdl-main-ready-and-sigterm.md) — SDL_SetMainReady and the SIGTERM bracket
- [Orientation support needs both halves, or it silently does nothing](orientation-needs-both-halves.md) — Info.plist *and* SDL_HINT_ORIENTATIONS
- [Engine console output does not reach `log stream`](engine-console-output-is-invisible.md) — use xcresult stdout or --console-pty
- [Every injected keydown must be paired with a keyup](soft-keyboard-keydown-keyup-pairing.md) — or cheat letters latch and the player walks forever
- [iOS 26 TabView tab-bar buttons ignore accessibility identifiers](ios26-tabview-accessibility.md) — address tabs by label, panes by identifier
- [iOS 26 List swipe actions change shape with row height](ios26-list-swipe-actions-row-height.md) — the stock idiom, already bisected; do not re-investigate
- [SwiftUI `Menu` cannot render `Slider` rows](swiftui-menu-cannot-host-sliders.md) — why tuning lives in the Control Feel sheet
- [Gesture recognizers do not fire inside SDL's own UIWindow](sdl-window-gesture-recognizers.md) — use responder-chain touches instead
- [Setting up a second worktree has two traps](worktree-setup-traps.md) — the Vendor symlink and the stale CMakeCache
- [Simulator hazards that produce misleading test results](simulator-test-hazards.md) — rotation, screenshot orientation, and RealWADTests fixtures
- [A test that builds a git fixture inherits the developer's signing config](git-fixtures-inherit-signing-config.md) — `tag.gpgSign` surfaces as `fatal: no tag message?`
- [Masking a query's exit status makes a guard fail open](masked-exit-status-fails-open.md) — four times now; test the status, then rule on empty output separately; `Scripts/check-masked-gh-status.sh` is the check
- [An empty simulator list means infrastructure, not a bad pin](simulator-enumeration-race.md) — CoreSimulator can fail to enumerate anything on a cold runner; `Scripts/check-simulator-available.sh` is the check
- [A simulator's name can contain parentheses, so parse the line from the right](simctl-device-names-contain-parens.md) — cutting at the first `" ("` truncates every iPad name, and `{36}` never matches in macOS awk
- [A second test destination buys nothing until one test reads the live device](a-second-destination-needs-a-live-device-test.md) — a pure-geometry suite gives the same verdict everywhere; `LiveDeviceOverlayLayoutTests` is what makes the iPad leg able to fail alone
- [An unattended `git push` hangs instead of failing](unattended-git-auth-hangs.md) — a locked 1Password agent, and why `credential.helper` must be cleared before it is set
- [The `.icon` package format, and the actool behaviours that mislead](icon-composer-package.md) — Dark/Tinted are generated for you, a silently-ignored key, nondeterministic output, and the simulator's icon cache
- [Command substitution around a function call discards everything but its stdout](command-substitution-discards-callee-state.md) — `$(...)` forks a subshell, so the callee's variable writes and even its `exit` never reach the caller
- [A loop body's trailing `&&` list trips `errexit` only when the loop is a pipeline stage](loop-body-last-status-triggers-errexit.md) — measured on bash 3.2: a piped loop aborts, a `for` or redirect-fed loop does not, and reading that backwards is how a real guard gets deleted
- [An exit status can mean "never ran", not "failed"](exit-status-conflates-failed-with-never-ran.md) — a suite exiting 126 or 127 is not the same signal as a real assertion failure; folding both into one `proved` fabricates a measurement
- [A test double written into the fixture's own working tree trips the guard it's testing](fixture-stub-trips-own-dirty-tree-guard.md) — a stubbed `xcodebuild` binary and its call log tripped `check-red-green.sh`'s own dirty-tree refusal; `.gitignore` them at base
- [Combining red-green domains is safe only because they never overlap in time](domain-composition-relies-on-strict-sequencing.md) — shared `REVERTED` global means one domain's `restore_tree` would clobber another's in-progress revert if they ever ran concurrently
- [`--no-renames` puts paths in the diff that do not exist at HEAD](no-renames-puts-head-absent-paths-in-the-diff.md) — a per-path rule that demands a test for a departed or deleted path demands a test for code that is gone, and forces `no-test` over a real `proved`
- [`env VAR=value some_function` fails at `env`, with a misleading error downstream](env-cannot-invoke-a-shell-function.md) — use the plain assignment-prefix form for a shell-function test helper instead
- [A one-instance fixture cannot test a rule that selects among instances](single-instance-fixture-cannot-test-a-selection-rule.md) — nine green tests over one `build-*` tag hid a changelog range that was empty on every release
- [A new test file does not fail — it silently does not exist](xcodegen-source-snapshot-hides-new-tests.md) — XcodeGen snapshots the source list, so an ungenerated test reports a green suite it never ran in; `mise run generate` after adding any file
- [Tearing down an fd tee has two lifetime traps, plus a contamination guard](fd-tee-teardown-lifetimes.md) — closing a captured fd right after `dup2` races the pump thread's pass-through write; a timed-out straggler must leak its fd, not close it
- [A content-hash lookup table fails silently, so its tests must not read it](content-hash-tables-fail-silently.md) — a wrong IWAD hash never throws, it just never matches; corroborate every entry and spell the literals out in the test
- [XcodeGen refuses to generate before the resources are fetched](xcodegen-needs-bootstrapped-resources.md) — `GameData/` and `woof.pk3` are gitignored build outputs, so a fresh worktree fails spec validation on `mise run generate`
- [Two detail-page UI tests are already red at HEAD, and CI will not tell you](ui-tests-are-red-at-head.md) — no pull request runs `WaddleUITests`, so reproduce any failure there at HEAD before blaming your own diff
- [`-loadgame` takes a composite number, and the newest save is usually the autosave](loadgame-argument-is-not-a-slot-index.md) — `10 * page + slot`, a project-pinned filename prefix, and a 255 sentinel that is the default path rather than an edge case
- ["The sheet never opened" usually means the sheet opened and the row is below the fold](lazy-form-hides-rows-from-uitests.md) — a lazy `Form`/`List`/`LazyVGrid` omits off-screen rows from the accessibility hierarchy; read the xcresult UI-hierarchy attachment before blaming presentation
- [The name is "Waddle"; the stylized form is only a wordmark](the-name-is-waddle.md) — two renames have leaked residue; `Scripts/check-name-consistency.sh` is the check, and the env vars, bundle ID and provisioning-profile name are deliberately not swept
- [Rewriting history unsigns every commit it touches](history-rewrites-drop-signatures.md) — `filter-branch` and friends drop signatures silently; GitHub reports it only as "unverified commits" at the merge button, and `git rebase --force-rebase --gpg-sign` is the fix
- [Under `pipefail`, a pipeline into `grep -q` or `head` fails when it MATCHES](pipefail-with-early-exit-consumer.md) — SIGPIPE turns the check inside out, so it refuses the healthy state and passes the broken one; capture into a variable and match with `case` instead
