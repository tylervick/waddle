import CoreGraphics
import SwiftData
import SwiftUI
import XCTest
@testable import Waddle

/// Covers the two rules spec §5 states outright and `ShelfView` cannot be asked
/// about directly (no view harness — same reason `ShelfTests` tests `Shelf`):
/// what a tile draws when no art decodes, and what VoiceOver reads for it.
@MainActor
final class TileAppearanceTests: XCTestCase {
    var service: LibraryService!
    var tmp: URL!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WADFile.self, Loadout.self, Game.self, configurations: config)
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        service = LibraryService(context: ModelContext(container), store: WADStore(directory: tmp))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - The no-art fallback

    func testItemWithNoDecodableArtResolvesToFlatTitledFallback() {
        // The spec's wording is "a flat dark tile with the title — no fake
        // art", so the absence of a decoded image must land on `.flatTitle`
        // and never on an image-bearing case. Asserting the case (rather than
        // "not nil") is what distinguishes this from the generated-monogram
        // placeholder it replaced, which also had nothing decoded.
        XCTAssertEqual(TileAppearance.resolve(decodedArt: nil), .flatTitle)
    }

    func testDecodedArtResolvesToArt() {
        XCTAssertEqual(TileAppearance.resolve(decodedArt: Self.opaquePixel()), .art)
    }

    // MARK: - VoiceOver labels

    func testTileLabelCarriesTitleAndLastPlayedPhrasing() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let label = TileAccessibility.label(title: "DOOM II",
                                            lastPlayed: now.addingTimeInterval(-86_400),
                                            now: now,
                                            locale: Locale(identifier: "en_US"))

        // The spec's own example, verbatim. The locale is pinned so this
        // asserts the phrasing rather than the runner's language setting.
        XCTAssertEqual(label, "DOOM II, last played yesterday")
    }

    func testTileLabelForNeverPlayedItemIsJustTheTitle() {
        // Discriminates in the other direction: a label that appended
        // last-played phrasing unconditionally would pass the test above and
        // fail here.
        let label = TileAccessibility.label(title: "Freedoom Phase 1",
                                            lastPlayed: nil,
                                            now: Date(timeIntervalSince1970: 1_700_000_000),
                                            locale: Locale(identifier: "en_US"))

        XCTAssertEqual(label, "Freedoom Phase 1")
    }

    func testTileLabelReadsThroughAGame() throws {
        // The shelf labels tiles from a `Game`, so the convenience overload it
        // actually calls gets its own check rather than being trusted to match
        // the primitive one. The expected title comes from the registered row
        // rather than a literal: what is under test is that the game's own
        // name and play date reach the label, not how the catalog chose to
        // name this WAD.
        let wad = try service.registerImported(filename: "doom2.wad", sha1: "d2",
                                               kind: WADKind.iwad.rawValue, family: "doom2")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let game = try XCTUnwrap(try service.game(id: wad.id))
        try service.markPlayed(game, at: now.addingTimeInterval(-86_400))

        let label = TileAccessibility.label(for: game,
                                            now: now,
                                            locale: Locale(identifier: "en_US"))

        XCTAssertEqual(label, "\(wad.displayName), last played yesterday")
    }

    func testTileLabelSaysWhenAGameNeedsABaseGame() throws {
        // An orphaned game's launch actions are disabled (M9); VoiceOver has
        // to say why, not just announce a title that silently does nothing.
        let game = try service.createGame(name: "Orphan", baseID: nil, fileIDs: [])
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let label = TileAccessibility.label(for: game, now: now, locale: Locale(identifier: "en_US"))

        XCTAssertEqual(label, "Orphan, needs a base game")
    }

    func testTileLabelForAPairedNeverPlayedGameIsUnchanged() throws {
        // Discriminates against a label that appends the "needs a base game"
        // suffix unconditionally: a paired game must read exactly like the
        // never-played case above.
        let wad = try service.registerImported(filename: "doom2.wad", sha1: "d2b",
                                               kind: WADKind.iwad.rawValue, family: "doom2")
        let game = try XCTUnwrap(try service.game(id: wad.id))

        let label = TileAccessibility.label(for: game,
                                            now: Date(timeIntervalSince1970: 1_700_000_000),
                                            locale: Locale(identifier: "en_US"))

        XCTAssertEqual(label, wad.displayName)
    }

    // MARK: - Dynamic Type

    func testGridDropsColumnsAtAccessibilitySizesInsteadOfShrinkingText() {
        // Spec §5's rule expressed as the only lever `.adaptive(minimum:)`
        // offers: a wider floor fits fewer columns into the same width.
        let standard = Theme.gridMinimumTileWidth(for: .large)
        let accessibility = Theme.gridMinimumTileWidth(for: .accessibility3)

        XCTAssertGreaterThan(accessibility, standard)
    }

    // MARK: - Helpers

    /// A 1×1 opaque bitmap — the smallest thing that is unambiguously "art
    /// decoded".
    private static func opaquePixel() -> CGImage {
        let context = CGContext(data: nil, width: 1, height: 1,
                                bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }
}
