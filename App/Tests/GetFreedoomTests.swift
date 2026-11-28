import CryptoKit
import Foundation
import SwiftData
import XCTest
import ZIPFoundation
@testable import Waddle

/// The Get Freedoom tile (#552): when the shelf offers Freedoom, the pinned
/// release it downloads, and what the download leaves in the library.
/// Every download is answered by `StubURLProtocol`; nothing here touches
/// the network.
@MainActor
final class GetFreedoomTests: XCTestCase {
    var context: ModelContext!
    var library: LibraryService!
    var importer: ImportService!
    var notices: ImportNotices!
    var tmp: URL!
    var storeDir: URL!
    var downloadsDir: URL!
    var defaults: UserDefaults!
    var suiteName: String!

    override func setUpWithError() throws {
        StubURLProtocol.reset()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WADFile.self, Game.self, configurations: config)
        context = ModelContext(container)
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        storeDir = tmp.appendingPathComponent("WADs", isDirectory: true)
        downloadsDir = tmp.appendingPathComponent("LinkDownloads", isDirectory: true)
        let store = WADStore(directory: storeDir)
        library = LibraryService(context: context, store: store)
        suiteName = "GetFreedoomTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        library.defaults = defaults
        notices = ImportNotices()
        importer = ImportService(library: library, store: store, notices: notices,
                                 usage: UsageStore(directory: tmp.appendingPathComponent("Diagnostics",
                                                                                         isDirectory: true)))
    }

    override func tearDownWithError() throws {
        StubURLProtocol.reset()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: Helpers

    private func linkImport() -> LinkImport {
        var downloader = LinkDownloader()
        downloader.directory = downloadsDir
        downloader.makeConfiguration = { StubURLProtocol.configuration() }
        return LinkImport(importer: importer, downloader: downloader, notices: notices)
    }

    private var link: String { FreedoomRelease.url.absoluteString }

    /// The tile's model on a stubbed downloader. `sha256` is the pin: the
    /// release's own by default, or the stand-in zip's.
    private func getFreedoom(sha256: String = FreedoomRelease.sha256,
                             link model: LinkImport? = nil) -> GetFreedoom {
        GetFreedoom(link: model ?? linkImport(), library: library, url: FreedoomRelease.url, sha256: sha256)
    }

    /// Taps **Get** and waits for the download to end.
    private func get(_ model: GetFreedoom) async {
        let finished = expectation(description: "the download ended")
        XCTAssertTrue(model.get { finished.fulfill() }, "Get did not start")
        await fulfillment(of: [finished], timeout: 30)
    }

    private func storedFiles() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: storeDir.path)) ?? []
    }

    private func downloadedFiles() -> [String] {
        guard let walker = FileManager.default.enumerator(at: downloadsDir,
                                                          includingPropertiesForKeys: [.isRegularFileKey])
        else { return [] }
        return walker.compactMap { item -> String? in
            guard let url = item as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { return nil }
            return url.lastPathComponent
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func shipWithoutFreedoom() throws {
        let empty = tmp.appendingPathComponent("NoBundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        library.bundledContentDirectory = empty
    }

    /// The real Freedoom 0.13.0 WADs: the subject is those exact bytes
    /// (their hashes are the rule's and the catalog's), which
    /// `FreedoomFixture`'s stand-ins cannot match.
    private func shippedFreedoom(_ filename: String) throws -> Data {
        try Data(contentsOf: FreedoomFixture.shippedRelease.appendingPathComponent(filename),
                 options: .mappedIfSafe)
    }

    /// A zip laid out as the release is: the WADs in a `freedoom-0.13.0/`
    /// folder beside documents the import ignores.
    private func freedoomLikeZip() throws -> Data {
        try zip([
            ("freedoom-0.13.0/COPYING.txt", Data("BSD".utf8)),
            ("freedoom-0.13.0/freedoom1.wad", try shippedFreedoom("freedoom1.wad")),
            ("freedoom-0.13.0/freedoom2.wad", try shippedFreedoom("freedoom2.wad")),
        ])
    }

    private func zip(_ members: [(String, Data)]) throws -> Data {
        let zipURL = tmp.appendingPathComponent(UUID().uuidString + ".zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        for (path, data) in members {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                                 provider: { pos, size in data.subdata(in: Int(pos)..<Int(pos) + size) })
        }
        let data = try Data(contentsOf: zipURL)
        try FileManager.default.removeItem(at: zipURL)
        return data
    }

    private func serve(_ body: Data, type: String = "application/zip") {
        StubURLProtocol.set(.respond(status: 200, headers: ["Content-Type": type], body: body), for: link)
    }

    /// A library row with Freedoom's hash for `file`, present or not.
    private func row(_ file: String) -> WADFile {
        WADFile(filename: file, displayName: file, kindRaw: WADKind.iwad.rawValue,
                sha1: LibraryService.shippedFreedoomSHA1[file]!,
                gameFamilyRaw: GameFamily.doom2.rawValue, isBundled: false, hasMaps: true)
    }

    // MARK: The release

    /// Spelled out, not read back: the link is the release the owner chose
    /// (#502), and the hash is the one its signed `freedoom-0.13.0-CHECKSUM`
    /// lists for the zip.
    func testTheReleaseIsThePinnedFreedoom0130Zip() {
        XCTAssertEqual(FreedoomRelease.url.absoluteString,
                       "https://github.com/freedoom/freedoom/releases/download/v0.13.0/freedoom-0.13.0.zip")
        XCTAssertEqual(FreedoomRelease.sha256,
                       "3f9b264f3e3ce503b4fb7f6bdcb1f419d93c7b546f4df3e874dd878db9688f59")
        XCTAssertEqual(FreedoomRelease.byteCount, 24_143_781)
    }

    /// The size the tile shows before the tap comes from `byteCount`, in
    /// `ByteCountFormatter`'s file style, not from hard-coded text.
    func testTheTileShowsTheSizeFromTheByteCount() {
        XCTAssertEqual(FreedoomRelease.sizeText,
                       ByteCountFormatter.string(fromByteCount: FreedoomRelease.byteCount, countStyle: .file))
        XCTAssertEqual(FreedoomRelease.sizeText, "24.1 MB")
    }

    /// The rule's hashes are the ones the app has always bundled, and the
    /// catalog titles both.
    func testTheReleasesWADsAreTheBundledFreedoom() {
        XCTAssertEqual(FreedoomRelease.wadSHA1s, Set(LibraryService.shippedFreedoomSHA1.values))
        XCTAssertEqual(Set(FreedoomRelease.wadSHA1s.compactMap(IWADCatalog.title(forSHA1:))),
                       ["Freedoom Phase 1", "Freedoom Phase 2"])
    }

    // MARK: When the tile shows

    func testOfferedWhenTheLibraryHasNoFreedoomAtAll() {
        XCTAssertTrue(Shelf.offersFreedoom(files: []) { _ in true })
    }

    func testNotOfferedWhenBothArePresent() {
        XCTAssertFalse(Shelf.offersFreedoom(files: [row("freedoom1.wad"), row("freedoom2.wad")]) { _ in true })
    }

    /// Deleting one of the two was deliberate: nothing is offered.
    func testNotOfferedWhenOneIsPresent() {
        let one = row("freedoom1.wad")
        XCTAssertFalse(Shelf.offersFreedoom(files: [one]) { _ in true })
        let other = row("freedoom2.wad")
        XCTAssertFalse(Shelf.offersFreedoom(files: [one, other]) { $0 === other })
    }

    /// Rows whose files have gone (released from a bundle that no longer
    /// ships them) do not count: Freedoom is offered, and the download
    /// repairs the rows (`testTheDownloadRestoresReleasedRowsUnderTheirIDs`).
    func testOfferedWhenTheRowsAreThereButTheirFilesAreNot() {
        XCTAssertTrue(Shelf.offersFreedoom(files: [row("freedoom1.wad"), row("freedoom2.wad")]) { _ in false })
    }

    /// Other files, the player's own games, do not stop the offer.
    func testOfferedBesideThePlayersOwnGames() {
        let doom2 = WADFile(filename: "DOOM2.WAD", displayName: "DOOM II", kindRaw: WADKind.iwad.rawValue,
                            sha1: "7ec7652fcfce8ddc6e801839291f0e28ef1f5ae7",
                            gameFamilyRaw: GameFamily.doom2.rawValue, isBundled: false, hasMaps: true)
        XCTAssertTrue(Shelf.offersFreedoom(files: [doom2]) { _ in true })
    }

    /// Through the library, while Freedoom is bundled, as it is today:
    /// never offered.
    func testNotOfferedWhileFreedoomIsBundled() throws {
        library.bundledContentDirectory = FreedoomFixture.shippedRelease
        try library.seedBundledContentIfNeeded()
        XCTAssertEqual(try library.allWADs().count, 2, "the test host should bundle both Freedoom WADs")
        XCTAssertFalse(try library.offersFreedoom())
    }

    /// A Freedoom the player removed from the shelf is still there: Hidden
    /// Games brings it back, so the tile does not offer a second copy.
    func testNotOfferedWhenFreedoomIsHiddenFromTheShelf() throws {
        library.bundledContentDirectory = FreedoomFixture.shippedRelease
        try library.seedBundledContentIfNeeded()
        for game in try library.games() { try library.hide(game) }
        XCTAssertTrue(try library.shelfGames().isEmpty)
        XCTAssertFalse(try library.offersFreedoom())
    }

    /// An existing install after #505: its bundled rows are released,
    /// their files gone. Offered.
    func testOfferedWhenBundledRowsAreReleased() throws {
        library.bundledContentDirectory = FreedoomFixture.shippedRelease
        try library.seedBundledContentIfNeeded()
        try shipWithoutFreedoom()
        try library.seedBundledContentIfNeeded()
        XCTAssertEqual(try library.allWADs().count, 2, "released rows stay in the library")
        XCTAssertTrue(try library.offersFreedoom())
    }

    /// A new install after #505: nothing is registered. Offered.
    func testOfferedOnANewInstallWithoutTheBundle() throws {
        try shipWithoutFreedoom()
        try library.seedBundledContentIfNeeded()
        XCTAssertTrue(try library.offersFreedoom())
    }

    /// A player who deleted both imported copies gets the tile back.
    func testOfferedAgainOnceBothImportedCopiesAreDeleted() async throws {
        try shipWithoutFreedoom()
        let zip = try freedoomLikeZip()
        serve(zip)
        await get(getFreedoom(sha256: Self.sha256(zip)))
        XCTAssertFalse(try library.offersFreedoom())

        for wad in try library.allWADs() { try library.deleteWAD(wad) }
        XCTAssertTrue(try library.offersFreedoom())
    }

    // MARK: The pin

    /// The pin accepts exactly its bytes: the right zip imports, and the
    /// same zip with one byte of its WAD flipped is refused, says why, and
    /// leaves the library and the disk as they were. The flipped zip is
    /// still a valid zip of a valid WAD (the byte pads a lump's name), and
    /// imports when nothing is pinned, so only the pin refuses it.
    func testThePinAcceptsTheRightBytesAndRefusesOneFlippedByte() async throws {
        let wad = makeWAD(magic: "PWAD", lumps: ["MAP01", "THINGS"])
        var flippedWAD = wad
        flippedWAD[flippedWAD.count - 1] ^= 0x01   // the padding after "THINGS"
        let good = try zip([("pinned/pinned.wad", wad)])
        let flipped = try zip([("pinned/pinned.wad", flippedWAD)])
        XCTAssertNotEqual(good, flipped)

        serve(flipped)
        let refused = getFreedoom(sha256: Self.sha256(good))
        await get(refused)
        XCTAssertEqual(refused.state, .offered(failure: "File didn't match"))
        XCTAssertEqual(notices.current, GetFreedoom.bannerMessage(for: .checksumMismatch))
        XCTAssertTrue(try library.allWADs().isEmpty, "a mismatched file reached the library")
        XCTAssertEqual(storedFiles(), [])
        XCTAssertEqual(downloadedFiles(), [], "the refused download was left on disk")

        serve(good)
        let accepted = getFreedoom(sha256: Self.sha256(good))
        await get(accepted)
        XCTAssertEqual(accepted.state, .offered(failure: nil))
        XCTAssertEqual(try library.allWADs().count, 1)

        // Unpinned, the flipped bytes are an ordinary valid WAD.
        let other = "https://files.example/unpinned.zip"
        StubURLProtocol.set(.respond(status: 200, headers: ["Content-Type": "application/zip"],
                                     body: flipped), for: other)
        let unpinned = await linkImport().run(URL(string: other)!)
        XCTAssertEqual(unpinned?.imported.count, 1, "the flipped zip is a good one, unpinned")
    }

    /// The tile pins the release's own hash: a body that is not the release
    /// is refused even when it is a perfectly good Freedoom zip.
    func testTheTilePinsTheReleasesHash() async throws {
        serve(try freedoomLikeZip())
        let model = getFreedoom()
        await get(model)
        XCTAssertEqual(model.link.lastFailure, .checksumMismatch)
        XCTAssertTrue(try library.allWADs().isEmpty)
    }

    // MARK: Failures

    /// Offline and a server error each leave the library and the disk as
    /// they were, keep the tile offering with a short reason, and put the
    /// full reason in the banner.
    func testOfflineAndA503LeaveTheLibraryUnchanged() async throws {
        let model = getFreedoom()
        StubURLProtocol.set(.fail(URLError(.notConnectedToInternet)), for: link)
        await get(model)
        XCTAssertEqual(model.state, .offered(failure: "You're offline"))
        XCTAssertEqual(notices.current, GetFreedoom.bannerMessage(for: .offline))

        StubURLProtocol.set(.respond(status: 503, headers: ["Content-Type": "text/html"],
                                     body: Data("<html>busy</html>".utf8)), for: link)
        await get(model)
        XCTAssertEqual(model.state, .offered(failure: "Download failed"))
        XCTAssertEqual(notices.current, GetFreedoom.bannerMessage(for: .httpStatus(503)))

        XCTAssertTrue(try library.allWADs().isEmpty)
        XCTAssertEqual(storedFiles(), [])
        XCTAssertEqual(downloadedFiles(), [])
        XCTAssertEqual(StubURLProtocol.requestedURLs, [link, link], "each tap is one request, and only a tap")
    }

    /// A cancel goes back to **Get** with nothing said and nothing left.
    func testCancelGoesBackToGetSilentlyWithNothingOnDisk() async throws {
        StubURLProtocol.set(.stall(headers: ["Content-Type": "application/zip",
                                             "Content-Length": "\(FreedoomRelease.byteCount)"],
                                   firstChunk: Data(repeating: 0x50, count: 4096)), for: link)
        let model = getFreedoom()
        let finished = expectation(description: "the download ended")
        XCTAssertTrue(model.get { finished.fulfill() })
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if case .downloading(let received, _) = model.state, received > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .downloading(let received, let expected) = model.state else {
            return XCTFail("never showed progress: \(model.state)")
        }
        XCTAssertEqual(received, 4096)
        XCTAssertEqual(expected, FreedoomRelease.byteCount)

        model.cancel()
        await fulfillment(of: [finished], timeout: 10)
        XCTAssertEqual(model.state, .offered(failure: nil))
        XCTAssertNil(notices.current, "a cancel says nothing")
        // #555's Cancel ends the queue at once; the cancelled download
        // removes its partial file as it winds down, a moment later.
        let cleared = Date().addingTimeInterval(10)
        while !downloadedFiles().isEmpty, Date() < cleared {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(downloadedFiles(), [], "the cancelled download was left on disk")
        XCTAssertTrue(try library.allWADs().isEmpty)
    }

    /// One link download at a time: a pasted link's download blocks
    /// **Get**, and the tile's blocks a pasted link.
    func testOneLinkDownloadAtATime() async throws {
        let pasted = "https://files.example/big.wad"
        StubURLProtocol.set(.stall(headers: ["Content-Type": "application/octet-stream"],
                                   firstChunk: Data(repeating: 0x50, count: 16)), for: pasted)
        StubURLProtocol.set(.stall(headers: ["Content-Type": "application/zip"],
                                   firstChunk: Data(repeating: 0x50, count: 16)), for: link)
        let shared = linkImport()
        let model = getFreedoom(link: shared)

        let pastedEnded = expectation(description: "the pasted download ended")
        XCTAssertTrue(shared.start(pasted) { pastedEnded.fulfill() })
        XCTAssertTrue(model.isBlocked)
        XCTAssertEqual(model.state, .offered(failure: nil), "the pasted link's progress is not the tile's")
        XCTAssertFalse(model.get(), "Get started beside a pasted link's download")
        model.cancel()
        XCTAssertTrue(shared.isBusy, "the tile's Cancel stopped someone else's download")
        shared.cancel()
        await fulfillment(of: [pastedEnded], timeout: 10)

        let tileEnded = expectation(description: "the tile's download ended")
        XCTAssertTrue(model.get { tileEnded.fulfill() })
        XCTAssertFalse(model.isBlocked)
        XCTAssertFalse(shared.start(pasted), "a pasted link started beside the tile's download")
        model.cancel()
        await fulfillment(of: [tileEnded], timeout: 10)
    }

    /// A link dropped while the tile downloads waits in #555's queue
    /// behind it, never beside it; the tile's Cancel is the queue's, so it
    /// drops that link too, and the dropped link is never fetched.
    func testADroppedLinkQueuesBehindTheTileAndItsCancelIsTheQueues() async throws {
        let dropped = URL(string: "https://files.example/dropped.wad")!
        StubURLProtocol.set(.stall(headers: ["Content-Type": "application/zip"],
                                   firstChunk: Data(repeating: 0x50, count: 16)), for: link)
        let shared = linkImport()
        let model = getFreedoom(link: shared)
        let tileEnded = expectation(description: "the tile's download ended")
        XCTAssertTrue(model.get { tileEnded.fulfill() })
        shared.enqueue([dropped])
        XCTAssertEqual(shared.current, FreedoomRelease.url, "the dropped link started beside the tile's")
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if case .downloading = model.state, shared.position != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(shared.position, LinkImport.Position(index: 1, count: 2))
        XCTAssertEqual(shared.current, FreedoomRelease.url)

        model.cancel()
        await fulfillment(of: [tileEnded], timeout: 10)
        XCTAssertFalse(shared.isBusy)
        XCTAssertEqual(model.state, .offered(failure: nil))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(StubURLProtocol.requestedURLs.contains(dropped.absoluteString))
    }

    // MARK: Success

    /// With nothing bundled (a build after #505), the release's zip brings
    /// both games to the shelf under their names, each with its base game,
    /// and the tile goes. Phase 1 keeps the name the UI tests' identifier
    /// is built from.
    func testADownloadedFreedoomArrivesAsBothTitledGames() async throws {
        try shipWithoutFreedoom()
        try library.seedBundledContentIfNeeded()
        let zip = try freedoomLikeZip()
        serve(zip)
        let model = getFreedoom(sha256: Self.sha256(zip))
        await get(model)

        XCTAssertNil(model.link.lastFailure)
        XCTAssertEqual(model.state, .offered(failure: nil))
        let byFile = Dictionary(uniqueKeysWithValues: try library.allWADs().map { ($0.filename, $0) })
        XCTAssertEqual(byFile["freedoom1.wad"]?.displayName, "Freedoom Phase 1")
        XCTAssertEqual(byFile["freedoom2.wad"]?.displayName, "Freedoom Phase 2")
        let games = try library.shelfGames()
        XCTAssertTrue(games.allSatisfy(\.isBaseGame))
        XCTAssertEqual(Set(games.map(\.name)), ["Freedoom Phase 1", "Freedoom Phase 2"])
        XCTAssertFalse(try library.offersFreedoom(), "the tile stayed after Freedoom arrived")
        XCTAssertEqual(notices.current, "Added freedoom1, freedoom2", "the ordinary import banner")
    }

    /// A failure's reason clears once a download arrives.
    func testASuccessClearsTheLastFailure() async throws {
        try shipWithoutFreedoom()
        let zip = try freedoomLikeZip()
        let model = getFreedoom(sha256: Self.sha256(zip))
        StubURLProtocol.set(.fail(URLError(.notConnectedToInternet)), for: link)
        await get(model)
        XCTAssertEqual(model.state, .offered(failure: "You're offline"))

        serve(zip)
        await get(model)
        XCTAssertEqual(model.state, .offered(failure: nil))
    }

    /// An install seeded with bundled rows, then the bundle emptied (#503):
    /// the download restores the rows under their old ids, so each game
    /// keeps its saves.
    func testTheDownloadRestoresReleasedRowsUnderTheirIDs() async throws {
        library.bundledContentDirectory = FreedoomFixture.shippedRelease
        try library.seedBundledContentIfNeeded()
        let before = Dictionary(uniqueKeysWithValues: try library.allWADs().map { ($0.sha1, $0.id) })
        let phase1 = try XCTUnwrap(before[LibraryService.shippedFreedoomSHA1["freedoom1.wad"]!])
        let saves = LibraryService.savesDirectory(forGameID: phase1)
        try FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: saves) }
        try Data("save".utf8).write(to: saves.appendingPathComponent("woofsav0.dsg"))

        try shipWithoutFreedoom()
        try library.seedBundledContentIfNeeded()
        XCTAssertTrue(try library.offersFreedoom())

        let zip = try freedoomLikeZip()
        serve(zip)
        await get(getFreedoom(sha256: Self.sha256(zip)))

        let after = Dictionary(uniqueKeysWithValues: try library.allWADs().map { ($0.sha1, $0.id) })
        XCTAssertEqual(after, before, "a row was re-created under a fresh id")
        XCTAssertEqual(Set(try library.games().map(\.id)), Set(before.values))
        XCTAssertEqual(try library.game(id: phase1)?.name, "Freedoom Phase 1")
        XCTAssertEqual(library.saveSlots(forKey: phase1).map(\.id), ["woofsav0.dsg"])
        for wad in try library.allWADs() { XCTAssertEqual(library.fileStatus(for: wad), .imported) }
        XCTAssertFalse(try library.offersFreedoom())
    }

    // MARK: A Freedoom the player hid

    /// Seeds the bundled rows, hides `hidden` of the two games, then empties
    /// the bundle: the state #505 leaves a player who had hidden Freedoom.
    private func hideThenRelease(_ hidden: Set<String>) throws {
        library.bundledContentDirectory = FreedoomFixture.shippedRelease
        try library.seedBundledContentIfNeeded()
        for game in try library.games() where hidden.contains(game.name) { try library.hide(game) }
        try shipWithoutFreedoom()
        try library.seedBundledContentIfNeeded()
    }

    /// Hidden and released: no Freedoom file is there, so the tile offers
    /// it; hiding never decides the offer. Get then brings both games back
    /// to the shelf, rather than restoring them hidden, which would take
    /// the tile away and add nothing.
    func testAHiddenFreedoomWhoseRowsAreReleasedIsOfferedAndGetPutsItBackOnTheShelf() async throws {
        try hideThenRelease(["Freedoom Phase 1", "Freedoom Phase 2"])
        XCTAssertTrue(try library.shelfGames().isEmpty)
        XCTAssertTrue(try library.offersFreedoom(), "a hidden row whose file is gone took the offer away")

        let zip = try freedoomLikeZip()
        serve(zip)
        await get(getFreedoom(sha256: Self.sha256(zip)))

        XCTAssertEqual(Set(try library.shelfGames().map(\.name)), ["Freedoom Phase 1", "Freedoom Phase 2"])
        XCTAssertEqual(try library.hiddenGames().map(\.name), [])
        XCTAssertFalse(try library.offersFreedoom())
    }

    /// One hidden, both released: offered, and both arrive on the shelf.
    func testOneHiddenGameComesBackWithTheOtherAfterGet() async throws {
        try hideThenRelease(["Freedoom Phase 2"])
        XCTAssertTrue(try library.offersFreedoom())
        let zip = try freedoomLikeZip()
        serve(zip)
        await get(getFreedoom(sha256: Self.sha256(zip)))
        XCTAssertEqual(Set(try library.shelfGames().map(\.name)), ["Freedoom Phase 1", "Freedoom Phase 2"])
    }

    /// Only the tile's Get asks for Freedoom. The same zip from **From a
    /// Link…** restores the rows and leaves the player's hiding alone, as
    /// any import of a file they already had does; Hidden Games brings
    /// them back.
    func testAPastedLinkRestoresHiddenGamesStillHidden() async throws {
        try hideThenRelease(["Freedoom Phase 1", "Freedoom Phase 2"])
        let zip = try freedoomLikeZip()
        let other = "https://files.example/freedoom.zip"
        StubURLProtocol.set(.respond(status: 200, headers: ["Content-Type": "application/zip"], body: zip),
                            for: other)
        _ = await linkImport().run(URL(string: other)!)
        XCTAssertEqual(Set(try library.hiddenGames().map(\.name)), ["Freedoom Phase 1", "Freedoom Phase 2"])
        XCTAssertFalse(try library.offersFreedoom(), "Freedoom is there, in Hidden Games")
    }

    /// A game of the player's own built on Freedoom keeps the state they
    /// gave it: Get puts back only Freedoom's two base games.
    func testGetLeavesAHiddenGameBuiltOnFreedoomHidden() async throws {
        try hideThenRelease([])
        let phase1 = try XCTUnwrap(try library.games().first { $0.name == "Freedoom Phase 1" })
        let mod = try library.duplicate(phase1)
        try library.hide(mod)
        let zip = try freedoomLikeZip()
        serve(zip)
        await get(getFreedoom(sha256: Self.sha256(zip)))
        XCTAssertTrue(try XCTUnwrap(try library.game(id: mod.id)).isHidden)
    }

    // MARK: What the player is told

    /// The tile's banner never talks about a link: the player tapped Get.
    func testTheTilesFailureNoticesNameNoLink() {
        let errors: [LinkDownloadError] = [.notALink, .insecure, .offline, .unreachable, .httpStatus(404),
                                           .httpStatus(503), .tooLarge(limit: 1), .webPage,
                                           .refusedType("pk3"), .notAGameFile, .checksumMismatch,
                                           .failed("The network connection was lost.")]
        for error in errors {
            let message = GetFreedoom.bannerMessage(for: error)
            XCTAssertFalse(message.localizedCaseInsensitiveContains("link"), "\(error): \(message)")
            XCTAssertTrue(message.hasPrefix("Freedoom was not"), "\(error): \(message)")
        }
    }

    /// VoiceOver hears the download start and the games it added.
    func testVoiceOverHearsTheStartAndTheGamesAdded() async throws {
        try shipWithoutFreedoom()
        let zip = try freedoomLikeZip()
        serve(zip)
        let model = getFreedoom(sha256: Self.sha256(zip))
        let heard = Heard()
        model.announce = { heard.lines.append($0) }
        await get(model)
        XCTAssertEqual(heard.lines, ["Downloading Freedoom, 24.1 MB.",
                               "Freedoom added: Freedoom Phase 1 and Freedoom Phase 2."])
    }

    /// VoiceOver hears a failure with its reason, and a cancel.
    func testVoiceOverHearsAFailureWithItsReasonAndACancel() async throws {
        let model = getFreedoom()
        let heard = Heard()
        model.announce = { heard.lines.append($0) }
        StubURLProtocol.set(.fail(URLError(.notConnectedToInternet)), for: link)
        await get(model)
        XCTAssertEqual(heard.lines, ["Downloading Freedoom, 24.1 MB.", GetFreedoom.bannerMessage(for: .offline)])

        heard.lines = []
        StubURLProtocol.set(.stall(headers: ["Content-Type": "application/zip"],
                                   firstChunk: Data(repeating: 0x50, count: 16)), for: link)
        let finished = expectation(description: "the download ended")
        XCTAssertTrue(model.get { finished.fulfill() })
        model.cancel()
        await fulfillment(of: [finished], timeout: 10)
        XCTAssertEqual(heard.lines, ["Downloading Freedoom, 24.1 MB.", "Download cancelled."])
    }

    /// A failure that is not the network's (here the downloads folder
    /// cannot be made, because a file stands where it goes) is a failure:
    /// a banner and an announcement with its reason, never "Download
    /// cancelled." in silence.
    func testAFailureBeforeTheDownloadStartsIsSaidWithItsReason() async throws {
        let blocker = tmp.appendingPathComponent("blocker")
        try Data("a file, not a folder".utf8).write(to: blocker)
        var downloader = LinkDownloader()
        downloader.directory = blocker.appendingPathComponent("LinkDownloads", isDirectory: true)
        downloader.makeConfiguration = { StubURLProtocol.configuration() }
        let model = GetFreedoom(link: LinkImport(importer: importer, downloader: downloader, notices: notices),
                                library: library)
        let heard = Heard()
        model.announce = { heard.lines.append($0) }

        await get(model)

        guard case .failed(let description)? = model.link.lastFailure else {
            return XCTFail("not a failure: \(String(describing: model.link.lastFailure))")
        }
        XCTAssertFalse(description.isEmpty)
        XCTAssertEqual(model.state, .offered(failure: "Download failed"))
        XCTAssertEqual(notices.current, GetFreedoom.bannerMessage(for: .failed(description)))
        XCTAssertEqual(heard.lines, ["Downloading Freedoom, 24.1 MB.",
                                     GetFreedoom.bannerMessage(for: .failed(description))])
        XCTAssertEqual(StubURLProtocol.requestedURLs, [], "nothing was fetched")
    }

    /// The tile reads its name, that it is free and its size, whether or
    /// not the title line is drawn.
    func testTheTilesLabelReadsTheNameThatItIsFreeAndItsSize() {
        XCTAssertEqual(GetFreedoomTile.accessibilityLabel(for: .offered(failure: nil)), "Freedoom, free, 24.1 MB")
        XCTAssertEqual(GetFreedoomTile.accessibilityLabel(for: .offered(failure: "You're offline")),
                       "Freedoom, free, 24.1 MB")
        XCTAssertEqual(GetFreedoomTile.accessibilityLabel(for: .downloading(received: 10_150_000,
                                                                            expected: FreedoomRelease.byteCount)),
                       "Freedoom, downloading, 10.2 MB of 24.1 MB")
        XCTAssertEqual(GetFreedoomTile.accessibilityLabel(for: .importing), "Freedoom, adding to your library")
    }

    // MARK: Hide from Shelf on the tile

    /// Hidden, and no Freedoom: no tile, and Hidden Games lists it.
    func testAHiddenTileIsNotOfferedAndHiddenGamesListsIt() throws {
        try shipWithoutFreedoom()
        XCTAssertTrue(try library.offersFreedoom())
        library.hideGetFreedoom()
        XCTAssertFalse(try library.offersFreedoom())
        XCTAssertTrue(try library.hiddenGamesListsGetFreedoom())
        XCTAssertFalse(Shelf.offersFreedoom(files: [], isPresent: { _ in false }, tileHidden: true))
    }

    /// Restore in Hidden Games brings it back.
    func testRestoringTheTileBringsItBack() throws {
        try shipWithoutFreedoom()
        library.hideGetFreedoom()
        library.restoreGetFreedoom()
        XCTAssertTrue(try library.offersFreedoom())
        XCTAssertFalse(try library.hiddenGamesListsGetFreedoom())
    }

    /// The choice is kept across launches: a new library on the same
    /// defaults still has the tile hidden.
    func testTheChoiceSurvivesARelaunch() throws {
        try shipWithoutFreedoom()
        library.hideGetFreedoom()
        let relaunched = LibraryService(context: context, store: WADStore(directory: storeDir))
        relaunched.defaults = defaults
        relaunched.bundledContentDirectory = library.bundledContentDirectory
        XCTAssertTrue(relaunched.isGetFreedoomHidden)
        XCTAssertFalse(try relaunched.offersFreedoom())
    }

    /// A fresh install has hidden nothing.
    func testAFreshInstallOffersTheTile() throws {
        try shipWithoutFreedoom()
        XCTAssertFalse(library.isGetFreedoomHidden)
        XCTAssertNil(defaults.object(forKey: LibraryService.getFreedoomHiddenKey))
        XCTAssertTrue(try library.offersFreedoom())
    }

    /// Hiding the tile hides only the offer. A Freedoom the player then
    /// brings another way, from a link here, is on the shelf as any import
    /// is, and Hidden Games does not list the tile while Freedoom is there.
    func testHidingTheTileHidesNoFreedoomThatArrivesAnotherWay() async throws {
        try shipWithoutFreedoom()
        library.hideGetFreedoom()
        let zip = try freedoomLikeZip()
        let other = "https://files.example/freedoom.zip"
        StubURLProtocol.set(.respond(status: 200, headers: ["Content-Type": "application/zip"], body: zip),
                            for: other)
        _ = await linkImport().run(URL(string: other)!)
        XCTAssertEqual(Set(try library.shelfGames().map(\.name)), ["Freedoom Phase 1", "Freedoom Phase 2"])
        XCTAssertEqual(try library.hiddenGames().map(\.name), [])
        XCTAssertFalse(try library.hiddenGamesListsGetFreedoom(), "Restore would bring back nothing")
    }

    /// With the last round's rule: a Freedoom the player hid, whose rows
    /// are released, is offered unless the tile is hidden too. Then Hidden
    /// Games lists the tile beside the two games; restoring the tile offers
    /// Get, and Get puts both games back on the shelf.
    func testAHiddenTileAndAHiddenReleasedFreedoom() async throws {
        try hideThenRelease(["Freedoom Phase 1", "Freedoom Phase 2"])
        library.hideGetFreedoom()
        XCTAssertFalse(try library.offersFreedoom())
        XCTAssertTrue(try library.hiddenGamesListsGetFreedoom())
        XCTAssertEqual(try library.hiddenGames().count, 2)

        library.restoreGetFreedoom()
        XCTAssertTrue(try library.offersFreedoom())
        let zip = try freedoomLikeZip()
        serve(zip)
        await get(getFreedoom(sha256: Self.sha256(zip)))
        XCTAssertEqual(Set(try library.shelfGames().map(\.name)), ["Freedoom Phase 1", "Freedoom Phase 2"])
        XCTAssertFalse(try library.offersFreedoom())
    }

}

/// What a test heard VoiceOver told.
@MainActor
private final class Heard {
    var lines: [String] = []
}
