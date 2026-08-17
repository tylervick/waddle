import XCTest
@testable import Waddle

/// Asserted against literal published hashes, never against the table itself.
/// A test that read `IWADCatalog.titlesBySHA1` to build its own expectations
/// would pass no matter what the table said — including when it said nothing —
/// which is precisely the failure this table is most exposed to (a wrong or
/// missing hash never crashes, it just quietly stops matching real files).
///
/// No commercial WAD content is involved: these are the published identifiers,
/// not the bytes they identify.
final class IWADCatalogTests: XCTestCase {
    func testResolvesThePublishedUltimateDoomHash() {
        XCTAssertEqual(IWADCatalog.title(forSHA1: "9b07b02ab3c275a6a7570c3f73cc20d63a0e3833"),
                       "The Ultimate DOOM")
    }

    func testResolvesThePublishedSharewareDoomHash() {
        XCTAssertEqual(IWADCatalog.title(forSHA1: "5b2e249b9c5133ec987b3ea77596381dc0d6bc1d"),
                       "DOOM (Shareware)")
    }

    func testResolvesThePublishedDoomIIHash() {
        XCTAssertEqual(IWADCatalog.title(forSHA1: "7ec7652fcfce8ddc6e801839291f0e28ef1d5ae7"),
                       "DOOM II: Hell on Earth")
    }

    /// Both shipped hashes for TNT resolve to the same title: the DOS 1.9
    /// release and the GOG/anthology re-release are different bytes carrying
    /// the same game, and a player who owns either should read "TNT: Evilution".
    func testResolvesBothPublishedTNTHashesToTheSameTitle() {
        XCTAssertEqual(IWADCatalog.title(forSHA1: "9fbc66aedef7fe3bae0986cdb9323d2b8db4c9d3"),
                       "TNT: Evilution")
        XCTAssertEqual(IWADCatalog.title(forSHA1: "4a65c8b960225505187c36040b41a40b152f8f3e"),
                       "TNT: Evilution")
    }

    func testResolvesThePublishedPlutoniaHash() {
        XCTAssertEqual(IWADCatalog.title(forSHA1: "f131cbe1946d7fddb3caec4aa258c83399c21e60"),
                       "The Plutonia Experiment")
    }

    /// The permanent normal case — every PWAD and every mod lands here.
    func testUnknownHashResolvesToNil() {
        XCTAssertNil(IWADCatalog.title(forSHA1: String(repeating: "0", count: 40)))
        XCTAssertNil(IWADCatalog.title(forSHA1: ""))
    }

    /// `WADStore.sha1` renders lowercase hex today, but nothing forces a
    /// caller to, and an uppercase miss would silently un-recognize every game.
    func testLookupIsCaseInsensitive() {
        XCTAssertEqual(IWADCatalog.title(forSHA1: "7EC7652FCFCE8DDC6E801839291F0E28EF1D5AE7"),
                       "DOOM II: Hell on Earth")
    }

    /// A key that isn't shaped like `WADStore.sha1`'s output is dead weight the
    /// lookup can never hit — an uppercase, truncated or typo'd entry would sit
    /// in the table looking correct forever.
    func testEveryKeyIsLowercaseFortyCharacterHex() {
        XCTAssertFalse(IWADCatalog.titlesBySHA1.isEmpty)
        for key in IWADCatalog.titlesBySHA1.keys {
            XCTAssertEqual(key.count, 40, "\(key) is not a 40-character SHA-1")
            XCTAssertEqual(key, key.lowercased(), "\(key) must be lowercase hex")
            XCTAssertTrue(key.allSatisfy(\.isHexDigit), "\(key) is not hex")
        }
    }

    /// No entry may carry an empty title: a recognized file falling back to ""
    /// would render a nameless tile, which is worse than the filename it
    /// replaced.
    func testNoEntryHasAnEmptyTitle() {
        for (key, title) in IWADCatalog.titlesBySHA1 {
            XCTAssertFalse(title.trimmingCharacters(in: .whitespaces).isEmpty,
                           "\(key) maps to an empty title")
        }
    }
}
