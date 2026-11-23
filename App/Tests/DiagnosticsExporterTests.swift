import SwiftData
import XCTest
import ZIPFoundation
@testable import Waddle

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
                        BreadcrumbLog.fileName, UsageStore.fileName],
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

    func testExportWithEmptyDiagnosticsStillProducesInfoAndUsageOnlyZip() throws {
        let empty = tmp.appendingPathComponent("empty", isDirectory: true)
        // Deliberately never created: the directory may not exist on a fresh
        // install that has never run a session. Export must still succeed,
        // and usage.json is written from zeros rather than copied (#487).
        let zip = try DiagnosticsExporter.export(diagnosticsDirectory: empty,
                                                 libraryLines: [])
        XCTAssertEqual(try zipEntryNames(zip), ["info.txt", UsageStore.fileName])
    }

    private func extracted(_ name: String, from zip: URL) throws -> Data {
        let archive = try Archive(url: zip, accessMode: .read)
        let entry = try XCTUnwrap(archive.first {
            ($0.path as NSString).lastPathComponent == name
        })
        var data = Data()
        _ = try archive.extract(entry, consumer: { data.append($0) })
        return data
    }

    func testExportedUsageHasOnlyTheListedKeysAndCountsThisExport() throws {
        let usage = UsageStore(directory: tmp)
        usage.recordLaunch(version: "1.5 (295)")
        usage.recordSessionStart(game: "Freedoom: Phase 1", scheme: .modern,
                                 controllerConnected: true, orientation: .landscape)
        usage.recordSessionEnd(game: "Freedoom: Phase 1", exitCode: 0, duration: 120)

        let zip = try DiagnosticsExporter.export(diagnosticsDirectory: tmp,
                                                 libraryLines: [])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: extracted(UsageStore.fileName, from: zip)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), [
            "first_seen_day", "last_seen_day", "app_versions", "launches",
            "sessions_started", "sessions_clean", "sessions_failed", "play_minutes_total",
            "sessions_by_control_scheme", "sessions_by_orientation", "sessions_by_game",
            "wads_imported", "games_created", "diagnostics_exports",
        ], "usage.json carries exactly the fields issue #487 lists, nothing else")
        XCTAssertEqual(object["sessions_started"] as? Int, 1)
        XCTAssertEqual(object["diagnostics_exports"] as? Int, 1,
                       "the export being made is counted in the file it makes")
    }

    func testCorruptUsageFileDoesNotFailTheExport() throws {
        try Data("{not json".utf8).write(to: UsageStore(directory: tmp).fileURL)
        let zip = try DiagnosticsExporter.export(diagnosticsDirectory: tmp,
                                                 libraryLines: [])
        let summary = try JSONDecoder().decode(
            UsageSummary.self, from: extracted(UsageStore.fileName, from: zip))
        var expected = UsageSummary()
        expected.diagnosticsExports = 1
        XCTAssertEqual(summary, expected, "a damaged file starts again from zero")
    }

    func testInfoTextShowsTheUsageCounts() throws {
        let usage = UsageStore(directory: tmp)
        usage.recordSessionStart(game: "Nuts", scheme: .classic,
                                 controllerConnected: false, orientation: .portrait)
        usage.recordSessionEnd(game: "Nuts", exitCode: -1, duration: 30)

        let zip = try DiagnosticsExporter.export(diagnosticsDirectory: tmp,
                                                 libraryLines: [])
        let info = String(decoding: try extracted("info.txt", from: zip), as: UTF8.self)
        XCTAssertTrue(info.contains("Sessions started: 1"), info)
        XCTAssertTrue(info.contains("Sessions ended in an error: 1"), info)
        XCTAssertTrue(info.contains("Classic controls: 1 session"), info)
        XCTAssertTrue(info.contains("Portrait: 1 session"), info)
        XCTAssertTrue(info.contains("Game: Nuts: 1 session, 0.5 min"), info)
        XCTAssertTrue(info.contains("Diagnostics exports: 1"), info)
    }

    func testExportNeverIncludesWADFiles() throws {
        try Data("IWAD....".utf8).write(to: tmp.appendingPathComponent("stray.wad"))
        let zip = try DiagnosticsExporter.export(diagnosticsDirectory: tmp,
                                                 libraryLines: [])
        XCTAssertFalse(try zipEntryNames(zip).contains("stray.wad"),
            "only session logs, payloads, and info.txt may be bundled")
    }

    func testExportBundlesMetricPayloadsAndStillExcludesWADFiles() throws {
        // Written through the subscriber rather than by hand, so the test
        // breaks if the metrics directory or prefix ever moves.
        DiagnosticsMetricSubscriber(directory: tmp).saveMetricPayloadData(
            Data("{\"launch\":1}".utf8),
            receivedAt: Date(timeIntervalSince1970: 1_770_000_000))
        try Data("IWAD....".utf8).write(to: tmp.appendingPathComponent("stray.wad"))

        let zip = try DiagnosticsExporter.export(diagnosticsDirectory: tmp,
                                                 libraryLines: [])
        let names = try zipEntryNames(zip)
        XCTAssertEqual(names.filter { $0.hasPrefix(DiagnosticsStore.metricPrefix) }.count, 1,
            "metric payloads are the signal for startup, memory and hang regressions")
        XCTAssertFalse(names.contains("stray.wad"),
            "bundling a new payload kind must not widen the allowlist to WAD content")
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
        let container = try ModelContainer(for: WADFile.self, Game.self, configurations: config)
        context = ModelContext(container)
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        service = LibraryService(context: context, store: WADStore(directory: tmp))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testLibraryLinesNameWADsAndGamesOnly() throws {
        let wad = try service.registerImported(filename: "gothic.wad", sha1: "abc123",
                                     kind: "pwad", family: GameFamily.doom2.rawValue)
        _ = try service.createGame(name: "Gothic Run", baseID: nil, fileIDs: [wad.id])
        let lines = DiagnosticsExporter.libraryLines(from: service)
        XCTAssertTrue(lines.contains { $0.contains("gothic.wad") })
        XCTAssertTrue(lines.contains { $0.contains("game: Gothic Run") })
        XCTAssertFalse(lines.joined().contains("abc123"),
            "hashes and paths stay out; names only")
    }

    func testLibraryLinesWithNilServiceIsEmpty() {
        XCTAssertEqual(DiagnosticsExporter.libraryLines(from: nil), [])
    }
}
