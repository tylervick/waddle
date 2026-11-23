# A UI test can hand the app a file by its path in the runner's bundle

On the simulator, the app under test can read files inside the UI-test
runner's own bundle. Pass the path in a launch environment variable and the
app opens it like any other path. The data container and the runner bundle
are both plain host directories under
`~/Library/Developer/CoreSimulator/Devices/<udid>/data/`, and the simulator
does not sandbox reads between them. Measured on the iOS 27.0 runtime
(Xcode 27.1) for issue #504: the app copied `freedoom1.wad` and
`freedoom2.wad` (28 MB each) from
`WaddleUITests-Runner.app/PlugIns/WaddleUITests.xctest/` into its own
`Documents/WADs`. This does not work on a device, where the runner is a
separate container.

This is how `XCUIApplication.provideFreedoom()` works
(`App/UITests/XCTestCase+UIHelpers.swift`). It sets `WADDLE_TEST_FREEDOOM_DIR`,
and `LibraryService.installFreedoomForTest(from:)` imports the files. Use the
same pattern for any large fixture. The launch environment is the wrong place
for one, and `Scripts/provision-test-wads.sh`'s `simctl get_app_container`
route needs the host, so a test cannot do it for itself.

Two things about the Freedoom seam that are easy to trip on:

- **It applies to one launch only.** A launch without `provideFreedoom()` runs
  the bundled seeder. Set it on every `XCUIApplication` in a test that plays
  Freedoom, including relaunches and cleanup launches.
- **Imported Freedoom is not factory state.** `LibraryService.isFactoryState()`
  is false as soon as a non-bundled file exists, so a seam launch never shows
  the welcome card. A test of the welcome card or of bundled status (the
  "Bundled" label in `FilesScreenTests`) still reads the bundle until #505
  changes what those mean.
