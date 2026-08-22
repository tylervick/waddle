# A CLI xcodebuild sharing DerivedData with an open Xcode races its preview builds

Running `xcodebuild` from a terminal while Xcode has the same project open —
especially right after `mise run generate` rewrites the project file — makes
two build systems fight over one build database. It presents as two different
failures, minutes apart, neither of which names the other:

- The CLI run dies with `unable to attach DB: … build.db: database is locked.
  Possibly there are two concurrent builds running in the same filesystem
  location.`
- Xcode's **preview session crashes at app launch** with a SwiftData
  assertion under `App.main()` (`EXC_BREAKPOINT` in `_assertionFailure` ←
  SwiftData ← XOJITExecutor frames): the canvas relaunched the app against
  the half-consistent build state the race left behind. Observed 2026-08-21
  at 21:46, timestamp-matched to the locked-DB CLI failure of the same
  minute. The crash report blames SwiftData; the cause was the collision.

**The fix is isolation, not sequencing.** Give CLI runs their own
`-derivedDataPath` (a scratch directory) whenever Xcode is or may be open.
The first such build is cold — a few minutes with the engine framework
already in `Vendor/out/` — and every later run is warm. Trying to take turns
with Xcode instead is a losing game: it rebuilds in the background whenever
the project or files change, which is exactly when you want to run tests.

Related but distinct: `killed-xcodebuild-wedges-coresimulator.md` covers a
*killed* session wedging CoreSimulator itself. This one needs no kill —
two live build systems are enough — and recovery needs no service restart,
just isolation and a canvas Resume.

A second thing the incident showed: the SwiftData-under-previews assertion
("Not a PersistentModel Type", or an anonymous SwiftData
`_assertionFailure` under `App.main()`) is an environmental flake of the
XOJIT preview bootstrap, seen once from stale preview caches after a
component install and once from this race — never from app code. If it fires
without a collision to blame, clear the preview simulators
(`xcrun simctl --set previews delete all`) and retry before reading the
stack as a Waddle bug.

**Provenance:** the 2026-08-21 design pass, working the shelf branch under
the same Xcode that was rendering `ShelfPreviews.swift`.
