import XCTest
@testable import WADdle

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
}
