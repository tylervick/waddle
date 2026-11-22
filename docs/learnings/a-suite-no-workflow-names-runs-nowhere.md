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

Two things decide what "registered" means, and both are in the check:

- **Only ci.yml counts.** It is the one workflow that runs on every pull
  request. A suite named only in a scheduled, dispatch-only or path-filtered
  workflow is the earlier version of this trap: `test-check-issue-format.sh`
  once ran only in `issue-format.yml`, which never fires on a pull request.
- **Only a `run:` block counts.** A suite mentioned in a comment, a step
  name or an `env:` value runs nothing, and ci.yml is full of comments that
  name suites.

Two suites needed `uv`, which the runner lacked. They now run because the
helper job installs `mise.toml`'s `[tools]`, where `uv` is pinned, rather than
by being exempted. A suite that genuinely cannot run on a runner goes on the
check's `EXEMPT` list with its reason; a reasonless or stale exemption is
refused.
