# Revyl proof-of-changes cannot be given a launch environment variable

XCUITest forces the touch overlay visible with `WADDLE_FORCE_TOUCH_OVERLAY`
through `app.launchEnvironment`, because `OverlayPresenter` hides the overlay
whenever `GCKeyboard.coalesced` or any `GCController` is present and the
simulator's automation session reports phantom versions of both. Revyl's
proof-of-changes harness hits the same wall on its devices — the first proof
run failed the "overlay is visible" invariant, and the invariant was softened
to excuse it — but **the same fix is not available there**, and the reason is
not obvious from the outside.

## Revyl does support launch variables. The project config does not.

This is the part that misleads. The CLI has a full launch-variable surface, so
the feature plainly exists:

```
revyl test run <name> --launch-env KEY=VALUE
revyl workflow run <name> --launch-env KEY=VALUE
revyl global launch-var create KEY=VALUE   # then: revyl test launch-var attach
```

All of it is addressed at a **test or workflow**. `proof_of_changes` is neither:
it is an AI harness driving a device session from `.revyl/config.yaml`, with no
command line to pass a flag on. And that file's contract has no launch-variable
field anywhere. Probed on 2026-09-19 against CLI v0.1.119, with
`revyl config validate` as the oracle — it is strict, and rejects an unknown key
by exact path, which is what makes the probe meaningful:

- Ten candidate names (`launch_env`, `launch_envs`, `env`, `environment`,
  `launch_variables`, `launch_vars`, `launch_var_ids`, `launch_env_vars`,
  `launch_args`, `launch_arg_sets`) against four levels
  (`pr_review.proof_of_changes`, `pr_review`, `session`, top level). Every
  combination rejected as `unsupported field`.
- Probing `harness` and `enabled` under `proof_of_changes` returns a
  *duplicate mapping key* error instead, which pins the accepted set to exactly
  what is already in the file: `enabled`, `harness`, `always_verify`,
  `system_prompt`.

The `launch_vars` YAML tag that turns up in the CLI binary belongs to the
device-session structs, not to this config. The binary says so itself:
*"Environment variables and launch vars are not managed here; use the
device-session launch_vars inputs instead."*

So the build is the only injection point we own, and the flag is a compilation
condition rather than an environment variable.

## The trap that would have made the fix do nothing

`.revyl/config.yaml` has a perfectly good `build.profiles.development.ios.build_commands`
recipe, and putting the flag there looks like the obvious and complete answer.
It is not, because a few lines further down the same file says:

```yaml
    build:
        kind: ci_upload_to_revyl
```

On the pull-request path Revyl never runs `build_commands` at all — it takes the
artifact that `ci.yml`'s **"Publish build to Revyl"** step built and uploaded.
A flag set only in `.revyl/config.yaml` reaches `revyl build` and
`revyl test run --build` and never once reaches a proof run, while looking
entirely correct in review. Both files therefore carry the setting.

## `$(inherited)` is not optional, and its absence is silent

`SWIFT_ACTIVE_COMPILATION_CONDITIONS` passed on an `xcodebuild` command line
**replaces** the configuration's value rather than adding to it. Debug's value
is `DEBUG`, so:

```
SWIFT_ACTIVE_COMPILATION_CONDITIONS=WADDLE_PROOF_HARNESS            # DEBUG is gone
SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) WADDLE_PROOF_HARNESS'  # DEBUG WADDLE_PROOF_HARNESS
```

The first still compiles, still links, still installs, and still defines the
flag — it just quietly stops being a Debug build, taking `WADDLE_FORCE_TOUCH_OVERLAY`,
`WADDLE_RESET_STORE` and `WADDLE_TOUCH_SCHEME` with it, which would break the
XCUITest suites and not the proof run. Verified with `-showBuildSettings`:
command-line overrides *do* honour `$(inherited)`, resolving to
`DEBUG WADDLE_PROOF_HARNESS`. The single quotes are separately load-bearing —
unquoted, the runner's shell expands `$(inherited)` as command substitution.

## The check

`Scripts/check-proof-harness-flag.sh` holds all of it: the Swift `#if` still
being read, both builds carrying the exact quoted setting, and the
`its absence is correct` exemption not creeping back into `always_verify` or the
system prompt while the flag forces the overlay visible. Read the script rather
than re-deriving any of the above; `Scripts/test-check-proof-harness-flag.sh`
pins each failure shape, and its last case runs the guard against the real tree.

**If proof-of-changes ever gains a launch-variable field**, the better fix is to
move to it and delete the flag, the guard and this file: the artifact would then
be identical to the shipped binary again, and the hide-on-keyboard policy would
become verifiable by proof instead of compiled out of the build that proves it.

**Provenance:** 2026-09-19, investigating why the on-screen overlay never
appeared under the UI test runners. CLI v0.1.119, Xcode 26.2.
