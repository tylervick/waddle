import XCTest
import ZIPFoundation
@testable import WADdle

final class DiagnosticsExporterTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagexport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func zipEntryNames(_ zipURL: URL) throws -> Set<String> {
        let archive = try Archive(url: zipURL, accessMode: .read)
        return Set(archive.map { ($0.path as NSString).lastPathComponent })
    }

    func testInfoTextCarriesBuildAndLibraryFacts() {
        let text = DiagnosticsExporter.infoText(libraryLines: ["wad: freedoom1.wad",
                                                               "loadout: Nuts"])
        XCTAssertTrue(text.contains(BuildInfo.commit))
        XCTAssertTrue(text.contains("wad: freedoom1.wad"))
        XCTAssertTrue(text.contains("loadout: Nuts"))
        XCTAssertTrue(text.contains("iOS"), "must name the OS version")
    }

    func testExportBundlesLogsPayloadsAndInfo() throws {
        try Data("engine says hi".utf8)
            .write(to: tmp.appendingPathComponent("session-a.log"))
        try Data("{}".utf8)
            .write(to: tmp.appendingPathComponent("metrickit-2026-b.json"))

        let zip = try DiagnosticsExporter.export(diagnosticsDirectory: tmp,
                                                 libraryLines: [])
        XCTAssertEqual(try zipEntryNames(zip),
                       ["info.txt", "session-a.log", "metrickit-2026-b.json"],
                       "exactly the allowlisted files, nothing else")
    }

    func testExportWithEmptyDiagnosticsStillProducesInfoOnlyZip() throws {
        let empty = tmp.appendingPathComponent("empty", isDirectory: true)
        // Deliberately never created: the directory may not exist on a fresh
        // install that has never run a session. Export must still succeed.
        let zip = try DiagnosticsExporter.export(diagnosticsDirectory: empty,
                                                 libraryLines: [])
        XCTAssertEqual(try zipEntryNames(zip), ["info.txt"])
    }

    func testExportNeverIncludesWADFiles() throws {
        try Data("IWAD....".utf8).write(to: tmp.appendingPathComponent("stray.wad"))
        let zip = try DiagnosticsExporter.export(diagnosticsDirectory: tmp,
                                                 libraryLines: [])
        XCTAssertFalse(try zipEntryNames(zip).contains("stray.wad"),
            "only session logs, payloads, and info.txt may be bundled")
    }
}
