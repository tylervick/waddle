# An empty simulator list means infrastructure, not a bad pin

CI run 31427755601 on PR #66 failed with `xcodebuild: error: Unable to find a
device matching the provided destination specifier: { platform:iOS Simulator,
OS:26.2, name:iPhone 17 Pro }`. The identical commit, on the identical runner
image (`macos-26-arm64/20260728.0273`), had passed two days earlier, and a
bare re-run with no code change passed. The tell: the error's own "Available
destinations" list had **no simulators at all** — only `My Mac` and two
`dvtdevice-…placeholder` entries. A genuinely wrong device pin still lists the
runner's other simulators; an empty list means CoreSimulator never enumerated
anything. It failed ~60s in, consistent with an enumeration timeout on a cold
runner.

A real, wrong destination pin looks different: `simctl list devices
available` still enumerates devices, just not the one requested. That
distinction is the whole guard — a re-run fixes the first shape, never the
second.

The check is `Scripts/check-simulator-available.sh`, wired into
`.github/workflows/ci.yml` and `.github/workflows/ui-tests.yml` ahead of
their test steps. It retries on a bounded schedule before giving up, and on a
zero-enumeration failure prints the `WADDLE_SIMULATOR_UNAVAILABLE` marker so
a log grep — including `Scripts/loop-prompt.md` section 4 — can tell a flaky
runner apart from a real regression and re-run the job instead of "fixing" a
clean diff.
