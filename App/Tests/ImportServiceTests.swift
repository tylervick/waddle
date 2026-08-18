import SwiftData
import XCTest
import ZIPFoundation
@testable import Waddle

@MainActor
final class ImportServiceTests: XCTestCase {
    var importer: ImportService!
    var library: LibraryService!
    var tmp: URL!

    override func setUpWithError() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WADFile.self, Loadout.self, configurations: config)
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = WADStore(directory: tmp.appendingPathComponent("WADs", isDirectory: true))
        library = LibraryService(context: ModelContext(container), store: store)
        importer = ImportService(library: library, store: store)
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
        let container = try ModelContainer(for: WADFile.self, Loadout.self, configurations: config)
        let store = WADStore(directory: tmp.appendingPathComponent(UUID().uuidString,
                                                                   isDirectory: true))
        let library = LibraryService(context: ModelContext(container), store: store)
        return (library, ImportService(library: library, store: store))
    }

    func testImportsValidPWAD() throws {
        let url = try write("sunlust.wad", makeWAD(magic: "PWAD", lumps: ["MAP01"]))
        let outcome = importer.importFiles(at: [url])
        XCTAssertEqual(outcome.imported, ["sunlust"])
        XCTAssertEqual(try library.allWADs().first?.kindRaw, WADKind.pwad.rawValue)
        XCTAssertEqual(try library.allWADs().first?.gameFamilyRaw, "doom2")
    }

    func testRejectsInvalidWadWithReason() throws {
        let url = try write("fake.wad", Data("not a wad".utf8))
        let outcome = importer.importFiles(at: [url])
        XCTAssertTrue(outcome.imported.isEmpty)
        XCTAssertNotNil(outcome.rejected["fake.wad"])
        XCTAssertTrue(try library.allWADs().isEmpty)
    }

    func testDuplicateImportReported() throws {
        let data = makeWAD(magic: "PWAD", lumps: ["MAP01"])
        _ = importer.importFiles(at: [try write("a.wad", data)])
        let outcome = importer.importFiles(at: [try write("b.wad", data)])
        XCTAssertEqual(outcome.duplicates.count, 1)
        XCTAssertEqual(try library.allWADs().count, 1)
    }

    func testImportingByteIdenticalCopyOfBundledIWADIsDuplicate() throws {
        try library.seedBundledContentIfNeeded()
        let freedoom = try XCTUnwrap(
            library.allWADs().first { $0.isBundled && $0.filename == "freedoom1.wad" })
        let copy = tmp.appendingPathComponent("my-freedoom.wad")
        try FileManager.default.copyItem(at: library.fileURL(for: freedoom), to: copy)

        let outcome = importer.importFiles(at: [copy])

        XCTAssertEqual(outcome.duplicates, ["my-freedoom"])
        XCTAssertTrue(outcome.imported.isEmpty)
        XCTAssertEqual(try library.allWADs().count, 2,
                       "a byte-identical copy of bundled content must not create a second entry")
    }

    func testImportsDEHByExtension() throws {
        let url = try write("tweaks.deh", Data("Patch File for DeHackEd 3.0".utf8))
        let outcome = importer.importFiles(at: [url])
        XCTAssertEqual(outcome.imported, ["tweaks"])
        XCTAssertEqual(try library.allWADs().first?.kindRaw, WADKind.deh.rawValue)
    }

    func testImportsWadsOutOfZip() throws {
        // Build a zip with a nested wad + junk, like real downloads.
        let zipURL = tmp.appendingPathComponent("dl.zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        let wadData = makeWAD(magic: "PWAD", lumps: ["E1M1"])
        try archive.addEntry(with: "release/map.wad", type: .file,
                             uncompressedSize: Int64(wadData.count),
                             provider: { pos, size in
            wadData.subdata(in: Int(pos)..<Int(pos) + size)
        })
        let outcome = importer.importFiles(at: [zipURL])
        XCTAssertEqual(outcome.imported, ["map"])
        XCTAssertEqual(try library.allWADs().first?.gameFamilyRaw, "doom1")
    }

    // MARK: oversize zip entries

    /// A zip whose only game-file entry blows the size cap: nothing gets
    /// extracted, so the old "no files extracted" guard rejected the zip
    /// once under its own name. The fix moves that bookkeeping onto the
    /// skipped entry itself, but the net behavior a caller cares about —
    /// the zip is rejected and nothing imports — must stay the same.
    func testOversizeOnlyZipStillRejectedWithoutImporting() throws {
        let big = Data(repeating: 0, count: 64)
        let zipURL = tmp.appendingPathComponent("big-only.zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        try archive.addEntry(with: "big.wad", type: .file,
                             uncompressedSize: Int64(big.count),
                             provider: { pos, size in big.subdata(in: Int(pos)..<Int(pos) + size) })
        importer.maxZipEntryBytes = 5

        let outcome = importer.importFiles(at: [zipURL])

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
    func testMixedZipImportsValidEntryAndRejectsOversizeEntry() throws {
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

        let outcome = importer.importFiles(at: [zipURL])

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
    /// the Library tab's grouped inventory.
    func testAdoptedLooseFileAppearsInLibraryGroups() async throws {
        let docs = URL.documentsDirectory
        let loose = docs.appendingPathComponent("dropped.wad")
        try makeWAD(magic: "PWAD", lumps: ["MAP01"]).write(to: loose)
        defer { try? FileManager.default.removeItem(at: loose) }

        let outcome = await importer.adoptLooseFiles()
        XCTAssertEqual(outcome.imported, ["dropped"])

        let groups = try library.libraryGroups()
        let mods = try XCTUnwrap(groups.first { $0.kind == .pwad })
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
    func testImportAppliesRecognizedTitleFromContentHash() throws {
        let data = makeWAD(magic: "IWAD", lumps: ["MAP01"])
        let sha1 = WADStore.sha1(of: data)
        library.recognizedTitle = { $0 == sha1 ? "DOOM II: Hell on Earth" : nil }

        let outcome = importer.importFiles(at: [try write("whatever-i-called-it.wad", data)])

        XCTAssertEqual(outcome.imported.count, 1)
        let wad = try XCTUnwrap(library.allWADs().first)
        XCTAssertEqual(wad.displayName, "DOOM II: Hell on Earth")
        XCTAssertNotEqual(wad.displayName, "whatever-i-called-it",
                          "a recognized IWAD must not be titled from its filename")
    }

    /// The parity requirement itself: renaming the file before importing it
    /// cannot change a recognized title. Two independent libraries, because the
    /// content hash would otherwise dedupe the second import away.
    func testRecognizedTitleIsUnchangedByRenamingTheFileBeforeImport() throws {
        let data = makeWAD(magic: "IWAD", lumps: ["MAP01"])
        let sha1 = WADStore.sha1(of: data)

        var titles: [String] = []
        for name in ["doom2.wad", "renamed-by-the-user.wad"] {
            let (library, importer) = try freshStack()
            library.recognizedTitle = { $0 == sha1 ? "DOOM II: Hell on Earth" : nil }
            _ = importer.importFiles(at: [try write(name, data)])
            titles.append(try XCTUnwrap(library.allWADs().first?.displayName))
        }

        XCTAssertEqual(titles, ["DOOM II: Hell on Earth", "DOOM II: Hell on Earth"])
    }

    /// The unknown-hash case, which is every PWAD and every mod, forever: the
    /// filename-derived name this line has always produced must survive.
    func testUnrecognizedImportKeepsTheFilenameDerivedTitle() throws {
        let data = makeWAD(magic: "PWAD", lumps: ["MAP01"])
        // Recognizes something, just not this file — so a pass here means the
        // fallback ran, not that recognition was switched off wholesale.
        library.recognizedTitle = { $0 == "not-this-files-hash" ? "Some Other Game" : nil }

        _ = importer.importFiles(at: [try write("sunlust.wad", data)])

        XCTAssertEqual(try library.allWADs().first?.displayName, "sunlust")
    }

    /// Production wiring: with no seam set, a real import resolves against the
    /// shipped catalog. A synthetic fixture can't match a published hash, so
    /// the observable end of this is the fallback — which is what proves the
    /// default is a live lookup and not a stub that returns nil unconditionally
    /// (the published-hash side of that same default is covered directly in
    /// IWADCatalogTests).
    func testDefaultRecognizerIsTheShippedCatalog() throws {
        let data = makeWAD(magic: "IWAD", lumps: ["MAP01"])
        XCTAssertNil(IWADCatalog.title(forSHA1: WADStore.sha1(of: data)),
                     "a synthetic fixture must not collide with a published IWAD hash")

        _ = importer.importFiles(at: [try write("mystery.wad", data)])

        XCTAssertEqual(try library.allWADs().first?.displayName, "mystery")
    }

    // MARK: dedupe ordering

    func testDuplicateImportDoesNotWriteNewStoreFile() throws {
        let data = makeWAD(magic: "PWAD", lumps: ["MAP01"])
        _ = importer.importFiles(at: [try write("a.wad", data)])
        let storeDir = tmp.appendingPathComponent("WADs", isDirectory: true)
        let before = try FileManager.default.contentsOfDirectory(
            at: storeDir, includingPropertiesForKeys: nil).count

        _ = importer.importFiles(at: [try write("b.wad", data)])

        let after = try FileManager.default.contentsOfDirectory(
            at: storeDir, includingPropertiesForKeys: nil).count
        XCTAssertEqual(after, before)
    }

    // MARK: repair when the stored file went missing

    func testReimportRestoresRowWhenStoredFileWasDeleted() throws {
        let data = makeWAD(magic: "PWAD", lumps: ["MAP01"])
        let first = importer.importFiles(at: [try write("a.wad", data)])
        XCTAssertEqual(first.imported, ["a"])
        let wad = try XCTUnwrap(library.allWADs().first)
        try FileManager.default.removeItem(at: library.fileURL(for: wad))

        let second = importer.importFiles(at: [try write("b.wad", data)])

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
    func testImportHashesMappedWADToItsOnDiskSHA1() throws {
        let data = makeWADWithBodies(magic: "PWAD",
                                     lumps: [("MAP01", [UInt8](repeating: 0x7F, count: 8192))])
        let url = try write("body.wad", data)
        let expected = try WADStore.sha1(ofFileAt: url)

        let outcome = importer.importFiles(at: [url])

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
}
