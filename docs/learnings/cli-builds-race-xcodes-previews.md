# The preview host crashes in App.main() — gate app startup, and don't share DerivedData

Two related traps from one evening (2026-08-21), with the misattribution
between them recorded on purpose.

**The crash.** Xcode's canvas boots the real app as a host for `#Preview`
content, and on current tooling (Xcode 26.2, iOS 26.3.1 simruntime) the
`ModelContainer(for:)` in `WaddleApp.init` intermittently dies there:
`EXC_BREAKPOINT` in `_assertionFailure` ← SwiftData ← `static App.main()` ←
XOJITExecutor, reported once as `Not a PersistentModel Type - WADFile`. Six
crash reports in one evening, bracketing one fully-working session — and a
crashing host loops (relaunch, assert, repeat), which the canvas shows as a
"Booting"/"Preparing" hang with a stale render behind an error banner.

Two environmental remedies each appeared to work once and did not hold:
clearing the preview simulators (`xcrun simctl --set previews delete all`)
and eliminating a concurrent CLI build. The crash recurred at 20:36 and
21:24 with neither in play, which is what ruled both out as the cause.

**The durable fix is to remove the crashing call from the boot path**:
`WaddleApp.init` returns empty (nil container/library/importer, no stores,
no MetricKit, no breadcrumbs) when `XCODE_RUNNING_FOR_PREVIEWS == "1"`, and
the scene renders a placeholder the canvas never shows. Previews build their
own in-memory fixtures inside `#Preview` bodies (`ShelfPreviews.swift`) —
the path that has never crashed. The env var is set by Xcode for every
preview host process and nothing else; the gate is `#if DEBUG` besides.

**The separate, real trap:** a CLI `xcodebuild` sharing DerivedData with an
open Xcode — especially right after `mise run generate` rewrites the
project — fails with `build.db: database is locked. Possibly there are two
concurrent builds running in the same filesystem location`, and leaves
Xcode's own build in a state worth distrusting. Give CLI runs their own
`-derivedDataPath` scratch directory whenever Xcode is or may be open; the
first build is cold, every later one is warm, and there is no turn-taking
game to lose.

**The misattribution worth remembering:** the first crash was blamed on
stale preview caches, the fourth on the DerivedData collision — each because
a plausible environmental event sat right next to it in time, and each
"confirmed" by one lucky retry. What broke both stories was the crash count:
timestamps accumulate in `~/Library/Logs/DiagnosticReports/Waddle-*.ips`,
and two of six fell where neither story could reach. Count the reports
before believing a coincidence.

**Provenance:** the 2026-08-21 design pass, working the shelf branch under
the same Xcode that was rendering `ShelfPreviews.swift`.
