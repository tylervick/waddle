import SwiftData
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

    func testExportBundlesLogsPayloadsBreadcrumbsAndInfo() throws {
        try Data("engine says hi".utf8)
            .write(to: tmp.appendingPathComponent("session-a.log"))
        try Data("{}".utf8)
            .write(to: tmp.appendingPathComponent("metrickit-2026-b.json"))
        BreadcrumbLog(directory: tmp).record(.appLaunch)

        let zip = try DiagnosticsExporter.export(diagnosticsDirectory: tmp,
                                                 libraryLines: [])
        XCTAssertEqual(try zipEntryNames(zip),
                       ["info.txt", "session-a.log", "metrickit-2026-b.json",
                        BreadcrumbLog.fileName],
                       "exactly the allowlisted files, nothing else")
    }

    func testExportedBreadcrumbsKeepTheirContents() throws {
        BreadcrumbLog(directory: tmp).record(.appLaunch,
                                             at: Date(timeIntervalSince1970: 0))

        let zip = try DiagnosticsExporter.export(diagnosticsDirectory: tmp,
                                                 libraryLines: [])
        let archive = try Archive(url: zip, accessMode: .read)
        let entry = try XCTUnwrap(archive.first {
            ($0.path as NSString).lastPathComponent == BreadcrumbLog.fileName
        })
        var extracted = Data()
        _ = try archive.extract(entry, consumer: { extracted.append($0) })
        XCTAssertEqual(String(decoding: extracted, as: UTF8.self),
                       "1970-01-01T00:00:00Z app launch\n",
                       "the trail must arrive intact, not merely be named in the zip")
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

    func testReclaimStaleExportsRemovesOnlyOldDirectories() throws {
        let old = tmp.appendingPathComponent("diagnostics-export-old", isDirectory: true)
        let fresh = tmp.appendingPathComponent("diagnostics-export-fresh", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: fresh.path)

        DiagnosticsExporter.reclaimStaleExports(in: tmp, olderThan: 3600, now: .now)

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path),
            "hour-old export directories should be swept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path),
            "recent export directories must survive -- they could still be mid-share")
    }
}

@MainActor
final class DiagnosticsLibraryLinesTests: XCTestCase {
    var service: LibraryService!
    var context: ModelContext!
    var tmp: URL!

    // Same rationale as LibraryServiceTests: async setUp()/tearDown() keep
    // the MainActor-isolated ModelContext construction properly isolated,
    // avoiding the Swift 6 "sending" diagnostic that setUpWithError()'s
    // nonisolated override would trigger when handing the context into
    // LibraryService's @MainActor init.
    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WADFile.self, Loadout.self, configurations: config)
        context = ModelContext(container)
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        service = LibraryService(context: context, store: WADStore(directory: tmp))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testLibraryLinesNameWADsAndLoadoutsOnly() throws {
        let wad = try service.registerImported(filename: "gothic.wad", sha1: "abc123",
                                     kind: "pwad", family: GameFamily.doom2.rawValue)
        try service.createLoadout(name: "Gothic Run", iwadID: wad.id,
                                  pwadIDs: [wad.id], dehIDs: [])
        let lines = DiagnosticsExporter.libraryLines(from: service)
        XCTAssertTrue(lines.contains { $0.contains("gothic.wad") })
        XCTAssertTrue(lines.contains { $0.contains("loadout: Gothic Run") })
        XCTAssertFalse(lines.joined().contains("abc123"),
            "hashes and paths stay out; names only")
    }

    func testLibraryLinesWithNilServiceIsEmpty() {
        XCTAssertEqual(DiagnosticsExporter.libraryLines(from: nil), [])
    }
}
