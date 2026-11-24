import Foundation

/// Stand-ins for the two Freedoom IWADs, for unit tests that seed "bundled"
/// rows (issue #504). `LibraryService.seedBundledContentIfNeeded()` reads
/// `bundledContentDirectory`, which defaults to the host app's GameData/; a suite
/// points it here instead, so its rows come from this fixture and not from
/// `Bundle.main`, and the suite keeps working once the app stops bundling
/// Freedoom (#505).
///
/// Each file is a valid IWAD with one map marker of its family (E1M1 for
/// Phase 1, MAP01 for Phase 2), built by `makeWAD`, plus a lump named for
/// the fixture, so no test's own synthetic IWAD (an `E1M1` + `THINGS` one is
/// common) can share its SHA-1 and dedupe against it by accident. The two
/// differ in content, so each has its own SHA-1, as the real ones do. Nothing
/// here is Freedoom's art or Freedoom's hash; a test that needs either does
/// not belong on this fixture.
enum FreedoomFixture {
    /// A directory holding `freedoom1.wad` and `freedoom2.wad`, written once
    /// per test process under the temporary directory.
    static func directory() throws -> URL {
        if let cached { return cached }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FreedoomFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try makeWAD(magic: "IWAD", lumps: ["E1M1", "THINGS", "FDFIXT1"])
            .write(to: dir.appendingPathComponent("freedoom1.wad"))
        try makeWAD(magic: "IWAD", lumps: ["MAP01", "THINGS", "FDFIXT2"])
            .write(to: dir.appendingPathComponent("freedoom2.wad"))
        cached = dir
        return dir
    }

    /// The host app's own `GameData/`, which holds the real Freedoom 0.13.0
    /// files while the app still bundles them. Only for the few tests whose
    /// subject is those exact bytes: `LibraryService.shippedFreedoomSHA1` is
    /// a table of their hashes, which no stand-in can match. #505, which
    /// stops bundling Freedoom, has to give these tests the real files some
    /// other way.
    static var shippedRelease: URL {
        Bundle.main.resourceURL!.appendingPathComponent("GameData", isDirectory: true)
    }

    nonisolated(unsafe) private static var cached: URL?
}
