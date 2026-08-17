import SwiftData
import XCTest
@testable import Waddle

final class LibraryViewTests: XCTestCase {
    func testFilesAppURLSwapsSchemeAndKeepsPath() throws {
        let fileURL = URL(fileURLWithPath: "/private/var/mobile/Documents/WADs/sunlust.wad")
        let url = try XCTUnwrap(LibraryView.filesAppURL(for: fileURL))
        XCTAssertEqual(url.scheme, "shareddocuments")
        XCTAssertEqual(url.path, "/private/var/mobile/Documents/WADs/sunlust.wad")
    }

    func testFilesAppURLNilForNonFileURL() {
        XCTAssertNil(LibraryView.filesAppURL(for: URL(string: "https://example.com/x.wad")!))
    }

    /// A multi-row delete blocks once per row; every blocked preset has to
    /// survive to the alert, not just the last row's.
    func testBlockedNamesAccumulateAcrossABatch() {
        var blocked: [String] = []
        for names in [["Sunlust"], ["Eviternity"], ["Ancient Aliens", "Valiant"]] {
            blocked = LibraryView.blockedNames(blocked, adding: names)
        }
        XCTAssertEqual(blocked, ["Sunlust", "Eviternity", "Ancient Aliens", "Valiant"])
    }

    func testBlockedNamesDropsRepeatsAcrossRows() {
        let first = LibraryView.blockedNames([], adding: ["Sunlust", "Eviternity"])
        XCTAssertEqual(LibraryView.blockedNames(first, adding: ["Eviternity", "Valiant"]),
                       ["Sunlust", "Eviternity", "Valiant"])
    }

    /// Each blocked row contributes its own file, so the alert can pair every
    /// filename with the presets that actually hold it.
    func testBlockedFilesAccumulateOnePerRow() {
        var blocked: [LibraryView.BlockedFile] = []
        blocked = LibraryView.blockedFiles(blocked, adding: ["Sunlust MP"], for: "sunlust.wad")
        blocked = LibraryView.blockedFiles(blocked, adding: ["Eviternity"], for: "eviternity.wad")
        XCTAssertEqual(blocked, [
            LibraryView.BlockedFile(filename: "sunlust.wad", presets: ["Sunlust MP"]),
            LibraryView.BlockedFile(filename: "eviternity.wad", presets: ["Eviternity"]),
        ])
    }

    /// Two loadouts may carry the same name, and the alert should not list one
    /// preset twice for the same file.
    func testBlockedFilesDropsRepeatedPresetsForOneFile() {
        let blocked = LibraryView.blockedFiles([], adding: ["Sunlust MP", "Sunlust MP"],
                                               for: "sunlust.wad")
        XCTAssertEqual(blocked, [
            LibraryView.BlockedFile(filename: "sunlust.wad", presets: ["Sunlust MP"]),
        ])
    }

    /// The plural form: with a batch blocked, the message has to say which file
    /// belongs to which preset, and must not tell the reader to remove "it".
    func testBlockedMessagePairsEachFileWithItsPresets() {
        let message = LibraryView.blockedMessage(for: [
            LibraryView.BlockedFile(filename: "sunlust.wad", presets: ["Sunlust MP"]),
            LibraryView.BlockedFile(filename: "eviternity.wad", presets: ["Eviternity"]),
        ])
        XCTAssertEqual(message, """
        sunlust.wad — used by Sunlust MP
        eviternity.wad — used by Eviternity
        Remove each file from those presets first.
        """)
        XCTAssertFalse(message.contains("Remove it"))
    }

    func testBlockedMessageSingularForOneFileInOnePreset() {
        let message = LibraryView.blockedMessage(for: [
            LibraryView.BlockedFile(filename: "sunlust.wad", presets: ["Sunlust MP"]),
        ])
        XCTAssertEqual(message, """
        sunlust.wad — used by Sunlust MP
        Remove it from that preset first.
        """)
    }

    /// One file held by several presets: still "it", but "those presets".
    func testBlockedMessageSingularFileInSeveralPresets() {
        let message = LibraryView.blockedMessage(for: [
            LibraryView.BlockedFile(filename: "sunlust.wad", presets: ["Sunlust MP", "Valiant"]),
        ])
        XCTAssertEqual(message, """
        sunlust.wad — used by Sunlust MP, Valiant
        Remove it from those presets first.
        """)
    }

    func testBlockedMessageEmptyWhenNothingIsBlocked() {
        XCTAssertEqual(LibraryView.blockedMessage(for: []), "")
    }

    // MARK: - The delete wiring itself
    //
    // Everything above pins a helper in isolation. These drive the batch the
    // Library tab actually runs, against a real LibraryService, so a revert of
    // the accumulation to a plain overwrite fails here instead of passing.

    /// An in-memory library plus its scratch directory, mirroring
    /// `LibraryServiceTests`' fixture. Real rows and real loadouts, so
    /// `deleteWAD` refuses for the actual reason the view reacts to rather
    /// than a stubbed error.
    @MainActor
    private func makeLibrary() throws -> (library: LibraryService, tmp: URL) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WADFile.self, Loadout.self,
                                           configurations: config)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let library = LibraryService(context: ModelContext(container),
                                     store: WADStore(directory: tmp))
        return (library, tmp)
    }

    /// Deleting a batch where every row is spoken for: each refusal has to
    /// survive to the alert. An overwrite keeps only the last row, which is
    /// exactly the bug this pins — and with the loop inline in the view, the
    /// whole suite stayed green through that revert.
    @MainActor
    func testDeletingABatchKeepsEveryBlockedRow() throws {
        let (library, tmp) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let iwad = try library.registerImported(filename: "doom2.wad", sha1: "i1",
                                                kind: WADKind.iwad.rawValue, family: "doom2")
        let sunlust = try library.registerImported(filename: "sunlust.wad", sha1: "p1",
                                                   kind: WADKind.pwad.rawValue, family: "doom2")
        let eviternity = try library.registerImported(filename: "eviternity.wad", sha1: "p2",
                                                      kind: WADKind.pwad.rawValue, family: "doom2")
        _ = try library.createLoadout(name: "Sunlust MP", iwadID: iwad.id,
                                      pwadIDs: [sunlust.id], dehIDs: [])
        _ = try library.createLoadout(name: "Eviternity", iwadID: iwad.id,
                                      pwadIDs: [eviternity.id], dehIDs: [])

        let blocked = LibraryView.deleting([sunlust, eviternity], from: library, blocked: [])

        XCTAssertEqual(blocked, [
            LibraryView.BlockedFile(filename: "sunlust.wad", presets: ["Sunlust MP"]),
            LibraryView.BlockedFile(filename: "eviternity.wad", presets: ["Eviternity"]),
        ])
    }

    /// A mixed batch: the unreferenced row is really gone, and only the
    /// referenced one reaches the alert. Pins that a refusal does not abort
    /// the rest of the batch.
    @MainActor
    func testDeletingABatchRemovesUnreferencedRowsAndBlocksTheRest() throws {
        let (library, tmp) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let iwad = try library.registerImported(filename: "doom2.wad", sha1: "i1",
                                                kind: WADKind.iwad.rawValue, family: "doom2")
        let sunlust = try library.registerImported(filename: "sunlust.wad", sha1: "p1",
                                                   kind: WADKind.pwad.rawValue, family: "doom2")
        let spare = try library.registerImported(filename: "spare.wad", sha1: "p2",
                                                 kind: WADKind.pwad.rawValue, family: "doom2")
        _ = try library.createLoadout(name: "Sunlust MP", iwadID: iwad.id,
                                      pwadIDs: [sunlust.id], dehIDs: [])

        let blocked = LibraryView.deleting([sunlust, spare], from: library, blocked: [])

        XCTAssertEqual(blocked, [
            LibraryView.BlockedFile(filename: "sunlust.wad", presets: ["Sunlust MP"]),
        ])
        XCTAssertNil(try library.wad(id: spare.id), "an unblocked row must still be deleted")
        XCTAssertNotNil(try library.wad(id: sunlust.id), "a blocked row must survive")
    }

    /// The batch starts from whatever is already on screen, so a second batch
    /// cannot drop the first one's entries while the alert is still up.
    @MainActor
    func testDeletingCarriesInAlreadyBlockedFiles() throws {
        let (library, tmp) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let iwad = try library.registerImported(filename: "doom2.wad", sha1: "i1",
                                                kind: WADKind.iwad.rawValue, family: "doom2")
        let sunlust = try library.registerImported(filename: "sunlust.wad", sha1: "p1",
                                                   kind: WADKind.pwad.rawValue, family: "doom2")
        _ = try library.createLoadout(name: "Sunlust MP", iwadID: iwad.id,
                                      pwadIDs: [sunlust.id], dehIDs: [])
        let existing = [LibraryView.BlockedFile(filename: "eviternity.wad",
                                                presets: ["Eviternity"])]

        let blocked = LibraryView.deleting([sunlust], from: library, blocked: existing)

        XCTAssertEqual(blocked, [
            LibraryView.BlockedFile(filename: "eviternity.wad", presets: ["Eviternity"]),
            LibraryView.BlockedFile(filename: "sunlust.wad", presets: ["Sunlust MP"]),
        ])
    }
}
