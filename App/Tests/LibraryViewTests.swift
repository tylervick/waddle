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
}
