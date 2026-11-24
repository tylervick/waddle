import CryptoKit
import Foundation
import SwiftData
import XCTest
import ZIPFoundation
@testable import Waddle

/// Sources (#502): the shipped Freedoom source, its pin, the player's own
/// sources, and what a downloaded Freedoom becomes in the library. Every
/// download is answered by `StubURLProtocol`; nothing here touches the
/// network.
@MainActor
final class SourcesTests: XCTestCase {
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
        notices = ImportNotices()
        importer = ImportService(library: library, store: store, notices: notices,
                                 usage: UsageStore(directory: tmp.appendingPathComponent("Diagnostics",
                                                                                         isDirectory: true)))
        suiteName = "SourcesTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        StubURLProtocol.reset()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmp)
    }

    private func linkImport() -> LinkImport {
        var downloader = LinkDownloader()
        downloader.directory = downloadsDir
        downloader.makeConfiguration = { StubURLProtocol.configuration() }
        return LinkImport(importer: importer, downloader: downloader, notices: notices)
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

    /// The real Freedoom 0.13.0 WADs: these tests' subject is those exact
    /// bytes (their hashes name them), which `FreedoomFixture`'s stand-ins
    /// cannot match, so they read `FreedoomFixture.shippedRelease`.
    private func bundledFreedoom(_ filename: String) throws -> Data {
        try Data(contentsOf: FreedoomFixture.shippedRelease.appendingPathComponent(filename),
                 options: .mappedIfSafe)
    }

    /// A zip laid out as the Freedoom release is: the WADs in a
    /// `freedoom-0.13.0/` folder beside documents the import ignores.
    private func freedoomLikeZip() throws -> Data {
        let zipURL = tmp.appendingPathComponent(UUID().uuidString + ".zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        let members: [(String, Data)] = [
            ("freedoom-0.13.0/COPYING.txt", Data("BSD".utf8)),
            ("freedoom-0.13.0/freedoom1.wad", try bundledFreedoom("freedoom1.wad")),
            ("freedoom-0.13.0/freedoom2.wad", try bundledFreedoom("freedoom2.wad")),
        ]
        for (path, data) in members {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                                 provider: { pos, size in data.subdata(in: Int(pos)..<Int(pos) + size) })
        }
        let data = try Data(contentsOf: zipURL)
        try FileManager.default.removeItem(at: zipURL)
        return data
    }

    // MARK: The shipped source

    /// Spelled out, not read back from `Source.freedoom`: the link is the
    /// release the owner chose, and the hash is the one that release's
    /// signed `freedoom-0.13.0-CHECKSUM` lists for the zip.
    func testTheFreedoomSourceIsThePinnedRelease() {
        XCTAssertEqual(Source.freedoom.url.absoluteString,
                       "https://github.com/freedoom/freedoom/releases/download/v0.13.0/freedoom-0.13.0.zip")
        XCTAssertEqual(Source.freedoom.sha256,
                       "3f9b264f3e3ce503b4fb7f6bdcb1f419d93c7b546f4df3e874dd878db9688f59")
        XCTAssertEqual(Source.freedoom.kind, .file)
        XCTAssertEqual(Source.freedoom.name, "Freedoom")
        XCTAssertEqual(Source.freedoom.byteCount, 24_143_781, "the release zip's size, shown before the tap")
        XCTAssertTrue(Source.freedoom.isShipped)
    }

    func testAFreshInstallHasTheFreedoomSource() {
        let store = SourceStore(defaults: defaults)
        XCTAssertEqual(store.sources, [Source.freedoom])
        XCTAssertEqual(store.deletedShipped, [])
    }

    // MARK: The pin

    /// The pin accepts exactly its bytes: the right file imports, and the
    /// same file with one byte flipped is refused, says why, and leaves the
    /// library and the disk as they were. The flipped file is still a valid
    /// WAD (the byte pads a lump's name), and imports when nothing is
    /// pinned, so only the pin refuses it.
    func testThePinAcceptsTheRightBytesAndRefusesOneFlippedByte() async throws {
        let good = makeWAD(magic: "PWAD", lumps: ["MAP01", "THINGS"])
        var flipped = good
        flipped[flipped.count - 1] ^= 0x01   // the padding after "THINGS"
        XCTAssertNotEqual(good, flipped)
        let link = "https://files.example/pinned.wad"
        let source = Source(name: "Pinned", url: URL(string: link)!, kind: .file,
                            sha256: Self.sha256(good))

        StubURLProtocol.set(.respond(status: 200, headers: ["Content-Type": "application/octet-stream"],
                                     body: flipped), for: link)
        let refused = await linkImport().run(source.url, expectedSHA256: source.sha256)
        XCTAssertNil(refused)
        XCTAssertEqual(notices.current, "Import failed: \(LinkDownloadError.checksumMismatch.reason)")
        XCTAssertTrue(try library.allWADs().isEmpty, "a mismatched file reached the library")
        XCTAssertEqual(storedFiles(), [])
        XCTAssertEqual(downloadedFiles(), [], "the refused download was left on disk")

        StubURLProtocol.set(.respond(status: 200, headers: ["Content-Type": "application/octet-stream"],
                                     body: good), for: link)
        let accepted = await linkImport().run(source.url, expectedSHA256: source.sha256)
        XCTAssertEqual(accepted?.imported, ["pinned"])
        XCTAssertEqual(try library.allWADs().count, 1)

        // Unpinned, the flipped bytes are an ordinary valid WAD.
        let other = "https://files.example/unpinned.wad"
        StubURLProtocol.set(.respond(status: 200, headers: ["Content-Type": "application/octet-stream"],
                                     body: flipped), for: other)
        let unpinned = await linkImport().run(URL(string: other)!)
        XCTAssertEqual(unpinned?.imported, ["unpinned"])
    }

    /// The pin through the entry point the sheet uses (`start(Source)`), not
    /// only `run(_:expectedSHA256:)`: a tap on a pinned source whose bytes
    /// do not match is refused. Passing the source's pin on is the line
    /// under test; drop it and the mismatched file imports.
    func testTappingAPinnedSourceRefusesBytesThatDoNotMatch() async throws {
        let link = "https://files.example/tapped.wad"
        let pinned = makeWAD(magic: "PWAD", lumps: ["MAP01", "THINGS"])
        var other = pinned
        other[other.count - 1] ^= 0x01
        StubURLProtocol.set(.respond(status: 200, headers: ["Content-Type": "application/octet-stream"],
                                     body: other), for: link)
        let source = Source(name: "Pinned", url: URL(string: link)!, kind: .file,
                            sha256: Self.sha256(pinned))
        let model = linkImport()
        let finished = expectation(description: "the tapped download ended")

        XCTAssertTrue(model.start(source) { finished.fulfill() })
        await fulfillment(of: [finished], timeout: 10)

        XCTAssertEqual(notices.current, "Import failed: \(LinkDownloadError.checksumMismatch.reason)")
        XCTAssertTrue(try library.allWADs().isEmpty, "a tap imported bytes the pin refuses")
        XCTAssertEqual(storedFiles(), [])
        XCTAssertEqual(downloadedFiles(), [])
    }

    /// Offline and a server error each leave the library unchanged and say
    /// why, for a source as for a pasted link.
    func testASourceThatCannotBeReachedLeavesTheLibraryUnchanged() async throws {
        StubURLProtocol.set(.fail(URLError(.notConnectedToInternet)), for: Source.freedoom.url.absoluteString)
        let model = linkImport()
        let offline = await model.run(Source.freedoom.url, expectedSHA256: Source.freedoom.sha256)
        XCTAssertNil(offline)
        XCTAssertEqual(notices.current, "Import failed: \(LinkDownloadError.offline.reason)")

        StubURLProtocol.set(.respond(status: 503, headers: ["Content-Type": "text/html"],
                                     body: Data("<html>busy</html>".utf8)),
                            for: Source.freedoom.url.absoluteString)
        let failed = await model.run(Source.freedoom.url, expectedSHA256: Source.freedoom.sha256)
        XCTAssertNil(failed)
        XCTAssertEqual(notices.current, "Import failed: \(LinkDownloadError.httpStatus(503).reason)")

        XCTAssertTrue(try library.allWADs().isEmpty)
        XCTAssertEqual(storedFiles(), [])
        XCTAssertEqual(downloadedFiles(), [])
    }

    // MARK: What a downloaded Freedoom becomes

    /// With nothing bundled (a build after #505), the release's zip brings
    /// both games to the shelf under their names, each with its base game.
    func testADownloadedFreedoomArrivesAsBothGames() async throws {
        library.bundledContentDirectory = tmp.appendingPathComponent("NoBundle", isDirectory: true)
        try library.seedBundledContentIfNeeded()
        let zip = try freedoomLikeZip()
        StubURLProtocol.set(.respond(status: 200, headers: ["Content-Type": "application/zip"], body: zip),
                            for: Source.freedoom.url.absoluteString)

        let outcome = await linkImport().run(Source.freedoom.url, expectedSHA256: Self.sha256(zip))

        XCTAssertEqual(Set(outcome?.games ?? []), ["freedoom1", "freedoom2"])
        XCTAssertEqual(outcome?.rejected, [:], "the documents in the zip are ignored, not failures")
        let byFile = Dictionary(uniqueKeysWithValues: try library.allWADs().map { ($0.filename, $0) })
        XCTAssertEqual(byFile["freedoom1.wad"]?.displayName, "Freedoom Phase 1")
        XCTAssertEqual(byFile["freedoom2.wad"]?.displayName, "Freedoom Phase 2")
        let names = Set(try library.shelfGames().filter(\.isBaseGame).map(\.name))
        XCTAssertEqual(names, ["Freedoom Phase 1", "Freedoom Phase 2"])
    }

    /// While Freedoom is still bundled, downloading it adds no second copy:
    /// both WADs are reported as already in the library.
    func testDownloadingFreedoomWhileItIsBundledAddsNoSecondCopy() async throws {
        library.bundledContentDirectory = FreedoomFixture.shippedRelease
        try library.seedBundledContentIfNeeded()
        let before = try library.allWADs().count
        XCTAssertEqual(before, 2, "the test host should bundle both Freedoom WADs")
        let zip = try freedoomLikeZip()
        StubURLProtocol.set(.respond(status: 200, headers: ["Content-Type": "application/zip"], body: zip),
                            for: Source.freedoom.url.absoluteString)

        let outcome = await linkImport().run(Source.freedoom.url, expectedSHA256: Self.sha256(zip))

        XCTAssertEqual(Set(outcome?.duplicates ?? []), ["freedoom1", "freedoom2"])
        XCTAssertEqual(outcome?.imported, [])
        XCTAssertEqual(try library.allWADs().count, before)
        XCTAssertEqual(try library.games().count, 2)
        XCTAssertEqual(storedFiles(), [], "a second copy reached the store")
        XCTAssertEqual(notices.current, "2 already in library")
    }

    // MARK: The player's sources

    func testAddedSourcesPersistAcrossLaunches() throws {
        let store = SourceStore(defaults: defaults)
        let added = try store.add(name: "  My Megawad ", link: " https://files.example/mega.zip\n").get()
        XCTAssertEqual(added.name, "My Megawad")
        XCTAssertEqual(added.kind, .file)
        XCTAssertNil(added.sha256, "a player's source has no known hash")

        let relaunched = SourceStore(defaults: defaults)
        XCTAssertEqual(relaunched.sources, [Source.freedoom, added])
    }

    func testABlankNameFallsBackToTheHost() throws {
        let added = try SourceStore(defaults: defaults).add(name: " ", link: "https://files.example/a.wad").get()
        XCTAssertEqual(added.name, "files.example")
    }

    func testALinkWaddleWouldNotDownloadIsNotAdded() {
        let store = SourceStore(defaults: defaults)
        XCTAssertEqual(store.add(name: "Plain", link: "http://files.example/a.wad").map(\.name), .failure(.insecure))
        XCTAssertEqual(store.add(name: "Nothing", link: "not a link").map(\.name), .failure(.notALink))
        XCTAssertEqual(SourceStore(defaults: defaults).sources, [Source.freedoom])
    }

    func testADeletedOwnSourceIsGone() throws {
        let store = SourceStore(defaults: defaults)
        let added = try store.add(name: "Mine", link: "https://files.example/a.wad").get()
        store.delete(added)
        XCTAssertEqual(store.sources, [Source.freedoom])
        XCTAssertEqual(store.deletedShipped, [], "only shipped sources can be restored")
        XCTAssertEqual(SourceStore(defaults: defaults).sources, [Source.freedoom])
    }

    /// A deleted example comes back with Restore, across launches.
    func testADeletedExampleComesBackWithRestore() {
        let store = SourceStore(defaults: defaults)
        store.delete(.freedoom)
        XCTAssertEqual(store.sources, [])
        XCTAssertEqual(store.deletedShipped, [.freedoom])

        let relaunched = SourceStore(defaults: defaults)
        XCTAssertEqual(relaunched.sources, [], "a deleted example came back on its own")
        relaunched.restore(.freedoom)
        XCTAssertEqual(relaunched.sources, [.freedoom])
        XCTAssertEqual(SourceStore(defaults: defaults).sources, [.freedoom])
        XCTAssertNil(defaults.data(forKey: SourceStore.userDefaultsKey),
                     "back to the shipped state, nothing should be stored")
    }

    func testUnreadableStoredSourcesReadAsAFreshInstall() {
        defaults.set(Data("not json".utf8), forKey: SourceStore.userDefaultsKey)
        XCTAssertEqual(SourceStore(defaults: defaults).sources, [Source.freedoom])
    }

    /// A page source needs #501's web view: it never starts a download.
    func testAPageSourceNeverStartsADownload() {
        let page = Source(name: "Freedoom page", url: URL(string: "https://freedoom.github.io/download.html")!,
                          kind: .page)
        XCTAssertFalse(linkImport().start(page))
        XCTAssertEqual(StubURLProtocol.requestedURLs, [])
    }
}
