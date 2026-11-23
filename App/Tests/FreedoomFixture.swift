import Foundation

/// Stand-ins for the two Freedoom IWADs, for unit tests that seed "bundled"
/// rows (issue #504). `LibraryService.seedBundledContentIfNeeded()` reads
/// `bundledContentDirectory`, which defaults to the host app's GameData/; a suite
/// points it here instead, so its rows come from this fixture and not from
/// `Bundle.main`, and the suite keeps working once the app stops bundling
/// Freedoom (#505).
///
/// Each file is a valid IWAD with one map marker of its family (E1M1 for
/// Phase 1, MAP01 for Phase 2), built by `makeWAD`. The two differ in content,
/// so each has its own SHA-1, as the real ones do. Nothing here is Freedoom's
/// art; a test that needs real lumps does not belong on this fixture.
enum FreedoomFixture {
    /// A directory holding `freedoom1.wad` and `freedoom2.wad`, written once
    /// per test process under the temporary directory.
    static func directory() throws -> URL {
        if let cached { return cached }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FreedoomFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try makeWAD(magic: "IWAD", lumps: ["E1M1", "THINGS"])
            .write(to: dir.appendingPathComponent("freedoom1.wad"))
        try makeWAD(magic: "IWAD", lumps: ["MAP01", "THINGS"])
            .write(to: dir.appendingPathComponent("freedoom2.wad"))
        cached = dir
        return dir
    }

    nonisolated(unsafe) private static var cached: URL?
}
