# Simulator hazards that produce misleading test results

*(The rule against two concurrent `xcodebuild` sessions on one simulator lives
in `CLAUDE.md` — it applies to every run, not just these cases.)*

- **The iPhone 17 Pro simulator never rotates its interface** under
  `XCUIDevice.shared.orientation`, caused by a stale
  `SimulatorWindowOrientation=LandscapeRight` in the
  `com.apple.iphonesimulator` prefs. iPhone 17 Pro Max works.
  `testSessionSurvivesRotation` carries a launcher-probe `XCTSkip` guard for
  such simulators.
- **The simulator keeps the orientation a test leaves it in**, across tests
  and across suites, and a failed tap ends a test before its last lines run.
  A rotation test that failed in landscape left the device there and failed
  both `TouchLayoutEditorTests` cases after it: one failure reported as three
  (issue #382). Every `XCUIDevice.shared.orientation` write is paired with
  `addTeardownBlock { XCUIDevice.shared.orientation = .portrait }`, registered
  before the write, and a suite that needs portrait sets it.
- **`XCUIScreen` screenshots of a landscape interface arrive sideways** in a
  portrait buffer. `Scripts/capture-screenshots.sh` compensates; anything new
  that captures screenshots must too.
- **`RealWADTests` needs `Scripts/provision-test-wads.sh`** run after app
  install, plus the WADs in `~/Downloads/doom-test-wads/`. Without them that one
  test class fails and nothing else does — a failure there usually means missing
  fixtures, not a regression.

**Provenance:** Plan 2 Task 9, Plan 3 Task 6, and the Plan 4 screenshot work.
