# A test inside a class CI skips runs nowhere, and its failures read as expected

`ui-tests.yml` skips `WaddleUITests/RealWADTests` as a whole class, because
three of its cases need non-redistributable WADs. Its fourth case,
`testUnrecognizedIWADFailsSoft`, needed only a 12-byte synthetic file, but it
sat in that class, so CI never ran it. The only other place it ran was a local
`mise run test`, where `RealWADTests` failures are documented as expected when
the fixtures are missing, so a genuine failure there was passed over too.

It broke without anyone seeing it (issue #513). Since fcf4318c (issue #95) a
session ending in `I_Error` shows the engine's own SDL box (`I_ErrorMsg`,
titled `Woof <version>`) and does not end until its OK is tapped; only then
does `engineExitLabel` appear and the launcher's "Couldn't run this game"
alert come up. The test waited 90 s for the exit label with the box still up,
and failed "engine never returned" on every run, for weeks.

Two rules come out of it:

- **Put a test where its own needs decide whether it runs.** A case that can
  bring its own fixture belongs in a class CI runs. A UI test brings a small
  file into the app's Documents through the `WADDLE_TEST_LOOSE_FILE` /
  `WADDLE_TEST_LOOSE_FILE_NAME` launch seam (`WaddleApp.swift`); the case now
  lives in `UnrecognizedIWADTests` and runs on every `push: main`.
- **A test that makes a session fail on purpose must deal with the engine's
  box**: tap its OK (`EngineErrorAlertDismissalTests`,
  `UnrecognizedIWADTests` via `runGame`) or launch with `WADDLE_TEST_NOGUI`
  (`CompressedNodesTests`, `SessionStartStateTests`). Waiting for the exit
  label first will time out.

Not an executable check: whether a skipped class's case could run without its
class's fixtures is a judgement about each test, not something a script can
read off the workflow.

**Provenance:** issue #513, found 2026-11-23 reviewing PR #508; cause
confirmed by running the moved test with and without the box tap.
