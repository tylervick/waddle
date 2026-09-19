import XCTest
@testable import Waddle

/// Spec §4.1: which installed IWAD a new map set pairs with.
final class PairingTests: XCTestCase {
    private func iwad(_ name: String, family: GameFamily, bundled: Bool = false) -> WADFile {
        WADFile(filename: name, displayName: (name as NSString).deletingPathExtension,
                kindRaw: WADKind.iwad.rawValue, sha1: name, gameFamilyRaw: family.rawValue,
                isBundled: bundled, hasMaps: true)
    }

    func testPrefersAnImportedIWADOverBundledFreedoom() {
        let freedoom = iwad("freedoom2.wad", family: .doom2, bundled: true)
        let doom2 = iwad("doom2.wad", family: .doom2)
        let chosen = Pairing.chooseBase(forFamily: .doom2, among: [
            .init(file: freedoom, lastPlayed: Date()), .init(file: doom2, lastPlayed: nil),
        ])
        XCTAssertEqual(chosen?.id, doom2.id, "imported wins even when never played")
    }

    func testAmongImportedTheMostRecentlyPlayedWins() {
        let a = iwad("a.wad", family: .doom2), b = iwad("b.wad", family: .doom2), c = iwad("c.wad", family: .doom2)
        let chosen = Pairing.chooseBase(forFamily: .doom2, among: [
            .init(file: a, lastPlayed: Date(timeIntervalSince1970: 100)),
            .init(file: b, lastPlayed: Date(timeIntervalSince1970: 300)),
            .init(file: c, lastPlayed: nil),
        ])
        XCTAssertEqual(chosen?.id, b.id)
    }

    func testNeverPlayedImportedTieBreaksByName() {
        let z = iwad("zeta.wad", family: .doom1), a = iwad("alpha.wad", family: .doom1)
        let chosen = Pairing.chooseBase(forFamily: .doom1, among: [.init(file: z, lastPlayed: nil), .init(file: a, lastPlayed: nil)])
        XCTAssertEqual(chosen?.id, a.id)
    }

    func testFamilyMustMatch() {
        let doom1 = iwad("doom.wad", family: .doom1)
        XCTAssertNil(Pairing.chooseBase(forFamily: .doom2, among: [.init(file: doom1, lastPlayed: Date())]))
    }

    func testUnknownFamilyNeverPairs() {
        let any = iwad("doom2.wad", family: .doom2)
        XCTAssertNil(Pairing.chooseBase(forFamily: .unknown, among: [.init(file: any, lastPlayed: nil)]))
    }

    func testBundledIsTheFallback() {
        let freedoom = iwad("freedoom1.wad", family: .doom1, bundled: true)
        XCTAssertEqual(Pairing.chooseBase(forFamily: .doom1, among: [.init(file: freedoom, lastPlayed: nil)])?.id, freedoom.id)
    }
}
