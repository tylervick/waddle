import SwiftData
import XCTest
@testable import Waddle

final class FilesViewTests: XCTestCase {
    func testFilesAppURLSwapsSchemeAndKeepsPath() throws {
        let fileURL = URL(fileURLWithPath: "/private/var/mobile/Documents/WADs/sunlust.wad")
        let url = try XCTUnwrap(FilesView.filesAppURL(for: fileURL))
        XCTAssertEqual(url.scheme, "shareddocuments")
        XCTAssertEqual(url.path, "/private/var/mobile/Documents/WADs/sunlust.wad")
    }

    func testFilesAppURLNilForNonFileURL() {
        XCTAssertNil(FilesView.filesAppURL(for: URL(string: "https://example.com/x.wad")!))
    }

    /// A multi-row delete blocks once per row; every blocked game has to
    /// survive to the alert, not just the last row's.
    func testBlockedNamesAccumulateAcrossABatch() {
        var blocked: [String] = []
        for names in [["Sunlust"], ["Eviternity"], ["Ancient Aliens", "Valiant"]] {
            blocked = FilesView.blockedNames(blocked, adding: names)
        }
        XCTAssertEqual(blocked, ["Sunlust", "Eviternity", "Ancient Aliens", "Valiant"])
    }

    func testBlockedNamesDropsRepeatsAcrossRows() {
        let first = FilesView.blockedNames([], adding: ["Sunlust", "Eviternity"])
        XCTAssertEqual(FilesView.blockedNames(first, adding: ["Eviternity", "Valiant"]),
                       ["Sunlust", "Eviternity", "Valiant"])
    }

    /// Each blocked row contributes its own file, so the alert can pair every
    /// filename with the games that actually hold it.
    func testBlockedFilesAccumulateOnePerRow() {
        var blocked: [FilesView.BlockedFile] = []
        blocked = FilesView.blockedFiles(blocked, adding: ["Sunlust MP"], for: "sunlust.wad")
        blocked = FilesView.blockedFiles(blocked, adding: ["Eviternity"], for: "eviternity.wad")
        XCTAssertEqual(blocked, [
            FilesView.BlockedFile(filename: "sunlust.wad", games: ["Sunlust MP"]),
            FilesView.BlockedFile(filename: "eviternity.wad", games: ["Eviternity"]),
        ])
    }

    /// Two games may carry the same name, and the alert should not list one
    /// game twice for the same file.
    func testBlockedFilesDropsRepeatedGamesForOneFile() {
        let blocked = FilesView.blockedFiles([], adding: ["Sunlust MP", "Sunlust MP"],
                                               for: "sunlust.wad")
        XCTAssertEqual(blocked, [
            FilesView.BlockedFile(filename: "sunlust.wad", games: ["Sunlust MP"]),
        ])
    }

    /// The plural form: with a batch blocked, the message has to say which file
    /// belongs to which game, and must not tell the reader to remove "it".
    func testBlockedMessagePairsEachFileWithItsGames() {
        let message = FilesView.blockedMessage(for: [
            FilesView.BlockedFile(filename: "sunlust.wad", games: ["Sunlust MP"]),
            FilesView.BlockedFile(filename: "eviternity.wad", games: ["Eviternity"]),
        ])
        XCTAssertEqual(message, """
        sunlust.wad — used by Sunlust MP
        eviternity.wad — used by Eviternity
        Remove each file from those games first.
        """)
        XCTAssertFalse(message.contains("Remove it"))
    }

    func testBlockedMessageSingularForOneFileInOneGame() {
        let message = FilesView.blockedMessage(for: [
            FilesView.BlockedFile(filename: "sunlust.wad", games: ["Sunlust MP"]),
        ])
        XCTAssertEqual(message, """
        sunlust.wad — used by Sunlust MP
        Remove it from that game first.
        """)
    }

    /// One file held by several games: still "it", but "those games".
    func testBlockedMessageSingularFileInSeveralGames() {
        let message = FilesView.blockedMessage(for: [
            FilesView.BlockedFile(filename: "sunlust.wad", games: ["Sunlust MP", "Valiant"]),
        ])
        XCTAssertEqual(message, """
        sunlust.wad — used by Sunlust MP, Valiant
        Remove it from those games first.
        """)
    }

    func testBlockedMessageEmptyWhenNothingIsBlocked() {
        XCTAssertEqual(FilesView.blockedMessage(for: []), "")
    }

    // MARK: - The delete wiring itself
    //
    // Everything above pins a helper in isolation. These drive the batch the
    // Library tab actually runs, against a real LibraryService, so a revert of
    // the accumulation to a plain overwrite fails here instead of passing.

    /// An in-memory library plus its scratch directory, mirroring
    /// `LibraryServiceTests`' fixture. Real rows and real games, so
    /// `deleteWAD` refuses for the actual reason the view reacts to rather
    /// than a stubbed error.
    @MainActor
    private func makeLibrary() throws -> (library: LibraryService, tmp: URL) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WADFile.self, Loadout.self, Game.self,
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
        _ = try library.createGame(name: "Sunlust MP", baseID: iwad.id, fileIDs: [sunlust.id])
        _ = try library.createGame(name: "Eviternity", baseID: iwad.id, fileIDs: [eviternity.id])

        let blocked = FilesView.deleting([sunlust, eviternity], from: library, blocked: [])

        XCTAssertEqual(blocked, [
            FilesView.BlockedFile(filename: "sunlust.wad", games: ["Sunlust MP"]),
            FilesView.BlockedFile(filename: "eviternity.wad", games: ["Eviternity"]),
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
        _ = try library.createGame(name: "Sunlust MP", baseID: iwad.id, fileIDs: [sunlust.id])

        let blocked = FilesView.deleting([sunlust, spare], from: library, blocked: [])

        XCTAssertEqual(blocked, [
            FilesView.BlockedFile(filename: "sunlust.wad", games: ["Sunlust MP"]),
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
        _ = try library.createGame(name: "Sunlust MP", baseID: iwad.id, fileIDs: [sunlust.id])
        let existing = [FilesView.BlockedFile(filename: "eviternity.wad",
                                              games: ["Eviternity"])]

        let blocked = FilesView.deleting([sunlust], from: library, blocked: existing)

        XCTAssertEqual(blocked, [
            FilesView.BlockedFile(filename: "eviternity.wad", games: ["Eviternity"]),
            FilesView.BlockedFile(filename: "sunlust.wad", games: ["Sunlust MP"]),
        ])
    }
}
