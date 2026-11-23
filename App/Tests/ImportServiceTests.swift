import SwiftData
import XCTest
import ZIPFoundation
@testable import Waddle

@MainActor
final class ImportServiceTests: XCTestCase {
    var importer: ImportService!
    var library: LibraryService!
    var tmp: URL!
    /// The importer's own notice banner and usage counts, so an import here
    /// neither touches the app's shared ones nor depends on them.
    var notices: ImportNotices!
    var usage: UsageStore!

    override func setUpWithError() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WADFile.self, Game.self, configurations: config)
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = WADStore(directory: tmp.appendingPathComponent("WADs", isDirectory: true))
        library = LibraryService(context: ModelContext(container), store: store)
        library.bundledContentDirectory = try FreedoomFixture.directory()
        notices = ImportNotices()
        usage = UsageStore(directory: tmp.appendingPathComponent("Diagnostics", isDirectory: true))
        importer = ImportService(library: library, store: store, notices: notices, usage: usage)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// A second, independent library+importer over its own in-memory store, for
    /// the tests that must import the same bytes twice without the hash dedupe
    /// collapsing the second import into a duplicate. Its store directory sits
    /// under `tmp`, so tearDown removes it with everything else.
    private func freshStack() throws -> (LibraryService, ImportService) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WADFile.self, Game.self, configurations: config)
        let store = WADStore(directory: tmp.appendingPathComponent(UUID().uuidString,
                                                                   isDirectory: true))
        let library = LibraryService(context: ModelContext(container), store: store)
        library.bundledContentDirectory = try FreedoomFixture.directory()
        return (library, ImportService(library: library, store: store, notices: ImportNotices(),
                                       usage: UsageStore(directory: tmp.appendingPathComponent(
                                           UUID().uuidString, isDirectory: true))))
    }

    func testImportsValidPWAD() async throws {
        let url = try write("sunlust.wad", makeWAD(magic: "PWAD", lumps: ["MAP01"]))
        let outcome = await importer.importFiles(at: [url], from: .picker)
        XCTAssertEqual(outcome.imported, ["sunlust"])
        XCTAssertEqual(try library.allWADs().first?.kindRaw, WADKind.pwad.rawValue)
        XCTAssertEqual(try library.allWADs().first?.gameFamilyRaw, "doom2")
    }

    func testRejectsInvalidWadWithReason() async throws {
        let url = try write("fake.wad", Data("not a wad".utf8))
        let outcome = await importer.importFiles(at: [url], from: .picker)
        XCTAssertTrue(outcome.imported.isEmpty)
        XCTAssertNotNil(outcome.rejected["fake.wad"])
        XCTAssertTrue(try library.allWADs().isEmpty)
    }

    func testDuplicateImportReported() async throws {
        let data = makeWAD(magic: "PWAD", lumps: ["MAP01"])
        _ = await importer.importFiles(at: [try write("a.wad", data)], from: .picker)
        let outcome = await importer.importFiles(at: [try write("b.wad", data)], from: .picker)
        XCTAssertEqual(outcome.duplicates.count, 1)
        XCTAssertEqual(try library.allWADs().count, 1)
    }

    func testImportCategorizesGamesAddOnsAndUnpaired() async throws {
        try library.seedBundledContentIfNeeded()
        let mapSet = try write("sunlust.wad", makeWAD(magic: "PWAD", lumps: ["MAP01", "THINGS"]))   // doom2 family
        let addOn = try write("smooth.wad", makeWAD(magic: "PWAD", lumps: ["TITLEPIC"]))
        let weird = try write("weird.wad", makeWAD(magic: "PWAD", lumps: ["MAP01"]))                // also doom2 — paired
        let outcome = await importer.importFiles(at: [mapSet, addOn, weird], from: .picker)
        XCTAssertEqual(Set(outcome.games), ["sunlust", "weird"])
        XCTAssertEqual(outcome.addOns, ["smooth"])
        XCTAssertTrue(outcome.unpaired.isEmpty)
        XCTAssertEqual(Set(outcome.imported), ["sunlust", "smooth", "weird"], "imported still lists everything")
    }

    func testImportReportsAnUnpairedMapSetWhenNoBaseOfItsFamilyExists() async throws {
        // No seed: no bases at all.
        let mapSet = try write("orphan.wad", makeWAD(magic: "PWAD", lumps: ["MAP01"]))
        let outcome = await importer.importFiles(at: [mapSet], from: .picker)
        XCTAssertEqual(outcome.unpaired, ["orphan"])
        XCTAssertTrue(outcome.games.isEmpty)
    }

    func testImportReportsAnIWADAsAGame() async throws {
        let iwad = try write("mygame.wad", makeWAD(magic: "IWAD", lumps: ["E1M1", "THINGS"]))
        let outcome = await importer.importFiles(at: [iwad], from: .picker)
        XCTAssertEqual(outcome.games, ["mygame"])
    }

    func testImportingByteIdenticalCopyOfBundledIWADIsDuplicate() async throws {
        try library.seedBundledContentIfNeeded()
        let freedoom = try XCTUnwrap(
            library.allWADs().first { $0.isBundled && $0.filename == "freedoom1.wad" })
        let copy = tmp.appendingPathComponent("my-freedoom.wad")
        try FileManager.default.copyItem(at: library.fileURL(for: freedoom), to: copy)

        let outcome = await importer.importFiles(at: [copy], from: .picker)

        XCTAssertEqual(outcome.duplicates, ["my-freedoom"])
        XCTAssertTrue(outcome.imported.isEmpty)
        XCTAssertEqual(try library.allWADs().count, 2,
                       "a byte-identical copy of bundled content must not create a second entry")
    }

    func testImportsDEHByExtension() async throws {
        let url = try write("tweaks.deh", Data("Patch File for DeHackEd 3.0".utf8))
        let outcome = await importer.importFiles(at: [url], from: .picker)
        XCTAssertEqual(outcome.imported, ["tweaks"])
        XCTAssertEqual(try library.allWADs().first?.kindRaw, WADKind.deh.rawValue)
    }

    func testImportsWadsOutOfZip() async throws {
        // Build a zip with a nested wad + junk, like real downloads.
        let zipURL = tmp.appendingPathComponent("dl.zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        let wadData = makeWAD(magic: "PWAD", lumps: ["E1M1"])
        try archive.addEntry(with: "release/map.wad", type: .file,
                             uncompressedSize: Int64(wadData.count),
                             provider: { pos, size in
            wadData.subdata(in: Int(pos)..<Int(pos) + size)
        })
        let outcome = await importer.importFiles(at: [zipURL], from: .picker)
        XCTAssertEqual(outcome.imported, ["map"])
        XCTAssertEqual(try library.allWADs().first?.gameFamilyRaw, "doom1")
    }

    // MARK: oversize zip entries

    /// A zip whose only game-file entry blows the size cap: nothing gets
    /// extracted, so the old "no files extracted" guard rejected the zip
    /// once under its own name. The fix moves that bookkeeping onto the
    /// skipped entry itself, but the net behavior a caller cares about —
    /// the zip is rejected and nothing imports — must stay the same.
    func testOversizeOnlyZipStillRejectedWithoutImporting() async throws {
        let big = Data(repeating: 0, count: 64)
        let zipURL = tmp.appendingPathComponent("big-only.zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        try archive.addEntry(with: "big.wad", type: .file,
                             uncompressedSize: Int64(big.count),
                             provider: { pos, size in big.subdata(in: Int(pos)..<Int(pos) + size) })
        importer.maxZipEntryBytes = 5

        let outcome = await importer.importFiles(at: [zipURL], from: .picker)

        XCTAssertTrue(outcome.imported.isEmpty)
        // The reason string reports the cap actually in effect; these tests
        // shrink it below 1 MB, which integer-divides down to "0 MB".
        XCTAssertEqual(outcome.rejected["big.wad"], "Entry exceeds the 0 MB import limit.")
    }

    /// A zip with one importable wad and one entry over the cap: the valid
    /// file must still import, AND the oversize entry must be recorded as
    /// its own rejection rather than silently dropped. Previously the drop
    /// happened because the "no files extracted" guard never fires once
    /// *something* extracted — the skipped entry's existence just vanished,
    /// and (via adoptLooseFiles) the zip carrying it got deleted as a clean
    /// import.
    func testMixedZipImportsValidEntryAndRejectsOversizeEntry() async throws {
        let wadData = makeWAD(magic: "PWAD", lumps: ["MAP01"])
        let big = Data(repeating: 0, count: wadData.count + 1000)
        let zipURL = tmp.appendingPathComponent("mixed.zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        try archive.addEntry(with: "ok.wad", type: .file,
                             uncompressedSize: Int64(wadData.count),
                             provider: { pos, size in wadData.subdata(in: Int(pos)..<Int(pos) + size) })
        try archive.addEntry(with: "big.wad", type: .file,
                             uncompressedSize: Int64(big.count),
                             provider: { pos, size in big.subdata(in: Int(pos)..<Int(pos) + size) })
        importer.maxZipEntryBytes = Int64(wadData.count)

        let outcome = await importer.importFiles(at: [zipURL], from: .picker)

        XCTAssertEqual(outcome.imported, ["ok"])
        XCTAssertEqual(outcome.rejected["big.wad"], "Entry exceeds the 0 MB import limit.")
    }

    // MARK: adoptLooseFiles

    func testAdoptLooseFilesMovesRejectedFilesToImportFailed() async throws {
        // adoptLooseFiles scans the real app Documents directory (Files-app
        // drop zone), not the tmp WADStore dir, so the fixture has to live
        // there too.
        let docs = URL.documentsDirectory
        let name = "junk-\(UUID().uuidString).wad"
        let junkURL = docs.appendingPathComponent(name)
        let importFailedURL = docs.appendingPathComponent("Import Failed").appendingPathComponent(name)
        try Data("not a wad".utf8).write(to: junkURL)
        defer {
            try? FileManager.default.removeItem(at: junkURL)
            try? FileManager.default.removeItem(at: importFailedURL)
        }

        let outcome = await importer.adoptLooseFiles()

        XCTAssertNotNil(outcome.rejected[name])
        XCTAssertFalse(FileManager.default.fileExists(atPath: junkURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: importFailedURL.path))
    }

    func testAdoptLooseFilesQuarantinesZipWhoseContentsAllFailImport() async throws {
        // The rejection from a corrupt inner .wad is recorded under the
        // inner file's own name ("corrupt.wad"), never the zip's — so the
        // zip-level keep/quarantine/delete decision can't be a lookup keyed
        // on the zip's own basename (it would never find a rejection there
        // and would wrongly delete the zip as if it had imported cleanly).
        let docs = URL.documentsDirectory
        let name = "bundle-\(UUID().uuidString).zip"
        let zipURL = docs.appendingPathComponent(name)
        let importFailedURL = docs.appendingPathComponent("Import Failed").appendingPathComponent(name)
        defer {
            try? FileManager.default.removeItem(at: zipURL)
            try? FileManager.default.removeItem(at: importFailedURL)
        }

        let archive = try Archive(url: zipURL, accessMode: .create)
        let badData = Data("not a wad".utf8)
        try archive.addEntry(with: "corrupt.wad", type: .file,
                             uncompressedSize: Int64(badData.count),
                             provider: { pos, size in
            badData.subdata(in: Int(pos)..<Int(pos) + size)
        })

        let outcome = await importer.adoptLooseFiles()

        XCTAssertFalse(outcome.rejected.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: zipURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: importFailedURL.path))
    }

    /// Plan 2 consciously accepted "import wins, delete the zip" when a
    /// candidate's *other* entries are simply corrupt (see the all-fail
    /// case above) — those bytes were never recoverable anyway. An oversize
    /// entry is different: it's legitimate content that only failed
    /// because of the import-time size cap, so deleting the zip would
    /// destroy the only surviving copy. The adopt path must quarantine
    /// instead, even though ok.wad did import successfully.
    func testAdoptLooseFilesQuarantinesMixedZipWithOversizeEntryEvenThoughSomethingImported() async throws {
        let docs = URL.documentsDirectory
        let name = "mixed-\(UUID().uuidString).zip"
        let zipURL = docs.appendingPathComponent(name)
        let importFailedURL = docs.appendingPathComponent("Import Failed").appendingPathComponent(name)
        defer {
            try? FileManager.default.removeItem(at: zipURL)
            try? FileManager.default.removeItem(at: importFailedURL)
        }

        let wadData = makeWAD(magic: "PWAD", lumps: ["MAP01"])
        let big = Data(repeating: 0, count: wadData.count + 1000)
        let archive = try Archive(url: zipURL, accessMode: .create)
        try archive.addEntry(with: "ok.wad", type: .file,
                             uncompressedSize: Int64(wadData.count),
                             provider: { pos, size in wadData.subdata(in: Int(pos)..<Int(pos) + size) })
        try archive.addEntry(with: "big.wad", type: .file,
                             uncompressedSize: Int64(big.count),
                             provider: { pos, size in big.subdata(in: Int(pos)..<Int(pos) + size) })
        importer.maxZipEntryBytes = Int64(wadData.count)

        let outcome = await importer.adoptLooseFiles()

        XCTAssertEqual(outcome.imported, ["ok"])
        XCTAssertEqual(outcome.rejected["big.wad"], "Entry exceeds the 0 MB import limit.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: zipURL.path),
                       "zip should have been moved out of Documents")
        XCTAssertTrue(FileManager.default.fileExists(atPath: importFailedURL.path),
                      "zip should be quarantined, not deleted, once it contributed an oversize rejection")
    }

    /// Regression: adoptLooseFiles used to decide keep/quarantine/delete by
    /// diffing a *shared* outcome's rejected-dictionary keys before/after
    /// each candidate, to isolate what that candidate contributed. When two
    /// zips each drop an oversize entry under the identical basename, the
    /// second zip's rejection landed on a key the first zip had already
    /// added — the diff saw nothing "new" for it — so a zip that also
    /// imported a valid wad got DELETED instead of quarantined, destroying
    /// the only surviving copy of its oversize entry. adoptLooseFiles now
    /// tracks each candidate's own local ImportOutcome, immune to this.
    func testAdoptLooseFilesQuarantinesBothZipsWhenOversizeEntriesShareABasename() async throws {
        let docs = URL.documentsDirectory
        let firstName = "first-\(UUID().uuidString).zip"
        let secondName = "second-\(UUID().uuidString).zip"
        let firstURL = docs.appendingPathComponent(firstName)
        let secondURL = docs.appendingPathComponent(secondName)
        let firstFailedURL = docs.appendingPathComponent("Import Failed").appendingPathComponent(firstName)
        let secondFailedURL = docs.appendingPathComponent("Import Failed").appendingPathComponent(secondName)
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
            try? FileManager.default.removeItem(at: firstFailedURL)
            try? FileManager.default.removeItem(at: secondFailedURL)
        }

        let wadData = makeWAD(magic: "PWAD", lumps: ["MAP01"])
        let big = Data(repeating: 0, count: wadData.count + 1000)

        // First zip: an oversize entry only, no valid content.
        let firstArchive = try Archive(url: firstURL, accessMode: .create)
        try firstArchive.addEntry(with: "big.wad", type: .file,
                                 uncompressedSize: Int64(big.count),
                                 provider: { pos, size in big.subdata(in: Int(pos)..<Int(pos) + size) })

        // Second zip: a valid wad PLUS an oversize entry with the exact same
        // basename ("big.wad") as the first zip's.
        let secondArchive = try Archive(url: secondURL, accessMode: .create)
        try secondArchive.addEntry(with: "ok.wad", type: .file,
                                  uncompressedSize: Int64(wadData.count),
                                  provider: { pos, size in wadData.subdata(in: Int(pos)..<Int(pos) + size) })
        try secondArchive.addEntry(with: "big.wad", type: .file,
                                  uncompressedSize: Int64(big.count),
                                  provider: { pos, size in big.subdata(in: Int(pos)..<Int(pos) + size) })

        importer.maxZipEntryBytes = Int64(wadData.count)

        let outcome = await importer.adoptLooseFiles()

        XCTAssertEqual(outcome.imported, ["ok"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path),
                       "first zip should have been moved out of Documents")
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path),
                       "second zip should have been moved out of Documents")
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstFailedURL.path),
                      "first zip (oversize-only) should be quarantined, not deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondFailedURL.path),
                      "second zip should be quarantined even though ok.wad imported, not deleted")
    }

    /// Spec: "files dropped directly into the container via the iOS Files app
    /// are adopted and simply appear" — an adopted loose PWAD must show up in
    /// Files' grouped inventory.
    func testAdoptedLooseFileAppearsInFileGroups() async throws {
        let docs = URL.documentsDirectory
        let loose = docs.appendingPathComponent("dropped.wad")
        try makeWAD(magic: "PWAD", lumps: ["MAP01"]).write(to: loose)
        defer { try? FileManager.default.removeItem(at: loose) }

        let outcome = await importer.adoptLooseFiles()
        XCTAssertEqual(outcome.imported, ["dropped"])

        let groups = try library.fileGroups()
        let mods = try XCTUnwrap(groups.first { $0.role == .mapSet })
        XCTAssertTrue(mods.wads.contains { $0.filename == "dropped.wad" })
        XCTAssertEqual(mods.wads.first { $0.filename == "dropped.wad" }
                           .map { library.fileStatus(for: $0) }, .imported)
    }

    /// `Task.detached` deliberately does not inherit the caller's
    /// cancellation, so adoptLooseFiles's detached hashing and copying used
    /// to run to completion no matter what the awaiting task did. Cancelling
    /// that task must now stop the scan at the top of the next candidate,
    /// before that candidate's detached work starts, returning whatever the
    /// scan had already accumulated.
    ///
    /// Deterministic without racing in-flight work: the Task below inherits
    /// this test's MainActor, so its body cannot begin until this method
    /// suspends at an `await` — cancelling on the line straight after
    /// creating it guarantees adoptLooseFiles sees cancellation before it
    /// touches the first candidate, so the expected outcome is empty rather
    /// than "empty or partial".
    func testAdoptLooseFilesStopsWhenTheCallingTaskIsCancelled() async throws {
        let docs = URL.documentsDirectory
        let name = "cancelled-\(UUID().uuidString).wad"
        let loose = docs.appendingPathComponent(name)
        let importFailedURL = docs.appendingPathComponent("Import Failed").appendingPathComponent(name)
        try makeWAD(magic: "PWAD", lumps: ["MAP01"]).write(to: loose)
        defer {
            try? FileManager.default.removeItem(at: loose)
            try? FileManager.default.removeItem(at: importFailedURL)
        }

        let task = Task { await importer.adoptLooseFiles() }
        task.cancel()
        let outcome = await task.value

        XCTAssertEqual(outcome, ImportOutcome(),
                       "a cancelled scan returns what it accumulated before stopping — here, nothing")
        XCTAssertTrue(try library.allWADs().isEmpty,
                      "a cancelled scan must not register anything in the library")
        XCTAssertTrue(FileManager.default.fileExists(atPath: loose.path),
                      "the loose file must be left in place for a later scan, not consumed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: importFailedURL.path),
                       "a cancelled scan must not quarantine anything either")
    }

    // MARK: recognized IWAD titles (#118)

    /// The import path must title a recognized file from its *content*. Driven
    /// through `LibraryService.recognizedTitle` rather than a real doom2.wad:
    /// the repository ships no commercial WAD content, so a synthetic fixture
    /// registers its own hash and stands in for one.
    ///
    /// The filename here is deliberately nothing like the game's name, so the
    /// assertion can only pass by way of the hash — and the second assertion
    /// pins that explicitly, since "whatever-i-called-it" is exactly what the
    /// old filename-derived behavior would have produced.
    func testImportAppliesRecognizedTitleFromContentHash() async throws {
        let data = makeWAD(magic: "IWAD", lumps: ["MAP01"])
        let sha1 = WADStore.sha1(of: data)
        library.recognizedTitle = { $0 == sha1 ? "DOOM II: Hell on Earth" : nil }

        let outcome = await importer.importFiles(at: [try write("whatever-i-called-it.wad", data)], from: .picker)

        XCTAssertEqual(outcome.imported.count, 1)
        let wad = try XCTUnwrap(library.allWADs().first)
        XCTAssertEqual(wad.displayName, "DOOM II: Hell on Earth")
        XCTAssertNotEqual(wad.displayName, "whatever-i-called-it",
                          "a recognized IWAD must not be titled from its filename")
    }

    /// The parity requirement itself: renaming the file before importing it
    /// cannot change a recognized title. Two independent libraries, because the
    /// content hash would otherwise dedupe the second import away.
    func testRecognizedTitleIsUnchangedByRenamingTheFileBeforeImport() async throws {
        let data = makeWAD(magic: "IWAD", lumps: ["MAP01"])
        let sha1 = WADStore.sha1(of: data)

        var titles: [String] = []
        for name in ["doom2.wad", "renamed-by-the-user.wad"] {
            let (library, importer) = try freshStack()
            library.recognizedTitle = { $0 == sha1 ? "DOOM II: Hell on Earth" : nil }
            _ = await importer.importFiles(at: [try write(name, data)], from: .picker)
            titles.append(try XCTUnwrap(library.allWADs().first?.displayName))
        }

        XCTAssertEqual(titles, ["DOOM II: Hell on Earth", "DOOM II: Hell on Earth"])
    }

    /// The unknown-hash case, which is every PWAD and every mod, forever: the
    /// filename-derived name this line has always produced must survive.
    func testUnrecognizedImportKeepsTheFilenameDerivedTitle() async throws {
        let data = makeWAD(magic: "PWAD", lumps: ["MAP01"])
        // Recognizes something, just not this file — so a pass here means the
        // fallback ran, not that recognition was switched off wholesale.
        library.recognizedTitle = { $0 == "not-this-files-hash" ? "Some Other Game" : nil }

        _ = await importer.importFiles(at: [try write("sunlust.wad", data)], from: .picker)

        XCTAssertEqual(try library.allWADs().first?.displayName, "sunlust")
    }

    /// Production wiring: with no seam set, a real import resolves against the
    /// shipped catalog. A synthetic fixture can't match a published hash, so
    /// the observable end of this is the fallback — which is what proves the
    /// default is a live lookup and not a stub that returns nil unconditionally
    /// (the published-hash side of that same default is covered directly in
    /// IWADCatalogTests).
    func testDefaultRecognizerIsTheShippedCatalog() async throws {
        let data = makeWAD(magic: "IWAD", lumps: ["MAP01"])
        XCTAssertNil(IWADCatalog.title(forSHA1: WADStore.sha1(of: data)),
                     "a synthetic fixture must not collide with a published IWAD hash")

        _ = await importer.importFiles(at: [try write("mystery.wad", data)], from: .picker)

        XCTAssertEqual(try library.allWADs().first?.displayName, "mystery")
    }

    // MARK: dedupe ordering

    func testDuplicateImportDoesNotWriteNewStoreFile() async throws {
        let data = makeWAD(magic: "PWAD", lumps: ["MAP01"])
        _ = await importer.importFiles(at: [try write("a.wad", data)], from: .picker)
        let storeDir = tmp.appendingPathComponent("WADs", isDirectory: true)
        let before = try FileManager.default.contentsOfDirectory(
            at: storeDir, includingPropertiesForKeys: nil).count

        _ = await importer.importFiles(at: [try write("b.wad", data)], from: .picker)

        let after = try FileManager.default.contentsOfDirectory(
            at: storeDir, includingPropertiesForKeys: nil).count
        XCTAssertEqual(after, before)
    }

    // MARK: repair when the stored file went missing

    func testReimportRestoresRowWhenStoredFileWasDeleted() async throws {
        let data = makeWAD(magic: "PWAD", lumps: ["MAP01"])
        let first = await importer.importFiles(at: [try write("a.wad", data)], from: .picker)
        XCTAssertEqual(first.imported, ["a"])
        let wad = try XCTUnwrap(library.allWADs().first)
        try FileManager.default.removeItem(at: library.fileURL(for: wad))

        let second = await importer.importFiles(at: [try write("b.wad", data)], from: .picker)

        XCTAssertEqual(second.imported, ["b"])
        XCTAssertTrue(second.duplicates.isEmpty)
        XCTAssertEqual(try library.allWADs().count, 1)
        let repaired = try XCTUnwrap(try library.wad(id: wad.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.fileURL(for: repaired).path))

        let storeDir = tmp.appendingPathComponent("WADs", isDirectory: true)
        let filesInStore = try FileManager.default.contentsOfDirectory(
            at: storeDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(filesInStore.count, 1)
    }

    /// A map PWAD whose row has `hasMaps == false` (e.g. it predates the field,
    /// or was migrated while its file was missing) must not stay classified
    /// `.addOn` forever: repairing it re-parses the restored bytes, so
    /// `hasMaps` must be recorded alongside the filename, not just the
    /// filename alone.
    func testRepairingAMissingPWADRecordsItsMaps() async throws {
        let data = makeWAD(magic: "PWAD", lumps: ["MAP01", "THINGS"])
        let first = await importer.importFiles(at: [try write("a.wad", data)], from: .picker)
        XCTAssertEqual(first.imported, ["a"])
        let wad = try XCTUnwrap(library.allWADs().first)
        wad.hasMaps = false   // the row predates hasMaps / was migrated while the file was missing
        try library.saveChanges()
        try FileManager.default.removeItem(at: library.fileURL(for: wad))

        // Re-import the same bytes (keeping the SHA-1 the row already holds)
        // under a new name, so this hits the "row exists but its file
        // vanished" repair branch rather than a fresh import.
        let second = await importer.importFiles(at: [try write("b.wad", data)], from: .picker)

        XCTAssertEqual(second.imported, ["b"])
        let repaired = try XCTUnwrap(try library.wad(id: wad.id))
        XCTAssertTrue(repaired.hasMaps)
        XCTAssertEqual(repaired.role, .mapSet)
    }

    // MARK: mapped reads

    /// A WAD whose directory sits *after* real lump data, so parsing has to
    /// address the middle of the file rather than read straight off the
    /// header. `makeWAD` puts the directory at offset 12 with zero-size lumps,
    /// which would not exercise the seek at all — and seeking by offset is
    /// exactly the property `.mappedIfSafe` has to preserve, since `Data`
    /// indexes the same way whether the bytes are a heap buffer or a mapping.
    private func makeWADWithBodies(magic: String, lumps: [(String, [UInt8])]) -> Data {
        var body = Data()
        var entries: [(pos: Int32, size: Int32, name: String)] = []
        for (name, bytes) in lumps {
            entries.append((pos: Int32(12 + body.count), size: Int32(bytes.count), name: name))
            body.append(contentsOf: bytes)
        }
        var data = Data(magic.utf8)
        data.append(contentsOf: withUnsafeBytes(of: Int32(lumps.count).littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: Int32(12 + body.count).littleEndian,
                                                Array.init))
        data.append(body)
        for entry in entries {
            data.append(contentsOf: withUnsafeBytes(of: entry.pos.littleEndian, Array.init))
            data.append(contentsOf: withUnsafeBytes(of: entry.size.littleEndian, Array.init))
            var nameBytes = Array(entry.name.utf8.prefix(8))
            nameBytes.append(contentsOf: Array(repeating: 0, count: 8 - nameBytes.count))
            data.append(contentsOf: nameBytes)
        }
        return data
    }

    /// The property the import path now turns on: reading a WAD mapped yields
    /// the same bytes, the same parse and the same SHA-1 as reading it whole.
    /// Hermetic — a few KB proves it; the 280MB megawad this exists for cannot
    /// be a fixture, and peak memory is deliberately not asserted here (see the
    /// issue: XCTMemoryMetric on a simulator does not measure what jetsam
    /// cares about).
    func testMappedReadParsesAndHashesIdenticallyToPlainRead() throws {
        let lumps: [(String, [UInt8])] = [
            ("MAP01", [UInt8](repeating: 0xAB, count: 4096)),
            ("THINGS", (0...255).map { UInt8($0) }),
            ("SIDEDEFS", []),
        ]
        let url = try write("mapped.wad", makeWADWithBodies(magic: "PWAD", lumps: lumps))

        let plain = try Data(contentsOf: url)
        let mapped = try Data(contentsOf: url, options: .mappedIfSafe)

        XCTAssertEqual(mapped.count, plain.count)
        XCTAssertEqual(Array(mapped), Array(plain), "mapped read differs byte-for-byte")

        let plainParsed = try WADParser.parse(plain)
        let mappedParsed = try WADParser.parse(mapped)
        XCTAssertEqual(mappedParsed.kind, plainParsed.kind)
        XCTAssertEqual(mappedParsed.kind, .pwad)
        XCTAssertEqual(mappedParsed.lumpNames, plainParsed.lumpNames)
        XCTAssertEqual(mappedParsed.lumpNames, ["MAP01", "THINGS", "SIDEDEFS"])
        XCTAssertEqual(WADParser.gameFamily(of: mappedParsed.lumpNames),
                       WADParser.gameFamily(of: plainParsed.lumpNames))

        XCTAssertEqual(WADStore.sha1(of: mapped), WADStore.sha1(of: plain))
        // ...and against the streamed hasher, which never loads the file at
        // all: three independent reads of the same bytes must agree.
        XCTAssertEqual(WADStore.sha1(of: mapped), try WADStore.sha1(ofFileAt: url))
    }

    /// The same property through `importOne` itself, on a WAD whose directory
    /// is past its lump data: what lands in the library must be the hash of
    /// the file on disk, not of whatever the mapped read happened to page in.
    func testImportHashesMappedWADToItsOnDiskSHA1() async throws {
        let data = makeWADWithBodies(magic: "PWAD",
                                     lumps: [("MAP01", [UInt8](repeating: 0x7F, count: 8192))])
        let url = try write("body.wad", data)
        let expected = try WADStore.sha1(ofFileAt: url)

        let outcome = await importer.importFiles(at: [url], from: .picker)

        XCTAssertEqual(outcome.imported, ["body"])
        let wad = try XCTUnwrap(try library.allWADs().first)
        XCTAssertEqual(wad.sha1, expected)
        XCTAssertEqual(wad.kindRaw, WADKind.pwad.rawValue)
        XCTAssertEqual(wad.gameFamilyRaw, GameFamily.doom2.rawValue)
    }

    /// And through the detached-task branch (`adoptLooseFiles`), which is the
    /// one that runs at launch and on every foreground — the reason a resident
    /// whole-file read mattered enough to fix.
    func testAdoptLooseFilesHashesMappedWADToItsOnDiskSHA1() async throws {
        let docs = URL.documentsDirectory
        let name = "mapped-\(UUID().uuidString).wad"
        let looseURL = docs.appendingPathComponent(name)
        try makeWADWithBodies(magic: "PWAD",
                              lumps: [("MAP01", [UInt8](repeating: 0x5A, count: 8192))])
            .write(to: looseURL)
        let expected = try WADStore.sha1(ofFileAt: looseURL)
        defer { try? FileManager.default.removeItem(at: looseURL) }

        let outcome = await importer.adoptLooseFiles()

        XCTAssertTrue(outcome.imported.contains((name as NSString).deletingPathExtension),
                      "adoptLooseFiles did not import the loose WAD: \(outcome)")
        let wad = try XCTUnwrap(try library.allWADs().first { $0.sha1 == expected })
        XCTAssertEqual(wad.kindRaw, WADKind.pwad.rawValue)
    }

    /// A PWAD with map lumps registers as a map set; one with only graphics
    /// lumps registers as an add-on (spec §2.1) -- `WADFile.role` reads this
    /// straight off `hasMaps`, so the import path has to set it.
    func testImportRecordsWhetherAPWADCarriesMaps() async throws {
        let maps = try write("maps.wad", makeWAD(magic: "PWAD", lumps: ["MAP01", "THINGS"]))
        let gfx = try write("gfx.wad", makeWAD(magic: "PWAD", lumps: ["TITLEPIC"]))

        _ = await importer.importFiles(at: [maps, gfx], from: .picker)

        XCTAssertEqual(try library.allWADs().first { $0.filename.hasPrefix("maps") }?.role, .mapSet)
        XCTAssertEqual(try library.allWADs().first { $0.filename.hasPrefix("gfx") }?.role, .addOn)
    }

    /// Same property as `testImportRecordsWhetherAPWADCarriesMaps`, through the
    /// async `adoptLooseFiles` path (the detached-task branch that scans the
    /// Files-app drop zone) rather than the picker route.
    func testAdoptLooseFilesRecordsWhetherAPWADCarriesMaps() async throws {
        try library.seedBundledContentIfNeeded()
        let docs = URL.documentsDirectory
        let mapsName = "maps-\(UUID().uuidString).wad"
        let gfxName = "gfx-\(UUID().uuidString).wad"
        let mapsURL = docs.appendingPathComponent(mapsName)
        let gfxURL = docs.appendingPathComponent(gfxName)
        try makeWAD(magic: "PWAD", lumps: ["MAP01", "THINGS"]).write(to: mapsURL)
        try makeWAD(magic: "PWAD", lumps: ["TITLEPIC"]).write(to: gfxURL)
        defer {
            try? FileManager.default.removeItem(at: mapsURL)
            try? FileManager.default.removeItem(at: gfxURL)
        }

        let outcome = await importer.adoptLooseFiles()

        XCTAssertTrue(outcome.imported.contains((mapsName as NSString).deletingPathExtension))
        XCTAssertTrue(outcome.imported.contains((gfxName as NSString).deletingPathExtension))
        XCTAssertEqual(try library.allWADs().first { $0.filename == mapsName }?.role, .mapSet)
        XCTAssertEqual(try library.allWADs().first { $0.filename == gfxName }?.role, .addOn)
        XCTAssertTrue(outcome.games.contains((mapsName as NSString).deletingPathExtension),
                      "the adoption route categorizes exactly like the picker route")
        XCTAssertTrue(outcome.addOns.contains((gfxName as NSString).deletingPathExtension))
        XCTAssertTrue(outcome.unpaired.isEmpty)
    }

    // MARK: repair adopts a restored map set (spec §3.5, §4.1)

    /// A map set's row can predate pairing entirely — registered with
    /// `hasMaps: false` (legacy migration default), so it never got a game —
    /// and then its backing file goes missing. Repairing it (via the picker route)
    /// must adopt it into a game exactly as a fresh import would, not just
    /// restore the filename.
    func testRepairingARestoredMapSetWithNoGameAdoptsIt() async throws {
        let data = makeWAD(magic: "PWAD", lumps: ["MAP01", "THINGS"])
        let sha1 = WADStore.sha1(of: data)
        let wad = try library.registerImported(filename: "a.wad", sha1: sha1,
                                               kind: WADKind.pwad.rawValue,
                                               family: GameFamily.doom2.rawValue, hasMaps: false)
        XCTAssertTrue(try library.gamesUsing(fileID: wad.id).isEmpty, "hasMaps false at registration created no game")
        let fileURL = library.fileURL(for: wad)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: fileURL)
        try FileManager.default.removeItem(at: fileURL)   // backing file vanished out-of-band

        try library.seedBundledContentIfNeeded()
        let outcome = await importer.importFiles(at: [try write("b.wad", data)], from: .picker)

        XCTAssertEqual(outcome.imported, ["b"])
        let repaired = try XCTUnwrap(try library.wad(id: wad.id))
        XCTAssertEqual(repaired.role, .mapSet)
        let game = try XCTUnwrap(try library.gamesUsing(fileID: repaired.id).first,
                                 "a restored map set must get a tile")
        XCTAssertEqual(game.fileIDs, [repaired.id])
        XCTAssertEqual(outcome.games, ["b"])
    }

    // MARK: one entry point, and files whose names do not carry their type (#499)

    /// A WAD written under an extensionless name, as a download lands in a
    /// temporary file: nothing in the URL says what it is.
    private func writeExtensionless(_ data: Data) throws -> URL {
        let dir = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("download")
        try data.write(to: url)
        return url
    }

    func testExtensionlessWADWithASuggestedFilenameIsImported() async throws {
        let url = try writeExtensionless(makeWAD(magic: "PWAD", lumps: ["MAP01"]))
        let outcome = await importer.importFile(at: url, from: .openIn, suggestedFilename: "x.wad")
        XCTAssertEqual(outcome.imported, ["x"])
        XCTAssertTrue(outcome.rejected.isEmpty)
        XCTAssertEqual(try library.allWADs().first?.filename, "x.wad")
        XCTAssertEqual(try library.allWADs().first?.kindRaw, WADKind.pwad.rawValue)
    }

    func testExtensionlessWADWithNoSuggestedFilenameIsImportedByItsHeader() async throws {
        let url = try writeExtensionless(makeWAD(magic: "IWAD", lumps: ["E1M1", "THINGS"]))
        let outcome = await importer.importFile(at: url, from: .openIn)
        XCTAssertEqual(outcome.imported, ["download"])
        XCTAssertEqual(outcome.games, ["download"])
        XCTAssertEqual(try library.allWADs().first?.filename, "download.wad",
                       "a WAD recognised by its header is stored as a .wad")
        XCTAssertEqual(try library.allWADs().first?.kindRaw, WADKind.iwad.rawValue)
    }

    func testExtensionlessZipIsUnpackedAndItsWADsImported() async throws {
        let zipURL = tmp.appendingPathComponent("build.zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        let wadData = makeWAD(magic: "PWAD", lumps: ["E1M1"])
        try archive.addEntry(with: "release/map.wad", type: .file,
                             uncompressedSize: Int64(wadData.count),
                             provider: { pos, size in
            wadData.subdata(in: Int(pos)..<Int(pos) + size)
        })
        let url = try writeExtensionless(try Data(contentsOf: zipURL))

        let outcome = await importer.importFile(at: url, from: .openIn)

        XCTAssertEqual(outcome.imported, ["map"])
        XCTAssertTrue(outcome.rejected.isEmpty)
        XCTAssertEqual(try library.allWADs().first?.gameFamilyRaw, "doom1")
    }

    /// The usual result of a link that leads to a page instead of a file.
    func testHTMLSavedAsDownloadIsRejectedAsUnsupported() async throws {
        let url = try writeExtensionless(Data("<!doctype html><html><body>Not here</body></html>".utf8))
        let outcome = await importer.importFile(at: url, from: .openIn)
        XCTAssertEqual(outcome.rejected, ["download": "Unsupported file type."])
        XCTAssertTrue(outcome.imported.isEmpty)
        XCTAssertTrue(try library.allWADs().isEmpty)
    }

    /// A name that says what the file is wins over the content: a `.wad`
    /// that is not one keeps today's specific reason, rather than being
    /// sniffed into something vaguer.
    func testANamedTypeIsTrustedOverTheContent() async throws {
        let url = try writeExtensionless(Data("<!doctype html>".utf8))
        let outcome = await importer.importFile(at: url, from: .openIn, suggestedFilename: "x.wad")
        XCTAssertEqual(outcome.rejected, ["x.wad": "Not a WAD file (bad header magic)."])
    }

    /// A DeHackEd patch has no magic, so only a name can say what it is.
    func testDEHIsRecognisedOnlyByName() async throws {
        let patch = Data("Patch File for DeHackEd v3.0".utf8)
        let unnamed = try writeExtensionless(patch)
        let rejected = await importer.importFile(at: unnamed, from: .openIn)
        XCTAssertEqual(rejected.rejected, ["download": "Unsupported file type."])

        let named = try writeExtensionless(patch)
        let imported = await importer.importFile(at: named, from: .openIn, suggestedFilename: "tweaks.bex")
        XCTAssertEqual(imported.imported, ["tweaks"])
        XCTAssertEqual(try library.allWADs().first?.kindRaw, WADKind.deh.rawValue)
    }

    func testTheAcceptedExtensionsAreDefinedOnceAndShared() {
        XCTAssertEqual(ImportFileType.acceptedExtensions, ["wad", "deh", "bex", "zip"])
        XCTAssertEqual(ImportFileType.zipMemberExtensions, ["wad", "deh", "bex"])
        XCTAssertEqual(WADImport.contentTypes.count, ImportFileType.acceptedExtensions.count,
                       "the picker offers every accepted type")
        XCTAssertTrue(WADImport.contentTypes.contains(.zip))
    }

    /// Each route gives the outcome, notice, usage count and refresh it gave
    /// before it went through the one entry point: the picker and Open In
    /// say what happened and leave the file where it was; adoption also
    /// takes the file, and its notice says where a failure went.
    func testEachRouteGivesTheSameOutcomeNoticeAndUsageAsBefore() async throws {
        let good = makeWAD(magic: "PWAD", lumps: ["TITLEPIC"])   // an add-on: no base needed
        let bad = Data("this is not a WAD file at all".utf8)   // past the 12-byte header

        for route in [ImportRoute.picker, .openIn] {
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            let container = try ModelContainer(for: WADFile.self, Game.self, configurations: config)
            let store = WADStore(directory: tmp.appendingPathComponent(UUID().uuidString, isDirectory: true))
            let library = LibraryService(context: ModelContext(container), store: store)
            let notices = ImportNotices()
            let usage = UsageStore(directory: tmp.appendingPathComponent(UUID().uuidString, isDirectory: true))
            let importer = ImportService(library: library, store: store, notices: notices, usage: usage)
            let dir = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let goodURL = dir.appendingPathComponent("smooth.wad")
            let badURL = dir.appendingPathComponent("junk.wad")
            try good.write(to: goodURL)
            try bad.write(to: badURL)

            let refreshed = expectation(forNotification: .libraryDidChange, object: nil)
            let outcome = await importer.importFiles(at: [goodURL, badURL], from: route)
            await fulfillment(of: [refreshed], timeout: 1)

            var expected = ImportOutcome()
            expected.imported = ["smooth"]
            expected.addOns = ["smooth"]
            expected.rejected = ["junk.wad": "Not a WAD file (bad header magic)."]
            XCTAssertEqual(outcome, expected, "\(route)")
            XCTAssertEqual(notices.current,
                           "Imported smooth as an add-on. Attach it from any game's page. · 1 failed",
                           "\(route)")
            XCTAssertEqual(usage.summary().wadsImported, 1, "\(route)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: goodURL.path),
                          "\(route) leaves the file it was handed where it was")
            XCTAssertTrue(FileManager.default.fileExists(atPath: badURL.path), "\(route)")
        }

        // Adoption: the same two files, dropped into Documents.
        let docs = URL.documentsDirectory
        let goodName = "smooth-\(UUID().uuidString).wad"
        let badName = "junk-\(UUID().uuidString).wad"
        let goodURL = docs.appendingPathComponent(goodName)
        let badURL = docs.appendingPathComponent(badName)
        let quarantined = docs.appendingPathComponent("Import Failed").appendingPathComponent(badName)
        try good.write(to: goodURL)
        try bad.write(to: badURL)
        defer {
            for url in [goodURL, badURL, quarantined] { try? FileManager.default.removeItem(at: url) }
        }

        let refreshed = expectation(forNotification: .libraryDidChange, object: nil)
        let outcome = await importer.adoptLooseFiles()
        await fulfillment(of: [refreshed], timeout: 1)

        let goodStem = (goodName as NSString).deletingPathExtension
        var expected = ImportOutcome()
        expected.imported = [goodStem]
        expected.addOns = [goodStem]
        expected.rejected = [badName: "Not a WAD file (bad header magic)."]
        XCTAssertEqual(outcome, expected)
        XCTAssertEqual(notices.current,
                       "Imported \(goodStem) as an add-on. Attach it from any game's page. "
                       + "· 1 failed (moved to Import Failed)")
        XCTAssertEqual(usage.summary().wadsImported, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: goodURL.path), "an adopted file is taken")
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantined.path), "a failure is quarantined")
    }

    /// An Open In of a Documents/Inbox copy that the adoption scan already
    /// took has nothing left to import, and must not report a failure for
    /// a file that did import.
    func testOpenInOfAnInboxCopyAdoptionAlreadyTookReportsNothing() async throws {
        let inbox = URL.documentsDirectory.appendingPathComponent("Inbox", isDirectory: true)
        let gone = inbox.appendingPathComponent("gone-\(UUID().uuidString).wad")
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path))

        let outcome = await importer.importFile(at: gone, from: .openIn)

        XCTAssertEqual(outcome, ImportOutcome())
        XCTAssertNil(notices.current)
    }

    // MARK: the gate: one request at a time across every caller (#506 review)

    /// Two routes importing the same bytes at once (an Open In whose Inbox
    /// copy the adoption scan also lists is the real case) must register the
    /// file once and report the other as a duplicate. Without the gate both
    /// miss the sha1 index across the awaits in the middle of the import and
    /// register it twice.
    func testConcurrentImportsOfTheSameBytesRegisterItOnce() async throws {
        // Big enough that hashing and copying it on a detached task takes
        // long enough for the other callers to reach the sha1 lookup.
        let data = makeWADWithBodies(magic: "PWAD",
                                     lumps: [("MAP01", []), ("BULK", Array(repeating: 0x5A, count: 8 << 20))])
        let importer = self.importer!
        var tasks: [Task<ImportOutcome, Never>] = []
        for i in 0..<6 {
            if i.isMultiple(of: 2) {
                let url = try write("picked-\(i).wad", data)
                tasks.append(Task { await importer.importFiles(at: [url], from: .picker) })
            } else {
                let url = try writeExtensionless(data)
                tasks.append(Task {
                    await importer.importFile(at: url, from: .openIn, suggestedFilename: "opened-\(i).wad")
                })
            }
        }
        var outcomes: [ImportOutcome] = []
        for task in tasks { outcomes.append(await task.value) }

        XCTAssertEqual(try library.allWADs().count, 1, "the same bytes are registered once")
        XCTAssertEqual(outcomes.map(\.imported.count).reduce(0, +), 1)
        XCTAssertEqual(outcomes.map(\.duplicates.count).reduce(0, +), 5,
                       "every import after the first reports a duplicate")
    }

    /// Callers cancelled while others hold or wait for the gate must not
    /// wedge it: every caller that was not cancelled still imports its file,
    /// a cancelled one imports either its file or nothing, and an import
    /// started afterwards still runs.
    func testCancelledCallersDoNotWedgeTheGate() async throws {
        let importer = self.importer!
        var tasks: [Task<ImportOutcome, Never>] = []
        for i in 0..<8 {
            let url = try write("many-\(i).wad", makeWAD(magic: "PWAD", lumps: ["MAP0\(i)", "LUMP\(i)"]))
            tasks.append(Task { await importer.importFiles(at: [url], from: .picker) })
        }
        // Let them start and queue on the gate, then cancel every other one.
        for _ in 0..<3 { await Task.yield() }
        for (i, task) in tasks.enumerated() where i % 2 == 1 { task.cancel() }

        var importedCount = 0
        for (i, task) in tasks.enumerated() {
            let outcome = await task.value
            if i % 2 == 0 {
                XCTAssertEqual(outcome.imported, ["many-\(i)"], "caller \(i) was not cancelled")
            } else {
                XCTAssertTrue(outcome.imported == [] || outcome.imported == ["many-\(i)"],
                              "caller \(i): \(outcome.imported)")
            }
            importedCount += outcome.imported.count
        }
        XCTAssertEqual(try library.allWADs().count, importedCount)

        let later = try write("later.wad", makeWAD(magic: "PWAD", lumps: ["LATER"]))
        let outcome = await importer.importFiles(at: [later], from: .picker)
        XCTAssertEqual(outcome.imported, ["later"], "the gate still admits a new caller")
    }

    /// A patch whose suggested name has no extension keeps the URL's, as a
    /// WAD gets `.wad` added.
    func testDEHWithAnExtensionlessSuggestedNameKeepsTheURLsExtension() async throws {
        let url = try write("tweaks.bex", Data("Patch File for DeHackEd v3.0".utf8))
        let outcome = await importer.importFile(at: url, from: .openIn, suggestedFilename: "tweaks")
        XCTAssertEqual(outcome.imported, ["tweaks"])
        XCTAssertEqual(try library.allWADs().first?.filename, "tweaks.bex")
    }

    /// A zip-based document that is not a game (a .docx through the zip
    /// document type) keeps its pre-sniffing rejection; a file that calls
    /// itself a .zip keeps the empty-zip one.
    func testANonGameZipDocumentIsUnsupportedButAnEmptyNamedZipSaysSo() async throws {
        let docx = tmp.appendingPathComponent("report.docx")
        let archive = try Archive(url: docx, accessMode: .create)
        let xml = Data("<w:document/>".utf8)
        try archive.addEntry(with: "word/document.xml", type: .file,
                             uncompressedSize: Int64(xml.count),
                             provider: { pos, size in xml.subdata(in: Int(pos)..<Int(pos) + size) })

        let asDocument = await importer.importFiles(at: [docx], from: .openIn)
        XCTAssertEqual(asDocument.rejected, ["report.docx": "Unsupported file type."])

        let named = try write("report.zip", try Data(contentsOf: docx))
        let asZip = await importer.importFiles(at: [named], from: .openIn)
        XCTAssertEqual(asZip.rejected, ["report.zip": "No WAD or DEH files inside the zip."])
    }

    // MARK: Restoring Freedoom a build no longer bundles (issue #503)

    /// Seeds the real bundled rows, gives Phase 1 a save, keeps a copy of its
    /// bytes, then relaunches as a build that ships no Freedoom. Returns the
    /// Phase 1 row's id and the copy.
    ///
    /// `legacyPlaceholder` gives every bundled row the pseudo-hash builds
    /// before a1dc675a stamped on it, as an install that skips straight from
    /// such a build to one without the files would have.
    private func releaseBundledFreedoom(copyTo copy: URL, legacyPlaceholder: Bool = false) throws -> UUID {
        try library.seedBundledContentIfNeeded()
        let phase1 = try XCTUnwrap(library.allWADs().first { $0.isBundled && $0.filename == "freedoom1.wad" })
        try FileManager.default.copyItem(at: library.fileURL(for: phase1), to: copy)
        if legacyPlaceholder {
            for wad in try library.allWADs() { wad.sha1 = "bundled:\(wad.filename)" }
            try library.saveChanges()
        }
        let saves = LibraryService.savesDirectory(forGameID: phase1.id)
        try FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: saves) }
        try Data("save".utf8).write(to: saves.appendingPathComponent("woofsav0.dsg"))

        let empty = tmp.appendingPathComponent("EmptyGameData", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        library.bundledContentDirectory = empty
        try library.seedBundledContentIfNeeded()
        XCTAssertEqual(library.fileStatus(for: phase1), .missing, "precondition")
        return phase1.id
    }

    private func assertRestored(_ id: UUID, _ outcome: ImportOutcome,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(outcome.duplicates.isEmpty, "a missing file is not a duplicate", file: file, line: line)
        XCTAssertEqual(outcome.imported.count, 1, file: file, line: line)
        XCTAssertEqual(try library.allWADs().count, 2, "restored in place, not added", file: file, line: line)
        let restored = try XCTUnwrap(try library.wad(id: id), file: file, line: line)
        XCTAssertEqual(library.fileStatus(for: restored), .imported, file: file, line: line)
        XCTAssertEqual(restored.displayName, "Freedoom Phase 1", file: file, line: line)
        XCTAssertNotNil(try library.game(id: id), "its base game keeps its id", file: file, line: line)
        XCTAssertEqual(library.saveSlots(forKey: id).map(\.id), ["woofsav0.dsg"],
                       "the game's existing saves are listed again", file: file, line: line)
    }

    func testImportingFreedoomAgainRestoresTheReleasedRowUnderItsOriginalID() async throws {
        let copy = tmp.appendingPathComponent("freedoom1.wad")
        let id = try releaseBundledFreedoom(copyTo: copy)

        let outcome = await importer.importFiles(at: [copy], from: .picker)

        try assertRestored(id, outcome)
        XCTAssertEqual(outcome.games, outcome.imported, "an IWAD is reported as a game")
    }

    func testAdoptingFreedoomAgainRestoresTheReleasedRowUnderItsOriginalID() async throws {
        // adoptLooseFiles scans the real Documents directory, so the copy has
        // to be dropped there.
        let copy = URL.documentsDirectory.appendingPathComponent("freedoom1-\(UUID().uuidString).wad")
        defer { try? FileManager.default.removeItem(at: copy) }
        let id = try releaseBundledFreedoom(copyTo: copy)

        let outcome = await importer.adoptLooseFiles()

        try assertRestored(id, outcome)
    }

    /// Another `freedoom1.wad` with different bytes (a different Freedoom
    /// release, say), imported after Phase 1 was released, must not be
    /// attached to the released row: it gets a row and a stored file of its
    /// own, and the original bytes still restore the released row.
    private func importOtherFreedoom1() async throws -> (outcome: ImportOutcome, row: WADFile) {
        let data = makeWAD(magic: "IWAD", lumps: ["E1M1", "THINGS"])
        let dir = tmp.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("freedoom1.wad")
        try data.write(to: url)
        let outcome = await importer.importFiles(at: [url], from: .picker)
        let row = try XCTUnwrap(try library.findWAD(sha1: WADStore.sha1(of: data)))
        return (outcome, row)
    }

    func testADifferentFileNamedLikeAReleasedRowGetsItsOwnRowAndFile() async throws {
        let original = tmp.appendingPathComponent("original.wad")
        let id = try releaseBundledFreedoom(copyTo: original)

        let (other, otherRow) = try await importOtherFreedoom1()

        XCTAssertEqual(other.imported.count, 1)
        XCTAssertNotEqual(otherRow.id, id)
        let released = try XCTUnwrap(try library.wad(id: id))
        XCTAssertNotEqual(otherRow.filename, released.filename, "each row needs its own stored file")
        XCTAssertEqual(library.fileStatus(for: released), .missing,
                       "the released row must not pick up a different file's bytes")
        XCTAssertEqual(library.fileStatus(for: otherRow), .imported)

        let restore = await importer.importFiles(at: [original], from: .picker)

        XCTAssertTrue(restore.duplicates.isEmpty, "only bytes matching the row's hash restore it")
        XCTAssertEqual(restore.imported.count, 1)
        let restored = try XCTUnwrap(try library.wad(id: id))
        XCTAssertEqual(library.fileStatus(for: restored), .imported)
        XCTAssertEqual(try WADStore.sha1(ofFileAt: library.fileURL(for: restored)), restored.sha1)
        XCTAssertEqual(try WADStore.sha1(ofFileAt: library.fileURL(for: otherRow)), otherRow.sha1)
        XCTAssertEqual(library.saveSlots(forKey: id).map(\.id), ["woofsav0.dsg"])
    }

    func testDeletingAReleasedRowLeavesAnotherRowsFileOfTheSameName() async throws {
        let id = try releaseBundledFreedoom(copyTo: tmp.appendingPathComponent("original.wad"))
        let (_, otherRow) = try await importOtherFreedoom1()

        try library.deleteWAD(try XCTUnwrap(try library.wad(id: id)))

        XCTAssertEqual(library.fileStatus(for: otherRow), .imported)
    }

    /// #506's import gate and #503's reserved store names compose: imports
    /// of different files with the same name, started at once from two
    /// routes, each end up with a row and a stored file of their own, and
    /// the released Freedoom row is restored only by its own bytes.
    func testConcurrentImportsOfDifferentFilesWithOneNameEachGetTheirOwnFile() async throws {
        let original = tmp.appendingPathComponent("Original", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let originalURL = original.appendingPathComponent("freedoom1.wad")
        let id = try releaseBundledFreedoom(copyTo: originalURL)

        var others: [(url: URL, sha1: String)] = []
        for (index, lumps) in [["E1M1", "THINGS"], ["E1M2", "THINGS"]].enumerated() {
            let data = makeWAD(magic: "IWAD", lumps: lumps)
            let dir = tmp.appendingPathComponent("Other\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("freedoom1.wad")
            try data.write(to: url)
            others.append((url, WADStore.sha1(of: data)))
        }

        let importer = self.importer!
        let tasks = [
            Task { _ = await importer.importFiles(at: [others[0].url], from: .picker) },
            Task { _ = await importer.importFiles(at: [originalURL], from: .openIn) },
            Task { _ = await importer.importFiles(at: [others[1].url], from: .picker) },
        ]
        for task in tasks { await task.value }

        let restored = try XCTUnwrap(try library.wad(id: id))
        let rows = try [restored] + others.map { try XCTUnwrap(try library.findWAD(sha1: $0.sha1)) }
        XCTAssertEqual(Set(rows.map(\.id)).count, 3, "every file has a row of its own")
        XCTAssertEqual(Set(rows.map(\.filename)).count, 3, "every row has a stored file of its own")
        for row in rows {
            XCTAssertEqual(library.fileStatus(for: row), .imported, row.filename)
            XCTAssertEqual(try WADStore.sha1(ofFileAt: library.fileURL(for: row)), row.sha1,
                           "\(row.filename) must hold its own row's bytes")
        }
        XCTAssertEqual(library.saveSlots(forKey: id).map(\.id), ["woofsav0.dsg"])
    }

    func testImportingFreedoomRestoresARowReleasedWithALegacyPlaceholder() async throws {
        let copy = tmp.appendingPathComponent("freedoom1.wad")
        let id = try releaseBundledFreedoom(copyTo: copy, legacyPlaceholder: true)

        let outcome = await importer.importFiles(at: [copy], from: .picker)

        try assertRestored(id, outcome)
    }
}
