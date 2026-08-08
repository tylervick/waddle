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

    func testBlockedNamesStartsFromEmptyAfterAlertDismissal() {
        XCTAssertEqual(LibraryView.blockedNames([], adding: ["Sunlust"]), ["Sunlust"])
    }
}
