# A test suite no workflow names runs nowhere

`Scripts/check-suites-registered.sh` refuses the shape; this file records why
it exists and what the check does not cover.

`ci.yml`'s "Verify the build-script helpers" step carried the sentence "This
list must name EVERY Scripts/test-*.sh suite". Nothing checked it. On
2026-11-22 three suites were named in no workflow at all
(`test-fetch-testflight-feedback.sh` since 2026-08-12, `test-build-mark.sh`
and `test-glyph-source.sh` since 2026-08-17), so a change breaking any of
them would have been green on its pull request and on `main` (issue #454).
All three still passed when measured; nothing had yet broken unseen.

What "registered" means is decided in the check, and it took two attempts:

- **Only ci.yml counts.** It is the one workflow that runs on every pull
  request. A suite named only in a scheduled, dispatch-only or path-filtered
  workflow is the earlier version of this trap: `test-check-issue-format.sh`
  once ran only in `issue-format.yml`, which never fires on a pull request.
- **Only a `run:` block counts.** A suite mentioned in a comment, a step
  name or an `env:` value runs nothing, and ci.yml is full of comments that
  name suites.
- **"In ci.yml" is still not "on every pull request".** The first version
  stopped at the two rules above, and the review of PR #473 moved a suite into
  four places in ci.yml that never fail a pull request -- the switched-off
  `changed-paths` job, the push-only `revyl-main` job, an `if: false` step and
  a `continue-on-error` step -- and it passed each. Now the suite must be on a
  line of its own, with nothing masking its status, in a step with no `if:`
  or `continue-on-error`, in a job the `testflight` job needs (which
  `Scripts/check-release-gate.sh --print-needs` reports). The same trap moved
  inside one file is still the trap.

Two suites needed `uv`, which the runner lacked. They now run because the
helper job installs the mise-pinned tools, rather than by being exempted. `uv`
is pinned in `.config/mise.toml`, not `mise.toml`: `Scripts/release-due.sh`
counts `mise.toml` as a change to what ships, and both build caches key on its
hash, so a pin there would have shipped a TestFlight build identical to the
last and rebuilt the engine for a tool the engine never runs. The flip side is
that a build tool pinned there would ship nothing and rebuild nothing, so
`Scripts/check-mise-tools-registry.sh` allows that file uv alone. Their Pillow is
pinned in `Scripts/build-mark.py` and locked with hashes beside it, and a
failed download reports itself as one. A suite that genuinely cannot run on a
runner goes on the check's `EXEMPT` list with its reason; a reasonless or
stale exemption is refused.
